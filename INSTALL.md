# Installation Spark — Guide pas a pas

> Ce guide part d'un Mac Mini vierge et aboutit a une stack Spark operationnelle en HTTPS. Temps total : ~35 minutes.

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
brew install colima docker docker-compose cloudflared git gh jq curl tmux mole node
# Note : avec Colima, la commande disponible est `docker-compose` (tiret, plugin v1).
# La sous-commande `docker compose` (sans tiret, v2 integree au CLI Docker Desktop)
# n'est PAS disponible. Tout le guide utilise `docker-compose`.

# Tailscale — VPN mesh pour acces distant securise au Mac
brew install --cask tailscale
# Ouvrir Tailscale.app et s'authentifier une premiere fois
```

```bash
# Demarrer Colima
colima start --cpu 4 --memory 3 --disk 60 --network-address --vm-type vz

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
        <string>3</string>
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
- Le MCP n8n n'est **pas** dans le compose — il est lance a la demande par Claude Code via `scripts/mcp-n8n.sh` (voir [CLAUDE-CODE.md](CLAUDE-CODE.md)). Ca economise ~512 Mo de RAM permanente.

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

---

**La stack tourne, le tunnel est ouvert, les cles API sont en place. L'infrastructure est terminee.** La suite se passe dans Claude Code : installer les skills, configurer le MCP, et lancer le smoke test qui valide que tout se parle.

**→ [CLAUDE-CODE.md](CLAUDE-CODE.md)**

Les sections ci-dessous (securite, backup, depannage) sont optionnelles — a consulter au besoin, pas maintenant.

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
colima start --cpu 4 --memory 4 --disk 60
```

### n8n affiche "secure cookie" error

**Symptome** : *"Your n8n server is configured to use a secure cookie, however you are either visiting this via an insecure URL"*.

**Cause** : `X-Forwarded-Proto https` n'est pas propage jusqu'a n8n.

**Solution** : verifier que le Caddyfile contient `header_up X-Forwarded-Proto https` dans chaque bloc `reverse_proxy`.

---

Suite : configurer Claude Code et lancer le smoke test → [CLAUDE-CODE.md](CLAUDE-CODE.md).
