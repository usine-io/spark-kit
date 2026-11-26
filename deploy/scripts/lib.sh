#!/usr/bin/env bash
# deploy/scripts/lib.sh — fonctions communes aux scripts du kit. A sourcer, pas a executer.
# Les scripts sont copies tels quels dans infra/scripts/ : ils retrouvent infra/ par leur
# propre chemin (../), ou par SPARK_INFRA_DIR si on les lance depuis ailleurs.
# Compatible bash 3.2 (macOS) et bash 5 (Linux).
#
# Le .env est SOURCE COMME DU SHELL (`. .env`), par les scripts du kit comme par ce fichier-ci :
# toute valeur qui contient `$`, un accent grave ou une espace doit etre entre guillemets simples
# (NOM='valeur avec $ ou espace'), sinon elle est interpretee ou coupee. init-env.sh ne genere que
# des valeurs A-Za-z0-9 ; check-env.sh juge la valeur telle que le shell la resout.

# Derniere erreur emise par spark_die : reprise dans le message d'alerte (spark_alert).
# Les messages de spark_die nomment des fichiers et des variables, jamais une valeur secrete.
SPARK_LAST_ERROR=""

# Alerte des la premiere erreur. Un script qui veut alerter pose SPARK_ALERT_SCRIPT="backup.sh"
# juste apres avoir source lib.sh, AVANT spark_infra_dir / spark_load_env : des lors tout spark_die
# (.env absent, variable obligatoire manquante, outil absent...) ecrit la ligne ALERTE sur stderr
# et appelle SPARK_ALERT_WEBHOOK s'il est connu (environnement, ou .env deja charge). Une fois le
# trap EXIT du script en place (le script pose SPARK_ALERT_TRAP=1), c'est le trap qui alerte, avec
# le code de sortie et le contexte : spark_die ne double pas l'alerte.
SPARK_ALERT_SCRIPT=""
SPARK_ALERT_TRAP=0

spark_die() {
  SPARK_LAST_ERROR="$*"
  printf 'ERREUR: %s\n' "$*" >&2
  if [ -n "$SPARK_ALERT_SCRIPT" ] && [ "$SPARK_ALERT_TRAP" -eq 0 ]; then
    spark_alert "$SPARK_ALERT_SCRIPT" "arret avant tout travail (code 2)"
  fi
  exit 2
}

# Meme sortie en code 2, sans alerte : pour les cas ou rien n'est casse (verrou deja pris).
spark_die_quiet() {
  SPARK_LAST_ERROR="$*"
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

# Valeur « utile » d'une variable : sans les espaces (les guillemets sont deja retires par le
# shell qui a charge le .env). Vide si la variable n'est pas definie.
spark_env_value() {
  local name="$1" value
  value="${!name:-}"
  printf '%s' "$value" | tr -d '[:space:]'
}

# Charge .env dans l'environnement (set -a) et verifie la presence des variables demandees,
# par NOM uniquement : rien n'est affiche.
# Priorite : une variable DEJA NON VIDE dans l'environnement (ligne de commande, Environment=
# d'une unit systemd) l'emporte sur le .env, y compris sur une ligne vide « NOM= » — meme regle
# que docker compose. Le .env fait foi pour tout ce qui n'est pas pose dans l'environnement.
spark_load_env() {
  local env_file="$1" var name line
  shift
  local kept=()
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      [A-Za-z_]*=*)
        name="${line%%=*}"
        case "$name" in *[!A-Za-z0-9_]*) continue ;; esac
        [ -n "${!name:-}" ] && kept+=("$name=${!name}")
        ;;
    esac
  done < "$env_file"
  set -a
  # shellcheck disable=SC1090
  . "$env_file"
  set +a
  if [ "${#kept[@]}" -gt 0 ]; then
    for line in "${kept[@]}"; do export "${line?}"; done
  fi
  for var in "$@"; do
    [ -n "$(spark_env_value "$var")" ] || spark_die "variable $var absente ou vide dans $env_file"
  done
}

# Verrou d'execution (un seul backup.sh, un seul restore-test.sh a la fois).
# `flock -n` quand il existe (Linux) ; sinon (macOS) un repertoire + pid, libere par spark_unlock.
# Appele AVANT le trap EXIT des scripts : un deuxieme lancement sort en code 2 avec un message
# clair, sans alerte (spark_die_quiet : rien n'est casse, la premiere execution continue).
SPARK_LOCK_DIR=""
spark_lock() {
  local lock="$1" what="$2" pid
  if command -v flock >/dev/null 2>&1; then
    exec 9>>"$lock"
    flock -n 9 || spark_die_quiet "$what deja en cours d'execution (verrou $lock) : rien n'est fait"
  else
    if ! mkdir "$lock.d" 2>/dev/null; then
      pid="$(cat "$lock.d/pid" 2>/dev/null || true)"
      if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        spark_die_quiet "$what deja en cours d'execution (pid $pid, verrou $lock.d) : rien n'est fait"
      fi
      rm -rf "$lock.d"
      mkdir "$lock.d" || spark_die "verrou $lock.d impossible a poser"
    fi
    printf '%s\n' "$$" > "$lock.d/pid"
    SPARK_LOCK_DIR="$lock.d"
  fi
}
spark_unlock() {
  [ -n "$SPARK_LOCK_DIR" ] && rm -rf "$SPARK_LOCK_DIR"
  SPARK_LOCK_DIR=""
  return 0
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

# Image (tag@digest) d'un service telle que le compose la fige, sans exiger que le service
# tourne : `config --format json` + jq, sinon `config --images` filtre par le depot de l'image.
#   spark_service_image postgres 'postgres'      spark_service_image n8n 'n8nio/n8n'
spark_service_image() {
  local service="$1" repo="$2" image
  image="$(spark_compose config --format json 2>/dev/null | jq -r --arg s "$service" '.services[$s].image // empty' 2>/dev/null || true)"
  if [ -z "$image" ]; then
    image="$(spark_compose config --images 2>/dev/null | grep -E "^(docker\.io/)?(library/)?${repo}[:@]" | head -1 || true)"
  fi
  [ -n "$image" ] || spark_die "image du service $service introuvable dans compose.yml (docker compose config)"
  printf '%s\n' "$image"
}

# Alerte d'echec : toujours sur stderr (donc dans le journal du timer), et vers SPARK_ALERT_WEBHOOK
# (POST JSON) s'il est defini. Sans .env lisible, le webhook n'est connu que s'il est pose dans
# l'environnement (Environment= de l'unit) : la ligne ALERTE, elle, sort toujours.
# La derniere ligne ERREUR du script (SPARK_LAST_ERROR) est jointe : elle ne porte jamais de valeur
# secrete, seulement des noms de fichiers et de variables.
spark_json_escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\n'; }
spark_alert() {
  local script="$1" message="$2" payload
  [ -n "$SPARK_LAST_ERROR" ] && message="$message — ERREUR: $SPARK_LAST_ERROR"
  printf 'ALERTE [%s] %s: %s\n' "$(hostname)" "$script" "$message" >&2
  if [ -n "${SPARK_ALERT_WEBHOOK:-}" ]; then
    if command -v jq >/dev/null 2>&1; then
      payload="$(jq -cn --arg host "$(hostname)" --arg script "$script" --arg message "$message" \
        --arg error "$SPARK_LAST_ERROR" --arg ts "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
        '{host: $host, script: $script, message: $message, error: $error, ts: $ts, status: "failure"}')"
    else
      # Sans jq (poste sans l'outil) : JSON minimal, guillemets et antislashs echappes a la main.
      payload="$(printf '{"host":"%s","script":"%s","message":"%s","error":"%s","ts":"%s","status":"failure"}' \
        "$(spark_json_escape "$(hostname)")" "$(spark_json_escape "$script")" "$(spark_json_escape "$message")" \
        "$(spark_json_escape "$SPARK_LAST_ERROR")" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')")"
    fi
    curl -fsS -m 15 -A "spark-kit-alert/1" -H 'Content-Type: application/json' \
      -d "$payload" "$SPARK_ALERT_WEBHOOK" >/dev/null 2>&1 \
      || printf 'ALERTE: le webhook SPARK_ALERT_WEBHOOK n a pas repondu\n' >&2
  fi
}
