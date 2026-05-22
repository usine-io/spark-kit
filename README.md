# Spark Kit

**La plomberie numerique pour PME industrielles.**

Spark transforme un Mac Mini en plateforme d'orchestration locale : prototypez des connexions entre vos logiciels existants, automatisez vos flux, donnez a vos equipes des outils qu'elles utilisent vraiment — sans toucher a ce qui marche deja.

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

### 4 etapes, 30 minutes

```
1. Preparer le Mac       brew, Colima, pmset             ~10 min
2. Configurer le site    .env, docker-compose             ~5 min
3. Lancer la stack       docker compose up -d             ~5 min
4. Ouvrir le tunnel      cloudflared + DNS Cloudflare    ~10 min
   ─────────────────────────────────────────────────────
   → n8n et NocoDB accessibles en HTTPS depuis n'importe ou
```

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
| **Admin / infra** | Installe le Mac, Docker, Colima, le tunnel. Gere le `.env` et les backups. | Terminal, `docker compose`, fichiers de config |
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
```

```bash
# Homebrew (si pas deja installe)
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Paquets essentiels
brew install colima docker docker-compose cloudflared git jq curl
```

```bash
# Demarrer Colima
colima start --cpu 4 --memory 4 --disk 60 --network-address --vm-type vz --vz-rosetta

# Verifier que Docker repond
docker info
```

---

## Etape 2 — Configurer le site

Tout au long de cette etape, remplacer `acme` par le slug de l'entreprise et `example.com` par le domaine reel.

### Creer l'arborescence

```bash
mkdir -p ~/spark/{config/postgres,apps,data,logs,backups,scripts}
cd ~/spark
```

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

**`config/postgres/init-db.sh`** — cree les bases et les utilisateurs separes :

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

**`config/Caddyfile`** — reverse proxy interne, pas de TLS (Cloudflare s'en charge) :

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
cd ~/spark
docker compose up -d
```

Verifier que les services repondent (attendre ~15s) :

```bash
for svc in n8n:5678 nocodb:8080; do
  name="${svc%%:*}" port="${svc##*:}"
  code=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$port" 2>/dev/null || echo "000")
  printf "  %-15s %s\n" "$name" "$([[ $code =~ ^(200|301|302)$ ]] && echo 'OK' || echo "FAIL ($code)")"
done
```

A ce stade, les services tournent mais ne sont accessibles que depuis le Mac lui-meme (port 18080 sur 127.0.0.1). L'etape suivante ouvre l'acces HTTPS.

---

## Etape 4 — Ouvrir le tunnel Cloudflare

Le tunnel Cloudflare cree une connexion sortante securisee entre le Mac et le reseau Cloudflare. Le trafic arrive en HTTPS chez CF, transite par le tunnel chiffre, et atterrit sur Caddy en HTTP local. Aucun port entrant a ouvrir, aucun certificat a gerer.

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

Ou via l'API CF pour plus de controle (voir `scripts/tunnel-up.sh`).

### 4.5 — Lancer cloudflared

```bash
cloudflared tunnel --config ~/.cloudflared/config-spark.yml run
```

Pour un fonctionnement permanent (survit aux redemarrages), installer un LaunchAgent :

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
    <string>${HOME}/spark/logs/cloudflared.log</string>
    <key>StandardErrorPath</key>
    <string>${HOME}/spark/logs/cloudflared.err</string>
</dict>
</plist>
PLIST

launchctl load ~/Library/LaunchAgents/com.spark.cloudflared.plist
```

### 4.6 — Mettre a jour le .env

Completer les variables tunnel dans `~/spark/.env` :

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

---

## Premier acces

| Service | URL | Identifiants |
|---------|-----|-------------|
| **n8n** (editeur) | `https://<prefix>-n8n.<domain>` | Creer le compte owner au premier acces |
| **n8n** (webhooks + apps) | `https://<prefix>-app.<domain>` | Pas de login — sert les webhooks et les apps metier statiques |
| **NocoDB** | `https://<prefix>-db.<domain>` | Creer le compte admin au premier acces |

Au premier acces, n8n demande de creer un compte owner. Ce compte est le seul admin — noter l'email et le mot de passe.

Les secrets des systemes metier (API keys, tokens des logiciels de l'entreprise) seront ensuite stockes dans **n8n > Settings > Credentials** — chiffres en base par `N8N_ENCRYPTION_KEY`, jamais en clair dans des fichiers.

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

```
spark-kit/
├── spark-kit        ← ce repo (meta, documentation, incidents)
├── templates/       ← methodologie : ingest legacy → PRD → POC
├── CLAUDE.md        ← guide agent pour travailler avec la stack
└── <entreprise>/    ← un repo par deploiement (prive)
       ├── infra/           docker-compose, scripts, config
       ├── discovery/       questionnaire, fiches logiciel, PRD
       └── LESSONS-LEARNED.md
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
cd ~/spark && docker compose up -d
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
| `n8n-mcp` | MCP server | Lire/ecrire workflows, activer, executer | docker-compose (service) + scripts/mcp-n8n.sh |
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
