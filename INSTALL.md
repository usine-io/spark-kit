# Installation Spark sur Mac — Guide pas a pas

> Ce guide part d'un Mac Mini vierge et aboutit a une stack Spark operationnelle en HTTPS. Temps total : ~35 minutes.
>
> **Ce guide installe un bac a sable.** Docker sur macOS tourne dans une machine virtuelle (Colima) : la latence est d'un ordre de grandeur plus elevee qu'en natif et la stack s'effondre sous charge (voir `INCIDENTS.md`). C'est le bon outil pour prototyper, former et tester. **Pour la production, suivre [INSTALL-LINUX.md](INSTALL-LINUX.md).** Les deux parcours posent la **meme stack**, depuis les **memes fichiers** du kit (`deploy/`).

Retour au [README](README.md) pour le contexte et l'architecture. Apres l'installation, configurer Claude Code avec [CLAUDE-CODE.md](CLAUDE-CODE.md).

---

## Etape 1 — Preparer le Mac

```bash
# Auto-reboot apres coupure electrique (critique en usine)
sudo pmset -a autorestart 1

# Pas de mise en veille (permanent)
sudo pmset -a sleep 0
sudo pmset -a disksleep 0
sudo pmset -a displaysleep 0

# Empecher la veille immediatement (le pmset peut necessiter un reboot)
caffeinate -dims &

# Firewall en mode stealth
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate on
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setstealthmode on

# Connexion a distance (SSH) — piloter le Mac sans ecran
sudo systemsetup -setremotelogin on

# Partage d'ecran (VNC) — observer et controler
sudo launchctl load -w /System/Library/LaunchDaemons/com.apple.screensharing.plist

# Auto-login — les LaunchAgents (Colima, cloudflared) ont besoin d'une session ouverte
# Configurer dans : Reglages Systeme > Utilisateurs et groupes > Ouverture de session automatique
# Choisir le compte utilisateur dans le menu deroulant.
# (la commande `defaults write autoLoginUser` ne prend pas sur les macOS recents,
#  passer par l'interface graphique)
```

```bash
# Homebrew (si pas deja installe)
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Homebrew affiche 2 commandes en fin d'installation pour ajouter brew au PATH.
# Sur Apple Silicon c'est :
echo >> ~/.zprofile
echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile
eval "$(/opt/homebrew/bin/brew shellenv)"

# Paquets essentiels
brew install colima docker docker-compose cloudflared age git gh jq curl tmux mole node

# Tailscale — VPN mesh pour acces distant securise au Mac
brew install --cask tailscale
# Ouvrir Tailscale.app et s'authentifier une premiere fois
```

Noter les versions installees dans le runbook du site (`colima version`, `docker --version`, `docker-compose version`, `cloudflared --version`) : le Mac n'epingle pas ses paquets, le runbook s'en charge. Le binaire `cloudflared` de Homebrew ne sert qu'a l'administration du tunnel (`login`, `tunnel create`, `route dns`) : le connecteur tourne dans le compose, a la version que le kit fige.

**`docker compose` ou `docker-compose` ?** Homebrew installe Compose (v2 ou superieure) sous la forme du binaire `docker-compose`. Pour que la sous-commande `docker compose` (celle qu'utilisent les guides et les scripts du kit) le trouve, declarer le repertoire des plugins dans `~/.docker/config.json` :

```bash
mkdir -p ~/.docker
[ -f ~/.docker/config.json ] || echo '{}' > ~/.docker/config.json
jq '.cliPluginsExtraDirs = ["/opt/homebrew/lib/docker/cli-plugins"]' ~/.docker/config.json > ~/.docker/config.json.tmp \
  && mv ~/.docker/config.json.tmp ~/.docker/config.json
docker compose version
```

> **Repli** : si `docker compose` n'est pas reconnu, `docker-compose` (avec un tiret) fonctionne a l'identique sur le fichier `compose.yml` du kit. Les scripts du kit essaient `docker compose` puis `docker-compose` automatiquement.

```bash
# Demarrer Colima : 4 CPU / 4 Go minimum (la stack pose des plafonds memoire : n8n 1 Go, NocoDB 900 Mo).
# Sur un Mac 16 Go : --memory 6
colima start --cpu 4 --memory 4 --disk 60 --network-address --vm-type vz

# Verifier que Docker repond
docker info
```

Colima doit redemarrer automatiquement apres un reboot. Le LaunchAgent vient du kit (`deploy/macos/launchd/`, le kit est clone a l'etape 2 : cloner d'abord si ce n'est pas fait, `git clone https://github.com/spark-kit/spark-kit.git ~/spark/spark-kit`) ; seul `__HOME__` est substitue a la copie, un plist n'accepte pas de variable :

```bash
mkdir -p ~/Library/LaunchAgents ~/spark/infra/logs
sed "s|__HOME__|$HOME|g" ~/spark/spark-kit/deploy/macos/launchd/com.spark.colima.plist > ~/Library/LaunchAgents/com.spark.colima.plist
plutil -lint ~/Library/LaunchAgents/com.spark.colima.plist
launchctl load ~/Library/LaunchAgents/com.spark.colima.plist
```

> Le plist demarre Colima avec `--memory 4` ; sur un Mac 16 Go, remplacer par `6` dans la copie (`~/Library/LaunchAgents/`), pas dans le kit.

> **Chaine de demarrage apres reboot** : auto-login → session utilisateur → LaunchAgent → Colima (Docker) → conteneurs `restart: unless-stopped` (cloudflared compris, profil `tunnel`). Tailscale demarre via Login Items (configure a la premiere ouverture de l'app).

---

## Etape 2 — Configurer le site

Tout au long de cette etape, remplacer `acme` par le slug de l'entreprise et `acme.example` par le domaine reel.

**Source unique.** Les fichiers d'infrastructure (compose, Caddyfile, script d'initialisation Postgres, gabarit `.env`, scripts) vivent **une seule fois** dans le depot du kit, sous [`deploy/`](deploy/). Cette etape les **copie** dans `~/spark/infra/` ; rien n'est recopie a la main.

### Cloner le kit et creer l'arborescence

```bash
mkdir -p ~/spark/{infra/{apps,logs,backups,scripts},discovery}
[ -d ~/spark/spark-kit ] || git clone https://github.com/spark-kit/spark-kit.git ~/spark/spark-kit
git clone https://github.com/spark-kit/templates.git ~/spark/templates
cd ~/spark/infra
```

`~/spark/spark-kit` est le kit (ce depot : fichiers d'infra dans `deploy/`, guides). Le repo `templates` contient la methodologie, les skills Claude Code et le smoke test. Toute la suite de l'installation travaille dans `~/spark/infra/`.

### Copier les fichiers d'infra depuis le kit

```bash
cp ~/spark/spark-kit/deploy/compose.yml ~/spark/infra/compose.yml
cp ~/spark/spark-kit/deploy/compose.runners.yml ~/spark/infra/compose.runners.yml
cp ~/spark/spark-kit/deploy/env.example ~/spark/infra/env.example
cp -R ~/spark/spark-kit/deploy/config ~/spark/infra/
chmod +x ~/spark/infra/config/postgres/init-db.sh
cp ~/spark/spark-kit/deploy/scripts/*.sh ~/spark/infra/scripts/
chmod +x ~/spark/infra/scripts/*.sh
```

Ce que ces copies posent :

| Fichier dans `infra/` | Role |
|---|---|
| `compose.yml` | La stack (Postgres, n8n, NocoDB, Caddy, et cloudflared sous le profil `tunnel`), images figees par tag **et** digest, plafond memoire et healthcheck sur chaque service |
| `compose.runners.yml` | Override optionnel : n8n en mode task runner externe (sidecar `runners`), profil `runners`, apres le banc d'[`UPGRADES.md`](UPGRADES.md) |
| `env.example` | Gabarit du `.env` (toute variable lue par le compose y figure) |
| `config/postgres/init-db.sh` | Cree les bases et utilisateurs separes (`n8n`, `nocodb`) au premier demarrage |
| `config/caddy/Caddyfile` | Reverse proxy interne (3 vhosts), pas de TLS (Cloudflare s'en charge) ; en-tetes de securite, journal d'acces, page de maintenance (`config/caddy/MAINTENANCE`), `404` pour tout `Host` inconnu |
| `config/caddy/sites.d/` | Vhosts additionnels du site, un fichier `.caddy` par vhost (vide au depart), qui importent `maintenance` et `securite` |
| `scripts/init-env.sh` | Cree le `.env` avec des secrets URL-safe (`--sync` : complete un `.env` existant) |
| `scripts/tunnel-config.sh` | Ecrit la configuration cloudflared du site depuis le `.env` (etape 4) |
| `scripts/n8n-releve.sh`, `scripts/restore-n8n.sh` | Releve avant/apres et retour arriere d'une montee de version n8n ([`UPGRADES.md`](UPGRADES.md)) |
| `scripts/check-env.sh` | Verifie, par nom et sans afficher de valeur, que les variables obligatoires du `.env` sont renseignees |
| `scripts/backup.sh`, `scripts/restore-test.sh` | Sauvegarde et test de restauration (voir « Aller plus loin »), un seul exemplaire de chacun a la fois (verrou) |
| `scripts/pin-digests.sh` | Releve ou controle les digests des images (compose et `mcp-n8n.sh`) |
| `scripts/mcp-n8n.sh` | Lance le serveur MCP n8n a la demande pour Claude Code (image figee par tag + digest), voir [CLAUDE-CODE.md](CLAUDE-CODE.md) |
| `scripts/lib.sh` | Fonctions communes (sourcees par les autres scripts) |
| `scripts/selftest-install.sh` | Verifie le kit : se lance **depuis le kit** (`~/spark/spark-kit/deploy/scripts/selftest-install.sh`), la copie dans `infra/scripts/` s'arrete avec un message qui renvoie au kit |

Verifier que chaque fichier monte par le compose existe bien (un fichier absent serait remplace par un repertoire vide au demarrage, sans erreur) :

```bash
cd ~/spark/infra
for f in compose.yml compose.runners.yml env.example config/postgres/init-db.sh config/caddy/Caddyfile config/caddy/sites.d/.keep; do
  [ -f "$f" ] && echo "OK   $f" || echo "FAIL $f"
done
```

### Generer le .env

```bash
~/spark/infra/scripts/init-env.sh --prefix acme --domain acme.example ~/spark/infra/.env
```

> Le script copie `env.example`, renseigne le site, genere les 6 secrets d'infrastructure (alphabet URL-safe `A-Za-z0-9` : jamais `base64`, qui produit des `+/=` incompatibles avec certaines configs) et pose `SPARK_UID`/`SPARK_GID` (votre compte : le conteneur cloudflared tournera sous cet utilisateur pour lire `~/.cloudflared`). Le fichier est cree en `600`. Les champs tunnel, sauvegarde et cles API restent vides : ils sont remplis plus loin.

Verifier la configuration, sans afficher les secrets :

```bash
cd ~/spark/infra
out=$(docker compose config -q 2>&1); [ -z "$out" ] && echo "compose: OK" || { echo "$out"; false; }
~/spark/infra/scripts/check-env.sh
```

`compose: OK` ne s'affiche que si `docker compose config` n'a **rien** ecrit : un avertissement `variable is not set` (code de retour 0 pourtant) est affiche a la place et la commande echoue. Compose ne dit rien d'une variable **presente mais vide** (`NOM=`) : `check-env.sh` verifie une a une celles qui doivent avoir une valeur (`SPARK_PREFIX`, `SPARK_DOMAIN`, les 6 secrets, `SPARK_UID`, `SPARK_GID`), sur la valeur resolue sans guillemets ni espaces, et affiche `OK   NOM` ou `FAIL NOM absent ou vide` (code 1), jamais la valeur. Il ne regarde que le fichier, jamais l'environnement du shell. Le `.env` est **source comme du shell** par les scripts du kit : une valeur ajoutee a la main qui contient `$`, un accent grave ou une espace va entre guillemets simples (`NOM='val eur'`).

> `header_up X-Forwarded-Proto https` dans le Caddyfile est obligatoire : Caddy recoit du HTTP depuis cloudflared, mais les apps doivent croire qu'elles sont en HTTPS (sinon n8n refuse les cookies securises).

> **Pas de Dockerfile MCP NocoDB.** L'agent accede a NocoDB via son API v3 (PAT) en passant par le CLI bundle dans la skill `nocodb` — pas via un serveur MCP. Raison : l'ecosysteme MCP NocoDB n'est pas stable contre NocoDB 2026.04.5+ (les packages disponibles ciblent v1/v2 qui rejettent les PAT). Cf. INC-02 dans `INCIDENTS.md`.

### Points cles du compose

Le `compose.yml` est commente ; l'essentiel :

- Caddy ecoute sur `127.0.0.1:18080` — pas accessible depuis le reseau. Avec le profil `tunnel` (etape 4), cloudflared tourne dans le compose et vise `http://caddy:80` : le port hote ne sert plus qu'aux sondes
- PostgreSQL cree des **utilisateurs separes** (n8n, nocodb) avec des mots de passe distincts ; `init-db.sh` ne rejoue jamais sur un volume existant
- NocoDB utilise `NC_DB_JSON` (objet) et non `NC_DB` (URL) — evite les crashloops si le password contient des caracteres speciaux
- **Toutes les images sont figees par tag et digest** (jamais `:latest`) : un `pull` surprise = migration de schema sans retour arriere, et une restauration de sauvegarde exige la meme version que la source. Monter une version = la fiche d'[`UPGRADES.md`](UPGRADES.md), jamais un simple changement de tag
- **`mem_limit` sur chaque service** (n8n 1 Go, NocoDB 900 Mo, Postgres 512 Mo, Caddy 128 Mo) : sans plafond, une rafale d'imports pousse un service a evincer les autres. D'ou la VM Colima a 4 Go minimum. Le tas Node de n8n est borne sous son plafond (`N8N_HEAP_MB`)
- **n8n** : module `insights` desactive, retention des executions a 7 jours / 150 000, task runner interne par defaut (`docker compose logs n8n` affiche a ce sujet une ligne `deprecation` attendue : le mode externe est le profil `runners`, option bancee), `N8N_PROXY_HOPS=2` (Cloudflare → cloudflared → Caddy)
- **Healthcheck sur chaque service** (`/healthz/readiness` pour n8n : `/healthz` ment quand la base est morte) ; `docker compose ps` affiche `(healthy)` apres 2 minutes au plus
- Le MCP n8n n'est **pas** dans le compose — il est lance a la demande par Claude Code via `infra/scripts/mcp-n8n.sh` (voir [CLAUDE-CODE.md](CLAUDE-CODE.md)). Ca economise ~512 Mo de RAM permanente
- Le repertoire `config/caddy/` est monte en entier : on peut remplacer le Caddyfile, poser un fichier dans `sites.d/` ou le drapeau `MAINTENANCE` puis `caddy reload`, sans redemarrer le conteneur. Les en-tetes de securite, le journal d'acces et le CORS NocoDB sont dans le Caddyfile du kit : rien a poser ; un `Host` inconnu recoit `404`

---

## Etape 3 — Lancer la stack

```bash
cd ~/spark/infra
docker compose up -d
```

Verifier que les services repondent via Caddy (attendre ~30 s). La sonde lit un **marqueur dans le corps** (`/healthz/readiness` de n8n, `/api/v1/health` de NocoDB) : un code `200` seul ne prouverait rien. Un `Host` inconnu doit recevoir `404`.

```bash
cd ~/spark/infra
(  # sous-shell : le .env est lu ici et n'est PAS exporte dans le shell interactif (une variable
   # exportee l'emporterait ensuite sur le fichier pour les scripts du kit, meme apres edition du .env)
  set -a && . ./.env && set +a
  [ -n "$SPARK_PREFIX" ] && [ -n "$SPARK_DOMAIN" ] || { echo "FAIL .env non charge"; exit 1; }
  probe() {  # service, chemin, marqueur attendu dans le corps
    body=$(curl -s -m 10 -H "Host: ${SPARK_PREFIX}-$1.${SPARK_DOMAIN}" "http://127.0.0.1:${SPARK_HOST_HTTP_PORT:-18080}$2" 2>/dev/null || true)
    case "$body" in
      *"$3"*) printf "  %-6s OK\n" "-$1" ;;
      *) printf "  %-6s FAIL (%s : corps « %.60s »)\n" "-$1" "$2" "$body"; false ;;
    esac
  }
  probe n8n /healthz/readiness '"status":"ok"'
  probe db  /api/v1/health '"message":"OK"'
  code=$(curl -s -m 10 -o /dev/null -w '%{http_code}' -H "Host: inconnu.${SPARK_DOMAIN}" "http://127.0.0.1:${SPARK_HOST_HTTP_PORT:-18080}/")
  [ "$code" = 404 ] && echo "  Host inconnu -> 404 OK" || echo "  Host inconnu -> $code FAIL (attendu 404)"
)
docker compose ps --format "table {{.Name}}\t{{.Image}}\t{{.Status}}"
```

A ce stade, les services tournent et repondent via Caddy sur `127.0.0.1:18080`, mais ne sont pas encore accessibles depuis l'exterieur. La colonne `IMAGE` affiche chaque image **tag suivi du digest** (`postgres:16.16-alpine@sha256:...`, `n8nio/n8n:2.49.6@sha256:...`), telle que le compose la fige ; la colonne `STATUS` passe a `(healthy)` pour les quatre services en 2 minutes au plus. L'etape suivante ouvre l'acces HTTPS via le tunnel.

---

## Etape 4 — Ouvrir le tunnel Cloudflare

Le tunnel Cloudflare cree une connexion sortante securisee entre le Mac et le reseau Cloudflare. Le trafic arrive en HTTPS chez CF, transite par le tunnel chiffre, et atterrit sur Caddy en HTTP. Aucun port entrant a ouvrir, aucun certificat a gerer. Le connecteur `cloudflared` tourne **dans le compose** (service `cloudflared`, profil `tunnel`), dans la VM Colima, vers `http://caddy:80` : il redemarre avec les autres conteneurs, sans LaunchAgent a part.

**Pre-requis** : le domaine utilise (`SPARK_DOMAIN`) doit avoir ses **nameservers pointes vers Cloudflare** (zone active sur le dashboard CF). C'est ce qui permet a Cloudflare de gerer le TLS et les DNS automatiquement.

Cette etape va creer **trois sous-domaines** sur ce domaine :

| Sous-domaine | Service | Acces |
|--------------|---------|-------|
| `<prefix>-n8n.<domain>` | Editeur n8n | Builder uniquement |
| `<prefix>-app.<domain>` | Webhooks + apps metier statiques | Equipes |
| `<prefix>-db.<domain>` | NocoDB | Equipes |

```
Internet → Cloudflare Edge (HTTPS) → tunnel chiffre → cloudflared (conteneur) → caddy:80 → n8n/NocoDB
```

### 4.1 — Authentification Cloudflare (une seule fois)

```bash
cloudflared login
```

Cela ouvre le navigateur et genere `~/.cloudflared/cert.pem`.

### 4.2 — Creer le tunnel

```bash
cloudflared tunnel create spark-acme
```

> Remplacer `acme` par le slug de l'entreprise. La commande affiche un UUID (ex: `a1b2c3d4-...`) et cree `~/.cloudflared/<UUID>.json`.

### 4.3 — Renseigner le tunnel dans le .env

Completer dans `~/spark/infra/.env` (`nano ~/spark/infra/.env`) :

```
SPARK_TUNNEL_ID=<UUID affiche ci-dessus>
SPARK_TUNNEL_DIR=/Users/<votre compte>/.cloudflared
COMPOSE_PROFILES=tunnel
CF_API_TOKEN=<token avec scope Zone:DNS:Edit>
CF_ZONE_ID=<ID de la zone parente>
```

> `SPARK_TUNNEL_DIR` en **chemin absolu** (`echo $HOME/.cloudflared` pour le connaitre : docker compose ne developpe ni `~` ni `$HOME`). Le conteneur tourne sous votre compte (`SPARK_UID`/`SPARK_GID`, poses par `init-env.sh`) et lit `<UUID>.json` en `600` tel que `cloudflared tunnel create` l'a ecrit ; le repertoire est monte en lecture seule. `COMPOSE_PROFILES=tunnel` fait entrer `cloudflared` dans tout `docker compose up -d`.

### 4.4 — Generer la configuration du tunnel

```bash
~/spark/infra/scripts/tunnel-config.sh
cat ~/.cloudflared/config.yml
cd ~/spark/infra
docker compose run --rm --no-deps cloudflared tunnel --config /etc/cloudflared/config.yml ingress validate
```

Attendu : `config.yml ecrit (container) : tunnel <UUID>, ingress -> http://caddy:80`, le fichier (trois `hostname` vers `http://caddy:80`, `credentials-file: /etc/cloudflared/<UUID>.json` : chemin **dans** le conteneur, `http_status:404` final), puis `Validating rules from /etc/cloudflared/config.yml` et `OK`. Le pattern single-level (`acme-n8n.acme.example`) est obligatoire pour profiter du Universal SSL gratuit de CF. Le script se relance apres tout changement du `.env` (`--check` dit si le fichier est a jour) ; les vhosts ajoutes dans `sites.d/` s'y ajoutent par `SPARK_TUNNEL_EXTRA_HOSTS` dans le `.env`.

### 4.5 — Creer les DNS

```bash
cloudflared tunnel route dns spark-acme acme-n8n.acme.example
cloudflared tunnel route dns spark-acme acme-app.acme.example
cloudflared tunnel route dns spark-acme acme-db.acme.example
```

### 4.6 — Lancer le connecteur

```bash
cd ~/spark/infra
docker compose up -d
sleep 10
docker compose ps cloudflared --format "table {{.Name}}\t{{.Image}}\t{{.Status}}"
curl -s -m 5 http://127.0.0.1:2000/ready; echo
```

Attendu : `spark-cloudflared-1` `Up` (pas `Restarting`) et `{"status":200,"readyConnections":4,...}` (`readyConnections` > 0 : tunnel etabli). Il redemarre avec Colima (`restart: always`), sans LaunchAgent dedie.

> **Variante « cloudflared sur l'hote »** (binaire Homebrew + LaunchAgent), si le site la prefere : laisser `COMPOSE_PROFILES` vide, `~/spark/infra/scripts/tunnel-config.sh --host` (ecrit `~/.cloudflared/config-spark.yml`, ingress vers `http://localhost:18080`), `SPARK_TUNNEL_CONFIG=/Users/<compte>/.cloudflared/config-spark.yml` dans le `.env`, puis `sed "s|__HOME__|$HOME|g" ~/spark/spark-kit/deploy/macos/launchd/com.spark.cloudflared.plist > ~/Library/LaunchAgents/com.spark.cloudflared.plist && launchctl load ~/Library/LaunchAgents/com.spark.cloudflared.plist`. Jamais les deux a la fois.

### Verifier

```bash
curl -sI https://acme-n8n.acme.example | head -5
curl -sI https://acme-app.acme.example | head -5
curl -sI https://acme-db.acme.example | head -5
```

Les trois doivent repondre en HTTPS avec un status 200 ou 302.

### 4.7 — Test de reboot

Verifier que tout redemarre sans intervention apres une coupure :

```bash
sudo reboot
```

Attendre ~2 min, puis se reconnecter en SSH (ou via Tailscale) et lancer la verification :

```bash
cd ~/spark/infra

echo "=== Colima ==="
colima status && echo "OK" || echo "FAIL"

echo "=== Containers ==="
docker ps --format "{{.Names}}\t{{.Status}}" | grep -E "spark"

echo "=== Tunnel (connecteur) ==="
curl -s -m 5 http://127.0.0.1:2000/ready; echo

(  # sous-shell : le .env n'est pas exporte dans le shell interactif
  set -a && . ./.env && set +a
  echo "=== Caddy → services (marqueur dans le corps, pas seulement le code) ==="
  [ -n "$SPARK_PREFIX" ] && [ -n "$SPARK_DOMAIN" ] || echo "  FAIL .env non charge"
  probe() {
    body=$(curl -s -m 10 -H "Host: ${SPARK_PREFIX}-$1.${SPARK_DOMAIN}" "http://127.0.0.1:${SPARK_HOST_HTTP_PORT:-18080}$2" 2>/dev/null || true)
    case "$body" in *"$3"*) printf "  %-6s OK\n" "-$1" ;; *) printf "  %-6s FAIL (%s)\n" "-$1" "$2" ;; esac
  }
  probe n8n /healthz/readiness '"status":"ok"'
  probe db  /api/v1/health '"message":"OK"'

  echo "=== Tunnel ==="
  curl -sI "https://${SPARK_PREFIX}-n8n.${SPARK_DOMAIN}" | head -1
)

echo "=== Tailscale ==="
/Applications/Tailscale.app/Contents/MacOS/Tailscale status --json 2>/dev/null | jq -r '.Self.Online' && echo "OK" || echo "FAIL"
```

Attendu : `OK` sous `=== Colima ===` et sous `=== Tailscale ===`, 5 conteneurs `Up` sous `=== Containers ===` (`spark-cloudflared-1` compris, les quatre autres `(healthy)` au bout de 2 minutes), `{"status":200,"readyConnections":4,...}` sous `=== Tunnel (connecteur) ===`, `-n8n   OK` et `-db    OK` sous `=== Caddy → services ===`, et une ligne de statut (`HTTP/2 200` ou `302`) sous `=== Tunnel ===`. Avant l'etape 4 : 4 conteneurs, et rien sous les deux blocs `Tunnel` (normal). Si Colima manque, verifier le LaunchAgent avec `launchctl list | grep spark` ; si un conteneur manque, `docker compose logs <service>`.

---

## Premier acces

| Service | URL | Identifiants |
|---------|-----|-------------|
| **n8n** (editeur) | `https://<prefix>-n8n.<domain>` | Creer le compte owner au premier acces |
| **n8n** (webhooks + apps) | `https://<prefix>-app.<domain>` | Pas de login — sert les webhooks et les apps metier statiques |
| **NocoDB** | `https://<prefix>-db.<domain>` | Creer le compte admin au premier acces |

Au premier acces, n8n demande de creer un compte owner. Ce compte est le seul admin — noter l'email et le mot de passe.

### Obtenir les cles API

1. **n8n** : Settings > API > Create API Key → copier la valeur
2. **NocoDB** : Team & Settings > Tokens > Add New Token → copier la valeur **immediatement** (NocoDB ne la re-affiche jamais)

Ecrire les deux tokens dans le `.env` :

```bash
nano ~/spark/infra/.env
# Remplir les lignes :
#   N8N_API_KEY=<cle copiee>
#   NOCODB_API_TOKEN=<token copie>
```

Puis relancer la stack :

```bash
cd ~/spark/infra && docker compose up -d
```

Le token NocoDB est lu depuis `.env` par le CLI au runtime (pas besoin de restart).

Les secrets des systemes metier (API keys, tokens des logiciels de l'entreprise) seront ensuite stockes dans **n8n > Settings > Credentials** — chiffres en base par `N8N_ENCRYPTION_KEY`, jamais en clair dans des fichiers.

---

**La stack tourne, le tunnel est ouvert, les cles API sont en place. L'infrastructure est terminee.** La suite se passe dans Claude Code : installer les skills, configurer le MCP, et lancer le smoke test qui valide que tout se parle.

**→ [CLAUDE-CODE.md](CLAUDE-CODE.md)**

Les sections ci-dessous (securite, sauvegarde, mise a jour, depannage) sont optionnelles — a consulter au besoin, pas maintenant.

---

## Aller plus loin — durcir et sauvegarder (optionnel)

La stack cœur ci-dessus est un prototype joignable. Deux briques optionnelles, **independantes l'une de l'autre**, la rendent exploitable — sur un Mac, pour un bac a sable qui porte des donnees qu'on ne veut pas perdre ; pour une production, c'est [INSTALL-LINUX.md](INSTALL-LINUX.md).

### Brique securite — authentification et durcissement · ~60-90 min

Recommande des qu'on y met de la donnee reelle : sans elle, les pages de login n8n/NocoDB et les webhooks/ecrans exposes sont publics (devinables via certificate transparency / scan DNS).

- **Couvre** : Cloudflare Access devant `-n8n`/`-app`/`-db`. Les en-tetes de securite Caddy (HSTS sans `preload`, X-Frame...), le journal d'acces et l'override CORS NocoDB sont **deja poses par le Caddyfile du kit** (valeurs dans [`SECURITY.md`](SECURITY.md) §2.2 et §2.3) : les verifier avec `curl -sI -H "Host: acme-n8n.acme.example" http://127.0.0.1:18080/ | grep -iE "strict|x-frame|x-content|referrer|permissions"`.
- **Options Cloudflare a prendre** : compte **Zero Trust** activé (Free, ≤50 users) ; un **IdP** (Entra ID M365 / Google) **ou** **One-time PIN** par email (zero config) ; un **Service Token** par machine qui doit franchir Access (CLI host, callback SaaS) — rotation 90j ; (recommande) **WAF + Rate Limiting** sur la zone.
- **Reversible a 100%** : supprimer l'application Access = retour immediat a l'etat non protege, aucun impact tunnel/DNS.
- **Doc** : standard [`SECURITY.md`](SECURITY.md), runbook pas-a-pas [`templates/docs/cf-access.md`](https://github.com/spark-kit/templates/blob/main/docs/cf-access.md), step [`setup-skeleton/03-securite-cf-access/`](https://github.com/spark-kit/templates/tree/main/setup-skeleton/03-securite-cf-access).

### Brique sauvegarde — backup + test de restauration · ~20 min

Les scripts sont ceux du kit, deja copies dans `~/spark/infra/scripts/` : `backup.sh` (dump `pg_dumpall` controle, tar des volumes hors Postgres, `.env` + config n8n chiffres avec `age`) et `restore-test.sh` (restauration dans un Postgres jetable de la meme image, comptes, dechiffrement d'un identifiant n8n sur la copie).

```bash
age-keygen -o ~/spark-backup.key          # copier la cle privee dans le coffre de l'entreprise, puis la supprimer d'ici
grep '^# public key:' ~/spark-backup.key  # -> BACKUP_AGE_RECIPIENT=age1... dans ~/spark/infra/.env
~/spark/infra/scripts/backup.sh
~/spark/infra/scripts/restore-test.sh
```

- **Planification** : un LaunchAgent par script (toutes les 6 h pour `backup.sh`, quotidien pour `restore-test.sh`), sur le modele de `deploy/macos/launchd/com.spark.cloudflared.plist` (variante hote) ; sur Linux, le kit livre les timers systemd (`deploy/linux/systemd/`).
- **Couche offsite** : agnostique au provider — un **remote rclone au choix** (S3/MinIO, Backblaze B2, SFTP, WebDAV…). `rclone copy` + retention par age (pas `sync`, qui casserait la retention offsite longue). Les dumps contiennent des secrets : distant chiffre.
- **Critere de validation** : `restore-test.sh` passe, avec au moins un identifiant n8n dechiffre — un backup non teste n'est pas un backup. Tant que n8n n'a aucun identifiant (*credential*, pas la cle API), le script avertit et reussit ; des qu'un identifiant existe, poser `RESTORE_TEST_REQUIRE_CREDENTIAL=1` dans `~/spark/infra/.env` pour que son absence fasse echouer le test. `backup.sh` n'ecrit rien sans `BACKUP_AGE_RECIPIENT`. Une variable deja exportee dans le shell (par un `set -a; . ./.env` anterieur) **l'emporte** sur le fichier pour ces scripts : apres avoir edite le `.env`, les lancer depuis un shell neuf. Les deux scripts alertent (`ALERTE` sur stderr, POST a `SPARK_ALERT_WEBHOOK` si renseigne) des la premiere erreur, `.env` absent compris.

> Les deux briques sont independantes : on peut poser la sauvegarde sans la securite, ou l'inverse. Les chiffrages sont des ordres de grandeur "premiere fois, a la main" (dashboard, pas IaC).

---

## Mettre a jour la stack depuis le kit

```bash
cd ~/spark/spark-kit && git pull --ff-only
diff -u ~/spark/infra/compose.yml ~/spark/spark-kit/deploy/compose.yml
diff -u ~/spark/infra/compose.runners.yml ~/spark/spark-kit/deploy/compose.runners.yml
diff -u ~/spark/infra/env.example ~/spark/spark-kit/deploy/env.example
diff -ru ~/spark/infra/config ~/spark/spark-kit/deploy/config
diff -ru ~/spark/infra/scripts ~/spark/spark-kit/deploy/scripts
~/spark/infra/scripts/pin-digests.sh --check ~/spark/infra/compose.yml
```

Les seules differences attendues sont celles que le site a faites lui-meme (fichiers `sites.d/`, drapeau `MAINTENANCE`) ; les scripts ne se modifient pas sur le site : `diff -ru` sur `scripts/` doit etre vide apres recopie (`cp ~/spark/spark-kit/deploy/scripts/*.sh ~/spark/infra/scripts/ && chmod +x ~/spark/infra/scripts/*.sh`) ; un `.env` qui n'a pas une variable nouvelle se complete par `~/spark/infra/scripts/init-env.sh --sync ~/spark/infra/.env`. Un changement de tag d'image est une **montee de version** : suivre la fiche d'[`UPGRADES.md`](UPGRADES.md) (sur un Mac, sans le drapeau `/opt/spark/MAINTENANCE`, seulement `config/caddy/MAINTENANCE`). Pour verifier le kit lui-meme avant de l'appliquer : `~/spark/spark-kit/deploy/scripts/selftest-install.sh --up` (projet separe `spark-selftest`, port 18090, detruit a la fin).

> **Site installe avec une version anterieure du guide** (fichiers recopies a la main) : l'arborescence etait `~/spark/infra/docker-compose.yml`, `~/spark/infra/config/Caddyfile` (fichier monte seul), NocoDB en `:latest` ; ni `env.example`, ni `scripts/`, ni `sites.d/`. Transition, stack en marche, apres un `docker compose exec -T postgres pg_dumpall -U postgres | gzip > ~/pg_dumpall-avant-transition.sql.gz` : faire les copies de l'etape 2 (chemins nouveaux ; seul `config/postgres/init-db.sh` est remplace, sans effet sur un volume existant) ; reporter dans `config/caddy/Caddyfile` et `compose.yml` ce que le site avait ajoute ; lire `diff -u docker-compose.yml compose.yml` (attendu : digests, `postgres:16-alpine` → `16.16-alpine`, `caddy:2-alpine` → `2.11.9-alpine`, `nocodb:latest` → `2026.04.5`, `mem_limit`, montage du repertoire `./config/caddy`, commentaires — tout autre ecart est une anomalie ; si le site servait un NocoDB plus recent que `2026.04.5`, **ne pas** redescendre : garder son tag et le figer avec `pin-digests.sh`) ; `docker compose -f compose.yml up -d` (memes volumes, meme projet `spark` : aucune donnee ne bouge), sondes de l'etape 3, puis ranger `docker-compose.yml` et l'ancien `config/Caddyfile` hors de `infra/`.

---

## Depannage

### NocoDB ne demarre pas (502 / crashloop)

**Symptome** : NocoDB redemarre en boucle, Caddy renvoie 502.

**Cause probable** : le mot de passe PostgreSQL contient des caracteres speciaux (`+`, `/`, `=`, `&`, `%`).

**Solution** : verifier que `NC_DB_JSON` est utilise (pas `NC_DB`). Regenerer le password avec des caracteres URL-safe uniquement (`A-Za-z0-9`) — `init-env.sh` le fait.

### Containers en restart loop silencieux

**Symptome** : containers qui sortent avec code 0, redemarrent toutes les ~60s. n8n affiche `Task runner connection attempt failed with status code 403`.

**Cause probable** : Colima manque de memoire.

**Diagnostic** :
```bash
docker run --rm alpine free -h
```
Si `available` < 200 MB → redimensionner :
```bash
colima stop
colima start --cpu 4 --memory 6 --disk 60 --network-address --vm-type vz
```

### Un volume monte est un repertoire vide

**Symptome** : Postgres demarre sans creer les bases, ou Caddy refuse de demarrer (`/etc/caddy/Caddyfile is a directory`).

**Cause** : un fichier reference par le compose n'existait pas au `up` ; Docker a cree un repertoire vide a sa place.

**Solution** : `docker compose down`, supprimer le repertoire fautif, refaire les copies de l'etape 2, `docker compose up -d`. Si Postgres a deja initialise un volume sans les bases : `docker compose down -v` (donnees perdues — uniquement sur une installation neuve).

### n8n affiche "secure cookie" error

**Symptome** : *"Your n8n server is configured to use a secure cookie, however you are either visiting this via an insecure URL"*.

**Cause** : `X-Forwarded-Proto https` n'est pas propage jusqu'a n8n.

**Solution** : verifier que le Caddyfile contient `header_up X-Forwarded-Proto https` dans chaque bloc `reverse_proxy`.

### n8n repond 503 `Database is not ready` apres un arret de Colima ou de Postgres

**Cause** : n8n ne retablit jamais son pool de connexions apres un incident Postgres.
**Solution** : `cd ~/spark/infra && docker compose restart n8n` une fois `spark-postgres-1` `(healthy)`.

### Tout repond 503 `Maintenance en cours`

**Cause** : le drapeau `~/spark/infra/config/caddy/MAINTENANCE` existe.
**Solution** : `rm ~/spark/infra/config/caddy/MAINTENANCE && cd ~/spark/infra && docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile`.

### `spark-cloudflared-1` est `Restarting`

**Symptome** : `docker compose logs cloudflared` : `Tunnel credentials file ... doesn't exist`, `permission denied` ou `yaml: unmarshal errors`.
**Cause** : `SPARK_TUNNEL_DIR` n'est pas le chemin absolu de `~/.cloudflared`, `SPARK_TUNNEL_ID` ne correspond pas au `.json`, `SPARK_UID`/`SPARK_GID` ne sont pas ceux du proprietaire, ou `config.yml` a ete edite a la main.
**Solution** : `~/spark/infra/scripts/tunnel-config.sh --check`, corriger le `.env`, relancer `tunnel-config.sh`, `docker compose up -d`. Sans tunnel (bac a sable local), laisser `COMPOSE_PROFILES` vide : le service ne demarre pas.

---

Suite : configurer Claude Code et lancer le smoke test → [CLAUDE-CODE.md](CLAUDE-CODE.md).
