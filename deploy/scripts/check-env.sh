#!/usr/bin/env bash
# deploy/scripts/check-env.sh — verifie qu'un .env porte une valeur pour chaque variable demandee.
#
# Usage : check-env.sh [--env chemin/.env] [VAR ...]
#   Sans VAR : les variables que le site doit renseigner avant `docker compose up`
#   (SPARK_PREFIX, SPARK_DOMAIN et les 5 secrets d'infrastructure).
#   --env : fichier a lire (defaut : infra/.env, infra/ etant le parent du repertoire du script,
#   ou SPARK_INFRA_DIR).
#
# Affiche une ligne `OK   NOM` ou `FAIL NOM absent ou vide` par variable, jamais la valeur. Sort
# en 0 si tout est renseigne, 1 sinon. La valeur est celle que le shell RESOUT en chargeant le
# fichier, debarrassee des guillemets et des espaces : `NOM=`, `NOM=''`, `NOM="  "` et une ligne
# absente sont « vides » ; `NOM=a` (un caractere) est renseigne. `docker compose config` ne dit
# rien d'une variable presente mais vide : ce script complete sa verification.
# Compatible bash 3.2 (macOS) et bash 5 (Linux).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

DEFAULT_VARS="SPARK_PREFIX SPARK_DOMAIN POSTGRES_ROOT_PASSWORD N8N_DB_PASSWORD NOCODB_DB_PASSWORD N8N_ENCRYPTION_KEY NC_AUTH_JWT_SECRET"
env_file=""
vars=""
while [ $# -gt 0 ]; do
  case "$1" in
    --env) [ $# -ge 2 ] || spark_die "--env attend un chemin"; env_file="$2"; shift 2 ;;
    -h|--help) sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 1 ;;
    -*) spark_die "option inconnue : $1" ;;
    *) case "$1" in *[!A-Za-z0-9_]*) spark_die "nom de variable invalide : $1" ;; esac
       vars="$vars $1"; shift ;;
  esac
done
[ -n "$env_file" ] || env_file="${SPARK_INFRA_DIR:-$SCRIPT_DIR/..}/.env"
[ -f "$env_file" ] || spark_die "$env_file introuvable"
vars="${vars:-$DEFAULT_VARS}"

# Les valeurs ne servent qu'a ce test : chargement dans un sous-shell, rien n'est exporte au-dela.
(
  set +u
  set -a
  # shellcheck disable=SC1090
  . "$env_file"
  set +a
  fails=0
  for v in $vars; do
    if [ -n "$(spark_env_value "$v")" ]; then
      printf 'OK   %s\n' "$v"
    else
      printf 'FAIL %s absent ou vide\n' "$v"
      fails=$((fails + 1))
    fi
  done
  [ "$fails" -eq 0 ]
)
