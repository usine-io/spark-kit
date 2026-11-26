#!/usr/bin/env bash
# deploy/scripts/restore-test.sh — test de restauration dans un Postgres jetable.
#
# Usage : restore-test.sh [chemin/pg_dumpall-*.sql.gz]    (defaut : le plus recent de infra/backups/)
#
# Un backup non teste n'est pas un backup. Le script :
#   1. demarre un Postgres jetable avec la MEME image (tag + digest) que la stack ;
#   2. y rejoue le dump avec ON_ERROR_STOP=0 et compte les ERROR (seule « role "postgres"
#      already exists » est attendue) ;
#   3. verifie la presence des bases n8n et nocodb, compte les tables et les migrations n8n ;
#   4. demarre un n8n jetable (meme image) sur la copie, avec la N8N_ENCRYPTION_KEY du .env, et
#      exporte les identifiants dechiffres : au moins un doit se dechiffrer. Seuls des COMPTES
#      sont affiches, jamais le contenu ;
#   5. supprime tout (conteneurs, reseau), ecrit infra/backups/RESTORE_TEST_OK (horodatage).
# Sortie 0 si tout passe, 2 sinon (alerte vers SPARK_ALERT_WEBHOOK si defini).
# RESTORE_TEST_REQUIRE_CREDENTIAL=1 rend l'absence d'identifiant n8n fatale (base vide = avertissement sinon).
# Ne touche jamais a la stack en production : tout se passe dans des conteneurs et un reseau dedies.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

INFRA_DIR="$(spark_infra_dir "$SCRIPT_DIR")"
cd "$INFRA_DIR"
spark_load_env ./.env N8N_DB_PASSWORD N8N_ENCRYPTION_KEY
BACKUP_DIR="${SPARK_BACKUP_DIR:-$INFRA_DIR/backups}"

dump="${1:-}"
if [ -z "$dump" ]; then
  dump="$(find "$BACKUP_DIR" -maxdepth 1 -name 'pg_dumpall-*.sql.gz' -print 2>/dev/null | sort | tail -1)"
fi
if [ -z "$dump" ] || [ ! -f "$dump" ]; then spark_die "aucun dump pg_dumpall-*.sql.gz dans $BACKUP_DIR (lancer backup.sh)"; fi

PROJECT="$(spark_project_name)"
pg_cid="$(spark_compose ps -q postgres)"; [ -n "$pg_cid" ] || spark_die "postgres ne tourne pas"
n8n_cid="$(spark_compose ps -q n8n)";     [ -n "$n8n_cid" ] || spark_die "n8n ne tourne pas"
PG_IMAGE="$(docker inspect --format '{{.Config.Image}}' "$pg_cid")"
N8N_IMAGE="$(docker inspect --format '{{.Config.Image}}' "$n8n_cid")"

NET="${PROJECT}-restore-test"
PG="${PROJECT}-restore-test-pg"
status=2
log="$(mktemp)"
cleanup() {
  rc=$?
  docker rm -f "$PG" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  rm -f "$log"
  if [ "$status" -ne 0 ]; then
    spark_alert "restore-test.sh" "test de restauration de $(basename "$dump") en echec (code $rc)"
    exit 2
  fi
}
trap cleanup EXIT

spark_log "dump : $dump"
spark_log "images : $PG_IMAGE / $N8N_IMAGE"

# 1. Postgres jetable ----------------------------------------------------------------------
docker rm -f "$PG" >/dev/null 2>&1 || true
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
# --entrypoint sh : l'entrypoint de l'image prefixe tout argument par `n8n`. Le fichier exporte
# reste dans le conteneur ephemere ; seul node en lit le nombre d'entrees.
counts="$(docker run --rm --network "$NET" --entrypoint sh \
  -e DB_TYPE=postgresdb -e DB_POSTGRESDB_HOST="$PG" -e DB_POSTGRESDB_PORT=5432 \
  -e DB_POSTGRESDB_DATABASE=n8n -e DB_POSTGRESDB_USER=n8n -e DB_POSTGRESDB_PASSWORD="$N8N_DB_PASSWORD" \
  -e N8N_ENCRYPTION_KEY="$N8N_ENCRYPTION_KEY" -e N8N_DIAGNOSTICS_ENABLED=false \
  -e N8N_LOG_LEVEL=error \
  "$N8N_IMAGE" -c '
    n8n export:credentials --all --decrypted --output=/tmp/creds.json >/tmp/n8n.log 2>&1 \
      || { tail -5 /tmp/n8n.log >&2; exit 3; }
    node -e "const c=require(\"/tmp/creds.json\");
      const ok=c.filter(x=>x.data&&typeof x.data===\"object\"&&Object.keys(x.data).length>0).length;
      console.log(c.length+\" \"+ok)"
  ')" || spark_die "n8n n'a pas pu exporter les identifiants (cle N8N_ENCRYPTION_KEY ou base)"
total="${counts%% *}"; decrypted="${counts##* }"
if [ "$total" -eq 0 ]; then
  if [ "${RESTORE_TEST_REQUIRE_CREDENTIAL:-0}" = "1" ]; then
    spark_die "aucun identifiant n8n dans la base : le controle de dechiffrement n'a rien a verifier"
  fi
  spark_log "AVERTISSEMENT : aucun identifiant n8n dans la base, dechiffrement non verifie (creer un identifiant de test)"
else
  [ "$decrypted" -ge 1 ] || spark_die "$total identifiant(s), aucun dechiffre"
  spark_log "identifiants n8n : $total exporte(s), $decrypted dechiffre(s)"
fi

date '+%Y-%m-%dT%H:%M:%S' > "$BACKUP_DIR/RESTORE_TEST_OK"
status=0
spark_log "test de restauration OK ($(basename "$dump"))"
