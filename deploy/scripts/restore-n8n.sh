#!/usr/bin/env bash
# deploy/scripts/restore-n8n.sh — restaure la base n8n ET son volume depuis un jeu de sauvegarde.
#
# Usage : restore-n8n.sh <stamp> [--confirm] [--expect-migrations N]
#   <stamp>  horodatage d'un jeu produit par backup.sh : backups/pg_dumpall-<stamp>.sql.gz et
#            backups/vol-n8n_data-<stamp>.tgz doivent exister.
#   Sans --confirm : affiche ce qui serait fait et sort en 0, sans rien toucher.
#   --expect-migrations N : apres redemarrage, `SELECT count(*) FROM migrations` doit valoir N
#            (le releve « avant » de n8n-releve.sh) ; sinon code 2.
#
# C'est le retour arriere de la fiche n8n d'UPGRADES.md : JAMAIS un simple changement de tag (une
# version plus ancienne demarre sans rien dire sur une base migree). Ordre :
#   1. `docker compose stop n8n` (et runners s'il tourne) ;
#   2. extraction de la section de la base n8n du pg_dumpall (de `\connect n8n` a la base suivante) :
#      le dump complet n'est PAS rejoue sur un cluster vivant, il dupliquerait les lignes des autres
#      bases ;
#   3. DROP DATABASE n8n WITH (FORCE) ; CREATE DATABASE n8n OWNER n8n ; rejeu de la section avec
#      ON_ERROR_STOP=1 (zero erreur toleree) ;
#   4. volume n8n_data vide puis restaure depuis le tar (cle de chiffrement, donnees binaires) ;
#   5. `docker compose up -d n8n` avec le compose.yml EN PLACE : c'est a l'operateur d'avoir remis
#      le compose entier du lot precedent avant (le script affiche l'image qu'il va demarrer) ;
#   6. attente de /healthz/readiness (jusqu'a 180 s), nombre de migrations affiche et compare.
# Les autres bases (nocodb) et volumes ne sont pas touches. Le site doit etre en maintenance
# (drapeaux MAINTENANCE, voir UPGRADES.md) : toute ecriture faite dans n8n depuis le jeu est perdue.
# Sortie 0 si tout passe, 2 sinon (ligne ERREUR, alerte comme backup.sh).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"
SPARK_ALERT_SCRIPT="restore-n8n.sh"

stamp="" confirm=0 expect=""
while [ $# -gt 0 ]; do
  case "$1" in
    --confirm) confirm=1; shift ;;
    --expect-migrations) [ $# -ge 2 ] || spark_die "--expect-migrations attend un nombre"; expect="$2"; shift 2 ;;
    -h|--help) sed -n '2,/^[^#]/{/^#/p;}' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) spark_die "option inconnue : $1" ;;
    *) stamp="$1"; shift ;;
  esac
done
[ -n "$stamp" ] || spark_die "horodatage du jeu de sauvegarde manquant (ex. 20260101-120000)"
case "$stamp" in [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]) ;; *) spark_die "horodatage invalide : $stamp (attendu AAAAMMJJ-HHMMSS)" ;; esac
case "$expect" in '') ;; *[!0-9]*) spark_die "--expect-migrations : nombre attendu, recu « $expect »" ;; esac

INFRA_DIR="$(spark_infra_dir "$SCRIPT_DIR")"
cd "$INFRA_DIR"
spark_load_env ./.env POSTGRES_ROOT_PASSWORD N8N_ENCRYPTION_KEY SPARK_PREFIX SPARK_DOMAIN
BACKUP_DIR="${SPARK_BACKUP_DIR:-$INFRA_DIR/backups}"
dump="$BACKUP_DIR/pg_dumpall-$stamp.sql.gz"
vol_tar="$BACKUP_DIR/vol-n8n_data-$stamp.tgz"
[ -f "$dump" ] || spark_die "dump introuvable : $dump"
[ -f "$vol_tar" ] || spark_die "archive du volume introuvable : $vol_tar"
gzip -t "$dump" 2>/dev/null || spark_die "dump $dump illisible (gzip -t)"
case "$(gzip -dc "$dump" | tail -n 3 | tr '\n' ' ')" in
  *"PostgreSQL database cluster dump complete"*) ;;
  *) spark_die "dump $(basename "$dump") tronque (ligne de controle absente)" ;;
esac
gzip -t "$vol_tar" 2>/dev/null || spark_die "archive $vol_tar illisible"

PROJECT="$(spark_project_name)"
N8N_IMAGE="$(spark_service_image n8n 'n8nio/n8n')"
pg_cid="$(spark_compose ps -q postgres)"
[ -n "$pg_cid" ] || spark_die "le service postgres ne tourne pas (docker compose ps)"
TOOL_IMAGE="$(docker inspect --format '{{.Config.Image}}' "$pg_cid")"
VOLUME="${PROJECT}_n8n_data"
docker volume inspect "$VOLUME" >/dev/null 2>&1 || spark_die "volume $VOLUME introuvable"

printf 'Jeu %s : %s + %s\n' "$stamp" "$(basename "$dump")" "$(basename "$vol_tar")"
printf 'Base n8n du cluster %s : DROP puis CREATE, puis rejeu de la section n8n du dump\n' "$(spark_compose ps --format '{{.Name}}' postgres)"
printf 'Volume %s : vide puis restaure depuis le tar\n' "$VOLUME"
printf 'n8n redemarre avec l image du compose.yml EN PLACE : %s\n' "$N8N_IMAGE"
if [ "$confirm" -ne 1 ]; then
  printf 'Rien n a ete fait (ajouter --confirm). Verifier d abord que compose.yml est celui du lot vise.\n'
  exit 0
fi

status=2
phase="avant tout arret : rien n'a ete modifie"
section=""
cleanup() {
  rc=$?
  [ -n "$section" ] && rm -f "$section"
  if [ "$status" -ne 0 ]; then
    spark_alert "restore-n8n.sh" "restauration n8n du jeu $stamp en echec (code $rc), $phase"
    exit 2
  fi
}
trap cleanup EXIT
SPARK_ALERT_TRAP=1

# 1. Arret de n8n (et du sidecar s'il existe dans la configuration courante) -----------------
spark_log "arret de n8n"
phase="n8n arrete, base et volume a verifier avant tout redemarrage"
spark_compose stop n8n >/dev/null
# (pas de `| grep -q` sur une commande docker : grep quitterait avant la fin et SIGPIPE ferait
# echouer le pipeline sous pipefail ; la liste est lue en entier dans une variable)
services="$(spark_compose config --services 2>/dev/null || true)"
case " $(printf '%s' "$services" | tr '\n' ' ') " in *" runners "*) spark_compose stop runners >/dev/null 2>&1 || true ;; esac

# 2. Section n8n du dump -------------------------------------------------------------------------
# De la ligne `\connect n8n` (exclue : on est deja connecte a la bonne base) jusqu'a la base
# suivante (`\connect ...` ou `CREATE DATABASE ...`), exclue. awk lit le dump jusqu'au bout sans
# `exit` : quitter avant la fin enverrait SIGPIPE a gzip et ferait echouer le pipeline (pipefail).
section="$(mktemp "$BACKUP_DIR/.n8n-section-XXXXXX")"
chmod 600 "$section"
gzip -dc "$dump" | awk '
  done { next }
  /^\\connect n8n$/ { inside = 1; next }
  inside && (/^\\connect / || /^CREATE DATABASE /) { done = 1; next }
  inside { print }
' > "$section"
[ -s "$section" ] || spark_die "section de la base n8n introuvable dans le dump (ligne \\connect n8n absente)"
grep -q 'COPY public.migrations' "$section" || spark_die "section n8n sans table migrations : dump inattendu"
spark_log "section n8n extraite ($(wc -l < "$section" | tr -d ' ') lignes)"

# 3. Base recreee et rejouee ------------------------------------------------------------------------
psql_root() { spark_compose exec -T postgres psql -U postgres -v ON_ERROR_STOP=1 -q "$@"; }
psql_root -d postgres -c 'DROP DATABASE IF EXISTS n8n WITH (FORCE)' -c 'CREATE DATABASE n8n OWNER n8n' </dev/null \
  || spark_die "DROP/CREATE DATABASE n8n en echec"
if ! psql_root -d n8n < "$section" >/dev/null; then
  spark_die "rejeu de la section n8n en echec (ON_ERROR_STOP) : base n8n incomplete, ne pas redemarrer n8n"
fi
rm -f "$section"; section=""
migrations="$(spark_compose exec -T postgres psql -U postgres -d n8n -Atc 'SELECT count(*) FROM migrations' </dev/null)"
spark_log "base n8n restauree : $migrations migrations"

# 4. Volume n8n_data ----------------------------------------------------------------------------------
docker run --rm -v "$VOLUME:/v" -v "$BACKUP_DIR:/b:ro" "$TOOL_IMAGE" \
  sh -c 'find /v -mindepth 1 -delete && tar xzf "/b/'"$(basename "$vol_tar")"'" -C /v && test -f /v/config' \
  || spark_die "restauration du volume $VOLUME en echec"
spark_log "volume $VOLUME restaure"

# 5. Redemarrage et readiness ----------------------------------------------------------------------------
phase="base et volume restaures, n8n relance : readiness ou nombre de migrations a verifier (docker compose logs n8n)"
spark_compose up -d n8n >/dev/null 2>&1 || spark_die "docker compose up -d n8n en echec"
URL="http://127.0.0.1:${SPARK_HOST_HTTP_PORT:-18080}"
ready=0
for _ in $(seq 1 90); do
  body="$(curl -s -m 5 -H "Host: ${SPARK_PREFIX}-n8n.${SPARK_DOMAIN}" "$URL/healthz/readiness" 2>/dev/null || true)"
  case "$body" in *'"status":"ok"'*) ready=1; break ;; esac
  sleep 2
done
[ "$ready" -eq 1 ] || spark_die "n8n ne repond pas sur /healthz/readiness apres 180 s (docker compose logs n8n)"
migrations="$(spark_compose exec -T postgres psql -U postgres -d n8n -Atc 'SELECT count(*) FROM migrations' </dev/null)"
spark_log "n8n pret ($(spark_compose exec -T n8n n8n --version </dev/null 2>/dev/null | tail -1 || printf '?')), $migrations migrations"
if [ -n "$expect" ] && [ "$migrations" != "$expect" ]; then
  phase="n8n est PRET mais a remigre la base restauree ($migrations migrations, $expect attendues) : remettre le compose du lot vise et rejouer la restauration"
  spark_die "$migrations migrations apres restauration, $expect attendues (le compose.yml en place n'est pas celui du lot vise ?)"
fi
status=0
spark_log "restauration n8n du jeu $stamp terminee"
