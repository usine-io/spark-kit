# Installation Spark sur serveur Linux — Guide pas a pas

> Ce guide part d'un serveur Debian 12+ (Bookworm) ou Ubuntu 22.04+ vierge et aboutit a une stack Spark operationnelle en HTTPS. Temps total : ~30 minutes.
>
> Pour un Mac Mini, voir le [guide macOS](../../INSTALL.md). Apres l'installation, configurer Claude Code avec [CLAUDE-CODE.md](../../CLAUDE-CODE.md).

## Conventions du guide

| Variable | Exemple | Remplacer par |
|----------|---------|---------------|
| `SPARK_HOME` | `/opt/spark` | Repertoire d'installation (confirmer avec l'hebergeur) |
| `<prefix>` | `erp` | Slug de l'instance |
| `<domain>` | `example.com` | Domaine reel (nameservers pointes vers Cloudflare) |

Toutes les commandes sont a executer en tant que `root` ou via `sudo`, sauf mention contraire.

---

## Etape 0 — Prerequis

| Besoin | Minimum |
|--------|---------|
| OS | Debian 12 (Bookworm) / Ubuntu 22.04 LTS |
| CPU | 4 vCPU |
| RAM | 8 Go |
| Disque | 60 Go |
| Reseau sortant | HTTPS (port 443) vers Cloudflare |
| Reseau entrant | SSH uniquement (aucun autre port) |
| Acces | Compte avec sudo |

Verifier la version :

```bash
cat /etc/os-release
```

---

## Etape 1 — Preparer le systeme

### 1.1 — Creer l'utilisateur spark

```bash
sudo useradd -r -m -d /opt/spark -s /bin/bash spark
```

> L'utilisateur `spark` possede `/opt/spark` (son home). Toute la stack tourne sous ce compte — pas de root en fonctionnement normal.

### 1.2 — Installer Docker CE

Installer depuis le **depot officiel Docker** (pas les paquets de la distribution) :

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg

sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg \
  | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

echo "deb [arch=$(dpkg --print-architecture) \
  signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/debian \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin
```

> **Ubuntu** : remplacer `download.docker.com/linux/debian` par `download.docker.com/linux/ubuntu` dans les 2 lignes ci-dessus.

Ajouter `spark` au groupe Docker :

```bash
sudo usermod -aG docker spark
```

Verifier :

```bash
sudo -u spark docker info >/dev/null 2>&1 && echo "OK" || echo "FAIL"
```

> **Important** : sur Linux, la commande est `docker compose` (espace, plugin v2). Tout ce guide utilise `docker compose`, pas `docker-compose`.

### 1.3 — Installer cloudflared

```bash
curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
  | sudo tee /usr/share/keyrings/cloudflare-main.gpg > /dev/null

echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] \
  https://pkg.cloudflare.com/cloudflared \
  $(lsb_release -cs) main" \
  | sudo tee /etc/apt/sources.list.d/cloudflared.list > /dev/null

sudo apt-get update
sudo apt-get install -y cloudflared
```

Verifier :

```bash
cloudflared --version
```

### 1.4 — Installer les outils

```bash
sudo apt-get install -y jq curl git tmux lsb-release
```

### 1.5 — Configurer le pare-feu

```bash
sudo apt-get install -y ufw
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow ssh
sudo ufw --force enable
sudo ufw status
```

> Docker manipule iptables directement et peut contourner UFW. Ce n'est pas un probleme ici : Caddy ecoute sur `127.0.0.1` uniquement, pas sur l'interface publique. Le trafic externe passe par le tunnel Cloudflare, pas par un port ouvert.

---

## Etape 2 — Configurer le site

A partir d'ici, travailler en tant qu'utilisateur `spark` :

```bash
sudo -iu spark
```

### 2.1 — Creer l'arborescence

```bash
mkdir -p ~/infra/{config/postgres,apps,logs,backups,scripts}
mkdir -p ~/discovery
git clone https://github.com/spark-kit/templates.git ~/templates
cd ~/infra
```

### 2.2 — Generer les secrets

Alphabet URL-safe uniquement — ne jamais utiliser `base64` qui produit des `+/=` incompatibles :

```bash
gen_secret() { LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "$1"; }

cat > .env <<EOF
# --- Site ---
SPARK_PREFIX=<prefix>
SPARK_DOMAIN=<domain>
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

> **Remplacer `<prefix>` et `<domain>`** par les vraies valeurs avant d'executer.

### 2.3 — Creer les fichiers de config

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

> `header_up X-Forwarded-Proto https` est obligatoire : Caddy recoit du HTTP depuis cloudflared, mais n8n doit croire qu'il est en HTTPS (sinon il refuse les cookies securises).

### 2.4 — Creer le docker-compose.yml

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

---

## Etape 3 — Lancer la stack

Toujours en tant qu'utilisateur `spark` :

```bash
cd ~/infra
docker compose up -d
```

Attendre ~15 secondes, puis verifier :

```bash
source .env
for svc in n8n db; do
  host="${SPARK_PREFIX}-${svc}.${SPARK_DOMAIN}"
  code=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Host: $host" \
    "http://localhost:${SPARK_HOST_HTTP_PORT:-18080}" 2>/dev/null || echo "000")
  printf "  %-15s %s\n" "$svc" \
    "$([[ $code =~ ^(200|301|302)$ ]] && echo 'OK' || echo "FAIL ($code)")"
done
```

Les services tournent et repondent via Caddy sur `127.0.0.1:18080`, mais ne sont pas encore accessibles depuis l'exterieur.

### Installer le service systemd

Revenir en root/sudo pour installer le service :

```bash
exit   # quitter le shell spark
sudo cp /opt/spark/templates/deploy/linux/systemd/spark-compose.service \
  /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable spark-compose.service
```

> Le fichier `spark-compose.service` est fourni dans `deploy/linux/systemd/`. Il lance `docker compose up -d` au demarrage du serveur en tant qu'utilisateur `spark`.

---

## Etape 4 — Ouvrir le tunnel Cloudflare

Le tunnel Cloudflare cree une connexion sortante securisee entre le serveur et Cloudflare. Le trafic arrive en HTTPS chez CF, transite par le tunnel chiffre, et atterrit sur Caddy en HTTP local. **Aucun port entrant a ouvrir, aucun certificat a gerer.**

**Pre-requis** : le domaine (`SPARK_DOMAIN`) doit avoir ses nameservers pointes vers Cloudflare (zone active sur le dashboard CF).

Trois sous-domaines vont etre crees :

| Sous-domaine | Service | Acces |
|--------------|---------|-------|
| `<prefix>-n8n.<domain>` | Editeur n8n | Builder uniquement |
| `<prefix>-app.<domain>` | Webhooks + apps metier | Equipes |
| `<prefix>-db.<domain>` | NocoDB | Equipes |

### 4.1 — Authentification Cloudflare

Executer en tant que `spark` :

```bash
sudo -iu spark
cloudflared login
```

> La commande affiche une URL a ouvrir dans un navigateur. Apres validation, le fichier `~/.cloudflared/cert.pem` est cree.

### 4.2 — Creer le tunnel

```bash
cloudflared tunnel create spark-<prefix>
```

> La commande affiche un UUID (ex: `a1b2c3d4-...`) et cree `~/.cloudflared/<UUID>.json`. Noter le UUID.

### 4.3 — Creer la config du tunnel

```bash
TUNNEL_ID="<UUID affiche ci-dessus>"

cat > ~/.cloudflared/config-spark.yml <<EOF
tunnel: $TUNNEL_ID
credentials-file: /opt/spark/.cloudflared/$TUNNEL_ID.json

ingress:
  - hostname: <prefix>-n8n.<domain>
    service: http://localhost:18080
  - hostname: <prefix>-app.<domain>
    service: http://localhost:18080
  - hostname: <prefix>-db.<domain>
    service: http://localhost:18080
  - service: http_status:404
EOF
```

> Adapter les hostnames avec les vraies valeurs de `<prefix>` et `<domain>`.

### 4.4 — Creer les DNS

```bash
cloudflared tunnel route dns spark-<prefix> <prefix>-n8n.<domain>
cloudflared tunnel route dns spark-<prefix> <prefix>-app.<domain>
cloudflared tunnel route dns spark-<prefix> <prefix>-db.<domain>
```

### 4.5 — Lancer cloudflared

Test rapide (au premier plan) :

```bash
cloudflared tunnel --config ~/.cloudflared/config-spark.yml run
```

Si tout repond, couper avec `Ctrl-C` et installer le service systemd :

```bash
exit   # quitter le shell spark
sudo cp /opt/spark/templates/deploy/linux/systemd/spark-cloudflared.service \
  /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now spark-cloudflared.service
```

Verifier :

```bash
sudo systemctl status spark-cloudflared.service
```

### 4.6 — Mettre a jour le .env

```bash
sudo -iu spark
nano ~/infra/.env
```

Completer :

```
SPARK_TUNNEL_ID=<UUID>
SPARK_TUNNEL_CONFIG=/opt/spark/.cloudflared/config-spark.yml
CF_API_TOKEN=<token avec scope Zone:DNS:Edit>
CF_ZONE_ID=<ID de la zone parente>
```

### 4.7 — Verifier l'acces HTTPS

```bash
source ~/infra/.env
curl -sI "https://${SPARK_PREFIX}-n8n.${SPARK_DOMAIN}" | head -5
curl -sI "https://${SPARK_PREFIX}-app.${SPARK_DOMAIN}" | head -5
curl -sI "https://${SPARK_PREFIX}-db.${SPARK_DOMAIN}" | head -5
```

Les trois doivent repondre en HTTPS avec un status 200 ou 302.

---

## Etape 5 — Durcir (recommande)

### 5.1 — Mises a jour automatiques

```bash
sudo apt-get install -y unattended-upgrades
sudo dpkg-reconfigure -plow unattended-upgrades
```

### 5.2 — Cloudflare Access

Configurer une application Access devant les 3 sous-domaines pour empecher l'acces anonyme. Sans elle, les pages de login n8n/NocoDB sont publiques.

Documentation detaillee : [`templates/docs/cf-access.md`](https://github.com/spark-kit/templates/blob/main/docs/cf-access.md).

### 5.3 — Headers de securite Caddy

Ajouter dans chaque bloc du Caddyfile :

```
header {
    Strict-Transport-Security "max-age=63072000; includeSubDomains; preload"
    X-Content-Type-Options "nosniff"
    X-Frame-Options "DENY"
    Referrer-Policy "strict-origin-when-cross-origin"
    Permissions-Policy "camera=(), microphone=(), geolocation=()"
}
```

Recharger Caddy :

```bash
docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile
```

### 5.4 — CORS NocoDB

Ajouter dans le service `nocodb` du `docker-compose.yml` :

```yaml
NC_CORS_ALLOWED_ORIGINS: "https://<prefix>-app.<domain>"
```

Puis `docker compose up -d` pour appliquer.

---

## Etape 6 — Premier acces

| Service | URL | Action |
|---------|-----|--------|
| **n8n** | `https://<prefix>-n8n.<domain>` | Creer le compte owner |
| **NocoDB** | `https://<prefix>-db.<domain>` | Creer le compte admin |
| **Apps** | `https://<prefix>-app.<domain>` | Webhooks + apps statiques (pas de login) |

### Obtenir les cles API

1. **n8n** : Settings > API > Create API Key
2. **NocoDB** : Team & Settings > Tokens > Add New Token (copier immediatement, NocoDB ne la re-affiche jamais)

Ecrire les tokens dans le `.env` :

```bash
nano ~/infra/.env
# Remplir :
#   N8N_API_KEY=<cle>
#   NOCODB_API_TOKEN=<token>
```

Relancer :

```bash
cd ~/infra && docker compose up -d
```

---

## Etape 7 — Test de reboot

Verifier que tout redemarre sans intervention :

```bash
sudo reboot
```

Attendre ~1 min, se reconnecter en SSH, puis :

```bash
echo "=== Services systemd ==="
systemctl is-active spark-compose.service && echo "compose: OK" || echo "compose: FAIL"
systemctl is-active spark-cloudflared.service && echo "cloudflared: OK" || echo "cloudflared: FAIL"

echo "=== Containers ==="
sudo -u spark docker compose -f /opt/spark/infra/docker-compose.yml ps \
  --format "table {{.Name}}\t{{.Status}}"

echo "=== Caddy → services ==="
source /opt/spark/infra/.env
for svc in n8n db; do
  host="${SPARK_PREFIX}-${svc}.${SPARK_DOMAIN}"
  code=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Host: $host" \
    "http://localhost:${SPARK_HOST_HTTP_PORT:-18080}" 2>/dev/null || echo "000")
  printf "  %-15s %s\n" "$svc" \
    "$([[ $code =~ ^(200|301|302)$ ]] && echo 'OK' || echo "FAIL ($code)")"
done

echo "=== Tunnel HTTPS ==="
curl -sI "https://${SPARK_PREFIX}-n8n.${SPARK_DOMAIN}" | head -1
```

Tout doit afficher OK. Si un service manque, verifier :

```bash
sudo systemctl status spark-compose.service
sudo journalctl -u spark-cloudflared.service --since "5 min ago"
```

---

## Depannage

### NocoDB ne demarre pas (502 / crashloop)

**Cause probable** : le mot de passe PostgreSQL contient des caracteres speciaux.
**Solution** : verifier que `NC_DB_JSON` est utilise (pas `NC_DB`). Regenerer le password avec `A-Za-z0-9` uniquement.

### Docker Compose introuvable

**Symptome** : `docker-compose: command not found`.
**Cause** : le guide utilise `docker compose` (espace, plugin v2), pas `docker-compose` (v1 standalone).
**Solution** : verifier que `docker-compose-plugin` est installe (`apt list --installed | grep compose`).

### n8n affiche "secure cookie" error

**Cause** : `X-Forwarded-Proto https` n'est pas propage.
**Solution** : verifier que le Caddyfile contient `header_up X-Forwarded-Proto https` dans chaque bloc `reverse_proxy`.

### UFW semble ne pas bloquer Docker

**Cause** : Docker manipule iptables directement. Les conteneurs qui publient des ports sur `0.0.0.0` contournent UFW.
**Impact** : nul ici — Caddy publie sur `127.0.0.1` uniquement, et le trafic externe passe par le tunnel Cloudflare (connexion sortante).

---

**La stack tourne, le tunnel est ouvert, les cles API sont en place.** Suite : configurer Claude Code → [CLAUDE-CODE.md](../../CLAUDE-CODE.md).
