#!/usr/bin/env bash
# deploy/scripts/backup.sh — sauvegarde locale de la stack Spark.
#
# Usage : backup.sh            (depuis infra/scripts/, ou avec SPARK_INFRA_DIR=/chemin/infra)
#
# Produit dans infra/backups/, un JEU complet par horodatage <stamp> :
#   pg_dumpall-<stamp>.sql.gz      dump complet (toutes les bases, roles compris), controle
#                                  de la derniere ligne « PostgreSQL database cluster dump complete »
#   vol-<volume>-<stamp>.tgz       tar de chaque volume du projet, SAUF le volume Postgres
#                                  (un tar a chaud d'un cluster Postgres ne vaut rien : le dump le couvre)
#   secrets-<stamp>.tar.age|.gpg   .env + fichier config de n8n, CHIFFRES. Sans N8N_ENCRYPTION_KEY,
#                                  les identifiants n8n d'une restauration sont illisibles.
#   LAST_OK                        horodatage de la derniere sauvegarde complete
# Retention locale : BACKUP_KEEP_DAYS (defaut 14), par jeu complet (tous les fichiers d'un meme
# horodatage partent ensemble). La copie hors machine (rclone copy + suppression par age, jamais
# sync) et le test de restauration (restore-test.sh) completent le 3-2-1.
# Sortie 0 si tout est ecrit et controle, 2 sinon : ligne ALERTE sur stderr (journal du timer) et POST
# a SPARK_ALERT_WEBHOOK s'il est defini, avec la derniere ligne ERREUR — y compris quand le script
# s'arrete avant d'avoir commence (.env absent, N8N_ENCRYPTION_KEY manquante, age absent...).
# Une seule execution a la fois (verrou backups/.lock-backup) : un deuxieme lancement sort en code 2
# avec un message clair, sans rien toucher ni alerter.
# Rien n'est ecrit tant que le chiffrement des secrets n'est pas possible (destinataire age valide
# ou passphrase gpg lisible, outil present) ; chaque fichier est produit en .part et renomme en fin
# de succes, secrets et volumes d'abord, dump en dernier : restore-test.sh prend « le dump le plus
# recent », qui a donc toujours ses secrets et ses volumes a cote de lui.
#
# `docker compose exec -T` : TOUJOURS -T. Un TTY alloue reecrit les fins de ligne et corrompt le dump.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"
# Alerte des la premiere ERREUR (.env absent, variable manquante...) : voir SPARK_ALERT_SCRIPT dans lib.sh.
SPARK_ALERT_SCRIPT="backup.sh"

INFRA_DIR="$(spark_infra_dir "$SCRIPT_DIR")"
cd "$INFRA_DIR"
spark_load_env ./.env POSTGRES_ROOT_PASSWORD N8N_ENCRYPTION_KEY
BACKUP_DIR="${SPARK_BACKUP_DIR:-$INFRA_DIR/backups}"
KEEP_DAYS="${BACKUP_KEEP_DAYS:-14}"
STAMP="$(date '+%Y%m%d-%H%M%S')"
mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"
spark_lock "$BACKUP_DIR/.lock-backup" "backup.sh"

status=2
tmpdir=""
parts=()
cleanup() {
  rc=$?
  [ -n "$tmpdir" ] && rm -rf "$tmpdir"
  if [ "$status" -ne 0 ]; then
    # Aucun fichier partiel ne doit passer pour une sauvegarde (restore-test prend « le plus recent »).
    [ "${#parts[@]}" -gt 0 ] && rm -f "${parts[@]}"
    spark_alert "backup.sh" "sauvegarde $STAMP incomplete (code $rc) dans $BACKUP_DIR"
    spark_unlock
    exit 2
  fi
  spark_unlock
}
trap cleanup EXIT
SPARK_ALERT_TRAP=1   # a partir d'ici, c'est cleanup qui alerte (spark_die ne double pas)

# 0. Pre-requis du chiffrement des secrets : verifies AVANT d'ecrire quoi que ce soit --------
if [ -n "${BACKUP_AGE_RECIPIENT:-}" ]; then
  command -v age >/dev/null || spark_die "age absent (apt install age / brew install age)"
  # Destinataire valide ? age refuse un « age1... » mal forme ou tronque ; test a blanc sur un flux vide.
  printf '' | age -r "$BACKUP_AGE_RECIPIENT" -o /dev/null 2>/dev/null \
    || spark_die "BACKUP_AGE_RECIPIENT invalide (cle publique age1... attendue) : rien n'est ecrit"
  secrets_mode=age
elif [ -n "${BACKUP_GPG_PASSPHRASE_FILE:-}" ]; then
  command -v gpg >/dev/null || spark_die "gpg absent (apt install gnupg / brew install gnupg)"
  [ -r "$BACKUP_GPG_PASSPHRASE_FILE" ] || spark_die "BACKUP_GPG_PASSPHRASE_FILE illisible"
  secrets_mode=gpg
else
  spark_die "ni BACKUP_AGE_RECIPIENT ni BACKUP_GPG_PASSPHRASE_FILE dans .env : les secrets ne seraient pas sauvegardes, rien n'est ecrit"
fi

PROJECT="$(spark_project_name)"
pg_cid="$(spark_compose ps -q postgres)"
[ -n "$pg_cid" ] || spark_die "le service postgres ne tourne pas (docker compose ps)"
# Image deja presente sur la machine (alpine + tar) : aucun pull, aucune image supplementaire.
TOOL_IMAGE="$(docker inspect --format '{{.Config.Image}}' "$pg_cid")"
volumes="$(docker volume ls -q --filter "label=com.docker.compose.project=$PROJECT")"
[ -n "$volumes" ] || spark_die "aucun volume pour le projet $PROJECT"

# 1. Dump complet ------------------------------------------------------------------------
dump="$BACKUP_DIR/pg_dumpall-$STAMP.sql.gz"
parts+=("$dump.part")
spark_log "dump pg_dumpall -> $dump"
# Jusqu'a 3 essais : juste apres un demarrage, les migrations de n8n peuvent interbloquer le
# LOCK TABLE de pg_dump (deadlock detected), ce qui est passager. stdin sur /dev/null : `exec -T`
# transmet encore l'entree standard, qui ne doit pas etre celle d'un script appelant.
dump_ok=0
for attempt in 1 2 3; do
  if spark_compose exec -T postgres pg_dumpall -U postgres </dev/null | gzip -c > "$dump.part"; then
    # pg_dumpall termine par la ligne de controle suivie d'une ligne vide : on lit les 3 dernieres.
    last="$(gzip -dc "$dump.part" | tail -n 3 | tr '\n' ' ')"
    case "$last" in *"PostgreSQL database cluster dump complete"*) dump_ok=1; break ;; esac
    spark_log "essai $attempt : dump tronque (ligne de controle absente ; le contenu n'est pas affiche)"
  else
    spark_log "essai $attempt : pg_dumpall en echec"
  fi
  [ "$attempt" -lt 3 ] && sleep 15
done
[ "$dump_ok" -eq 1 ] || spark_die "dump pg_dumpall en echec apres 3 essais (voir les lignes pg_dump ci-dessus)"
chmod 600 "$dump.part"

# 2. Volumes hors Postgres --------------------------------------------------------------
vol_parts=()
for vol in $volumes; do
  short="${vol#"${PROJECT}_"}"
  case "$short" in
    postgres*_data) spark_log "volume $vol ignore (couvert par le dump)"; continue ;;
  esac
  out="$BACKUP_DIR/vol-$short-$STAMP.tgz"
  parts+=("$out.part"); vol_parts+=("$out.part")
  spark_log "volume $vol -> $out"
  docker run --rm -v "$vol:/v:ro" "$TOOL_IMAGE" tar czf - -C /v . > "$out.part"
  gzip -t "$out.part" || spark_die "archive $out illisible (gzip -t)"
  chmod 600 "$out.part"
done

# 3. Secrets chiffres : .env + config n8n ------------------------------------------------
tmpdir="$(mktemp -d "$BACKUP_DIR/.secrets-XXXXXX")"
chmod 700 "$tmpdir"
cp ./.env "$tmpdir/env"
docker run --rm -v "${PROJECT}_n8n_data:/v:ro" "$TOOL_IMAGE" cat /v/config > "$tmpdir/n8n-config" \
  || spark_die "lecture de n8n_data/config impossible"
[ -s "$tmpdir/n8n-config" ] || spark_die "n8n_data/config vide"
if [ "$secrets_mode" = age ]; then
  secrets="$BACKUP_DIR/secrets-$STAMP.tar.age"
  parts+=("$secrets.part")
  tar cf - -C "$tmpdir" env n8n-config | age -r "$BACKUP_AGE_RECIPIENT" -o "$secrets.part"
else
  secrets="$BACKUP_DIR/secrets-$STAMP.tar.gpg"
  parts+=("$secrets.part")
  tar cf - -C "$tmpdir" env n8n-config \
    | gpg --batch --yes --quiet --pinentry-mode loopback --symmetric --cipher-algo AES256 \
        --passphrase-file "$BACKUP_GPG_PASSPHRASE_FILE" -o "$secrets.part"
fi
[ -s "$secrets.part" ] || spark_die "archive de secrets vide"
chmod 600 "$secrets.part"
rm -rf "$tmpdir"; tmpdir=""

# Tout est ecrit et controle : les .part deviennent definitifs dans un ordre sur, secrets puis
# volumes puis dump. Le dump n'apparait qu'en dernier : des qu'il existe, son jeu est complet.
mv "$secrets.part" "$secrets"
if [ "${#vol_parts[@]}" -gt 0 ]; then
  for part in "${vol_parts[@]}"; do mv "$part" "${part%.part}"; done
fi
mv "$dump.part" "$dump"
parts=()
spark_log "secrets chiffres -> $secrets"

# 4. Retention locale, par jeu complet --------------------------------------------------
# Un dump plus vieux que KEEP_DAYS emporte tous les fichiers de son horodatage ; un .part oublie
# (coupure brutale) part au bout d'un jour.
find "$BACKUP_DIR" -maxdepth 1 -type f -name 'pg_dumpall-*.sql.gz' -mtime +"$KEEP_DAYS" -print 2>/dev/null \
  | while IFS= read -r old; do
      stamp="${old##*/pg_dumpall-}"; stamp="${stamp%.sql.gz}"
      case "$stamp" in [0-9]*-[0-9]*) ;; *) continue ;; esac
      find "$BACKUP_DIR" -maxdepth 1 -type f \( -name "pg_dumpall-$stamp.sql.gz" -o -name "vol-*-$stamp.tgz" \
        -o -name "secrets-$stamp.tar.*" \) -print -delete | sed "s/^/retention: suppression du jeu $stamp : /"
    done || true
# Orphelins (volume ou secrets d'un horodatage dont le dump n'existe plus) au-dela de KEEP_DAYS.
find "$BACKUP_DIR" -maxdepth 1 -type f \( -name 'vol-*.tgz' -o -name 'secrets-*.tar.*' \) -mtime +"$KEEP_DAYS" -print 2>/dev/null \
  | while IFS= read -r old; do
      # sed -E : meme syntaxe sur GNU (Linux) et BSD (macOS) ; l'alternance \| est GNU seulement.
      stamp="$(printf '%s' "${old##*/}" | sed -En 's/.*-([0-9]{8}-[0-9]{6})\.(tgz|tar\..*)$/\1/p')"
      [ -n "$stamp" ] && [ ! -f "$BACKUP_DIR/pg_dumpall-$stamp.sql.gz" ] || continue
      rm -f "$old" && printf 'retention: suppression de l orphelin %s\n' "$old"
    done || true
find "$BACKUP_DIR" -maxdepth 1 -type f -name '*.part' -mtime +1 -print -delete 2>/dev/null \
  | sed 's/^/retention: suppression du fichier partiel /' || true

date '+%Y-%m-%dT%H:%M:%S' > "$BACKUP_DIR/LAST_OK"
status=0
spark_log "sauvegarde $STAMP complete ($(du -sh "$BACKUP_DIR" | cut -f1) dans $BACKUP_DIR)"
