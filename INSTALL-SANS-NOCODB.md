# Installation Spark sur Mac — variante sans NocoDB

> Variante du guide [`INSTALL.md`](INSTALL.md) : même kit, mêmes fichiers (`deploy/`), mais la stack tourne **sans NocoDB** : Postgres, n8n, Caddy, et cloudflared pour le tunnel. NocoDB est coupé par un petit fichier d'override posé sur le site, sans modifier le kit. On peut le réactiver plus tard (voir la fin).
>
> Exemple : Mac mini 32 Go (VM Colima à 8 Go ; sur un Mac 16 Go, `--memory 6`). Temps total : ~30 minutes.
>
> Ce guide installe un bac à sable (Docker tourne dans une VM Colima). Pour une production, préférer [`INSTALL-LINUX.md`](INSTALL-LINUX.md).

---

## Étape 1 — Préparer le Mac

```bash
# Auto-reboot après coupure électrique
sudo pmset -a autorestart 1

# Pas de mise en veille
sudo pmset -a sleep 0
sudo pmset -a disksleep 0
sudo pmset -a displaysleep 0
caffeinate -dims &

# Firewall en mode stealth
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate on
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setstealthmode on

# SSH
sudo systemsetup -setremotelogin on

# Partage d'écran (VNC)
sudo launchctl load -w /System/Library/LaunchDaemons/com.apple.screensharing.plist
```

**Auto-login** (obligatoire : Colima démarre dans la session utilisateur) : Réglages Système > Utilisateurs et groupes > Ouverture de session automatique → choisir le compte.

```bash
# Homebrew
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
echo >> ~/.zprofile
echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile
eval "$(/opt/homebrew/bin/brew shellenv)"

# Paquets
brew install colima docker docker-compose cloudflared age git gh jq curl tmux mole node

# Tailscale (accès distant) — ouvrir Tailscale.app et s'authentifier une fois
brew install --cask tailscale
```

Faire trouver `docker compose` (avec un espace) à Docker :

```bash
mkdir -p ~/.docker
[ -f ~/.docker/config.json ] || echo '{}' > ~/.docker/config.json
jq '.cliPluginsExtraDirs = ["/opt/homebrew/lib/docker/cli-plugins"]' ~/.docker/config.json > ~/.docker/config.json.tmp \
  && mv ~/.docker/config.json.tmp ~/.docker/config.json
docker compose version
```

> Si `docker compose` n'est toujours pas reconnu, `docker-compose` (avec un tiret) fait exactement la même chose.

Démarrer Colima (Mac 32 Go : **8 Go** pour la VM ; Mac 16 Go : 6) :

```bash
colima start --cpu 4 --memory 8 --disk 60 --network-address --vm-type vz
docker info
```

Cloner le kit et installer le démarrage automatique de Colima. Le plist du kit lance Colima avec `--memory 4` : on le passe à 8 dans la copie.

```bash
mkdir -p ~/spark ~/Library/LaunchAgents ~/spark/infra/logs
git clone https://github.com/usine-io/spark-kit.git ~/spark/spark-kit
sed -e "s|__HOME__|$HOME|g" ~/spark/spark-kit/deploy/macos/launchd/com.spark.colima.plist \
  | awk 'p=="<string>--memory</string>" && /<string>4<\/string>/ {sub(/4/,"8")} {p=$1; print}' \
  > ~/Library/LaunchAgents/com.spark.colima.plist
grep -A1 -- '--memory' ~/Library/LaunchAgents/com.spark.colima.plist   # doit montrer <string>8</string>
plutil -lint ~/Library/LaunchAgents/com.spark.colima.plist
launchctl load ~/Library/LaunchAgents/com.spark.colima.plist
```

> Si la ligne sous `--memory` affiche encore `4`, ouvrir le fichier (`nano ~/Library/LaunchAgents/com.spark.colima.plist`) et remplacer à la main.

Chaîne de démarrage après un reboot : auto-login → LaunchAgent → Colima → conteneurs (`restart: unless-stopped`, `always` pour cloudflared).

---

## Étape 2 — Configurer le site

Remplacer partout `acme` par le slug de l'entreprise et `acme.example` par son domaine.

### Arborescence et copies depuis le kit

```bash
mkdir -p ~/spark/{infra/{apps,logs,backups,scripts},discovery}
git -C ~/spark/spark-kit log -1 --format='kit : %h %s'
git clone https://github.com/usine-io/templates.git ~/spark/templates

cp ~/spark/spark-kit/deploy/compose.yml ~/spark/infra/compose.yml
cp ~/spark/spark-kit/deploy/compose.runners.yml ~/spark/infra/compose.runners.yml
cp ~/spark/spark-kit/deploy/env.example ~/spark/infra/env.example
cp -R ~/spark/spark-kit/deploy/config ~/spark/infra/
chmod +x ~/spark/infra/config/postgres/init-db.sh
cp ~/spark/spark-kit/deploy/scripts/*.sh ~/spark/infra/scripts/
chmod +x ~/spark/infra/scripts/*.sh
cd ~/spark/infra
```

### Couper NocoDB (le seul ajout de cette variante)

```bash
cp ~/spark/spark-kit/deploy/compose.sans-nocodb.yml ~/spark/infra/compose.sans-nocodb.yml
```

Cet override (`deploy/compose.sans-nocodb.yml`) met NocoDB derrière un profil `nocodb` que le site n'active pas, et retire la dépendance de Caddy envers lui.

Vérifier que chaque fichier est là :

```bash
cd ~/spark/infra
for f in compose.yml compose.sans-nocodb.yml env.example config/postgres/init-db.sh config/caddy/Caddyfile config/caddy/sites.d/.keep; do
  [ -f "$f" ] && echo "OK   $f" || echo "FAIL $f"
done
```

### Générer le .env

```bash
~/spark/infra/scripts/init-env.sh --prefix acme --domain acme.example ~/spark/infra/.env
echo 'COMPOSE_FILE=compose.yml:compose.sans-nocodb.yml' >> ~/spark/infra/.env
```

> Le script crée le `.env` en `600` avec tous les secrets. Il génère aussi les variables NocoDB (`NOCODB_DB_PASSWORD`, `NC_AUTH_JWT_SECRET`) : **les laisser**, le kit les vérifie et elles ne servent à rien d'autre ici. Postgres créera aussi une base `nocodb` vide : sans effet.

Vérifier, sans afficher les secrets :

```bash
cd ~/spark/infra
out=$(docker compose config -q 2>&1); [ -z "$out" ] && echo "compose: OK" || { echo "$out"; false; }
docker compose config --services      # attendu : postgres, n8n, caddy (PAS nocodb)
~/spark/infra/scripts/check-env.sh
```

Attendu : `compose: OK`, trois services, et que des lignes `OK` dans `check-env.sh`.

> Si `docker compose config` se plaint de `!override`, Compose est trop ancien : `brew upgrade docker-compose`.

---

## Étape 3 — Lancer la stack

```bash
cd ~/spark/infra
docker compose up -d
```

Attendre ~30 s puis vérifier (lit un marqueur dans la réponse, pas juste le code) :

```bash
cd ~/spark/infra
(
  set -a && . ./.env && set +a
  body=$(curl -s -m 10 -H "Host: ${SPARK_PREFIX}-n8n.${SPARK_DOMAIN}" "http://127.0.0.1:${SPARK_HOST_HTTP_PORT:-18080}/healthz/readiness")
  case "$body" in *'"status":"ok"'*) echo "  -n8n   OK" ;; *) echo "  -n8n   FAIL ($body)" ;; esac
  code=$(curl -s -m 10 -o /dev/null -w '%{http_code}' -H "Host: inconnu.${SPARK_DOMAIN}" "http://127.0.0.1:${SPARK_HOST_HTTP_PORT:-18080}/")
  [ "$code" = 404 ] && echo "  Host inconnu -> 404 OK" || echo "  Host inconnu -> $code FAIL"
)
docker compose ps --format "table {{.Name}}\t{{.Image}}\t{{.Status}}"
```

Attendu : `-n8n OK`, `404 OK`, et **trois** conteneurs (`spark-postgres-1`, `spark-n8n-1`, `spark-caddy-1`) qui passent à `(healthy)` en 2 minutes au plus.

> `docker compose logs n8n` montre au démarrage trois avertissements normaux : `DeprecationWarning ... pg@9.0`, `Python 3 is missing` (le node Code n'existe qu'en JavaScript ici) et `Internal task runner mode is deprecated`.

---

## Étape 4 — Ouvrir le tunnel Cloudflare

Prérequis : le domaine de l'entreprise est géré par Cloudflare (nameservers pointés chez CF, zone active).

Deux sous-domaines seulement :

| Sous-domaine | Service | Accès |
|---|---|---|
| `acme-n8n.acme.example` | Éditeur n8n | Builder uniquement |
| `acme-app.acme.example` | Webhooks + apps statiques | Équipes |

### 4.1 — Se connecter à Cloudflare (une fois)

```bash
cloudflared login
```

### 4.2 — Créer le tunnel

```bash
cloudflared tunnel create spark-acme
```

Noter l'UUID affiché.

### 4.3 — Renseigner le .env

`nano ~/spark/infra/.env`, **sans toucher à `COMPOSE_PROFILES` pour l'instant** :

```
SPARK_TUNNEL_ID=<UUID>
SPARK_TUNNEL_DIR=/Users/<compte>/.cloudflared
CF_API_TOKEN=<token Zone:DNS:Edit>
CF_ZONE_ID=<ID de la zone>
```

> `SPARK_TUNNEL_DIR` en chemin absolu (`echo $HOME/.cloudflared`).

### 4.4 — Générer la config du tunnel, puis activer le profil

```bash
~/spark/infra/scripts/tunnel-config.sh
cat ~/.cloudflared/config.yml
cd ~/spark/infra
docker compose --profile tunnel run --rm --no-deps cloudflared tunnel --config /etc/cloudflared/config.yml ingress validate
```

Attendu : `OK`. Le fichier liste aussi `acme-db` : c'est normal, on ne crée simplement pas son DNS, il reste injoignable.

**Seulement maintenant** :

```bash
sed -i '' 's/^COMPOSE_PROFILES=.*/COMPOSE_PROFILES=tunnel/' ~/spark/infra/.env
~/spark/infra/scripts/check-env.sh | tail -1
```

Attendu : `OK   COMPOSE_PROFILES coherent (tunnel)`.

### 4.5 — Créer les DNS (deux seulement)

```bash
cloudflared tunnel route dns spark-acme acme-n8n.acme.example
cloudflared tunnel route dns spark-acme acme-app.acme.example
```

### 4.6 — Lancer le connecteur

```bash
cd ~/spark/infra
docker compose up -d
sleep 10
docker compose ps cloudflared --format "table {{.Name}}\t{{.Status}}"
curl -s -m 5 http://127.0.0.1:2000/ready; echo
```

Attendu : `spark-cloudflared-1` `Up` (pas `Restarting`) et `"readyConnections":4` (au moins 1).

> **Si le conteneur cloudflared boucle** (`permission denied` sur `~/.cloudflared`) : passer en variante hôte. `docker compose --profile tunnel stop cloudflared && docker compose --profile tunnel rm -f cloudflared`, remettre `COMPOSE_PROFILES=` dans le `.env`, puis :
> ```bash
> ~/spark/infra/scripts/tunnel-config.sh --host
> sed "s|__HOME__|$HOME|g" ~/spark/spark-kit/deploy/macos/launchd/com.spark.cloudflared.plist > ~/Library/LaunchAgents/com.spark.cloudflared.plist
> launchctl load ~/Library/LaunchAgents/com.spark.cloudflared.plist
> ```
> Jamais les deux connecteurs en même temps.

### Vérifier depuis Internet

```bash
curl -sI https://acme-n8n.acme.example | head -1
curl -sI https://acme-app.acme.example | head -1
```

Les deux répondent en HTTPS (`200`, `302` ou `404` pour `-app` tant qu'aucun webhook n'existe).

### 4.7 — Test de reboot

```bash
sudo reboot
```

Après ~2 min, se reconnecter (SSH ou Tailscale) :

```bash
cd ~/spark/infra
colima status && echo "Colima OK"
docker ps --format "{{.Names}}\t{{.Status}}" | grep spark
curl -s -m 5 http://127.0.0.1:2000/ready; echo
curl -sI https://acme-n8n.acme.example | head -1
/Applications/Tailscale.app/Contents/MacOS/Tailscale status --json 2>/dev/null | jq -r '.Self.Online'
```

Attendu : Colima OK, **4** conteneurs `Up` (postgres, n8n, caddy `(healthy)` + cloudflared), `readyConnections` > 0, une ligne HTTP 200/302, `true` pour Tailscale.

---

## Premier accès

| Service | URL | Identifiants |
|---|---|---|
| n8n (éditeur) | `https://acme-n8n.acme.example` | Créer le compte owner au premier accès (noter email + mot de passe) |
| n8n (webhooks + apps) | `https://acme-app.acme.example` | Pas de login |

Clé API n8n : Settings > API > Create API Key, puis dans `~/spark/infra/.env` :

```
N8N_API_KEY=<clé copiée>
```

`NOCODB_API_TOKEN` reste vide.

Les secrets des logiciels de l'entreprise vont dans **n8n > Settings > Credentials**, jamais dans des fichiers.

**L'infrastructure est terminée.** Pour Claude Code, suivre [`CLAUDE-CODE.md`](CLAUDE-CODE.md) en **sautant** tout ce qui concerne NocoDB (skill `nocodb`, token) ; le smoke test de `templates` utilise NocoDB et ne s'applique pas ici : la validation, c'est l'étape 3 et le test de reboot.

---

## Optionnel — sécurité et sauvegarde

- **Cloudflare Access** devant `-n8n` et `-app` (sans lui, la page de login n8n est publique) : voir [`SECURITY.md`](SECURITY.md) et [`templates/docs/cf-access.md`](https://github.com/usine-io/templates/blob/main/docs/cf-access.md). À faire dès qu'il y a de la vraie donnée.
- **Sauvegarde** :
  ```bash
  age-keygen -o ~/spark-backup.key          # copier la clé privée dans le coffre de l'entreprise, puis la supprimer d'ici
  grep '^# public key:' ~/spark-backup.key  # -> BACKUP_AGE_RECIPIENT=age1... dans ~/spark/infra/.env
  ~/spark/infra/scripts/backup.sh
  ~/spark/infra/scripts/restore-test.sh
  ```

---

## Réactiver NocoDB plus tard

Dans `~/spark/infra/.env`, remplacer `COMPOSE_FILE=compose.yml:compose.sans-nocodb.yml` par `COMPOSE_FILE=compose.yml`, puis `cd ~/spark/infra && docker compose up -d`, et créer le DNS `acme-db` (`cloudflared tunnel route dns spark-acme acme-db.acme.example`).

---

## Dépannage

- **`docker compose ps` montre nocodb** : la ligne `COMPOSE_FILE` manque dans `.env` ou une variable `COMPOSE_FILE` traîne dans le shell (`unset COMPOSE_FILE`). Retrait : `docker compose --profile nocodb stop nocodb && docker compose --profile nocodb rm -f nocodb`.
- **`-db` répond 502** : normal dans cette variante.
- **Conteneurs qui redémarrent en boucle** : mémoire de Colima, `docker run --rm alpine free -h` ; si `available` < 200 Mo, `colima stop && colima start --cpu 4 --memory 8 --disk 60 --network-address --vm-type vz`.
- **n8n 503 `Database is not ready`** après un arrêt de Postgres : `docker compose restart n8n` une fois Postgres `(healthy)`.
- **Tout répond 503 Maintenance** : `rm ~/spark/infra/config/caddy/MAINTENANCE && docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile`.
- **Erreur « secure cookie » n8n** : on passe par `http://127.0.0.1` au lieu de l'URL HTTPS du tunnel ; utiliser `https://acme-n8n…`.
- **`spark-cloudflared-1` Restarting** : `~/spark/infra/scripts/tunnel-config.sh --check`, vérifier `SPARK_TUNNEL_DIR` (absolu) et `SPARK_TUNNEL_ID`, sinon variante hôte (encart de 4.6).
