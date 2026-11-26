#!/usr/bin/env bash
# deploy/scripts/selftest-install.sh — rejoue l'installation du guide dans un repertoire temporaire.
#
# Usage : selftest-install.sh [--up] [--keep]
#   (defaut) copie deploy/ comme le guide le demande, cree un .env de test, puis :
#            `docker compose config` sans variable manquante (sans profil, puis avec les profils
#            tunnel et runners et l'override compose.runners.yml), `caddy validate` avec sites.d/
#            vide puis avec un fichier, `caddy fmt --diff` sans ecart, verifie que chaque chemin
#            monte existe (test -f), puis teste check-env.sh (valeurs vides, espaces, un caractere,
#            variable exportee mais ligne absente), la priorite environnement > .env de lib.sh, le
#            verrou d'execution, l'alerte de backup.sh quand il s'arrete avant d'avoir commence
#            (.env absent : ligne ALERTE ; variable manquante : ligne ALERTE + POST recu par un
#            webhook local), tunnel-config.sh (config ecrite depuis le .env, --check), et shellcheck
#            sur les scripts s'il est installe.
#   --up     demarre ensuite la stack sous le projet compose `spark-selftest` (port hote 18090),
#            verifie que cloudflared et runners ne demarrent PAS sans profil, attend que -n8n
#            (/healthz/readiness) et -db repondent via Caddy avec un MARQUEUR dans le corps, que les
#            trois services deviennent `healthy`, qu'un Host inconnu recoit 404, que les en-tetes de
#            securite sont la sur chaque vhost (et le CORS de -db), que le drapeau MAINTENANCE donne
#            503 partout puis se retire, que le journal d'acces s'ecrit, que la config cloudflared
#            generee passe `cloudflared tunnel ingress validate`, que le sidecar runners demarre avec
#            son profil ; puis, si `age` est installe, joue backup.sh et restore-test.sh sur cette
#            stack et verifie que le nombre de volumes Docker anonymes est le meme avant et apres
#            (restore-test.sh ne laisse rien), puis detruit tout.
#   --keep   conserve le repertoire temporaire (affiche) pour inspection.
# Sortie 0 si tout passe, 1 sinon. Ne touche pas a une stack `spark` deja presente sur la machine.
# Se lance depuis le DEPOT DU KIT (spark-kit/deploy/scripts/) : la copie dans infra/scripts/ n'a pas
# deploy/ a cote d'elle et s'arrete avec un message explicite.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
if [ ! -f "$KIT_DIR/deploy/compose.yml" ] || [ ! -f "$KIT_DIR/deploy/env.example" ]; then
  printf 'selftest-install.sh : pas de deploy/ a cote de ce script (%s).\n' "$SCRIPT_DIR" >&2
  printf 'Il se lance depuis le depot du kit, pas depuis la copie infra/scripts/ :\n' >&2
  printf '  Linux : ~/spark-kit/deploy/scripts/selftest-install.sh --up\n  macOS : ~/spark/spark-kit/deploy/scripts/selftest-install.sh --up\n' >&2
  exit 1
fi
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

up=0 keep=0
for arg in "$@"; do
  case "$arg" in
    --up) up=1 ;;
    --keep) keep=1 ;;
    -h|--help) sed -n '2,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 1 ;;
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
    (cd "$INFRA" && COMPOSE_PROFILES=tunnel,runners spark_compose -p "$PROJECT" -f compose.yml -f compose.runners.yml down -v --remove-orphans >/dev/null 2>&1) || true
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
cp "$KIT_DIR/deploy/compose.runners.yml" "$INFRA/compose.runners.yml"
cp "$KIT_DIR/deploy/env.example" "$INFRA/env.example"
cp -R "$KIT_DIR/deploy/config" "$INFRA/"
chmod +x "$INFRA/config/postgres/init-db.sh"
cp "$KIT_DIR"/deploy/scripts/*.sh "$INFRA/scripts/"
chmod +x "$INFRA"/scripts/*.sh
"$INFRA/scripts/init-env.sh" --prefix "$PREFIX" --domain "$DOMAIN" --port "$PORT" "$INFRA/.env" >/dev/null
# Un bind mount vers un fichier absent fait creer un REPERTOIRE vide par Docker : test -f, pas -e.
for f in compose.yml compose.runners.yml env.example .env config/postgres/init-db.sh config/caddy/Caddyfile config/caddy/sites.d/.keep; do
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
# Profils et override : tout doit se resoudre aussi (variables du tunnel et du sidecar dans env.example).
if out="$(COMPOSE_PROFILES=tunnel,runners spark_compose -p "$PROJECT" -f compose.yml -f compose.runners.yml config -q 2>&1)" \
   && ! printf '%s' "$out" | grep -qi 'variable is not set'; then
  ok "compose config valide avec les profils tunnel + runners et compose.runners.yml"
else
  fail "compose config (profils + override) : $out"
fi
services="$(spark_compose -p "$PROJECT" config --services 2>/dev/null | sort | tr '\n' ' ')"
case " $services" in
  *" cloudflared "*|*" runners "*) fail "sans profil, cloudflared/runners ne doivent pas etre actifs : $services" ;;
  *) ok "sans profil : $services" ;;
esac

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
# Un vhost de site, ecrit comme le guide le demande : il importe les deux snippets du kit.
printf 'http://%s-selftest.%s {\n\timport maintenance\n\timport securite\n\trespond "selftest" 200\n}\n' "$PREFIX" "$DOMAIN" > "$INFRA/config/caddy/sites.d/selftest.caddy"
if out="$(caddy_validate)"; then ok "Caddyfile valide, un fichier dans sites.d/ (import des snippets)"; else fail "Caddyfile (sites.d/selftest.caddy) : $out"; fi
# Format caddy fmt : seul le diff compte (le code de sortie varie selon la version).
fmt_diff="$(docker run --rm -v "$INFRA/config/caddy:/etc/caddy:ro" "$caddy_image" caddy fmt --diff /etc/caddy/Caddyfile 2>&1 | grep -E '^[+-]' || true)"
if [ -z "$fmt_diff" ]; then ok "Caddyfile au format caddy fmt"; else fail "Caddyfile pas au format caddy fmt :"; printf '%s\n' "$fmt_diff" | head -5 >&2; fi

printf '== 5. Scripts : syntaxe bash (et shellcheck s il est installe)\n'
for s in "$INFRA"/scripts/*.sh; do
  if bash -n "$s"; then ok "$(basename "$s")"; else fail "$(basename "$s") : erreur de syntaxe"; fi
done
if command -v shellcheck >/dev/null 2>&1; then
  if out="$(cd "$KIT_DIR" && shellcheck -x deploy/scripts/*.sh deploy/config/postgres/init-db.sh 2>&1)"; then
    ok "shellcheck sans remarque"
  else
    fail "shellcheck :"; printf '%s\n' "$out" | head -20 >&2
  fi
else
  printf '  INFO  shellcheck absent : non joue (apt install shellcheck / brew install shellcheck)\n'
fi

printf '== 6. check-env.sh : valeur resolue, sans guillemets ni espaces (cas T19)\n'
# Le .env genere est complet ; puis des copies ou SPARK_PREFIX est vide, fait d'espaces, long d'un
# caractere, entre guillemets, ou absent. Jamais de faux vert sur '' ou '  ', jamais de faux rouge sur 'a'.
if out="$("$INFRA/scripts/check-env.sh" --env "$INFRA/.env" 2>&1)"; then ok ".env genere : $(printf '%s' "$out" | grep -c '^OK') variables renseignees"; else fail "check-env sur le .env genere : $out"; fi
env_case() {  # libelle, ligne SPARK_PREFIX a substituer ('' = ligne retiree), resultat attendu (0 ou 1)
  local label="$1" line="$2" want="$3" f="$work/env-case" rc=0 out
  grep -v '^SPARK_PREFIX=' "$INFRA/.env" > "$f"
  [ -n "$line" ] && printf '%s\n' "$line" >> "$f"
  out="$("$INFRA/scripts/check-env.sh" --env "$f" SPARK_PREFIX 2>&1)" || rc=$?
  if [ "$rc" -eq "$want" ]; then ok "SPARK_PREFIX $label -> code $rc ($out)"; else fail "SPARK_PREFIX $label -> code $rc, attendu $want ($out)"; fi
}
env_case "vide (NOM=)" "SPARK_PREFIX=" 1
env_case "guillemets vides" "SPARK_PREFIX=''" 1
env_case "espaces entre guillemets" "SPARK_PREFIX='  '" 1
env_case "espaces nus" "SPARK_PREFIX=   " 1
env_case "un caractere" "SPARK_PREFIX=a" 0
env_case "un caractere entre guillemets" 'SPARK_PREFIX="a"' 0
env_case "ligne absente" "" 1
# Seul le FICHIER compte : une variable exportee dans le shell appelant ne doit pas faire passer une ligne absente.
grep -v '^SPARK_PREFIX=' "$INFRA/.env" > "$work/env-case"
rc=0; out="$(SPARK_PREFIX=exportee "$INFRA/scripts/check-env.sh" --env "$work/env-case" SPARK_PREFIX 2>&1)" || rc=$?
if [ "$rc" -eq 1 ]; then ok "SPARK_PREFIX exportee dans le shell, ligne absente -> code 1 ($out)"; else fail "SPARK_PREFIX exportee, ligne absente -> code $rc, attendu 1 ($out)"; fi
rm -f "$work/env-case"

printf '== 7. lib.sh : priorite de l environnement sur une ligne vide du .env, verrou\n'
printf 'SPARK_ALERT_WEBHOOK=\nOTHER=from-env-file\n' > "$work/env-prec"
out="$(cd "$INFRA/scripts" && SPARK_ALERT_WEBHOOK=http://acme.example/hook OTHER='' bash -c '. ./lib.sh; spark_load_env "$1"; printf "%s|%s" "$SPARK_ALERT_WEBHOOK" "$OTHER"' _ "$work/env-prec")"
if [ "$out" = "http://acme.example/hook|from-env-file" ]; then ok "variable posee gardee, variable vide prise au .env ($out)"; else fail "priorite .env/environnement : « $out »"; fi
if (cd "$INFRA/scripts" && bash -c '. ./lib.sh; spark_load_env "$1" OTHER' _ "$work/env-prec" >/dev/null 2>&1); then ok "spark_load_env accepte une variable renseignee"; else fail "spark_load_env refuse OTHER renseignee"; fi
if (cd "$INFRA/scripts" && bash -c '. ./lib.sh; spark_load_env "$1" SPARK_ALERT_WEBHOOK' _ "$work/env-prec" >/dev/null 2>&1); then fail "spark_load_env accepte une variable vide"; else ok "spark_load_env refuse une variable vide (absente ou vide)"; fi
rm -f "$work/env-prec"
# Verrou : un premier detenteur garde le verrou 3 s, le second doit sortir en 2 avec le message.
(cd "$INFRA/scripts" && bash -c '. ./lib.sh; spark_lock "$1" premier; sleep 3; spark_unlock' _ "$work/lock") &
holder=$!
sleep 1
out="$(cd "$INFRA/scripts" && bash -c '. ./lib.sh; spark_lock "$1" second' _ "$work/lock" 2>&1)" && rc=0 || rc=$?
wait "$holder" || true
case "$rc:$out" in
  2:*"deja en cours d'execution"*) ok "verrou : second lancement refuse ($out)" ;;
  *) fail "verrou : code $rc, sortie « $out »" ;;
esac
if (cd "$INFRA/scripts" && bash -c '. ./lib.sh; spark_lock "$1" apres; spark_unlock' _ "$work/lock" >/dev/null 2>&1); then ok "verrou libere apres la premiere execution"; else fail "verrou non libere"; fi

printf '== 7.b backup.sh : alerte meme quand le script s arrete avant d avoir commence\n'
# .env absent : code 2, ligne ERREUR et ligne ALERTE sur stderr (le journal du timer les garde).
mkdir -p "$work/alert-infra" && cp "$INFRA/compose.yml" "$work/alert-infra/"
rc=0; out="$(SPARK_INFRA_DIR="$work/alert-infra" "$INFRA/scripts/backup.sh" 2>&1)" || rc=$?
case "$rc:$out" in
  2:*"ERREUR: .env introuvable"*"ALERTE ["*"backup.sh"*) ok ".env absent -> code 2, ERREUR puis ALERTE sur stderr" ;;
  *) fail ".env absent -> code $rc, sortie « $out »" ;;
esac
# Variable obligatoire manquante, webhook renseigne dans le .env : ALERTE + POST JSON recu.
if command -v python3 >/dev/null 2>&1; then
  python3 - "$work/hook" > "$work/hook.port" <<'PY' &
import http.server, sys
out = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get('Content-Length', 0)))
        open(out, 'wb').write(body)
        self.send_response(200); self.end_headers()
    def log_message(self, *a): pass
srv = http.server.HTTPServer(('127.0.0.1', 0), H)
print(srv.server_address[1], flush=True)
srv.handle_request()
PY
  hook_pid=$!
  for _ in $(seq 1 50); do [ -s "$work/hook.port" ] && break; sleep 0.1; done
  hook_port="$(cat "$work/hook.port")"
  grep -v -E '^(N8N_ENCRYPTION_KEY|SPARK_ALERT_WEBHOOK)=' "$INFRA/.env" > "$work/alert-infra/.env"
  printf 'SPARK_ALERT_WEBHOOK=http://127.0.0.1:%s/hook\n' "$hook_port" >> "$work/alert-infra/.env"
  rc=0; out="$(SPARK_INFRA_DIR="$work/alert-infra" "$INFRA/scripts/backup.sh" 2>&1)" || rc=$?
  for _ in $(seq 1 50); do { [ -s "$work/hook" ] || ! kill -0 "$hook_pid" 2>/dev/null; } && break; sleep 0.1; done
  body="$(cat "$work/hook" 2>/dev/null || true)"
  case "$rc:$out" in
    2:*"ERREUR: variable N8N_ENCRYPTION_KEY absente"*"ALERTE ["*) ok "N8N_ENCRYPTION_KEY absente -> code 2, ERREUR puis ALERTE" ;;
    *) fail "N8N_ENCRYPTION_KEY absente -> code $rc, sortie « $out »" ;;
  esac
  case "$body" in
    *'"script":"backup.sh"'*N8N_ENCRYPTION_KEY*'"status":"failure"'*) ok "webhook : POST JSON recu, nomme la variable manquante" ;;
    *) fail "webhook : rien recu ou corps inattendu « ${body:0:120} »" ;;
  esac
  kill "$hook_pid" 2>/dev/null || true
else
  printf '  INFO  python3 absent : POST du webhook non teste (la ligne ALERTE l est)\n'
fi
rm -rf "$work/alert-infra" "$work/hook" "$work/hook.port"

printf '== 7.c tunnel-config.sh : config cloudflared ecrite depuis le .env, sans secret\n'
tunnel_id="12345678-1234-4123-8123-123456789abc"
mkdir -p "$work/tunnel-infra" "$work/cfd" && cp "$INFRA/compose.yml" "$work/tunnel-infra/" && cp -R "$INFRA/scripts" "$work/tunnel-infra/"
grep -v -E '^(SPARK_TUNNEL_ID|SPARK_TUNNEL_DIR)=' "$INFRA/.env" > "$work/tunnel-infra/.env"
printf 'SPARK_TUNNEL_ID=%s\nSPARK_TUNNEL_DIR=%s\n' "$tunnel_id" "$work/cfd" >> "$work/tunnel-infra/.env"
rc=0; out="$("$work/tunnel-infra/scripts/tunnel-config.sh" 2>&1)" || rc=$?
case "$rc:$out" in 2:*"identifiants du tunnel absents"*) ok "sans <id>.json : refus explicite (code 2)" ;; *) fail "sans <id>.json : code $rc, « $out »" ;; esac
printf '{}' > "$work/cfd/$tunnel_id.json"
if out="$("$work/tunnel-infra/scripts/tunnel-config.sh" 2>&1)" && [ -f "$work/cfd/config.yml" ] \
   && grep -q "service: http://caddy:80" "$work/cfd/config.yml" && grep -q "credentials-file: /etc/cloudflared/$tunnel_id.json" "$work/cfd/config.yml" \
   && [ "$(grep -c "hostname: $PREFIX-" "$work/cfd/config.yml")" -eq 3 ]; then
  ok "config.yml (conteneur) : 3 ingress vers caddy:80, credentials sous /etc/cloudflared/"
else
  fail "config.yml (conteneur) : $out"
fi
if "$work/tunnel-infra/scripts/tunnel-config.sh" --check >/dev/null 2>&1; then ok "--check : config conforme au .env (code 0)"; else fail "--check devrait sortir 0 sur une config a jour"; fi
if out="$("$work/tunnel-infra/scripts/tunnel-config.sh" --host 2>&1)" && grep -q "service: http://localhost:$PORT" "$work/cfd/config-spark.yml" \
   && grep -q "credentials-file: $work/cfd/$tunnel_id.json" "$work/cfd/config-spark.yml"; then
  ok "config-spark.yml (variante hote) : ingress vers localhost:$PORT"
else
  fail "config-spark.yml (variante hote) : $out"
fi
if grep -rq -E 'PASSWORD|SECRET|TOKEN' "$work/cfd/config.yml" "$work/cfd/config-spark.yml"; then fail "la config cloudflared contient un nom de secret"; else ok "aucun secret dans la config cloudflared"; fi

if [ "$up" -eq 1 ]; then
  printf '== 8. docker compose up (projet %s, port %s)\n' "$PROJECT" "$PORT"
  spark_compose -p "$PROJECT" up -d --quiet-pull 2>&1 | grep -v -E '^\s*$' | sed 's/^/        /' || true
  running="$(spark_compose -p "$PROJECT" ps --services 2>/dev/null | sort | tr '\n' ' ')"
  case " $running" in
    *" cloudflared "*|*" runners "*) fail "cloudflared ou runners demarre sans profil : $running" ;;
    *) ok "sans profil, services demarres : $running" ;;
  esac
  # Sonde par marqueur : un code 200 ne prouve pas le routage, on exige un fragment du corps propre
  # au service (et, depuis ce lot, un Host inconnu recoit 404).
  probe() {
    curl -s -m 10 -H "Host: $PREFIX-$1.$DOMAIN" "http://127.0.0.1:$PORT$2" 2>/dev/null || true
  }
  code_of() {  # service, chemin [, options curl] -> code HTTP
    local svc="$1" path="$2"; shift 2
    curl -s -m 10 -o /dev/null -w '%{http_code}' -H "Host: $PREFIX-$svc.$DOMAIN" "$@" "http://127.0.0.1:$PORT$path" 2>/dev/null || printf '000'
  }
  headers_of() { curl -s -m 10 -D - -o /dev/null -H "Host: $PREFIX-$1.$DOMAIN" "http://127.0.0.1:$PORT$2" 2>/dev/null || true; }
  wait_marker() {
    local svc="$1" path="$2" marker="$3" body=""
    for _ in $(seq 1 90); do
      body="$(probe "$svc" "$path")"
      case "$body" in *"$marker"*) ok "-$svc repond via Caddy ($path contient $marker)"; return 0 ;; esac
      sleep 2
    done
    fail "-$svc ne repond pas via Caddy ($path, corps : '${body:0:80}')"
  }
  wait_marker n8n /healthz/readiness '"status":"ok"'
  wait_marker db /api/v1/health '"message":"OK"'
  # Fichier de sites.d/ reellement servi (pas seulement valide)
  wait_marker selftest / selftest
  # Attrape-tout : Host inconnu -> 404 (plus jamais 200 et corps vide)
  unknown="$(curl -s -m 10 -o /dev/null -w '%{http_code}' -H "Host: nope.$DOMAIN" "http://127.0.0.1:$PORT/" 2>/dev/null || printf '000')"
  if [ "$unknown" = "404" ]; then ok "Host inconnu -> 404"; else fail "Host inconnu -> $unknown, attendu 404"; fi
  # En-tetes de securite (snippet securite) sur chaque vhost, X-Frame-Options selon le vhost, CORS sur -db.
  for svc in n8n app db selftest; do
    h="$(headers_of "$svc" /)"
    missing=""
    for want in 'strict-transport-security: max-age=63072000; includeSubDomains' 'x-content-type-options: nosniff' 'referrer-policy: strict-origin-when-cross-origin' 'permissions-policy: accelerometer=()'; do
      printf '%s' "$h" | grep -qi "^$want" || missing="$missing [$want]"
    done
    if printf '%s' "$h" | grep -qiE '^(server|x-powered-by):'; then missing="$missing [Server/X-Powered-By present]"; fi
    if [ -z "$missing" ]; then ok "-$svc : en-tetes de securite presents, Server et X-Powered-By absents"; else fail "-$svc : en-tetes manquants$missing"; fi
  done
  xfo_n8n="$(headers_of n8n / | grep -i '^x-frame-options:' | tr -d '\r' | awk '{print $2}')"
  xfo_app="$(headers_of app /apps/ | grep -i '^x-frame-options:' | tr -d '\r' | awk '{print $2}')"
  if [ "$xfo_n8n" = "DENY" ] && [ "$xfo_app" = "SAMEORIGIN" ]; then ok "X-Frame-Options : DENY sur -n8n, SAMEORIGIN sur -app"; else fail "X-Frame-Options : -n8n « $xfo_n8n », -app « $xfo_app »"; fi
  acao="$(headers_of db /api/v1/health | grep -i '^access-control-allow-origin:' | tr -d '\r' | awk '{print $2}')"
  if [ "$acao" = "https://$PREFIX-app.$DOMAIN" ]; then ok "-db : Access-Control-Allow-Origin = https://$PREFIX-app.$DOMAIN"; else fail "-db : Access-Control-Allow-Origin « $acao »"; fi
  # Drapeau MAINTENANCE : 503 + Retry-After sur tous les vhosts (webhook compris), retour apres retrait.
  touch "$INFRA/config/caddy/MAINTENANCE"
  spark_compose -p "$PROJECT" exec -T caddy caddy reload --config /etc/caddy/Caddyfile >/dev/null 2>&1 || fail "caddy reload (MAINTENANCE pose)"
  m="$(code_of n8n /rest/settings) $(code_of app /webhook/x -X POST) $(code_of db /api/v1/health) $(code_of selftest /) $(code_of n8n /healthz/readiness)"
  retry="$(headers_of app / | grep -i '^retry-after:' | tr -d '\r' | awk '{print $2}')"
  if [ "$m" = "503 503 503 503 200" ] && [ "$retry" = "300" ]; then ok "MAINTENANCE pose : 503 sur -n8n, -app (POST /webhook), -db, sites.d, Retry-After 300 ; /healthz/readiness reste servi (200)"; else fail "MAINTENANCE pose : codes « $m » (attendu 503 503 503 503 200), Retry-After « $retry »"; fi
  rm -f "$INFRA/config/caddy/MAINTENANCE"
  spark_compose -p "$PROJECT" exec -T caddy caddy reload --config /etc/caddy/Caddyfile >/dev/null 2>&1 || fail "caddy reload (MAINTENANCE retire)"
  m="$(code_of n8n /healthz/readiness) $(code_of db /api/v1/health)"
  if [ "$m" = "200 200" ]; then ok "MAINTENANCE retire : 200 sur -n8n et -db"; else fail "MAINTENANCE retire : codes « $m »"; fi
  # Journal d'acces JSON ecrit dans le volume caddy_logs
  if spark_compose -p "$PROJECT" exec -T caddy sh -c 'test -s /var/log/caddy/access.log && head -c 400 /var/log/caddy/access.log | grep -q "\"request\""' >/dev/null 2>&1; then
    ok "journal d'acces JSON ecrit (/var/log/caddy/access.log)"
  else
    fail "journal d'acces absent ou vide"
  fi
  # Healthchecks compose : les trois services passent healthy (start_period n8n 120 s, caddy 150 s)
  n_healthy=0
  for _ in $(seq 1 100); do
    hs="$(spark_compose -p "$PROJECT" ps --format '{{.Service}}={{.Health}}' n8n nocodb caddy postgres 2>/dev/null | sort | tr '\n' ' ')"
    # shellcheck disable=SC2086
    n_healthy="$(printf '%s\n' $hs | grep -c '=healthy$' || true)"
    case "$hs" in *unhealthy*) break ;; esac
    [ "$n_healthy" -eq 4 ] && break
    sleep 3
  done
  if [ "$n_healthy" -eq 4 ]; then ok "healthchecks : $hs"; else fail "healthchecks : $hs"; fi
  # Config cloudflared generee : validee par l'image du compose, sans jeton ni compte (aucun tunnel ouvert)
  cfd_image="$(spark_compose -p "$PROJECT" --profile tunnel config --images 2>/dev/null | grep '^cloudflare/cloudflared' | head -1 || true)"
  # --user comme le compose (SPARK_UID:SPARK_GID) : config.yml et <id>.json sont en 600, proprietaire = l'installateur.
  if [ -n "$cfd_image" ] && docker run --rm --user "$(id -u):$(id -g)" -v "$work/cfd:/etc/cloudflared:ro" "$cfd_image" tunnel --config /etc/cloudflared/config.yml ingress validate >/dev/null 2>&1; then
    ok "cloudflared tunnel ingress validate : config.yml acceptee par $cfd_image"
  else
    fail "cloudflared tunnel ingress validate (image « $cfd_image »)"
  fi
  cfd_user="$(docker image inspect --format '{{.Config.User}}' "$cfd_image" 2>/dev/null || true)"
  if [ "$cfd_user" = "65532:65532" ]; then ok "image cloudflared : utilisateur non root ($cfd_user)"; else fail "image cloudflared : utilisateur « $cfd_user »"; fi
  # Sidecar runners : demarre avec son profil et l'override, reste Up (le banc fonctionnel est dans UPGRADES.md)
  if COMPOSE_PROFILES=runners spark_compose -p "$PROJECT" -f compose.yml -f compose.runners.yml up -d --quiet-pull >/dev/null 2>&1; then
    sleep 20
    st="$(spark_compose -p "$PROJECT" --profile runners ps --format '{{.Status}}' runners 2>/dev/null | head -1)"
    case "$st" in Up*) ok "profil runners : sidecar $st" ;; *) fail "profil runners : sidecar « $st »" ;; esac
    if spark_compose -p "$PROJECT" --profile runners logs runners 2>/dev/null | grep -qiE 'registered|connected|ready'; then ok "sidecar : connecte au broker n8n (journal)"; else printf '  INFO  journal du sidecar sans ligne registered/connected (voir docker compose logs runners)\n'; fi
    COMPOSE_PROFILES=runners spark_compose -p "$PROJECT" -f compose.yml -f compose.runners.yml stop runners >/dev/null 2>&1 || true
    spark_compose -p "$PROJECT" up -d >/dev/null 2>&1 || true   # n8n revient en mode interne
    wait_marker n8n /healthz/readiness '"status":"ok"'
  else
    fail "profil runners : up en echec"
  fi
  spark_compose -p "$PROJECT" ps --format 'table {{.Name}}\t{{.Image}}\t{{.Status}}' 2>/dev/null | sed 's/^/        /' || true

  printf '== 9. backup.sh puis restore-test.sh sur la stack de test\n'
  if command -v age >/dev/null 2>&1 && command -v age-keygen >/dev/null 2>&1; then
    # n8n repond a /healthz avant d'avoir fini ses migrations : attendre les tables que restore-test.sh compte.
    for _ in $(seq 1 60); do
      n="$(spark_compose -p "$PROJECT" exec -T postgres psql -U postgres -d n8n -Atc "SELECT count(*) FROM migrations WHERE EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name='credentials_entity')" 2>/dev/null </dev/null || true)"
      case "$n" in ''|0|*[!0-9]*) sleep 2 ;; *) break ;; esac
    done
    age-keygen -o "$work/backup.key" 2>/dev/null
    recipient="$(sed -n 's/^# public key: //p' "$work/backup.key")"
    sed -i.bak "s|^BACKUP_AGE_RECIPIENT=.*|BACKUP_AGE_RECIPIENT=$recipient|" "$INFRA/.env" && rm -f "$INFRA/.env.bak"
    anon_volumes() { docker volume ls -q | grep -cE '^[0-9a-f]{64}$' || true; }
    before="$(anon_volumes)"
    # COMPOSE_PROJECT_NAME : les scripts lisent le nom du projet dans compose.yml (`spark`) ; ici la
    # stack de test porte un autre nom, exactement comme `-p` ci-dessus.
    if out="$(COMPOSE_PROJECT_NAME="$PROJECT" "$INFRA/scripts/backup.sh" 2>&1)"; then
      ok "backup.sh : $(printf '%s' "$out" | grep -c 'volume .* -> ') volume(s) + dump + secrets, LAST_OK ecrit"
    else
      fail "backup.sh : $(printf '%s' "$out" | tail -3 | tr '\n' ' ')"
    fi
    if out="$(COMPOSE_PROJECT_NAME="$PROJECT" "$INFRA/scripts/restore-test.sh" 2>&1)"; then
      ok "restore-test.sh : $(printf '%s' "$out" | grep -o 'restauration rejouee[^;]*' | head -1)"
    else
      fail "restore-test.sh : $(printf '%s' "$out" | tail -3 | tr '\n' ' ')"
    fi
    after="$(anon_volumes)"
    if [ "$before" = "$after" ]; then ok "volumes Docker anonymes : $before avant, $after apres (restore-test.sh ne laisse rien)"; else fail "volumes Docker anonymes : $before avant, $after apres (fuite d'un volume par execution)"; fi
    if [ -f "$INFRA/backups/LAST_OK" ] && [ -f "$INFRA/backups/RESTORE_TEST_OK" ]; then ok "LAST_OK et RESTORE_TEST_OK presents"; else fail "LAST_OK ou RESTORE_TEST_OK absent"; fi
    # Dump tronque : refuse avant tout rejeu, code 2.
    dump="$(find "$INFRA/backups" -maxdepth 1 -name 'pg_dumpall-*.sql.gz' | sort | tail -1)"
    { gzip -dc "$dump" 2>/dev/null || true; } | head -n 50 | gzip -c > "$work/tronque.sql.gz"
    rc=0; out="$(COMPOSE_PROJECT_NAME="$PROJECT" "$INFRA/scripts/restore-test.sh" "$work/tronque.sql.gz" 2>&1)" || rc=$?
    case "$rc:$out" in 2:*"tronque"*) ok "dump tronque refuse (code 2)" ;; *) fail "dump tronque : code $rc, « $(printf '%s' "$out" | tail -2 | tr '\n' ' ') »" ;; esac
  else
    printf '  INFO  age absent : backup.sh / restore-test.sh non joues (apt install age / brew install age)\n'
  fi
fi

printf '== Resultat : %d echec(s)\n' "$fails"
[ "$fails" -eq 0 ]
