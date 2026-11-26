#!/usr/bin/env bash
# deploy/scripts/cloudflared-host-guard.sh — garde « un seul connecteur » de la variante
# « cloudflared sur l'hote » (ExecCondition= de deploy/linux/systemd/spark-cloudflared.service).
#
# Usage : cloudflared-host-guard.sh            (lance par systemd ; a la main pour un diagnostic)
# Sort 0 si l'unit hote peut demarrer, 1 si elle doit rester inactive. Un refus est ecrit sur stderr,
# que l'unit envoie au journal (StandardError=journal) : `journalctl -u spark-cloudflared.service`
# montre la cause, ligne « un seul connecteur a la fois ». (Pas de systemd-cat ni logger : depuis un
# processus aussi bref, journald n'attribue pas toujours le message a l'unit, verifie sur le banc.)
#
# Pourquoi un script : la verification « le conteneur du profil tunnel tourne-t-il ? » faite par
# `docker ps` au demarrage est contournee au reboot (l'unit demarre avant que Docker ait relance le
# conteneur `restart: always`, puis les deux connecteurs tournent ensemble). Le script lit donc :
#   1. COMPOSE_PROFILES dans infra/.env (par NOM, rien n'est affiche) : le profil `tunnel` pose =
#      le conteneur reviendra au prochain `up -d`, `reload` ou reboot, meme s'il n'est pas la ;
#   2. l'existence d'un conteneur spark-cloudflared-N, MEME ARRETE (`docker ps -a`) : un conteneur
#      cree n'est pas retire par un profil vide, Docker le relance au boot ;
#   3. l'etat du demon Docker : injoignable = impossible de garantir l'invariant, refus (l'unit est
#      ordonnee After=docker.service, ce cas n'arrive qu'avec un demon arrete ou en panne).
# Et pourquoi ExecCondition= plutot qu'ExecStartPre= : un refus laisse l'unit `inactive` (resultat
# `exec-condition`), SANS la marquer en echec, donc sans boucle Restart=on-failure : l'unit ne
# « prend pas la main » des que le conteneur s'arrete un instant. Elle est reessayee au prochain
# `systemctl start` ou au prochain boot.
set -euo pipefail

case "${1:-}" in
  -h|--help) sed -n '2,/^[^#]/{/^#/p;}' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
  "") ;;
  *) printf 'option inconnue : %s (ce script ne prend aucun argument)\n' "$1" >&2; exit 2 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="${SPARK_INFRA_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
ENV_FILE="$INFRA_DIR/.env"

refuse() {
  printf 'spark-cloudflared.service : un seul connecteur a la fois, l'"'"'unit hote reste inactive : %s\n' "$1" >&2
  exit 1
}

# 1. Profil `tunnel` dans le .env (par nom de variable, dans un shell neutre : rien n'est affiche).
if [ -f "$ENV_FILE" ]; then
  # shellcheck disable=SC2016
  profiles="$(env -i HOME="${HOME:-/}" PATH="$PATH" LC_ALL=C bash -c '
    set +u; set -a; . "$1" 2>/dev/null; set +a
    printf "%s" ",${COMPOSE_PROFILES:-},"' _ "$ENV_FILE" | tr -d '[:space:]')"
  case "$profiles" in
    *,tunnel,*) refuse "le profil tunnel est pose dans $ENV_FILE (COMPOSE_PROFILES) : le conteneur cloudflared du compose est, ou sera, le connecteur ; pour la variante hote, vider le profil et retirer le conteneur (docker compose --profile tunnel stop cloudflared && docker compose --profile tunnel rm -f cloudflared)" ;;
  esac
fi

# 2. et 3. Conteneur du compose, meme arrete ; demon Docker joignable.
if ! names="$(docker ps -a --format '{{.Names}}' 2>/dev/null)"; then
  refuse "demon Docker injoignable (docker ps -a), impossible de verifier qu'aucun conteneur cloudflared n'existe"
fi
if printf '%s\n' "$names" | grep -qE '^spark-cloudflared(-[0-9]+)?$'; then
  refuse "un conteneur cloudflared du compose existe (profil tunnel, $(printf '%s\n' "$names" | grep -E '^spark-cloudflared(-[0-9]+)?$' | head -1), meme arrete il est relance par Docker au boot) ; le retirer d'abord : docker compose --profile tunnel stop cloudflared && docker compose --profile tunnel rm -f cloudflared"
fi
exit 0
