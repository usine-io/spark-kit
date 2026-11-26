# Installation Spark sur serveur Linux — Guide pas a pas

> Ce guide part d'un serveur Debian 12+ (Bookworm) ou Ubuntu 22.04+ vierge et aboutit a une stack Spark operationnelle en HTTPS, sauvegardee et testee. Temps total : ~40 minutes.
>
> C'est le **parcours production**. Pour un bac a sable sur Mac, voir le [guide macOS](INSTALL.md). Apres l'installation, configurer Claude Code avec [CLAUDE-CODE.md](CLAUDE-CODE.md).

## Conventions du guide

| Variable | Exemple | Remplacer par |
|----------|---------|---------------|
| `SPARK_HOME` | `/opt/spark` | Repertoire d'installation (confirmer avec l'hebergeur) |
| `<prefix>` | `acme` | Slug de l'instance |
| `<domain>` | `acme.example` | Domaine reel (nameservers pointes vers Cloudflare) |

Toutes les commandes sont a executer en tant que `root` ou via `sudo`, sauf mention contraire.

**Source unique.** Les fichiers d'infrastructure (compose, Caddyfile, script d'initialisation Postgres, gabarit `.env`, scripts, units systemd) vivent **une seule fois** dans le depot du kit, sous [`deploy/`](deploy/). Ce guide les **copie** dans `/opt/spark/infra/` ; il ne les recopie jamais a la main. Pour voir ce que le site a de different du kit : `diff -ru /opt/spark/spark-kit/deploy/config /opt/spark/infra/config`.

**Changements d'utilisateur** — `sudo -iu spark` et `exit` sont toujours la **derniere ligne de leur bloc**, jamais suivis d'autres commandes. Ces deux commandes changent de shell : ce qui suit dans le meme bloc est avale par le stdin du shell qu'on quitte ou qu'on ouvre, au lieu d'etre tape dedans — une commande plein ecran comme `nano` ne s'affiche alors pas. Coller un bloc a la fois, et attendre le nouveau prompt avant le suivant.

---

## Etape 0 — Prerequis

| Besoin | Minimum |
|--------|---------|
| OS | Debian 12 (Bookworm) / Ubuntu 22.04 LTS |
| CPU | 4 vCPU |
| RAM | 8 Go |
| Disque | 60 Go |
| Reseau sortant | HTTPS (port 443) + port 7844 (TCP+UDP) vers Cloudflare |
| Reseau entrant | SSH uniquement (aucun autre port) |
| Acces | Compte avec sudo |

> ⚠️ **Ne pas provisionner SOUS ces minima, meme pour une preprod.** Vecu chez une PME :
> un serveur livre sous ces minima fait tourner la stack, mais sans aucune marge, et
> des incidents OOM (n8n, NocoDB, Postgres) sont survenus meme sur une machine
> mieux dotee. Verifier des la reception : `nproc`, `free -h`, `df -h /`.

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

Verifier, et noter les versions dans le runbook du site :

```bash
sudo -u spark docker info >/dev/null 2>&1 && echo "OK" || echo "FAIL"
docker --version
docker compose version
```

> **Important** : sur Linux, la commande est `docker compose` (avec un espace) : c'est le plugin
> Compose fourni par le paquet `docker-compose-plugin`, en version 2 ou superieure (`docker compose version`
> affiche aujourd'hui une **v5.x**). Tout ce guide utilise `docker compose`. Le binaire `docker-compose`
> v1 (avec un tiret) est en fin de vie et n'est pas installe ici. Le fichier `compose.yml` du kit est
> lu a l'identique par les deux.

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

Verifier (et noter la version dans le runbook) :

```bash
cloudflared --version
```

### 1.4 — Installer les outils

```bash
sudo apt-get install -y jq curl git tmux lsb-release python3 age
```

> `python3` est present par defaut sur Debian mais explicite ici : les jobs planifies
> Spark (controles quotidiens, notifications) en dependent — stdlib uniquement,
> aucun pip requis. `age` chiffre les secrets dans les sauvegardes (etape 3.b).

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

### 2.1 — Cloner le kit et creer l'arborescence

```bash
git clone https://github.com/spark-kit/spark-kit.git ~/spark-kit
git clone https://github.com/spark-kit/templates.git ~/templates
mkdir -p ~/infra/{apps,logs,backups,scripts}
mkdir -p ~/discovery
cd ~/infra
```

> `~/spark-kit` est le kit (ce depot : fichiers d'infra dans `deploy/`, guides) ; `~/templates` contient la methodologie, les skills Claude Code et le smoke test. La stack live vit dans `~/infra/`.

### 2.2 — Copier les fichiers d'infra depuis le kit

Une commande par famille de fichiers, toujours depuis `~/spark-kit/deploy/` :

```bash
cp ~/spark-kit/deploy/compose.yml ~/infra/compose.yml
cp ~/spark-kit/deploy/env.example ~/infra/env.example
cp -R ~/spark-kit/deploy/config ~/infra/
chmod +x ~/infra/config/postgres/init-db.sh
cp ~/spark-kit/deploy/scripts/*.sh ~/infra/scripts/
chmod +x ~/infra/scripts/*.sh
```

Ce que ces copies posent :

| Fichier dans `~/infra/` | Role |
|---|---|
| `compose.yml` | La stack (Postgres, n8n, NocoDB, Caddy), images figees par tag **et** digest |
| `env.example` | Gabarit du `.env` (toute variable lue par le compose y figure) |
| `config/postgres/init-db.sh` | Cree les bases et utilisateurs separes (`n8n`, `nocodb`) au premier demarrage |
| `config/caddy/Caddyfile` | Reverse proxy interne (3 vhosts), pas de TLS (Cloudflare s'en charge) |
| `config/caddy/sites.d/` | Vhosts additionnels du site, un fichier `.caddy` par vhost (vide au depart) |
| `scripts/init-env.sh` | Cree le `.env` avec des secrets URL-safe |
| `scripts/backup.sh`, `scripts/restore-test.sh` | Sauvegarde et test de restauration (etape 3.b) |
| `scripts/pin-digests.sh` | Releve ou controle les digests des images |
| `scripts/selftest-install.sh` | Rejoue cette etape dans un repertoire temporaire pour verifier le kit |

Verifier que chaque fichier monte par le compose existe bien (un fichier absent serait remplace par un repertoire vide au demarrage, sans erreur) :

```bash
cd ~/infra
for f in compose.yml env.example config/postgres/init-db.sh config/caddy/Caddyfile config/caddy/sites.d/.keep; do
  [ -f "$f" ] && echo "OK   $f" || echo "FAIL $f"
done
```

### 2.3 — Generer le .env

```bash
~/infra/scripts/init-env.sh --prefix <prefix> --domain <domain> ~/infra/.env
```

> **Remplacer `<prefix>` et `<domain>`** par les vraies valeurs. Le script copie `deploy/env.example`,
> renseigne le site et genere les 5 secrets d'infrastructure (alphabet URL-safe `A-Za-z0-9` : jamais
> `base64`, qui produit des `+/=` incompatibles avec certaines configs). Le fichier est cree en `600`.
> Les champs tunnel, sauvegarde et cles API restent vides : ils sont remplis aux etapes 3.b, 4 et 6.

Verifier la configuration, sans afficher les secrets :

```bash
cd ~/infra
docker compose config --quiet && echo "compose: OK"
grep -c '^[A-Z0-9_]*=.' .env
```

`docker compose config` ne doit afficher **aucun** avertissement `variable is not set` ; le `grep` compte les variables renseignees (9 attendues a ce stade : site, port, 5 secrets, retention des sauvegardes).

### 2.4 — Points cles du compose

Le `compose.yml` est commente ; l'essentiel :

- Caddy ecoute sur `127.0.0.1:18080` — pas accessible depuis le reseau, uniquement via cloudflared
- PostgreSQL cree des **utilisateurs separes** (n8n, nocodb) avec des mots de passe distincts ; `init-db.sh` ne rejoue jamais sur un volume existant (changer un mot de passe ensuite = `ALTER USER`)
- NocoDB utilise `NC_DB_JSON` (objet) et non `NC_DB` (URL) — evite les crashloops si le password contient des caracteres speciaux
- **Toutes les images sont figees par tag et digest** (jamais `:latest`) : un `pull` surprise = migration
  de schema sans retour arriere, et une **restauration de sauvegarde exige la meme version
  que la source** (vecu chez une PME : un serveur en `:latest` face a une prod
  figee sur une version plus ancienne — a realigner avant tout transfert de donnees). Monter une version
  = modifier le tag dans `compose.yml` volontairement, puis `scripts/pin-digests.sh compose.yml`
- **`mem_limit` sur n8n et NocoDB** : sans plafond, une rafale d'imports peut pousser un
  service a evincer les autres (incidents OOM vecus chez une PME). Ajuster a la RAM du
  serveur, mais toujours en poser un
- Le repertoire `config/caddy/` est monte en entier : on peut remplacer le Caddyfile ou poser un fichier dans `sites.d/` puis `caddy reload`, sans redemarrer le conteneur

---

## Etape 3 — Lancer la stack

Toujours en tant qu'utilisateur `spark` :

```bash
cd ~/infra
docker compose up -d
```

Attendre ~30 secondes, puis verifier :

```bash
cd ~/infra && set -a && . ./.env && set +a
for svc in n8n db; do
  host="${SPARK_PREFIX}-${svc}.${SPARK_DOMAIN}"
  code=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Host: $host" \
    "http://localhost:${SPARK_HOST_HTTP_PORT:-18080}" 2>/dev/null || echo "000")
  printf "  %-15s %s\n" "$svc" \
    "$([[ $code =~ ^(200|301|302)$ ]] && echo 'OK' || echo "FAIL ($code)")"
done
docker compose ps --format "table {{.Name}}\t{{.Image}}\t{{.Status}}"
```

Les services tournent et repondent via Caddy sur `127.0.0.1:18080`, mais ne sont pas encore accessibles depuis l'exterieur. La colonne `IMAGE` doit afficher les tags du `compose.yml` (`postgres:16.16-alpine`, `n8nio/n8n:2.19.4`, `nocodb/nocodb:2026.04.5`, `caddy:2.11.9-alpine`), et `postgres` doit etre `healthy`.

### Installer le service systemd

Revenir en root/sudo pour installer le service :

```bash
exit   # quitter le shell spark
```

Puis, de retour dans le shell administrateur :

```bash
sudo cp /opt/spark/spark-kit/deploy/linux/systemd/spark-compose.service \
  /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable spark-compose.service
```

> Le fichier `spark-compose.service` est fourni dans `deploy/linux/systemd/` **du kit** (`/opt/spark/spark-kit`). Il lance `docker compose up -d` au demarrage du serveur en tant qu'utilisateur `spark`, et refuse de demarrer si `~/infra/.env` ou `compose.yml` manque.

---

## Etape 3.b — Sauvegardes et test de restauration

Un backup non teste n'est pas un backup. Le kit livre les deux scripts et leurs timers systemd ; ils s'installent **avant** d'y mettre de la donnee reelle, et la premiere restauration reussie est notee dans le runbook du site : c'est le pre-requis de toute montee de version.

### 3.b.1 — Cle de chiffrement des secrets

Les sauvegardes contiennent le `.env` et le fichier `config` de n8n (il porte la cle qui chiffre les identifiants n8n : sans elle, une restauration donne des identifiants illisibles). Ils sont chiffres avec `age` vers une **cle publique** ; la cle privee ne reste pas sur la machine.

```bash
sudo -iu spark
```

Puis, dans le shell `spark` :

```bash
age-keygen -o ~/spark-backup.key
grep '^# public key:' ~/spark-backup.key
```

> **Copier la cle privee** (`~/spark-backup.key`, ligne `AGE-SECRET-KEY-...`) dans le coffre de mots de passe de l'entreprise, puis la supprimer du serveur : `shred -u ~/spark-backup.key`. Sans elle, les archives `secrets-*.tar.age` sont illisibles. La cle **publique** (`age1...`) n'est pas un secret.

Renseigner la cle publique dans le `.env` :

```bash
nano ~/infra/.env
# Remplir :
#   BACKUP_AGE_RECIPIENT=age1...
```

### 3.b.2 — Premiere sauvegarde et premier test de restauration

```bash
~/infra/scripts/backup.sh
~/infra/scripts/restore-test.sh
ls -la ~/infra/backups/
```

Attendu :
- `backup.sh` ecrit `pg_dumpall-<date>.sql.gz`, un `vol-<volume>-<date>.tgz` par volume hors Postgres (`n8n_data`, `nocodb_data`, `caddy_data`, `caddy_config`), `secrets-<date>.tar.age`, et termine par `sauvegarde ... complete`.
- `restore-test.sh` demarre un Postgres jetable avec la meme image, rejoue le dump, affiche `restauration rejouee : 1 erreur(s), toutes attendues` (le role `postgres` existe deja), les comptes de bases, de tables et de migrations n8n, puis `test de restauration OK`. Tant qu'aucun identifiant n8n n'existe (avant l'etape 6), il affiche un **avertissement** « aucun identifiant n8n dans la base » : relancer le test apres avoir cree un identifiant dans n8n pour que le controle de dechiffrement porte sur quelque chose.
- Les deux ecrivent `backups/LAST_OK` et `backups/RESTORE_TEST_OK` (horodatage).

```bash
exit   # quitter le shell spark
```

### 3.b.3 — Planifier

```bash
sudo cp /opt/spark/spark-kit/deploy/linux/systemd/spark-backup.{service,timer} \
  /opt/spark/spark-kit/deploy/linux/systemd/spark-restore-test.{service,timer} \
  /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now spark-backup.timer spark-restore-test.timer
systemctl list-timers 'spark-*'
```

Sauvegarde toutes les 6 h, test de restauration chaque nuit. Les deux units sont sautees tant que le drapeau `/opt/spark/MAINTENANCE` existe (`sudo touch /opt/spark/MAINTENANCE` avant une intervention, `rm` apres).

> **Hors machine.** Ces sauvegardes sont locales. Copier `~/infra/backups/` vers un stockage distant
> (`rclone copy` + suppression par age, jamais `sync` ; un second serveur chez le meme hebergeur n'est pas
> un site distant). Les dumps contiennent des secrets : le distant est chiffre ou le dump le devient avant envoi.
> En cas d'echec, les scripts appellent `SPARK_ALERT_WEBHOOK` (`.env`) s'il est renseigne.

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
```

Puis, une fois dans le shell `spark` :

```bash
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

> Adapter les hostnames avec les vraies valeurs de `<prefix>` et `<domain>`. Ce fichier est propre au site (identifiant de tunnel) : c'est le seul fichier de configuration qui ne vient pas du kit.

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
```

Puis, de retour dans le shell administrateur :

```bash
sudo cp /opt/spark/spark-kit/deploy/linux/systemd/spark-cloudflared.service \
  /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now spark-cloudflared.service
```

Verifier :

```bash
sudo systemctl status spark-cloudflared.service
```

> ⚠️ **Un seul service cloudflared.** Le paquet apt (ou un `cloudflared service
> install` lance par ailleurs) peut avoir cree/active son propre `cloudflared.service`
> (config dans `/etc/cloudflared/`). Deux services = deux connecteurs sur des configs
> potentiellement differentes. Verifier et ne garder qu'UN service actif :
>
> ```bash
> systemctl list-unit-files | grep cloudflared
> # si cloudflared.service (paquet) est deja celui qui tourne avec la bonne config,
> # le garder et NE PAS activer spark-cloudflared ; sinon :
> sudo systemctl disable --now cloudflared.service
> ```
>
> (Vecu chez une PME : l'installation a fini sur le `cloudflared.service` du paquet —
> fonctionnel, mais a documenter pour ne pas activer le doublon ensuite.)

### 4.6 — Mettre a jour le .env

```bash
sudo -iu spark
```

Puis, une fois dans le shell `spark` :

```bash
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
cd ~/infra && set -a && . ./.env && set +a
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

Les valeurs de reference sont dans [`SECURITY.md`](SECURITY.md) §2.2. Les poser dans `~/infra/config/caddy/Caddyfile`, dans chaque bloc de vhost (sans `preload` sur HSTS : il engage tout le domaine de facon quasi irreversible) :

```caddy
header {
    Strict-Transport-Security "max-age=63072000; includeSubDomains"
    X-Content-Type-Options "nosniff"
    X-Frame-Options "SAMEORIGIN"
    Referrer-Policy "strict-origin-when-cross-origin"
    Permissions-Policy "accelerometer=(), camera=(), geolocation=(), gyroscope=(), magnetometer=(), microphone=(), payment=(), usb=()"
    -X-Powered-By
    -Server
}
```

Valider **avant** de recharger, puis recharger Caddy (le repertoire est monte : l'edition en place est vue par le conteneur) :

```bash
cd ~/infra
docker compose exec caddy caddy validate --config /etc/caddy/Caddyfile
docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile
```

> Cette edition rend le Caddyfile du site different de celui du kit : c'est attendu, et visible par `diff -ru ~/spark-kit/deploy/config ~/infra/config`.

### 5.4 — CORS NocoDB

Ajouter dans le service `nocodb` de `~/infra/compose.yml` (bloc `environment`) :

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

Relancer, puis rejouer le test de restauration maintenant qu'un identifiant n8n existe (le controle de dechiffrement doit afficher `1 dechiffre(s)` au moins) :

```bash
cd ~/infra && docker compose up -d
~/infra/scripts/backup.sh && ~/infra/scripts/restore-test.sh
exit   # quitter le shell spark
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
systemctl is-active spark-backup.timer spark-restore-test.timer

echo "=== Containers ==="
sudo -u spark docker compose -f /opt/spark/infra/compose.yml ps \
  --format "table {{.Name}}\t{{.Status}}"

echo "=== Caddy → services ==="
set -a; . /opt/spark/infra/.env; set +a
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

## Mettre a jour la stack depuis le kit

Le kit evolue ; le site ne bouge que volontairement. Procedure :

```bash
sudo -iu spark
```

```bash
cd ~/spark-kit && git pull --ff-only
diff -u ~/infra/compose.yml ~/spark-kit/deploy/compose.yml
diff -u ~/infra/env.example ~/spark-kit/deploy/env.example
diff -ru ~/infra/config ~/spark-kit/deploy/config
~/infra/scripts/pin-digests.sh --check ~/infra/compose.yml
```

Lire le diff : les seules differences attendues sont celles que le site a faites lui-meme (en-tetes 5.3, CORS 5.4, fichiers `sites.d/`). Un changement de tag d'image est une **montee de version** : sauvegarde + test de restauration reussis et dates d'abord, puis `cp` du fichier concerne, `docker compose up -d`, verification. Jamais de `pull` sans l'avoir decide.

---

## Depannage

### NocoDB ne demarre pas (502 / crashloop)

**Cause probable** : le mot de passe PostgreSQL contient des caracteres speciaux.
**Solution** : verifier que `NC_DB_JSON` est utilise (pas `NC_DB`). Regenerer le password avec `A-Za-z0-9` uniquement (`init-env.sh` le fait).

### Docker Compose introuvable

**Symptome** : `docker: 'compose' is not a docker command` ou `docker-compose: command not found`.
**Cause** : le plugin `docker-compose-plugin` n'est pas installe (etape 1.2), ou un ancien `docker-compose` v1 est attendu.
**Solution** : `sudo apt-get install -y docker-compose-plugin`, puis `docker compose version`. Le fichier `compose.yml` est le meme pour les deux outils.

### Un volume monte est un repertoire vide

**Symptome** : Postgres demarre sans creer les bases, ou Caddy refuse de demarrer (`/etc/caddy/Caddyfile is a directory`).
**Cause** : un fichier reference par le compose (`config/postgres/init-db.sh`, `config/caddy/Caddyfile`) n'existait pas au `up` ; Docker a cree un repertoire vide a sa place.
**Solution** : `docker compose down`, supprimer le repertoire fautif, refaire les copies de l'etape 2.2, `docker compose up -d`. Si Postgres a deja initialise un volume sans les bases : `docker compose down -v` (donnees perdues — uniquement sur une installation neuve).

### n8n affiche "secure cookie" error

**Cause** : `X-Forwarded-Proto https` n'est pas propage.
**Solution** : verifier que le Caddyfile contient `header_up X-Forwarded-Proto https` dans chaque bloc `reverse_proxy`.

### UFW semble ne pas bloquer Docker

**Cause** : Docker manipule iptables directement. Les conteneurs qui publient des ports sur `0.0.0.0` contournent UFW.
**Impact** : nul ici — Caddy publie sur `127.0.0.1` uniquement, et le trafic externe passe par le tunnel Cloudflare (connexion sortante).

### Verifier le kit lui-meme

Sur une machine avec Docker, `~/spark-kit/deploy/scripts/selftest-install.sh --up` rejoue les copies de l'etape 2 dans un repertoire temporaire, valide le compose et le Caddyfile, demarre la stack sous un projet separe (`spark-selftest`, port 18090) et la detruit. Utile avant d'appliquer une mise a jour du kit a un site.

---

**La stack tourne, le tunnel est ouvert, les sauvegardes sont planifiees et testees, les cles API sont en place.** Suite : configurer Claude Code → [CLAUDE-CODE.md](CLAUDE-CODE.md).

Les **jobs planifies metier** du site (controles quotidiens, notifications) s'installent ensuite depuis le repo client, sur le modele des units `spark-backup` / `spark-restore-test` du kit (`ExecCondition` sur le drapeau `MAINTENANCE`).
