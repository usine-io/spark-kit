#!/usr/bin/env bash
# deploy/scripts/n8n-releve.sh — releve « avant / apres » d'une montee de version n8n (UPGRADES.md).
#
# Usage : n8n-releve.sh [--out <fichier>]
#           ecrit le releve (defaut : infra/backups/releve-n8n-<horodatage>.txt) et l'affiche :
#           version et image n8n, nombre de migrations, IDs des workflows actifs, nombres de
#           workflows / executions / identifiants, memoire du conteneur n8n, latence mediane (ms)
#           de trois endpoints temoins via Caddy (defaut : -n8n /healthz/readiness, -n8n /rest/settings,
#           -app /healthz ; un site met les siens dans SPARK_RELEVE_ENDPOINTS, dans .env ou
#           l'environnement : `nom=service:chemin` separes par des espaces, ex.
#           `stock=app:/webhook/api/stock?limit=10 ...`, GET en 2xx attendu). Les latences se
#           mesurent AVANT la pause de maintenance (en maintenance tout repond 503 sauf
#           /healthz/readiness). Aucune valeur secrete : des comptes, des IDs, des durees.
#         n8n-releve.sh --compare <avant> <apres> [--rollback]
#           compare deux releves et sort 0 si tout passe, 1 sinon :
#           - migrations : apres >= avant (montee) ; avec --rollback, apres == avant ;
#           - workflows actifs : memes IDs, un par un ;
#           - latences : chaque endpoint du releve avant <= 2 x avant + 50 ms apres (critere d'UPGRADES.md).
# Le releve « avant » se fait dans le meme bloc que la sauvegarde (regle : l'outil de comparaison
# refuse de conclure sans lui). La stack doit tourner (n8n pret) pour un releve complet.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

mode=releve out="" before="" after="" rollback=0
while [ $# -gt 0 ]; do
  case "$1" in
    --out) [ $# -ge 2 ] || spark_die "--out attend un chemin"; out="$2"; shift 2 ;;
    --compare) [ $# -ge 3 ] || spark_die "--compare attend deux fichiers"; mode=compare; before="$2"; after="$3"; shift 3 ;;
    --rollback) rollback=1; shift ;;
    -h|--help) sed -n '2,/^[^#]/{/^#/p;}' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) spark_die "option inconnue : $1" ;;
  esac
done

# Valeur d'une cle dans un releve (ligne `cle=valeur`).
rv() { sed -n "s/^$2=//p" "$1" | head -1; }

if [ "$mode" = compare ]; then
  [ -f "$before" ] || spark_die "releve avant introuvable : $before"
  [ -f "$after" ] || spark_die "releve apres introuvable : $after"
  fails=0
  ok()   { printf '  OK    %s\n' "$*"; }
  fail() { printf '  FAIL  %s\n' "$*" >&2; fails=$((fails + 1)); }
  mb="$(rv "$before" migrations)"; ma="$(rv "$after" migrations)"
  case "$mb$ma" in ''|*[!0-9]*) spark_die "nombre de migrations illisible (avant « $mb », apres « $ma »)" ;; esac
  if [ "$rollback" -eq 1 ]; then
    if [ "$ma" -eq "$mb" ]; then ok "migrations : $ma = $mb (retour arriere complet)"; else fail "migrations : $ma apres, $mb avant (retour arriere incomplet)"; fi
  else
    if [ "$ma" -ge "$mb" ]; then ok "migrations : $mb -> $ma"; else fail "migrations : $ma < $mb (base plus ancienne que le releve avant ?)"; fi
  fi
  wb="$(rv "$before" workflows_active)"; wa="$(rv "$after" workflows_active)"
  if [ "$wb" = "$wa" ]; then ok "workflows actifs identiques : ${wb:-(aucun)}"; else fail "workflows actifs : avant « $wb », apres « $wa »"; fi
  while IFS= read -r ep; do
    [ -n "$ep" ] || continue
    lb="$(rv "$before" "latence_${ep}_ms")"; la="$(rv "$after" "latence_${ep}_ms")"
    case "$lb$la" in ''|*[!0-9]*) fail "latence $ep illisible (avant « $lb », apres « $la ») : endpoint hors service ou en maintenance au moment du releve"; continue ;; esac
    limit=$((lb * 2 + 50))
    if [ "$la" -le "$limit" ]; then ok "latence $ep : $lb -> $la ms (<= $limit)"; else fail "latence $ep : $lb -> $la ms (> $limit)"; fi
  done < <(sed -n 's/^latence_\(.*\)_ms=.*/\1/p' "$before")
  printf 'version : %s -> %s ; executions : %s -> %s ; identifiants : %s -> %s\n' \
    "$(rv "$before" n8n_version)" "$(rv "$after" n8n_version)" "$(rv "$before" executions)" "$(rv "$after" executions)" \
    "$(rv "$before" credentials)" "$(rv "$after" credentials)"
  [ "$fails" -eq 0 ] && printf 'COMPARAISON OK\n' || printf 'COMPARAISON : %d ecart(s)\n' "$fails" >&2
  [ "$fails" -eq 0 ]
  exit
fi

INFRA_DIR="$(spark_infra_dir "$SCRIPT_DIR")"
cd "$INFRA_DIR"
spark_load_env ./.env SPARK_PREFIX SPARK_DOMAIN
BACKUP_DIR="${SPARK_BACKUP_DIR:-$INFRA_DIR/backups}"
mkdir -p "$BACKUP_DIR"
[ -n "$out" ] || out="$BACKUP_DIR/releve-n8n-$(date '+%Y%m%d-%H%M%S').txt"
URL="http://127.0.0.1:${SPARK_HOST_HTTP_PORT:-18080}"

psql_n8n() { spark_compose exec -T postgres psql -U postgres -d n8n -Atc "$1" </dev/null 2>/dev/null || printf '?'; }
# Latence mediane de 5 mesures, en millisecondes entieres ; « ? » si le service ne repond pas en 2xx.
latency_ms() {
  local host="$1" path="$2" t code samples=()
  for _ in 1 2 3 4 5; do
    t="$(curl -s -m 20 -o /dev/null -w '%{http_code} %{time_total}' -H "Host: $host" "$URL$path" 2>/dev/null || true)"
    code="${t%% *}"; t="${t#* }"
    case "$code" in 2*) samples+=("$t") ;; *) printf '?'; return ;; esac
  done
  printf '%s\n' "${samples[@]}" | sort -n | sed -n 3p | awk '{ printf "%d", $1 * 1000 + 0.5 }'
}

image="$(spark_service_image n8n 'n8nio/n8n')"
version="$(spark_compose exec -T n8n n8n --version </dev/null 2>/dev/null | tail -1 | tr -d '[:space:]' || true)"
[ -n "$version" ] || version="?"
cid="$(spark_compose ps -q n8n 2>/dev/null || true)"
mem="?"
[ -n "$cid" ] && mem="$(docker stats --no-stream --format '{{.MemUsage}}' "$cid" 2>/dev/null | cut -d/ -f1 | tr -d ' ' || true)"

{
  printf 'horodatage=%s\n' "$(date '+%Y-%m-%dT%H:%M:%S')"
  printf 'hostname=%s\n' "$(hostname)"
  printf 'image=%s\n' "$image"
  printf 'n8n_version=%s\n' "$version"
  printf 'migrations=%s\n' "$(psql_n8n 'SELECT count(*) FROM migrations')"
  printf 'workflows_total=%s\n' "$(psql_n8n 'SELECT count(*) FROM workflow_entity')"
  printf 'workflows_active=%s\n' "$(psql_n8n "SELECT coalesce(string_agg(id, ',' ORDER BY id), '') FROM workflow_entity WHERE active")"
  printf 'executions=%s\n' "$(psql_n8n 'SELECT count(*) FROM execution_entity')"
  printf 'credentials=%s\n' "$(psql_n8n 'SELECT count(*) FROM credentials_entity')"
  printf 'memoire_n8n=%s\n' "${mem:-?}"
  # shellcheck disable=SC2086
  for ep in ${SPARK_RELEVE_ENDPOINTS:-n8n_readiness=n8n:/healthz/readiness n8n_settings=n8n:/rest/settings app_healthz=app:/healthz}; do
    name="${ep%%=*}"; svc="${ep#*=}"; path="${svc#*:}"; svc="${svc%%:*}"
    case "$name" in *[!A-Za-z0-9_]*|'') spark_die "SPARK_RELEVE_ENDPOINTS : nom invalide dans « $ep » (nom=service:chemin)" ;; esac
    printf 'latence_%s_ms=%s\n' "$name" "$(latency_ms "${SPARK_PREFIX}-${svc}.${SPARK_DOMAIN}" "$path")"
  done
} > "$out"
chmod 600 "$out"
cat "$out"
printf 'releve ecrit : %s\n' "$out"
