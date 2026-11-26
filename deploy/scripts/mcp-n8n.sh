#!/usr/bin/env bash
# deploy/scripts/mcp-n8n.sh — lance le serveur MCP n8n (n8n-mcp) a la demande, pour Claude Code.
#
# Usage : reference par .mcp.json a la racine du site :
#   {"mcpServers":{"n8n-mcp":{"command":"bash","args":["infra/scripts/mcp-n8n.sh"]}}}
# Copie dans infra/scripts/ avec les autres scripts du kit (etape 2.2 des guides) ; voir CLAUDE-CODE.md.
#
# Le conteneur rejoint le reseau du projet compose et parle a n8n en interne (http://n8n:5678),
# sans passer par Caddy ni par le tunnel. Rien n'est permanent : `-i --rm`, un processus par session
# Claude Code (c'est pourquoi il n'est pas dans le compose : ~512 Mo de RAM economises au repos).
# Image figee par tag ET digest comme celles du compose, jamais :latest. Montee de version = modifier
# la ligne N8N_MCP_IMAGE volontairement, puis `pin-digests.sh` sur ce fichier, puis CHANGELOG.md.
# N8N_API_KEY vient de infra/.env et passe par `-e NOM` sans valeur : jamais sur la ligne de commande.
# WEBHOOK_SECURITY_MODE=permissive : n8n-mcp refuse par defaut d'appeler un webhook dont l'hote est
# une adresse privee ou un nom interne (garde anti-SSRF). Ici la cible EST interne (http://n8n:5678,
# reseau compose, jamais expose) : sans `permissive`, l'outil de declenchement de webhook echoue.
# Le mode ne relache rien cote n8n ; il ne concerne que les URL que le MCP accepte d'appeler.
# Aucune ecriture sur stdout avant l'exec : stdout est le canal MCP (stdio).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

N8N_MCP_IMAGE="ghcr.io/czlonkowski/n8n-mcp:2.104.0@sha256:89048e350b8fc7cf205981d6d6266b2009721d1658848c14b877cfc0750dd964"

INFRA_DIR="$(spark_infra_dir "$SCRIPT_DIR")"
cd "$INFRA_DIR"
spark_load_env ./.env N8N_API_KEY

# Reseau : <projet compose>_spark (name: du compose.yml + reseau `spark`). Jamais code en dur.
PROJECT="$(spark_project_name)"
NETWORK="${SPARK_COMPOSE_NETWORK:-${PROJECT}_spark}"
docker network inspect "$NETWORK" >/dev/null 2>&1 \
  || spark_die "reseau $NETWORK introuvable : la stack tourne-t-elle (docker compose up -d) ?"

exec docker run -i --rm \
  --network "$NETWORK" \
  -e MCP_MODE=stdio \
  -e LOG_LEVEL=error \
  -e DISABLE_CONSOLE_OUTPUT=true \
  -e N8N_API_URL=http://n8n:5678 \
  -e N8N_API_KEY \
  -e N8N_MCP_TELEMETRY_DISABLED=true \
  -e WEBHOOK_SECURITY_MODE=permissive \
  "$N8N_MCP_IMAGE"
