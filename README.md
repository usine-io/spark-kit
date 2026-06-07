# Spark Kit

**La plomberie numerique pour PME industrielles.**

Spark transforme un Mac Mini en plateforme d'orchestration locale : prototypez des connexions entre vos logiciels existants, automatisez vos flux, donnez a vos equipes des outils qu'elles utilisent vraiment — sans toucher a ce qui marche deja.

Spark vous permet ainsi de créer des prototypes à plusieurs étages : 
- Browser extensions : décuplez la puissande de vos logiciels web
- Automatisation simple : interconnexion de logiciels
- Automatisation + Data : travail sur des données métier déportées
- Automatisation + Data + NEW LOGICIEL : POC d'intégration de nouveaux logiciels metiers avec le legacy
- Automatisation + Data + Code html : Création de POCs web complets

```
  Logiciels metier (CRM, ERP, WMS, facturation, support...)
                       |  source de verite business — INTOUCHABLE
                       |  API / webhook / export CSV
                       v
  ┌──────────────────────────────────────┐
  │  Spark  (Mac Mini dans l'entreprise) │
  │                                      │
  │  n8n       pont controle entre les   │
  │            logiciels existants       │
  │     ↕                                │
  │  NocoDB    tables de travail,        │
  │            ecrans metier,            │
  │            donnees qui n'existaient  │
  │            nulle part avant          │
  │     ↕                                │
  │  Equipes   utilisent NocoDB          │
  │            comme outil quotidien     │
  └──────────────────────────────────────┘
```

Spark ne remplace rien. Le CRM reste. L'ERP reste. Le fichier Excel qui marche depuis 2012 reste. Spark les fait parler entre eux — et le jour ou vous deciderez d'en changer un, les connexions seront deja cartographiees. Les secrets des logiciels connectes sont chiffres dans le coffre-fort natif de n8n — pas de mots de passe en clair dans des fichiers.

Spark se lit comme **3 briques empilables** : une solution technique qui tourne en 30 min, puis deux briques optionnelles qui la rendent exploitable en production.

### Brique 1 — la solution technique · 4 etapes, 30 minutes

```
1. Preparer le Mac       brew, Colima, pmset             ~10 min
2. Configurer le site    .env, docker-compose             ~5 min
3. Lancer la stack       docker-compose up -d             ~5 min
4. Ouvrir le tunnel      cloudflared + DNS Cloudflare    ~10 min
   ─────────────────────────────────────────────────────
   → n8n et NocoDB accessibles en HTTPS depuis n'importe ou
```

### Briques 2 & 3 — pour passer en production (optionnelles)

```
+ Securite      CF Access + headers Caddy + CORS NocoDB     ~60-90 min   recommande des qu'il y a de la donnee reelle
+ Sauvegarde    backup 3-2-1 : dump + volumes + drill de    ~45-60 min   recommande (offsite = +~25 min)
                restore + offsite rclone (provider au choix)
```

Detail de chaque brique, chiffrage et options a prendre (Cloudflare Zero Trust, remote offsite) : [Aller plus loin](#aller-plus-loin--durcir-et-sauvegarder-optionnel).

---

## Stack

| Composant | Role | Pourquoi celui-la |
|-----------|------|-------------------|
| **n8n** | Orchestration, workflows, connexion entre logiciels | Open source, 400+ connecteurs, code quand il faut |
| **NocoDB** | Base de donnees visuelle (comme Airtable, en local) | Les non-devs peuvent creer des vues et des formulaires |
| **PostgreSQL 16** | Base relationnelle (n8n + NocoDB, users separes) | Un seul backup couvre tout |
| **Caddy** | Reverse proxy + serveur de fichiers | Route le trafic, sert les apps metier statiques |
| **Cloudflare Tunnel** | Acces HTTPS distant | TLS gere par Cloudflare, zero cert a gerer, zero port ouvert |

Tout tourne dans Docker via **Colima** (MIT, headless, leger en RAM).

**Securite des secrets** : les identifiants des systemes connectes (API keys, tokens, mots de passe) sont stockes dans le coffre-fort de credentials natif de n8n, chiffres par `N8N_ENCRYPTION_KEY`. Pas de fichier `.env` sauvage avec des secrets metier — le `.env` ne contient que les secrets d'infrastructure de la stack elle-meme.

---

## Qui fait quoi

Spark implique 4 roles. Dans une petite structure, une seule personne peut cumuler les 4 — mais les casquettes restent distinctes.

| Role | Ce qu'il fait | Ce qu'il touche |
|------|--------------|-----------------|
| **Admin / infra** | Installe le Mac, Docker, Colima, le tunnel. Gere le `.env` et les backups. | Terminal, `docker-compose`, fichiers de config |
| **Gestionnaire de credentials** | Configure les connexions aux logiciels metier (API keys, OAuth2) dans le coffre-fort n8n. | `<prefix>-n8n.<domain>` > Settings > Credentials |
| **Builder** | Concoit et construit les POCs avec Claude Code : tables, workflows, pages HTML. | Claude Code + MCP, n8n, NocoDB, repo Git |
| **Utilisateur final** | Utilise les outils construits : formulaires, dashboards, vues NocoDB. | `<prefix>-app.<domain>` et `<prefix>-db.<domain>` uniquement |

L'utilisateur final ne va **jamais** sur `-n8n`. S'il a besoin de quelque chose, il le demande — le builder le construit.

Le guide complet des roles (matrice d'acces, documentation par profil) est dans [`BIENVENUE.md`](https://github.com/spark-kit/templates/blob/main/BIENVENUE.md) du repo templates.

---

## Pre-requis

### Materiel

| | Minimum | Recommande |
|---|---------|------------|
| **Machine** | Mac Mini Apple Silicon | Mac Mini M2/M4 |
| **RAM** | 8 GB | 16 GB |
| **Stockage** | 50 GB libres | 100 GB+ |
| **Reseau** | Ethernet LAN | Ethernet LAN + IP fixe/DHCP reserve |

### Logiciel

- macOS 14 (Sonoma) ou superieur
- Compte administrateur sur la machine

### Cloudflare (obligatoire)

- Compte Cloudflare (gratuit)
- Un domaine dont les nameservers pointent vers Cloudflare
- `brew install cloudflared`

Le tunnel Cloudflare est le seul moyen d'obtenir du HTTPS propre sans infrastructure externe. Sans lui, n8n refuse les cookies securises et devient quasi inutilisable.

### Verifications rapides

```bash
uname -m          # doit afficher "arm64"
sw_vers           # macOS 14+
```

---

## Vue d'ensemble

L'installation se fait en 4 etapes depuis un terminal sur le Mac, puis se verifie avec un smoke test pilote par Claude Code.

```
Etape 1   Preparer le Mac         outils, acces distant, Docker         ~10 min
Etape 2   Configurer le site      repos, secrets, fichiers de config    ~10 min
Etape 3   Lancer la stack         docker-compose up                     ~5 min
Etape 4   Ouvrir le tunnel        cloudflared + DNS Cloudflare          ~10 min
          ─────────────────────────────────────────────────────────────
          Premier acces            comptes admin, cles API
          Smoke test               ouvrir Claude Code dans ~/spark
```

A la fin de ces etapes, le dossier `~/spark/` sur le Mac ressemble a ca :

```
~/spark/
├── templates/      ← clone du repo spark-kit/templates (methodologie, scripts setup, skills)
├── infra/          ← docker-compose, .env, config, scripts, apps
└── discovery/      ← fiches logiciel, PRD, questionnaires
```

L'aboutissement : ouvrir Claude Code dans `~/spark/` et lancer le smoke test (`templates/crash-test/`). Si le test passe, la stack est operationnelle et l'agent a acces a tout.

---

## Etape 1 — Preparer le Mac

```bash
# Auto-reboot apres coupure electrique (critique en usine)
sudo pmset -a autorestart 1

# Pas de mise en veille
sudo pmset -a sleep 0
sudo pmset -a disksleep 0
sudo pmset -a displaysleep 0

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
brew install colima docker docker-compose cloudflared git jq curl tmux mole

# Tailscale — VPN mesh pour acces distant securise au Mac
brew install --cask tailscale
# Ouvrir Tailscale.app et s'authentifier une premiere fois
```

```bash
# Demarrer Colima
colima start --cpu 4 --memory 4 --disk 60 --network-address --vm-type vz

# Verifier que Docker repond
docker info
```

Colima doit redemarrer automatiquement apres un reboot. Installer un LaunchAgent :

```bash
cat > ~/Library/LaunchAgents/com.spark.colima.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.spark.colima</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>
    <key>ProgramArguments</key>
    <array>
        <string>/opt/homebrew/bin/colima</string>
        <string>start</string>
        <string>--cpu</string>
        <string>4</string>
        <string>--memory</string>
        <string>4</string>
        <string>--disk</string>
        <string>60</string>
        <string>--network-address</string>
        <string>--vm-type</string>
        <string>vz</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
    <key>StandardOutPath</key>
    <string>${HOME}/spark/infra/logs/colima.log</string>
    <key>StandardErrorPath</key>
    <string>${HOME}/spark/infra/logs/colima.err</string>
</dict>
</plist>
PLIST

launchctl load ~/Library/LaunchAgents/com.spark.colima.plist
```

> **Chaine de demarrage apres reboot** : auto-login → session utilisateur → LaunchAgents → Colima (Docker) → cloudflared (tunnel). Tailscale demarre via Login Items (configure a la premiere ouverture de l'app).

---

## Etape 2 — Configurer le site

Tout au long de cette etape, remplacer `acme` par le slug de l'entreprise et `example.com` par le domaine reel.

### Creer l'arborescence

```bash
mkdir -p ~/spark/{infra/{config/postgres,apps,logs,backups,scripts},discovery}
git clone https://github.com/spark-kit/templates.git ~/spark/templates
cd ~/spark/infra
```

Le repo `templates` contient la methodologie, les scripts de setup avances (securite, backup), les skills Claude Code et le smoke test. Toute la suite de l'installation travaille dans `~/spark/infra/`.

### Generer les secrets

Alphabet URL-safe uniquement — ne jamais utiliser `base64` qui produit des `+/=` incompatibles avec certaines configs :

```bash
gen_secret() { LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "$1"; }

cat > .env <<EOF
# --- Site ---
SPARK_PREFIX=acme
SPARK_DOMAIN=example.com
SPARK_HOST_HTTP_PORT=18080

# --- PostgreSQL ---
POSTGRES_ROOT_PASSWORD=$(gen_secret 32)
N8N_DB_PASSWORD=$(gen_secret 32)
NOCODB_DB_PASSWORD=$(gen_secret 32)

# --- n8n ---
N8N_ENCRYPTION_KEY=$(openssl rand -hex 32)

# --- NocoDB ---
NC_AUTH_JWT_SECRET=$(openssl rand -hex 32)

# --- Cloudflare Tunnel (a remplir a l'etape 4) ---
SPARK_TUNNEL_ID=
SPARK_TUNNEL_CONFIG=
CF_API_TOKEN=
CF_ZONE_ID=

# --- MCP / outillage agent (a remplir apres premier acces) ---
N8N_API_KEY=
NOCODB_API_TOKEN=
N8N_MCP_AUTH_TOKEN=$(gen_secret 32)
EOF

chmod 600 .env
```

### Creer les fichiers de config

**`infra/config/postgres/init-db.sh`** — cree les bases et les utilisateurs separes :

```bash
cat > config/postgres/init-db.sh <<'INITDB'
#!/bin/bash
set -euo pipefail
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres <<-EOSQL
    CREATE USER n8n WITH ENCRYPTED PASSWORD '${N8N_DB_PASSWORD}';
    CREATE DATABASE n8n OWNER n8n;

    CREATE USER nocodb WITH ENCRYPTED PASSWORD '${NOCODB_DB_PASSWORD}';
    CREATE DATABASE nocodb OWNER nocodb;
EOSQL
INITDB
chmod +x config/postgres/init-db.sh
```

**`infra/config/Caddyfile`** — reverse proxy interne, pas de TLS (Cloudflare s'en charge) :

```bash
cat > config/Caddyfile <<'CADDY'
{
    auto_https off
}

http://{$SPARK_PREFIX}-n8n.{$SPARK_DOMAIN} {
    reverse_proxy n8n:5678 {
        header_up X-Forwarded-Proto https
    }
}

http://{$SPARK_PREFIX}-app.{$SPARK_DOMAIN} {
    handle /apps/* {
        root * /srv
        file_server
    }
    handle {
        reverse_proxy n8n:5678 {
            header_up X-Forwarded-Proto https
        }
    }
}

http://{$SPARK_PREFIX}-db.{$SPARK_DOMAIN} {
    reverse_proxy nocodb:8080 {
        header_up X-Forwarded-Proto https
    }
}
CADDY
```

> `header_up X-Forwarded-Proto https` est obligatoire : Caddy recoit du HTTP depuis cloudflared, mais les apps doivent croire qu'elles sont en HTTPS (sinon n8n refuse les cookies securises).

> **Pas de Dockerfile MCP NocoDB.** L'agent acces a NocoDB via son API v3 (PAT) en passant par le CLI bundle dans la skill `nocodb` — pas via un serveur MCP. Raison : l'ecosysteme MCP NocoDB n'est pas stable contre NocoDB 2026.04.5+ (les packages disponibles ciblent v1/v2 qui rejettent les PAT). Cf. INC-2026-05-19 dans `INCIDENTS.md`.

### Creer le docker-compose.yml

```bash
cat > docker-compose.yml <<'COMPOSE'
name: spark

services:
  postgres:
    image: postgres:16-alpine
    restart: unless-stopped
    networks: [spark]
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: ${POSTGRES_ROOT_PASSWORD}
      POSTGRES_DB: postgres
      N8N_DB_PASSWORD: ${N8N_DB_PASSWORD}
      NOCODB_DB_PASSWORD: ${NOCODB_DB_PASSWORD}
    volumes:
      - postgres_data:/var/lib/postgresql/data
      - ./config/postgres/init-db.sh:/docker-entrypoint-initdb.d/init-db.sh:ro
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 10s
      timeout: 5s
      retries: 5

  n8n:
    image: n8nio/n8n:2.19.4
    restart: unless-stopped
    networks: [spark]
    depends_on:
      postgres: { condition: service_healthy }
    environment:
      DB_TYPE: postgresdb
      DB_POSTGRESDB_HOST: postgres
      DB_POSTGRESDB_PORT: 5432
      DB_POSTGRESDB_DATABASE: n8n
      DB_POSTGRESDB_USER: n8n
      DB_POSTGRESDB_PASSWORD: ${N8N_DB_PASSWORD}
      N8N_HOST: ${SPARK_PREFIX}-n8n.${SPARK_DOMAIN}
      N8N_PORT: 5678
      N8N_PROTOCOL: https
      N8N_EDITOR_BASE_URL: https://${SPARK_PREFIX}-n8n.${SPARK_DOMAIN}/
      WEBHOOK_URL: https://${SPARK_PREFIX}-app.${SPARK_DOMAIN}/
      N8N_ENCRYPTION_KEY: ${N8N_ENCRYPTION_KEY}
      N8N_DIAGNOSTICS_ENABLED: "false"
      N8N_PERSONALIZATION_ENABLED: "false"
      N8N_USER_MANAGEMENT_DISABLED: "false"
      NODE_ENV: production
      GENERIC_TIMEZONE: Europe/Paris
      TZ: Europe/Paris
    volumes:
      - n8n_data:/home/node/.n8n

  nocodb:
    image: nocodb/nocodb:latest
    restart: unless-stopped
    networks: [spark]
    depends_on:
      postgres: { condition: service_healthy }
    environment:
      NC_DB_JSON: '{"client":"pg","connection":{"host":"postgres","port":5432,"user":"nocodb","password":"${NOCODB_DB_PASSWORD}","database":"nocodb"}}'
      NC_AUTH_JWT_SECRET: ${NC_AUTH_JWT_SECRET}
      NC_PUBLIC_URL: https://${SPARK_PREFIX}-db.${SPARK_DOMAIN}
    volumes:
      - nocodb_data:/usr/app/data

  caddy:
    image: caddy:2-alpine
    restart: unless-stopped
    networks: [spark]
    ports:
      - "127.0.0.1:${SPARK_HOST_HTTP_PORT:-18080}:80"
    environment:
      SPARK_DOMAIN: ${SPARK_DOMAIN}
      SPARK_PREFIX: ${SPARK_PREFIX}
    volumes:
      - ./config/Caddyfile:/etc/caddy/Caddyfile:ro
      - ./apps:/srv/apps:ro
      - caddy_data:/data
      - caddy_config:/config
    depends_on:
      - n8n
      - nocodb

  # --- Serveurs MCP (outillage agent IA) ---
  # n8n-mcp : https://github.com/czlonkowski/n8n-mcp

  n8n-mcp:
    image: ghcr.io/czlonkowski/n8n-mcp:latest
    restart: unless-stopped
    networks: [spark]
    depends_on: [n8n]
    environment:
      MCP_MODE: http
      N8N_API_URL: http://n8n:5678
      N8N_API_KEY: ${N8N_API_KEY}
      AUTH_TOKEN: ${N8N_MCP_AUTH_TOKEN}
      NODE_ENV: production
      LOG_LEVEL: error
      PORT: "3000"
      N8N_MCP_TELEMETRY_DISABLED: "true"
    deploy:
      resources:
        limits:
          memory: 512M

volumes:
  postgres_data:
  n8n_data:
  nocodb_data:
  caddy_data:
  caddy_config:

networks:
  spark:
    driver: bridge
COMPOSE
```

Points cles :
- Caddy ecoute sur `127.0.0.1:18080` — pas accessible depuis le reseau, uniquement via cloudflared
- PostgreSQL cree des **utilisateurs separes** (n8n, nocodb) avec des mots de passe distincts
- NocoDB utilise `NC_DB_JSON` (objet) et non `NC_DB` (URL) — evite les crashloops si le password contient des caracteres speciaux

---

## Etape 3 — Lancer la stack

```bash
cd ~/spark/infra
docker-compose up -d
```

Verifier que les services repondent via Caddy (attendre ~15s) :

```bash
source .env
for svc in n8n db; do
  host="${SPARK_PREFIX}-${svc}.${SPARK_DOMAIN}"
  code=$(curl -s -o /dev/null -w "%{http_code}" -H "Host: $host" "http://localhost:${SPARK_HOST_HTTP_PORT:-18080}" 2>/dev/null || echo "000")
  printf "  %-15s %s\n" "$svc" "$([[ $code =~ ^(200|301|302)$ ]] && echo 'OK' || echo "FAIL ($code)")"
done
```

A ce stade, les services tournent et repondent via Caddy sur `127.0.0.1:18080`, mais ne sont pas encore accessibles depuis l'exterieur. L'etape suivante ouvre l'acces HTTPS via le tunnel.

---

## Etape 4 — Ouvrir le tunnel Cloudflare

Le tunnel Cloudflare cree une connexion sortante securisee entre le Mac et le reseau Cloudflare. Le trafic arrive en HTTPS chez CF, transite par le tunnel chiffre, et atterrit sur Caddy en HTTP local. Aucun port entrant a ouvrir, aucun certificat a gerer.

**Pre-requis** : le domaine utilise (`SPARK_DOMAIN`) doit avoir ses **nameservers pointes vers Cloudflare** (zone active sur le dashboard CF). C'est ce qui permet a Cloudflare de gerer le TLS et les DNS automatiquement.

Cette etape va creer **trois sous-domaines** sur ce domaine :

| Sous-domaine | Service | Acces |
|--------------|---------|-------|
| `<prefix>-n8n.<domain>` | Editeur n8n | Builder uniquement |
| `<prefix>-app.<domain>` | Webhooks + apps metier statiques | Equipes |
| `<prefix>-db.<domain>` | NocoDB | Equipes |

```
Internet → Cloudflare Edge (HTTPS) → tunnel chiffre → cloudflared (Mac) → Caddy :18080 → n8n/NocoDB
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

### 4.3 — Creer la config du tunnel

```bash
TUNNEL_ID="<UUID affiche ci-dessus>"

cat > ~/.cloudflared/config-spark.yml <<EOF
tunnel: $TUNNEL_ID
credentials-file: $HOME/.cloudflared/$TUNNEL_ID.json

ingress:
  - hostname: acme-n8n.example.com
    service: http://localhost:18080
  - hostname: acme-app.example.com
    service: http://localhost:18080
  - hostname: acme-db.example.com
    service: http://localhost:18080
  - service: http_status:404
EOF
```

> Adapter les hostnames : `<prefix>-<service>.<domain>`. Le pattern single-level (`acme-n8n.example.com`) est obligatoire pour profiter du Universal SSL gratuit de CF.

### 4.4 — Creer les DNS

```bash
cloudflared tunnel route dns spark-acme acme-n8n.example.com
cloudflared tunnel route dns spark-acme acme-app.example.com
cloudflared tunnel route dns spark-acme acme-db.example.com
```

Ou via l'API CF pour plus de controle (voir `infra/scripts/tunnel-up.sh`).

### 4.5 — Lancer cloudflared

```bash
cloudflared tunnel --config ~/.cloudflared/config-spark.yml run
```

Pour un fonctionnement permanent (survit aux redemarrages), installer un LaunchAgent :

```bash
mkdir -p ~/Library/LaunchAgents
```

```bash
cat > ~/Library/LaunchAgents/com.spark.cloudflared.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.spark.cloudflared</string>
    <key>ProgramArguments</key>
    <array>
        <string>/opt/homebrew/bin/cloudflared</string>
        <string>tunnel</string>
        <string>--config</string>
        <string>${HOME}/.cloudflared/config-spark.yml</string>
        <string>run</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${HOME}/spark/infra/logs/cloudflared.log</string>
    <key>StandardErrorPath</key>
    <string>${HOME}/spark/infra/logs/cloudflared.err</string>
</dict>
</plist>
PLIST
```

Charger le LaunchAgent (sans sudo — c'est un agent utilisateur, pas un daemon systeme) :

```bash
launchctl load ~/Library/LaunchAgents/com.spark.cloudflared.plist
```

### 4.6 — Mettre a jour le .env

Completer les variables tunnel dans `~/spark/infra/.env` :

```bash
SPARK_TUNNEL_ID=<UUID>
SPARK_TUNNEL_CONFIG=~/.cloudflared/config-spark.yml
CF_API_TOKEN=<token avec scope Zone:DNS:Edit>
CF_ZONE_ID=<ID de la zone parente>
```

### Verifier

```bash
curl -sI https://acme-n8n.example.com | head -5
curl -sI https://acme-app.example.com | head -5
curl -sI https://acme-db.example.com | head -5
```

Les trois doivent repondre en HTTPS avec un status 200 ou 302.

### 4.7 — Test de reboot

Verifier que tout redemarre sans intervention apres une coupure :

```bash
sudo reboot
```

Attendre ~2 min, puis se reconnecter en SSH (ou via Tailscale) et lancer la verification :

```bash
source ~/spark/infra/.env

echo "=== Colima ==="
colima status && echo "OK" || echo "FAIL"

echo "=== Containers ==="
docker ps --format "{{.Names}}\t{{.Status}}" | grep -E "spark"

echo "=== Caddy → services ==="
for svc in n8n db; do
  host="${SPARK_PREFIX}-${svc}.${SPARK_DOMAIN}"
  code=$(curl -s -o /dev/null -w "%{http_code}" -H "Host: $host" "http://localhost:${SPARK_HOST_HTTP_PORT:-18080}" 2>/dev/null || echo "000")
  printf "  %-15s %s\n" "$svc" "$([[ $code =~ ^(200|301|302)$ ]] && echo 'OK' || echo "FAIL ($code)")"
done

echo "=== Tunnel ==="
curl -sI "https://${SPARK_PREFIX}-n8n.${SPARK_DOMAIN}" | head -1

echo "=== Tailscale ==="
/Applications/Tailscale.app/Contents/MacOS/Tailscale status --json 2>/dev/null | jq -r '.Self.Online' && echo "OK" || echo "FAIL"
```

Tout doit afficher OK. Si un service manque, verifier le LaunchAgent correspondant avec `launchctl list | grep spark`.

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

Puis relancer la stack pour que le MCP n8n prenne sa cle :

```bash
cd ~/spark/infra && docker-compose up -d
```

Le token NocoDB est lu depuis `.env` par le CLI au runtime (pas besoin de restart).

Les secrets des systemes metier (API keys, tokens des logiciels de l'entreprise) seront ensuite stockes dans **n8n > Settings > Credentials** — chiffres en base par `N8N_ENCRYPTION_KEY`, jamais en clair dans des fichiers.

### Smoke test

Copier le briefing agent depuis le repo templates, puis ouvrir Claude Code :

```bash
cp ~/spark/templates/CLAUDE.md ~/spark/CLAUDE.md
cd ~/spark
claude
```

Claude Code charge le `CLAUDE.md` a la racine et a acces a toute l'arborescence : `infra/` (stack live), `templates/` (methodologie, scripts, skills), `discovery/` (fiches projet).

Lancer le smoke test :

```
> Lance le smoke test dans templates/crash-test/
```

Le smoke test verifie la liaison n8n ↔ NocoDB (ecriture, trigger, lecture). S'il passe, la stack est operationnelle. Detail du test : [`templates/crash-test/README.md`](https://github.com/spark-kit/templates/blob/main/crash-test/README.md).

---

## Aller plus loin — durcir et sauvegarder (optionnel)

La stack cœur ci-dessus est un prototype joignable. Deux briques optionnelles, **independantes l'une de l'autre**, la rendent exploitable en production. Chacune est documentee comme un "step" dans `templates/setup-skeleton/` (clone en local dans `~/spark/templates/`).

### Brique securite — authentification et durcissement · ~60-90 min

Recommande des qu'on y met de la donnee reelle : sans elle, les pages de login n8n/NocoDB et les webhooks/ecrans exposes sont publics (devinables via certificate transparency / scan DNS).

- **Couvre** : Cloudflare Access devant `-n8n`/`-app`/`-db`, headers de securite Caddy (HSTS, X-Frame...), override CORS NocoDB.
- **Options Cloudflare a prendre** : compte **Zero Trust** activé (Free, ≤50 users) ; un **IdP** (Entra ID M365 / Google) **ou** **One-time PIN** par email (zero config) ; un **Service Token** par machine qui doit franchir Access (CLI host, callback SaaS) — rotation 90j ; (recommande) **WAF + Rate Limiting** sur la zone.
- **Reversible a 100%** : supprimer l'application Access = retour immediat a l'etat non protege, aucun impact tunnel/DNS.
- **Doc** : standard [`SECURITY.md`](SECURITY.md), runbook pas-a-pas [`templates/docs/cf-access.md`](https://github.com/spark-kit/templates/blob/main/docs/cf-access.md), step [`setup-skeleton/03-securite-cf-access/`](https://github.com/spark-kit/templates/tree/main/setup-skeleton/03-securite-cf-access).

### Brique sauvegarde — backup 3-2-1 deployable · ~45-60 min

Scripts generiques (pg_dumpall + tar des volumes + **drill de restore** + planification launchd), resolus par labels Docker Compose, sans nom de client en dur.

- **Couches locales** (dump 6h + volumes quotidien + drill hebdo) : ~45-60 min, aucune dependance externe, testable immediatement.
- **Couche offsite** : +~25 min, agnostique au provider — un **remote rclone au choix** (S3/MinIO, Backblaze B2, Google Drive, OneDrive, SFTP, WebDAV…), configure par l'installateur. `rclone copy` + retention par age (pas `sync`, qui casserait la retention offsite longue).
- **Critere de validation** : la **drill de restore** passe — un backup non teste n'est pas un backup.
- **Doc** : step [`setup-skeleton/04-strategie-backup-3-2-1/`](https://github.com/spark-kit/templates/tree/main/setup-skeleton/04-strategie-backup-3-2-1).

> Les deux briques sont independantes : on peut poser la sauvegarde sans la securite, ou l'inverse. Les chiffrages sont des ordres de grandeur "premiere fois, a la main" (dashboard, pas IaC).

---

## Architecture

```
                    Internet
                       │
                       ▼
              Cloudflare Edge (HTTPS)
                       │
                 tunnel chiffre
                       │
                       ▼
┌──────────────────────────────────────────────┐
│              Mac Mini (Spark)                │
│                                              │
│   cloudflared (host, LaunchAgent)            │
│        │                                     │
│        ▼ http://127.0.0.1:18080              │
│   ┌─────────┐                                │
│   │  Caddy   │ reverse proxy + file_server   │
│   └────┬─────┘                               │
│        │                                     │
│   -n8n │  -app (webhooks)  -app (/apps/*)    │
│    ┌───▼──────────▸┐       ┌──────────────┐  │
│    │     n8n       │       │  apps/ (html)│  │
│    │     :5678     │       │  file_server │  │
│    └───────┬───────┘       └──────────────┘  │
│            │          -db                    │
│            │    ┌───────────┐                │
│            │    │  NocoDB   │                │
│            │    │  :8080    │                │
│            │    └─────┬─────┘                │
│            │          │                      │
│            │    ┌─────▼─────────────────┐    │
│            │    │    PostgreSQL 16      │    │
│            └───▸│    users: n8n, nocodb │    │
│                 └───────────────────────┘    │
│                                              │
│   Volumes: n8n_data, nocodb_data,            │
│   postgres_data, caddy_*                     │
└──────────────────────────────────────────────┘
```

**Choix structurants** :
- Caddy ecoute sur `127.0.0.1` uniquement — pas d'acces reseau direct, tout passe par le tunnel
- Cloudflare gere le TLS et les certificats — zero config cote Mac
- Utilisateurs PostgreSQL separes (n8n, nocodb) avec mots de passe distincts
- `restart: unless-stopped` + `pmset autorestart 1` → la stack survit aux coupures electriques
- Images Docker epinglees (pas de `latest` sauf NocoDB)
- Secrets metier dans le coffre n8n Credentials, pas dans des fichiers `.env`

---

## Depannage

### NocoDB ne demarre pas (502 / crashloop)

**Symptome** : NocoDB redemarre en boucle, Caddy renvoie 502.

**Cause probable** : le mot de passe PostgreSQL contient des caracteres speciaux (`+`, `/`, `=`, `&`, `%`).

**Solution** : verifier que `NC_DB_JSON` est utilise (pas `NC_DB`). Regenerer le password avec des caracteres URL-safe uniquement (`A-Za-z0-9`).

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
colima start --cpu 4 --memory 6 --disk 60
```

### n8n affiche "secure cookie" error

**Symptome** : *"Your n8n server is configured to use a secure cookie, however you are either visiting this via an insecure URL"*.

**Cause** : `X-Forwarded-Proto https` n'est pas propage jusqu'a n8n.

**Solution** : verifier que le Caddyfile contient `header_up X-Forwarded-Proto https` dans chaque bloc `reverse_proxy`.

---

## Vocabulaire

| Terme | Sens |
|-------|------|
| **Spark** | Le kit / template — ce projet |
| **Site** | Un deploiement Spark concret : 1 Mac Mini, 1 entreprise, 1 domaine |
| **`SPARK_PREFIX`** | Slug par-site qui forme les hostnames (`<prefix>-<service>.<domain>`) |
| **`-n8n`** | Sous-domaine editeur/admin — acces reserve au builder |
| **`-app`** | Sous-domaine equipes — webhooks n8n + apps metier statiques (`/apps/*`) |
| **`-db`** | Sous-domaine NocoDB — vues, formulaires, data pour les equipes |
| **Pattern A** | Tunnel Cloudflare local-managed (config YAML sur le Mac, pas sur le dashboard CF) |
| **Playbook** | Brique d'integration assemblable (workflow n8n + tables NocoDB + config) |

---

## Organisation du projet

**Deux repos GitHub** dans l'organisation `spark-kit` :

| Repo | Contenu |
|------|---------|
| **spark-kit** (ce repo) | Meta : README installation, SECURITY.md, INCIDENTS.md, ROADMAP.md |
| **templates** | Methodologie, scripts setup, skills Claude Code, smoke test |

**Sur le Mac**, les deux repos se retrouvent dans `~/spark/` a cote des fichiers du site :

```
~/spark/                              ← dossier de travail sur le Mac
├── templates/                        ← clone de spark-kit/templates (read-only)
│   ├── setup-skeleton/               scripts de setup avances (securite, backup)
│   ├── crash-test/                   smoke test
│   ├── skills/                       skills Claude Code specifiques Spark
│   ├── docs/                         runbooks (Caddy, CF Access, cloudflared)
│   ├── CLAUDE.md                     gabarit agent a copier/adapter
│   └── BIENVENUE.md, GETTING-STARTED.md, prd-template.md...
├── infra/                            ← stack live (docker-compose, .env, config)
│   ├── .env                          secrets (gitignore)
│   ├── docker-compose.yml
│   ├── config/
│   ├── apps/
│   ├── scripts/
│   ├── logs/
│   └── backups/
└── discovery/                        ← fiches logiciel, PRD, questionnaires
```

---

## Philosophie

Spark est ne d'une conviction : **les petites entreprises meritent l'industrie 4.0**.

Siemens et Dassault Systemes ont construit l'usine connectee pour les grands groupes. Les PME de 10 a 100 personnes n'ont ni le budget ni les equipes pour ca. Spark est leur porte d'entree.

- **Pas a pas, pas big bang** — on resout un probleme concret en une semaine, puis un autre
- **Side-stack** — on ne touche pas au systeme qui tourne, on pose un deuxieme cerveau a cote
- **La donnee reste dans l'entreprise** — Mac Mini sur le LAN, pas de cloud obligatoire
- **La plomberie avant l'IA** — connecter les logiciels existants est le prerequis, l'IA viendra apres
- **Les secrets au coffre** — les credentials metier dans n8n, pas dans des fichiers

---

## Travailler avec Claude Code

Spark est concu pour etre opere avec un agent IA. Le fichier [`CLAUDE.md`](CLAUDE.md) est le guide de reference que Claude Code charge automatiquement a l'ouverture d'un repo Spark.

Le serveur MCP `n8n-mcp` est deja dans le `docker-compose.yml` ci-dessus. Il reste a creer le script de connexion, configurer Claude Code, et installer les skills. Pour NocoDB, **pas de MCP** : l'agent passe par le CLI `nocodb.sh` de la skill `nocodb` (API v3, PAT). Raison : aucun package MCP NocoDB n'est aujourd'hui compatible avec les versions recentes de NocoDB (2026.04.5+) — cf. INC-2026-05-19. La doc se tient au canal qui fonctionne maintenant.

### Obtenir les cles API

Apres le premier acces (etape 4), creer les tokens dans chaque app :

1. **n8n** : Settings > API > Create API Key → copier dans `.env` a la ligne `N8N_API_KEY=`
2. **NocoDB** : Team & Settings > Tokens > Add New Token → copier dans `.env` a la ligne `NOCODB_API_TOKEN=` (PAT `nc_pat_...`). **Copier la valeur immediatement** dans la modale — NocoDB ne la re-affiche jamais ; si vous la perdez, il faudra regenerer un nouveau token.

Puis relancer la stack pour que le MCP n8n prenne sa cle :

```bash
cd ~/spark/infra && docker-compose up -d
```

Le token NocoDB est lu depuis `.env` par le CLI au runtime (pas besoin de restart).

### Creer le script MCP n8n

**`scripts/mcp-n8n.sh`** — connecte Claude Code a n8n via le reseau Docker :

```bash
cat > scripts/mcp-n8n.sh <<'MCP'
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../.env"
exec docker run -i --rm \
  --network spark_spark \
  -e MCP_MODE=stdio \
  -e LOG_LEVEL=error \
  -e DISABLE_CONSOLE_OUTPUT=true \
  -e "N8N_API_URL=http://n8n:5678" \
  -e "N8N_API_KEY=${N8N_API_KEY}" \
  -e N8N_MCP_TELEMETRY_DISABLED=true \
  ghcr.io/czlonkowski/n8n-mcp:latest
MCP
chmod +x scripts/mcp-n8n.sh
```

> Le reseau `spark_spark` correspond au projet compose `spark` + le reseau `spark`. Si vous avez change le `name:` dans le compose, adaptez en consequence.

### Configurer Claude Code

Creer `.mcp.json` a la racine du repo (gitignored) — uniquement n8n :

```bash
cat > .mcp.json <<'JSON'
{
  "mcpServers": {
    "n8n-mcp": {
      "command": "bash",
      "args": ["infra/scripts/mcp-n8n.sh"]
    }
  }
}
JSON
```

Au demarrage d'une session Claude Code dans ce repo, le MCP n8n apparait automatiquement comme tool provider. NocoDB est utilisable via le CLI de la skill (voir plus bas).

### Installer les skills

Les skills donnent a Claude Code la documentation de reference pour configurer n8n et NocoDB sans allers-retours. **La skill NocoDB est essentielle ici** : elle embarque le CLI `nocodb.sh` qui est le canal d'acces a NocoDB pour l'agent (en l'absence de MCP NocoDB stable).

```bash
# NocoDB — reference API v3 + CLI nocodb.sh (canal d'acces live)
npx @anthropic-ai/claude-code skills add nocodb/agent-skills

# n8n — 7 skills (nodes, workflows, expressions, code, validation)
npx @anthropic-ai/claude-code skills add n8n/agent-skills
```

> Les skills s'installent dans `~/.claude/skills/` et sont disponibles dans toutes les sessions Claude Code. A faire une seule fois par poste.

Utilisation type du CLI NocoDB (a partager avec l'agent au demarrage d'une session) :

```bash
set -a; source infra/.env; set +a
export NOCODB_TOKEN="$NOCODB_API_TOKEN"
export NOCODB_URL="https://<prefix>-db.<domain>"
bash ~/.claude/skills/nocodb/scripts/nocodb.sh workspace:list
# … table:list, field:create, record:list, etc.
unset NOCODB_TOKEN NOCODB_API_TOKEN
```

Le CLI cible `/api/v3/...` avec le header `xc-token`, lit le token via env, ne l'expose jamais en sortie.

### Resume outillage

| Outil | Type | Ce qu'il fait | Ou il vit |
|-------|------|---------------|-----------|
| [`n8n-mcp`](https://github.com/czlonkowski/n8n-mcp) | MCP server | Lire/ecrire workflows, activer, executer | docker-compose (service) + scripts/mcp-n8n.sh |
| `nocodb.sh` (skill `nocodb`) | CLI v3 | Lire/ecrire records, schema, tables via API v3 | ~/.claude/skills/nocodb/scripts/ |
| `n8n-*` skills (x7) | Reference | Config nodes, patterns workflow, expressions, code JS/Python, validation | ~/.claude/skills/ |
| `nocodb` skill | Reference | API v3 complete, filtres `where`, CLI bash | ~/.claude/skills/ |
| `CLAUDE.md` | Guide agent | Vocabulaire, principes, conventions | racine du repo |

**Regles** :
- n8n : utiliser le MCP pour agir sur les instances live ; ne jamais `curl` quand le MCP peut le faire.
- NocoDB : utiliser le CLI `nocodb.sh` de la skill ; jamais de curl ad-hoc, jamais d'acces direct via `docker exec psql` ou lecture brute de `.env`.
- Skills : pour comprendre la syntaxe et les patterns en amont de l'action.

---

## Roadmap & decisions

Le suivi detaille de la templatification, les decisions d'architecture et les questions ouvertes sont dans [`ROADMAP.md`](ROADMAP.md).

Les incidents de production et leurs lecons sont archives dans [`INCIDENTS.md`](INCIDENTS.md).

---

*Spark Kit est un projet [Atelier B](https://github.com/spark-kit). Licence a definir.*
