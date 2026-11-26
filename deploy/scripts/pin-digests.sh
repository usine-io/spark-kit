#!/usr/bin/env bash
# deploy/scripts/pin-digests.sh — fige chaque image d'un fichier par tag ET digest.
#
# Usage : pin-digests.sh [--check] [fichier]        (defaut : deploy/compose.yml)
#   Lignes reconnues : `image: <ref>` (compose) et `<NOM>_IMAGE="<ref>"` (scripts, ex. mcp-n8n.sh).
#   sans option : pour chaque image, `docker pull <repo:tag>`, releve du digest servi par le tag,
#                 reecriture `<repo:tag>@sha256:...` EN PLACE (meme inode), diff affiche.
#   --check     : ne modifie rien ; sortie 1 si un digest du fichier differe de celui que le tag
#                 sert aujourd'hui (derive detectee), 0 sinon.
#
# Le digest releve est celui de l'index multi-architecture resolu par le tag (RepoDigests) :
# il vaut pour amd64 et arm64. Montee de version = changer le tag dans le compose, puis relancer.
# Une image sans tag explicite (`repo` ou `repo@sha256:...`) ou en `:latest` est refusee (code 2) :
# le compose doit dire quelle version il fige.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
check=0
file=""
for arg in "$@"; do
  case "$arg" in
    --check) check=1 ;;
    -h|--help) sed -n '2,/^[^#]/{/^#/p;}' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) file="$arg" ;;
  esac
done
file="${file:-$SCRIPT_DIR/../compose.yml}"
[ -f "$file" ] || { printf 'fichier introuvable : %s\n' "$file" >&2; exit 2; }
docker info >/dev/null 2>&1 || { printf 'docker injoignable\n' >&2; exit 2; }

# Digest de l'index que `repo:tag` resout aujourd'hui.
digest_for() {
  local ref="$1" repo digest
  repo="${ref%%@*}"
  repo="${repo%:*}"
  docker pull -q "$ref" >/dev/null
  digest="$(docker inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$ref" \
    | grep "^${repo}@" | head -1 | sed 's/.*@//')"
  [ -n "$digest" ] || { printf 'aucun RepoDigest pour %s\n' "$ref" >&2; return 1; }
  printf '%s\n' "$digest"
}

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

drift=0
while IFS= read -r line || [ -n "$line" ]; do
  # `image: <ref>` (compose) ou `<NOM>_IMAGE="<ref>"` (scripts) ; guillemets optionnels.
  if [[ "$line" =~ ^([[:space:]]*(image:[[:space:]]*|[A-Z][A-Z0-9_]*_IMAGE=)[\"\']?)([^[:space:]#\"\']+)(.*)$ ]]; then
    prefix="${BASH_REMATCH[1]}"
    ref="${BASH_REMATCH[3]}"
    rest="${BASH_REMATCH[4]}"
    base="${ref%%@*}"
    case "${base##*/}" in
      *:latest) printf 'image en :latest refusee : %s (ecrire repo:<version>)\n' "$base" >&2; exit 2 ;;
      *:*) ;;
      *) printf 'image sans tag refusee : %s (ecrire repo:<version>, jamais :latest implicite)\n' "$base" >&2; exit 2 ;;
    esac
    current="${ref#*@}"
    [ "$current" = "$ref" ] && current=""
    served="$(digest_for "$base")"
    if [ "$current" != "$served" ]; then
      drift=1
      printf '%-45s %s -> %s\n' "$base" "${current:-(aucun)}" "$served" >&2
    fi
    printf '%s%s@%s%s\n' "$prefix" "$base" "$served" "$rest"
  else
    printf '%s\n' "$line"
  fi
done < "$file" > "$tmp"

if [ "$check" -eq 1 ]; then
  if [ "$drift" -eq 1 ]; then
    printf 'DERIVE : les digests de %s ne sont plus ceux servis par leurs tags\n' "$file" >&2
    exit 1
  fi
  printf 'OK : digests de %s conformes aux tags\n' "$file"
  exit 0
fi

if diff -u "$file" "$tmp"; then
  printf 'aucun changement : %s deja fige\n' "$file"
else
  # Ecriture en place (cat >, pas mv) : un fichier monte dans un conteneur garde son inode.
  cat "$tmp" > "$file"
  printf '%s mis a jour\n' "$file"
fi
