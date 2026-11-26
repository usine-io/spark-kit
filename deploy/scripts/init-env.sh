#!/usr/bin/env bash
# deploy/scripts/init-env.sh — cree le .env d'un site depuis deploy/env.example.
#
# Usage : init-env.sh --prefix <prefix> --domain <domain> [--port 18080] [--force] <chemin/.env>
#
# Copie le gabarit, renseigne SPARK_PREFIX / SPARK_DOMAIN / SPARK_HOST_HTTP_PORT et genere les
# secrets d'infrastructure vides. Alphabet URL-safe uniquement (A-Za-z0-9) : un mot de passe
# avec des caracteres speciaux d'URL a deja fait boucler un service. Refuse d'ecraser un .env
# existant sans --force. Le fichier est cree en 600. Aucun secret n'est affiche.
# Compatible bash 3.2 (macOS) et bash 5 (Linux).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Gabarit : a cote du repertoire scripts/ (deploy/env.example dans le kit, infra/env.example sur un site).
TEMPLATE="${SPARK_ENV_TEMPLATE:-$SCRIPT_DIR/../env.example}"

usage() {
  sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 1
}

prefix="" domain="" port="18080" force=0 target=""
while [ $# -gt 0 ]; do
  case "$1" in
    --prefix|--domain|--port)
      [ $# -ge 2 ] || { printf '%s attend une valeur\n' "$1" >&2; usage; }
      case "$1" in --prefix) prefix="$2" ;; --domain) domain="$2" ;; --port) port="$2" ;; esac
      shift 2 ;;
    --force) force=1; shift ;;
    -h|--help) usage ;;
    -*) printf 'option inconnue : %s\n' "$1" >&2; usage ;;
    *) target="$1"; shift ;;
  esac
done

if [ -z "$prefix" ] || [ -z "$domain" ] || [ -z "$target" ]; then usage; fi
[ -f "$TEMPLATE" ] || { printf 'gabarit introuvable : %s\n' "$TEMPLATE" >&2; exit 2; }
printf '%s' "$prefix" | grep -Eq '^[a-z0-9][a-z0-9-]*$' || { printf 'prefix invalide (a-z0-9-) : %s\n' "$prefix" >&2; exit 2; }
# Domaine : etiquettes de 1 a 63 caracteres a-z0-9, tiret ni en tete ni en queue, TLD alphabetique.
printf '%s' "$domain" | grep -Eq '^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$' || { printf 'domaine invalide (ex. acme.example) : %s\n' "$domain" >&2; exit 2; }
if ! printf '%s' "$port" | grep -Eq '^[0-9]{1,5}$' || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
  printf 'port invalide (1-65535) : %s\n' "$port" >&2; exit 2
fi
if [ -e "$target" ] && [ "$force" -ne 1 ]; then
  printf '%s existe deja ; --force pour l ecraser (les secrets actuels seraient perdus)\n' "$target" >&2
  exit 2
fi

# Lecture bornee de /dev/urandom puis cut : aucun SIGPIPE dans la chaine (set -o pipefail).
gen_secret() {
  local s
  s="$(head -c 2048 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c "1-$1")"
  [ "${#s}" -eq "$1" ] || { printf 'generation de secret trop courte\n' >&2; exit 2; }
  printf '%s' "$s"
}
gen_hex() { openssl rand -hex "$1"; }

# Valeur a poser pour une variable du gabarit ; vide = recopier la ligne telle quelle.
value_for() {
  case "$1" in
    SPARK_PREFIX) printf '%s' "$prefix" ;;
    SPARK_DOMAIN) printf '%s' "$domain" ;;
    SPARK_HOST_HTTP_PORT) printf '%s' "$port" ;;
    POSTGRES_ROOT_PASSWORD|N8N_DB_PASSWORD|NOCODB_DB_PASSWORD) gen_secret 32 ;;
    N8N_ENCRYPTION_KEY|NC_AUTH_JWT_SECRET) gen_hex 32 ;;
    *) printf '' ;;
  esac
}
# Variables qui DOIVENT exister dans le gabarit (ancre bloquante : le script s'arrete si l'une manque).
REQUIRED="SPARK_PREFIX SPARK_DOMAIN SPARK_HOST_HTTP_PORT POSTGRES_ROOT_PASSWORD N8N_DB_PASSWORD NOCODB_DB_PASSWORD N8N_ENCRYPTION_KEY NC_AUTH_JWT_SECRET"

umask 077
tmp="$(mktemp "${target}.XXXXXX")"
trap 'rm -f "$tmp"' EXIT

while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    [A-Z_0-9]*=*)
      name="${line%%=*}"
      value="$(value_for "$name")"
      if [ -n "$value" ]; then
        printf '%s=%s\n' "$name" "$value"
        continue
      fi
      ;;
  esac
  printf '%s\n' "$line"
done < "$TEMPLATE" > "$tmp"

for name in $REQUIRED; do
  grep -q "^${name}=." "$tmp" || { printf 'gabarit sans ligne %s= : abandon\n' "$name" >&2; exit 2; }
done

mv "$tmp" "$target"
chmod 600 "$target"
trap - EXIT
printf '%s cree (600) : prefix=%s domain=%s port=%s, 5 secrets generes\n' "$target" "$prefix" "$domain" "$port"
