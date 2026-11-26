#!/usr/bin/env bash
# deploy/scripts/check-env.sh — verifie qu'un .env porte une valeur pour chaque variable demandee.
#
# Usage : check-env.sh [--env chemin/.env] [VAR ...]
#   Sans VAR : les variables que le site doit renseigner avant `docker compose up`
#   (SPARK_PREFIX, SPARK_DOMAIN, les 5 secrets d'infrastructure, le jeton du sidecar runner et
#   SPARK_UID/SPARK_GID du conteneur cloudflared ; init-env.sh les pose tous).
#   --env : fichier a lire (defaut : infra/.env, infra/ etant le parent du repertoire du script,
#   ou SPARK_INFRA_DIR).
#
# Affiche une ligne `OK   NOM` ou `FAIL NOM absent ou vide` par variable, jamais la valeur. Sort
# en 0 si tout est renseigne, 1 sinon. La valeur est celle que le shell RESOUT en chargeant le
# fichier, debarrassee des guillemets et des espaces : `NOM=`, `NOM=''`, `NOM="  "` et une ligne
# absente sont « vides » ; `NOM=a` (un caractere) est renseigne. `docker compose config` ne dit
# rien d'une variable presente mais vide : ce script complete sa verification.
# Sans VAR (liste par defaut), il verifie aussi la COHERENCE des profils compose, une ligne
# `OK   COMPOSE_PROFILES ...` ou `FAIL COMPOSE_PROFILES ...` : `tunnel` exige SPARK_TUNNEL_ID,
# SPARK_TUNNEL_DIR et <SPARK_TUNNEL_DIR>/config.yml (ecrit par tunnel-config.sh ; sans lui le
# conteneur boucle en redemarrage) ; `runners` exige COMPOSE_FILE=compose.yml:compose.runners.yml
# (sinon le sidecar tourne pour rien, n8n reste en mode interne) et reciproquement (l'override sans
# le profil mettrait n8n en mode externe sans sidecar : les nodes Code echoueraient).
# Le script NE REGARDE QUE LE FICHIER : il est charge dans un environnement vide (`env -i`), une
# variable exportee dans le shell appelant ne compte pas (ligne absente du fichier = FAIL, meme si
# `SPARK_PREFIX` est pose dans le shell). Le fichier est source comme du shell : une valeur avec `$`,
# accent grave ou espace doit etre entre guillemets simples.
# Compatible bash 3.2 (macOS) et bash 5 (Linux).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

DEFAULT_VARS="SPARK_PREFIX SPARK_DOMAIN POSTGRES_ROOT_PASSWORD N8N_DB_PASSWORD NOCODB_DB_PASSWORD N8N_ENCRYPTION_KEY NC_AUTH_JWT_SECRET N8N_RUNNERS_AUTH_TOKEN SPARK_UID SPARK_GID"
env_file=""
vars=""
while [ $# -gt 0 ]; do
  case "$1" in
    --env) [ $# -ge 2 ] || spark_die "--env attend un chemin"; env_file="$2"; shift 2 ;;
    -h|--help) sed -n '2,19p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 1 ;;
    -*) spark_die "option inconnue : $1" ;;
    *) case "$1" in *[!A-Za-z0-9_]*) spark_die "nom de variable invalide : $1" ;; esac
       vars="$vars $1"; shift ;;
  esac
done
[ -n "$env_file" ] || env_file="${SPARK_INFRA_DIR:-$SCRIPT_DIR/..}/.env"
[ -f "$env_file" ] || spark_die "$env_file introuvable"
coherence=0
[ -n "$vars" ] || { vars="$DEFAULT_VARS"; coherence=1; }

# Chargement dans un bash NEUTRE (`env -i` : aucune variable de l'appelant, seulement HOME et PATH) :
# seul le fichier compte, et rien n'est exporte au-dela. `$vars` est volontairement eclate en mots.
# shellcheck disable=SC2086,SC2016
env -i HOME="${HOME:-/}" PATH="$PATH" LC_ALL=C bash -c '
  set +u
  env_file="$1"; coherence="$2"; shift 2
  set -a
  . "$env_file"
  set +a
  fails=0
  for v in "$@"; do
    if [ -n "$(printf "%s" "${!v:-}" | tr -d "[:space:]")" ]; then
      printf "OK   %s\n" "$v"
    else
      printf "FAIL %s absent ou vide\n" "$v"
      fails=$((fails + 1))
    fi
  done
  if [ "$coherence" -eq 1 ]; then
    profiles=",$(printf "%s" "${COMPOSE_PROFILES:-}" | tr -d "[:space:]"),"
    files="${COMPOSE_FILE:-}"
    pb=""
    case "$profiles" in
      *,tunnel,*)
        if [ -z "$(printf "%s" "${SPARK_TUNNEL_ID:-}" | tr -d "[:space:]")" ] || [ -z "$(printf "%s" "${SPARK_TUNNEL_DIR:-}" | tr -d "[:space:]")" ]; then
          pb="profil tunnel sans SPARK_TUNNEL_ID ou SPARK_TUNNEL_DIR (etape 4 des guides)"
        elif [ ! -f "${SPARK_TUNNEL_DIR}/config.yml" ]; then
          pb="profil tunnel sans ${SPARK_TUNNEL_DIR}/config.yml : lancer tunnel-config.sh AVANT de poser le profil (sinon cloudflared boucle en redemarrage)"
        fi ;;
    esac
    case "$profiles:$files" in
      *,runners,*:*compose.runners.yml*) ;;
      *,runners,*:*) pb="${pb:+$pb ; }profil runners sans COMPOSE_FILE=compose.yml:compose.runners.yml : le sidecar tournerait pour rien, n8n resterait en mode interne" ;;
      *:*compose.runners.yml*) pb="${pb:+$pb ; }COMPOSE_FILE lit compose.runners.yml sans le profil runners : n8n passerait en mode externe sans sidecar, les nodes Code echoueraient" ;;
    esac
    if [ -z "$pb" ]; then
      shown="$(printf "%s" "${COMPOSE_PROFILES:-}" | tr -d "[:space:]")"
      printf "OK   COMPOSE_PROFILES coherent (%s)\n" "${shown:-aucun profil}"
    else
      printf "FAIL COMPOSE_PROFILES : %s\n" "$pb"
      fails=$((fails + 1))
    fi
  fi
  [ "$fails" -eq 0 ]
' _ "$env_file" "$coherence" $vars
