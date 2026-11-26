#!/usr/bin/env bash
# deploy/scripts/tunnel-config.sh — ecrit la configuration cloudflared du site depuis le .env.
#
# Usage : tunnel-config.sh [--host] [--check]
#   (defaut)  ecrit <SPARK_TUNNEL_DIR>/config.yml pour le conteneur du profil `tunnel` :
#             ingress vers http://caddy:80 (reseau compose), credentials-file sous /etc/cloudflared/
#             (chemin DANS le conteneur, ou SPARK_TUNNEL_DIR est monte en lecture seule).
#   --host    ecrit <SPARK_TUNNEL_DIR>/config-spark.yml pour la variante « cloudflared sur l'hote »
#             (unit systemd spark-cloudflared.service, LaunchAgent com.spark.cloudflared.plist) :
#             ingress vers http://localhost:<SPARK_HOST_HTTP_PORT>, credentials-file en chemin hote.
#   --check   n'ecrit rien : affiche le fichier qui serait ecrit et sort 0 si l'existant est identique,
#             1 sinon (derive entre .env et config).
#
# Lit SPARK_PREFIX, SPARK_DOMAIN, SPARK_TUNNEL_ID, SPARK_TUNNEL_DIR (et SPARK_HOST_HTTP_PORT avec --host)
# dans infra/.env ; exige que <SPARK_TUNNEL_DIR>/<SPARK_TUNNEL_ID>.json existe (cree par
# `cloudflared tunnel create`). Un vhost = une regle d'ingress ; le dernier ingress est le 404
# obligatoire de cloudflared. Les vhosts du site poses dans sites.d/ s'ajoutent a la main sous la
# meme forme (ou via SPARK_TUNNEL_EXTRA_HOSTS="x y", noms complets separes par des espaces).
# Rien de secret dans ce fichier (l'identifiant de tunnel n'est pas un secret, le .json l'est).
# Ecrit en place (cat >), jamais par mv : le repertoire est monte, l'inode du fichier est conserve.
# Compatible bash 3.2 (macOS) et bash 5 (Linux).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

mode=container check=0
for arg in "$@"; do
  case "$arg" in
    --host) mode=host ;;
    --check) check=1 ;;
    -h|--help) sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 1 ;;
    *) spark_die "option inconnue : $arg" ;;
  esac
done

INFRA_DIR="$(spark_infra_dir "$SCRIPT_DIR")"
cd "$INFRA_DIR"
spark_load_env ./.env SPARK_PREFIX SPARK_DOMAIN SPARK_TUNNEL_ID SPARK_TUNNEL_DIR

printf '%s' "$SPARK_TUNNEL_ID" | grep -Eq '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' \
  || spark_die "SPARK_TUNNEL_ID n'est pas un UUID de tunnel (valeur affichee par cloudflared tunnel create)"
case "$SPARK_TUNNEL_DIR" in /*) ;; *) spark_die "SPARK_TUNNEL_DIR doit etre un chemin absolu (docker compose ne developpe pas ~)" ;; esac
[ -d "$SPARK_TUNNEL_DIR" ] || spark_die "repertoire SPARK_TUNNEL_DIR introuvable : $SPARK_TUNNEL_DIR"
[ -f "$SPARK_TUNNEL_DIR/$SPARK_TUNNEL_ID.json" ] \
  || spark_die "identifiants du tunnel absents : $SPARK_TUNNEL_DIR/$SPARK_TUNNEL_ID.json (cloudflared tunnel create spark-$SPARK_PREFIX)"

if [ "$mode" = container ]; then
  target="$SPARK_TUNNEL_DIR/config.yml"
  credentials="/etc/cloudflared/$SPARK_TUNNEL_ID.json"
  service="http://caddy:80"
else
  target="$SPARK_TUNNEL_DIR/config-spark.yml"
  credentials="$SPARK_TUNNEL_DIR/$SPARK_TUNNEL_ID.json"
  service="http://localhost:${SPARK_HOST_HTTP_PORT:-18080}"
fi

render() {
  local h
  printf '# Genere par tunnel-config.sh (%s) depuis infra/.env : ne pas editer, relancer le script.\n' "$mode"
  printf 'tunnel: %s\ncredentials-file: %s\n' "$SPARK_TUNNEL_ID" "$credentials"
  printf 'no-autoupdate: true\n\ningress:\n'
  for h in "${SPARK_PREFIX}-n8n.${SPARK_DOMAIN}" "${SPARK_PREFIX}-app.${SPARK_DOMAIN}" "${SPARK_PREFIX}-db.${SPARK_DOMAIN}"; do
    printf '  - hostname: %s\n    service: %s\n' "$h" "$service"
  done
  # shellcheck disable=SC2086
  for h in ${SPARK_TUNNEL_EXTRA_HOSTS:-}; do
    printf '  - hostname: %s\n    service: %s\n' "$h" "$service"
  done
  printf '  - service: http_status:404\n'
}

new="$(render)"
if [ "$check" -eq 1 ]; then
  printf '%s\n' "$new"
  if [ -f "$target" ] && [ "$(cat "$target")" = "$new" ]; then
    printf 'OK : %s conforme au .env\n' "$target"
    exit 0
  fi
  printf 'DERIVE : %s absent ou different de ce que le .env produit\n' "$target" >&2
  exit 1
fi

umask 077
printf '%s\n' "$new" > "$target"
chmod 600 "$target"
printf '%s ecrit (%s) : %s, ingress -> %s\n' "$target" "$mode" "tunnel $SPARK_TUNNEL_ID" "$service"
