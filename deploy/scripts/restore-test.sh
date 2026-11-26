#!/usr/bin/env bash
# deploy/scripts/restore-test.sh — test de restauration dans un Postgres jetable.
#
# Usage : restore-test.sh [chemin/pg_dumpall-*.sql.gz]    (defaut : le plus recent de infra/backups/)
#   Un chemin explicite qui n'existe pas : « ERREUR: dump <chemin> introuvable », code 2, aucun repli
#   sur le dump le plus recent.
#
# Le dechiffrement des identifiants n8n (etape 4) utilise la N8N_ENCRYPTION_KEY du .env COURANT
# de infra/, pas celle contenue dans l'archive secrets-*.tar.age du meme jeu : le test prouve que
# la cle en service lit la base sauvegardee, pas que l'archive est lisible (verification de
# l'archive avec la cle privee age hors machine : guide Linux, etape 3.b).
#
# Un backup non teste n'est pas un backup. Le script :
#   0. refuse un dump illisible ou tronque (derniere ligne « PostgreSQL database cluster dump
#      complete » absente) ;
#   1. demarre un Postgres jetable avec la MEME image (tag + digest) que celle du compose.yml
#      (lue par `docker compose config`, la stack n'a pas besoin de tourner) ;
#   2. y rejoue le dump avec ON_ERROR_STOP=0 et compte les ERROR (seule « role "postgres"
#      already exists » est attendue) ;
#   3. verifie la presence des bases n8n et nocodb, compte les tables et les migrations n8n ;
#   4. compte les identifiants n8n dans la copie (SQL). S'il y en a, demarre un n8n jetable (meme
#      image) sur la copie, avec la N8N_ENCRYPTION_KEY du .env, et exporte les identifiants
#      dechiffres : au moins un doit se dechiffrer. Seuls des COMPTES sont affiches, jamais le contenu.
#      Base sans identifiant : AVERTISSEMENT et succes (avant le premier acces n8n, il n'y a rien a
#      dechiffrer), sauf si RESTORE_TEST_REQUIRE_CREDENTIAL=1 (variable d'environnement ou .env),
#      a poser en production des qu'un identifiant n8n existe : l'absence devient alors fatale ;
#   5. supprime tout (conteneurs ET leur volume anonyme : `docker rm -v`, reseau), ecrit
#      infra/backups/RESTORE_TEST_OK (horodatage). Le nombre de volumes Docker est le meme avant et apres.
# Sortie 0 si tout passe, 2 sinon : ligne ALERTE sur stderr (journal du timer) et POST a SPARK_ALERT_WEBHOOK
# s'il est defini, avec la derniere ligne ERREUR — y compris quand le script s'arrete avant d'avoir
# commence (.env absent, variable manquante). Une seule execution a la fois (verrou
# backups/.lock-restore-test) : un deuxieme lancement sort en code 2 avec un message clair, sans alerter.
# Ne touche jamais a la stack en production : tout se passe dans des conteneurs et un reseau dedies.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"
# Alerte des la premiere ERREUR (.env absent, variable manquante...) : voir SPARK_ALERT_SCRIPT dans lib.sh.
SPARK_ALERT_SCRIPT="restore-test.sh"

INFRA_DIR="$(spark_infra_dir "$SCRIPT_DIR")"
cd "$INFRA_DIR"
# spark_load_env : une variable deja posee (ligne de commande, Environment= systemd) l'emporte sur le .env.
spark_load_env ./.env N8N_DB_PASSWORD N8N_ENCRYPTION_KEY
require_credential="${RESTORE_TEST_REQUIRE_CREDENTIAL:-0}"
BACKUP_DIR="${SPARK_BACKUP_DIR:-$INFRA_DIR/backups}"
mkdir -p "$BACKUP_DIR"
spark_lock "$BACKUP_DIR/.lock-restore-test" "restore-test.sh"

dump="${1:-}"
if [ -n "$dump" ]; then
  # Chemin explicite : il doit exister tel quel (pas de repli silencieux sur le plus recent).
  [ -f "$dump" ] || spark_die "dump $dump introuvable"
else
  dump="$(find "$BACKUP_DIR" -maxdepth 1 -name 'pg_dumpall-*.sql.gz' -print 2>/dev/null | sort | tail -1)"
  if [ -z "$dump" ] || [ ! -f "$dump" ]; then spark_die "aucun dump pg_dumpall-*.sql.gz dans $BACKUP_DIR (lancer backup.sh)"; fi
fi

PROJECT="$(spark_project_name)"
PG_IMAGE="$(spark_service_image postgres 'postgres')"
N8N_IMAGE="$(spark_service_image n8n 'n8nio/n8n')"

NET="${PROJECT}-restore-test"
PG="${PROJECT}-restore-test-pg"
status=2
log="$(mktemp)"
cleanup() {
  rc=$?
  # -v : emporte le volume ANONYME que l'image postgres declare pour /var/lib/postgresql/data.
  # Sans lui, chaque execution laissait une copie complete du cluster sur le disque.
  docker rm -f -v "$PG" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  rm -f "$log"
  if [ "$status" -ne 0 ]; then
    spark_alert "restore-test.sh" "test de restauration de $(basename "$dump") en echec (code $rc)"
    spark_unlock
    exit 2
  fi
  spark_unlock
}
trap cleanup EXIT
SPARK_ALERT_TRAP=1   # a partir d'ici, c'est cleanup qui alerte (spark_die ne double pas)

spark_log "dump : $dump"
# Dump complet ? Meme controle que backup.sh : gzip lisible et derniere ligne de pg_dumpall presente.
# Un dump tronque (coupure pendant la sauvegarde, copie partielle) est rejete avant tout rejeu.
gzip -t "$dump" 2>/dev/null || spark_die "dump $dump illisible (gzip -t)"
last="$(gzip -dc "$dump" | tail -n 3 | tr '\n' ' ')"
case "$last" in
  *"PostgreSQL database cluster dump complete"*) ;;
  *) spark_die "dump $(basename "$dump") tronque : la ligne « PostgreSQL database cluster dump complete » manque (le contenu n'est pas affiche)" ;;
esac
spark_log "images : $PG_IMAGE / $N8N_IMAGE"

# 1. Postgres jetable ----------------------------------------------------------------------
docker rm -f -v "$PG" >/dev/null 2>&1 || true
docker network rm "$NET" >/dev/null 2>&1 || true
docker network create "$NET" >/dev/null
docker run -d --name "$PG" --network "$NET" -e POSTGRES_PASSWORD=restore-test "$PG_IMAGE" >/dev/null
for _ in $(seq 1 60); do
  docker exec "$PG" pg_isready -U postgres -q >/dev/null 2>&1 && break
  sleep 1
done
docker exec "$PG" pg_isready -U postgres -q || spark_die "le Postgres jetable ne repond pas"

# 2. Rejeu du dump ----------------------------------------------------------------------
gzip -dc "$dump" | docker exec -i "$PG" psql -U postgres -q -v ON_ERROR_STOP=0 > "$log" 2>&1 || true
errors="$(grep -c '^ERROR' "$log" || true)"
expected="$(grep -c 'role "postgres" already exists' "$log" || true)"
if [ "$errors" -ne "$expected" ]; then
  grep '^ERROR' "$log" | grep -v 'role "postgres" already exists' | head -5 >&2
  spark_die "$((errors - expected)) erreur(s) inattendue(s) a la restauration"
fi
spark_log "restauration rejouee : $errors erreur(s), toutes attendues"

# 3. Comptes ----------------------------------------------------------------------------
psql_q() { docker exec "$PG" psql -U postgres -At -d "$1" -c "$2"; }
dbs="$(psql_q postgres "SELECT string_agg(datname, ' ' ORDER BY datname) FROM pg_database WHERE NOT datistemplate")"
for db in n8n nocodb; do
  case " $dbs " in *" $db "*) ;; *) spark_die "base $db absente de la copie (bases : $dbs)" ;; esac
done
n8n_tables="$(psql_q n8n "SELECT count(*) FROM information_schema.tables WHERE table_schema='public'")"
n8n_migrations="$(psql_q n8n "SELECT count(*) FROM migrations")"
if [ "$n8n_tables" -le 0 ] || [ "$n8n_migrations" -le 0 ]; then spark_die "base n8n vide ($n8n_tables tables, $n8n_migrations migrations)"; fi
spark_log "bases : $dbs ; n8n : $n8n_tables tables, $n8n_migrations migrations"

# 4. Dechiffrement d'un identifiant n8n ---------------------------------------------------
# Compte SQL d'abord : `n8n export:credentials` sort en erreur (« No credentials found ») sur une
# base sans identifiant, ce qui n'est pas un defaut de la sauvegarde. Le compte decide.
cred_total="$(psql_q n8n "SELECT count(*) FROM credentials_entity")"
case "$cred_total" in ''|*[!0-9]*) spark_die "compte des identifiants n8n illisible (« $cred_total »)" ;; esac
if [ "$cred_total" -eq 0 ]; then
  if [ "$require_credential" = "1" ]; then
    spark_die "aucun identifiant n8n dans la base (RESTORE_TEST_REQUIRE_CREDENTIAL=1) : le controle de dechiffrement n'a rien a verifier"
  fi
  spark_log "AVERTISSEMENT : aucun identifiant n8n dans la base, dechiffrement non verifie (creer un identifiant dans n8n, puis poser RESTORE_TEST_REQUIRE_CREDENTIAL=1)"
else
  # --entrypoint sh : l'entrypoint de l'image prefixe tout argument par `n8n`. Le fichier exporte
  # reste dans le conteneur ephemere ; seul node en lit le nombre d'entrees. Les secrets passent
  # par `-e NOM` sans valeur (lus dans l'environnement, jamais sur la ligne de commande).
  counts="$(DB_POSTGRESDB_PASSWORD="$N8N_DB_PASSWORD" docker run --rm --network "$NET" --entrypoint sh \
    -e DB_TYPE=postgresdb -e DB_POSTGRESDB_HOST="$PG" -e DB_POSTGRESDB_PORT=5432 \
    -e DB_POSTGRESDB_DATABASE=n8n -e DB_POSTGRESDB_USER=n8n \
    -e DB_POSTGRESDB_PASSWORD -e N8N_ENCRYPTION_KEY \
    -e N8N_DIAGNOSTICS_ENABLED=false -e N8N_LOG_LEVEL=error \
    "$N8N_IMAGE" -c '
      n8n export:credentials --all --decrypted --output=/tmp/creds.json >/tmp/n8n.log 2>&1 \
        || { tail -5 /tmp/n8n.log >&2; exit 3; }
      node -e "const c=require(\"/tmp/creds.json\");
        const ok=c.filter(x=>x.data&&typeof x.data===\"object\"&&Object.keys(x.data).length>0).length;
        console.log(c.length+\" \"+ok)"
    ')" || spark_die "n8n n'a pas pu exporter les $cred_total identifiant(s) (cle N8N_ENCRYPTION_KEY ou base)"
  total="${counts%% *}"; decrypted="${counts##* }"
  [ "$total" -eq "$cred_total" ] || spark_die "$cred_total identifiant(s) en base, $total exporte(s)"
  [ "$decrypted" -ge 1 ] || spark_die "$total identifiant(s), aucun dechiffre"
  spark_log "identifiants n8n : $total exporte(s), $decrypted dechiffre(s)"
fi

date '+%Y-%m-%dT%H:%M:%S' > "$BACKUP_DIR/RESTORE_TEST_OK"
status=0
spark_log "test de restauration OK ($(basename "$dump"))"
