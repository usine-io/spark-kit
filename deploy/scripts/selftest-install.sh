#!/usr/bin/env bash
# deploy/scripts/selftest-install.sh — rejoue l'installation du guide dans un repertoire temporaire.
#
# Usage : selftest-install.sh [--up] [--keep]
#   (defaut) copie deploy/ comme le guide le demande, cree un .env de test, puis :
#            `docker compose config` sans variable manquante, `caddy validate` avec sites.d/ vide
#            puis avec un fichier, et verifie que chaque chemin monte existe (test -f).
#   --up     demarre ensuite la stack sous le projet compose `spark-selftest` (port hote 18090),
#            attend que -n8n et -db repondent via Caddy, puis detruit tout (down -v).
#   --keep   conserve le repertoire temporaire (affiche) pour inspection.
# Sortie 0 si tout passe, 1 sinon. Ne touche pas a une stack `spark` deja presente sur la machine.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

up=0 keep=0
for arg in "$@"; do
  case "$arg" in
    --up) up=1 ;;
    --keep) keep=1 ;;
    -h|--help) sed -n '2,11p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 1 ;;
    *) printf 'option inconnue : %s\n' "$arg" >&2; exit 1 ;;
  esac
done

PROJECT=spark-selftest
PORT=18090
PREFIX=acme
DOMAIN=acme.example
fails=0
ok()   { printf '  OK    %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*" >&2; fails=$((fails + 1)); }

work="$(mktemp -d "${TMPDIR:-/tmp}/spark-selftest-XXXXXX")"
INFRA="$work/infra"
cleanup() {
  if [ "$up" -eq 1 ] && [ -f "$INFRA/compose.yml" ]; then
    (cd "$INFRA" && spark_compose -p "$PROJECT" down -v --remove-orphans >/dev/null 2>&1) || true
  fi
  if [ "$keep" -eq 1 ]; then
    printf 'repertoire conserve : %s\n' "$work"
  else
    rm -rf "$work"
  fi
}
trap cleanup EXIT

printf '== 1. Copies du guide (source : %s/deploy)\n' "$KIT_DIR"
mkdir -p "$INFRA"/{apps,logs,backups,scripts}
cp "$KIT_DIR/deploy/compose.yml" "$INFRA/compose.yml"
cp "$KIT_DIR/deploy/env.example" "$INFRA/env.example"
cp -R "$KIT_DIR/deploy/config" "$INFRA/"
chmod +x "$INFRA/config/postgres/init-db.sh"
cp "$KIT_DIR"/deploy/scripts/*.sh "$INFRA/scripts/"
chmod +x "$INFRA"/scripts/*.sh
"$INFRA/scripts/init-env.sh" --prefix "$PREFIX" --domain "$DOMAIN" --port "$PORT" "$INFRA/.env" >/dev/null
# Un bind mount vers un fichier absent fait creer un REPERTOIRE vide par Docker : test -f, pas -e.
for f in compose.yml env.example .env config/postgres/init-db.sh config/caddy/Caddyfile config/caddy/sites.d/.keep; do
  if [ -f "$INFRA/$f" ]; then ok "$f present"; else fail "$f absent"; fi
done
if [ -d "$INFRA/apps" ]; then ok "apps/ present"; else fail "apps/ absent"; fi
mode="$(stat -c %a "$INFRA/.env" 2>/dev/null || stat -f %Lp "$INFRA/.env")"
if [ "$mode" = "600" ]; then ok ".env en 600"; else fail ".env en $mode, attendu 600"; fi

printf '== 2. docker compose config\n'
cd "$INFRA"
if out="$(spark_compose -p "$PROJECT" config -q 2>&1)"; then
  if printf '%s' "$out" | grep -qi 'variable is not set'; then
    fail "variables manquantes :"; printf '%s\n' "$out" | grep -i 'variable is not set' >&2
  else
    ok "compose config valide, aucune variable manquante"
  fi
else
  fail "compose config : $out"
fi

printf '== 3. env.example tel quel (toute variable lue par le compose doit y figurer)\n'
mkdir -p "$work/envcheck/config" && cp "$KIT_DIR/deploy/compose.yml" "$work/envcheck/" \
  && cp "$KIT_DIR/deploy/env.example" "$work/envcheck/.env"
if out="$(cd "$work/envcheck" && spark_compose -p "$PROJECT-env" config -q 2>&1)" \
   && ! printf '%s' "$out" | grep -qi 'variable is not set'; then
  ok "env.example couvre toutes les variables du compose"
else
  fail "env.example incomplet : $(printf '%s' "$out" | grep -i 'variable is not set' || printf '%s' "$out")"
fi

printf '== 4. caddy validate\n'
caddy_image="$(spark_compose -p "$PROJECT" config --images 2>/dev/null | grep '^caddy' || true)"
[ -n "$caddy_image" ] || caddy_image="$(sed -n 's/^[[:space:]]*image:[[:space:]]*\(caddy:[^[:space:]]*\).*/\1/p' compose.yml | head -1)"
caddy_validate() {
  docker run --rm -v "$INFRA/config/caddy:/etc/caddy:ro" \
    -e SPARK_PREFIX="$PREFIX" -e SPARK_DOMAIN="$DOMAIN" \
    "$caddy_image" caddy validate --config /etc/caddy/Caddyfile 2>&1
}
if out="$(caddy_validate)"; then ok "Caddyfile valide, sites.d/ vide"; else fail "Caddyfile (sites.d vide) : $out"; fi
printf 'http://%s-selftest.%s {\n    respond "selftest" 200\n}\n' "$PREFIX" "$DOMAIN" > "$INFRA/config/caddy/sites.d/selftest.caddy"
if out="$(caddy_validate)"; then ok "Caddyfile valide, un fichier dans sites.d/"; else fail "Caddyfile (sites.d/selftest.caddy) : $out"; fi

printf '== 5. Scripts : syntaxe bash\n'
for s in "$INFRA"/scripts/*.sh; do
  if bash -n "$s"; then ok "$(basename "$s")"; else fail "$(basename "$s") : erreur de syntaxe"; fi
done

if [ "$up" -eq 1 ]; then
  printf '== 6. docker compose up (projet %s, port %s)\n' "$PROJECT" "$PORT"
  spark_compose -p "$PROJECT" up -d --quiet-pull 2>&1 | grep -v -E '^\s*$' | sed 's/^/        /' || true
  probe() {
    curl -s -o /dev/null -w '%{http_code}' -H "Host: $PREFIX-$1.$DOMAIN" "http://127.0.0.1:$PORT/" 2>/dev/null || printf '000'
  }
  for svc in n8n db selftest; do
    code=000
    for _ in $(seq 1 90); do
      code="$(probe "$svc")"
      case "$code" in 200|301|302) break ;; esac
      sleep 2
    done
    case "$code" in
      200|301|302) ok "-$svc repond via Caddy ($code)" ;;
      *) fail "-$svc ne repond pas via Caddy ($code)" ;;
    esac
  done
  # Fichier de sites.d/ reellement servi (pas seulement valide)
  body="$(curl -s -H "Host: $PREFIX-selftest.$DOMAIN" "http://127.0.0.1:$PORT/" 2>/dev/null || true)"
  if [ "$body" = "selftest" ]; then ok "sites.d/selftest.caddy servi (corps verifie)"; else fail "sites.d/selftest.caddy non servi (corps : '$body')"; fi
  spark_compose -p "$PROJECT" ps --format 'table {{.Name}}\t{{.Image}}\t{{.Status}}' 2>/dev/null | sed 's/^/        /' || true
fi

printf '== Resultat : %d echec(s)\n' "$fails"
[ "$fails" -eq 0 ]
