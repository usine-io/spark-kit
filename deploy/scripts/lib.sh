#!/usr/bin/env bash
# deploy/scripts/lib.sh — fonctions communes aux scripts du kit. A sourcer, pas a executer.
# Les scripts sont copies tels quels dans infra/scripts/ : ils retrouvent infra/ par leur
# propre chemin (../), ou par SPARK_INFRA_DIR si on les lance depuis ailleurs.

spark_die() {
  printf 'ERREUR: %s\n' "$*" >&2
  exit 2
}

spark_log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

# `docker compose` (plugin v2+) si disponible, sinon `docker-compose` (binaire autonome,
# meme syntaxe de fichier). Les deux acceptent compose.yml comme nom par defaut.
spark_compose() {
  if docker compose version >/dev/null 2>&1; then
    docker compose "$@"
  elif command -v docker-compose >/dev/null 2>&1; then
    docker-compose "$@"
  else
    spark_die "ni 'docker compose' ni 'docker-compose' n'est disponible"
  fi
}

# Repertoire infra/ : SPARK_INFRA_DIR, sinon le parent du repertoire du script appelant.
# Un script sans .env sort en erreur (jamais de faux vert « rien a faire »).
spark_infra_dir() {
  local script_dir="$1" dir
  dir="${SPARK_INFRA_DIR:-$(cd "$script_dir/.." && pwd)}"
  [ -f "$dir/compose.yml" ] || spark_die "compose.yml introuvable dans $dir (SPARK_INFRA_DIR ?)"
  [ -f "$dir/.env" ] || spark_die ".env introuvable dans $dir"
  printf '%s\n' "$dir"
}

# Charge .env dans l'environnement (set -a) et verifie la presence des variables demandees,
# par NOM uniquement : rien n'est affiche.
spark_load_env() {
  local env_file="$1" var
  shift
  set -a
  # shellcheck disable=SC1090
  . "$env_file"
  set +a
  for var in "$@"; do
    [ -n "${!var:-}" ] || spark_die "variable $var vide ou absente dans $env_file"
  done
}

# Nom du projet compose (prefixe des volumes et des conteneurs). Jamais code en dur.
spark_project_name() {
  local name
  name="$(spark_compose config --format json 2>/dev/null | jq -r '.name // empty' 2>/dev/null || true)"
  if [ -z "$name" ]; then
    name="$(sed -n 's/^name:[[:space:]]*//p' compose.yml | head -1)"
  fi
  printf '%s\n' "${name:-spark}"
}

# Alerte d'echec : toujours sur stderr, et vers SPARK_ALERT_WEBHOOK (POST JSON) s'il est defini.
spark_alert() {
  local script="$1" message="$2" payload
  printf 'ALERTE [%s] %s: %s\n' "$(hostname)" "$script" "$message" >&2
  if [ -n "${SPARK_ALERT_WEBHOOK:-}" ]; then
    payload="$(jq -cn --arg host "$(hostname)" --arg script "$script" --arg message "$message" \
      --arg ts "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
      '{host: $host, script: $script, message: $message, ts: $ts, status: "failure"}')"
    curl -fsS -m 15 -A "spark-kit-alert/1" -H 'Content-Type: application/json' \
      -d "$payload" "$SPARK_ALERT_WEBHOOK" >/dev/null 2>&1 \
      || printf 'ALERTE: le webhook SPARK_ALERT_WEBHOOK n a pas repondu\n' >&2
  fi
}
