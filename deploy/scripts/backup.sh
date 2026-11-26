#!/usr/bin/env bash
# deploy/scripts/backup.sh — sauvegarde locale de la stack Spark.
#
# Usage : backup.sh            (depuis infra/scripts/, ou avec SPARK_INFRA_DIR=/chemin/infra)
#
# Produit dans infra/backups/ :
#   pg_dumpall-<horodatage>.sql.gz      dump complet (toutes les bases, roles compris), controle
#                                       de la derniere ligne « PostgreSQL database cluster dump complete »
#   vol-<volume>-<horodatage>.tgz       tar de chaque volume du projet, SAUF le volume Postgres
#                                       (un tar a chaud d'un cluster Postgres ne vaut rien : le dump le couvre)
#   secrets-<horodatage>.tar.age|.gpg   .env + fichier config de n8n, CHIFFRES. Sans N8N_ENCRYPTION_KEY,
#                                       les identifiants n8n d'une restauration sont illisibles.
#   LAST_OK                             horodatage de la derniere sauvegarde complete
# Retention locale : BACKUP_KEEP_DAYS (defaut 14). La copie hors machine (rclone copy + suppression
# par age, jamais sync) et le test de restauration (restore-test.sh) completent le 3-2-1.
# Sortie 0 si tout est ecrit et controle, 2 sinon (alerte envoyee a SPARK_ALERT_WEBHOOK si defini).
#
# `docker compose exec -T` : TOUJOURS -T. Un TTY alloue reecrit les fins de ligne et corrompt le dump.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

INFRA_DIR="$(spark_infra_dir "$SCRIPT_DIR")"
cd "$INFRA_DIR"
spark_load_env ./.env POSTGRES_ROOT_PASSWORD N8N_ENCRYPTION_KEY
BACKUP_DIR="${SPARK_BACKUP_DIR:-$INFRA_DIR/backups}"
KEEP_DAYS="${BACKUP_KEEP_DAYS:-14}"
STAMP="$(date '+%Y%m%d-%H%M%S')"
mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

status=2
tmpdir=""
cleanup() {
  rc=$?
  [ -n "$tmpdir" ] && rm -rf "$tmpdir"
  if [ "$status" -ne 0 ]; then
    spark_alert "backup.sh" "sauvegarde $STAMP incomplete (code $rc) dans $BACKUP_DIR"
    exit 2
  fi
}
trap cleanup EXIT

PROJECT="$(spark_project_name)"
pg_cid="$(spark_compose ps -q postgres)"
[ -n "$pg_cid" ] || spark_die "le service postgres ne tourne pas (docker compose ps)"
# Image deja presente sur la machine (alpine + tar) : aucun pull, aucune image supplementaire.
TOOL_IMAGE="$(docker inspect --format '{{.Config.Image}}' "$pg_cid")"

# 1. Dump complet ------------------------------------------------------------------------
dump="$BACKUP_DIR/pg_dumpall-$STAMP.sql.gz"
spark_log "dump pg_dumpall -> $dump"
spark_compose exec -T postgres pg_dumpall -U postgres | gzip -c > "$dump.part"
# pg_dumpall termine par la ligne de controle suivie d'une ligne vide : on lit les 3 dernieres.
last="$(gzip -dc "$dump.part" | tail -n 3 | tr '\n' ' ')"
case "$last" in
  *"PostgreSQL database cluster dump complete"*) ;;
  *) rm -f "$dump.part"; spark_die "dump tronque : fin de fichier « $last »" ;;
esac
mv "$dump.part" "$dump"
chmod 600 "$dump"

# 2. Volumes hors Postgres --------------------------------------------------------------
volumes="$(docker volume ls -q --filter "label=com.docker.compose.project=$PROJECT")"
[ -n "$volumes" ] || spark_die "aucun volume pour le projet $PROJECT"
for vol in $volumes; do
  short="${vol#"${PROJECT}_"}"
  case "$short" in
    postgres*_data) spark_log "volume $vol ignore (couvert par le dump)"; continue ;;
  esac
  out="$BACKUP_DIR/vol-$short-$STAMP.tgz"
  spark_log "volume $vol -> $out"
  docker run --rm -v "$vol:/v:ro" "$TOOL_IMAGE" tar czf - -C /v . > "$out.part"
  gzip -t "$out.part"
  mv "$out.part" "$out"
  chmod 600 "$out"
done

# 3. Secrets chiffres : .env + config n8n ------------------------------------------------
tmpdir="$(mktemp -d "$BACKUP_DIR/.secrets-XXXXXX")"
chmod 700 "$tmpdir"
cp ./.env "$tmpdir/env"
docker run --rm -v "${PROJECT}_n8n_data:/v:ro" "$TOOL_IMAGE" cat /v/config > "$tmpdir/n8n-config" \
  || spark_die "lecture de n8n_data/config impossible"
[ -s "$tmpdir/n8n-config" ] || spark_die "n8n_data/config vide"
if [ -n "${BACKUP_AGE_RECIPIENT:-}" ]; then
  command -v age >/dev/null || spark_die "age absent (apt install age / brew install age)"
  secrets="$BACKUP_DIR/secrets-$STAMP.tar.age"
  tar cf - -C "$tmpdir" env n8n-config | age -r "$BACKUP_AGE_RECIPIENT" -o "$secrets"
elif [ -n "${BACKUP_GPG_PASSPHRASE_FILE:-}" ]; then
  [ -r "$BACKUP_GPG_PASSPHRASE_FILE" ] || spark_die "BACKUP_GPG_PASSPHRASE_FILE illisible"
  secrets="$BACKUP_DIR/secrets-$STAMP.tar.gpg"
  tar cf - -C "$tmpdir" env n8n-config \
    | gpg --batch --yes --quiet --symmetric --cipher-algo AES256 \
        --passphrase-file "$BACKUP_GPG_PASSPHRASE_FILE" -o "$secrets"
else
  spark_die "ni BACKUP_AGE_RECIPIENT ni BACKUP_GPG_PASSPHRASE_FILE : les secrets ne seraient pas sauvegardes"
fi
chmod 600 "$secrets"
rm -rf "$tmpdir"; tmpdir=""
spark_log "secrets chiffres -> $secrets"

# 4. Retention locale -------------------------------------------------------------------
find "$BACKUP_DIR" -maxdepth 1 -type f \
  \( -name 'pg_dumpall-*.sql.gz' -o -name 'vol-*.tgz' -o -name 'secrets-*.tar.*' \) \
  -mtime +"$KEEP_DAYS" -print -delete | sed 's/^/retention: suppression /' || true

date '+%Y-%m-%dT%H:%M:%S' > "$BACKUP_DIR/LAST_OK"
status=0
spark_log "sauvegarde $STAMP complete ($(du -sh "$BACKUP_DIR" | cut -f1) dans $BACKUP_DIR)"
