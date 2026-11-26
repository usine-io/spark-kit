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

**Source unique.** Les fichiers d'infrastructure (compose, Caddyfile, script d'initialisation Postgres, gabarit `.env`, scripts, units systemd) vivent **une seule fois** dans le depot du kit, sous [`deploy/`](deploy/). Ce guide les **copie** dans `/opt/spark/infra/` ; il ne les recopie jamais a la main. La configuration cloudflared du site est **generee** depuis le `.env` par `scripts/tunnel-config.sh` (etape 4). Pour voir ce que le site a de different du kit : `diff -ru /opt/spark/spark-kit/deploy/config /opt/spark/infra/config` (attendu : rien, hors `sites.d/` et le drapeau `MAINTENANCE`).

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

### 1.3 — Installer le client cloudflared

Le **tunnel lui-meme tourne dans le compose** (service `cloudflared`, profil `tunnel`, etape 4). Le binaire installe ici ne sert qu'aux commandes d'administration : `cloudflared login`, `tunnel create`, `tunnel route dns`.

```bash
curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
  | sudo tee /usr/share/keyrings/cloudflare-main.gpg > /dev/null

echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] \
  https://pkg.cloudflare.com/cloudflared \
  $(. /etc/os-release && echo "$VERSION_CODENAME") main" \
  | sudo tee /etc/apt/sources.list.d/cloudflared.list > /dev/null

sudo apt-get update
sudo apt-get install -y cloudflared
```

> Le nom de version vient de `/etc/os-release` comme en 1.2 : `lsb_release` manque sur une Debian minimale et ce guide ne l'installe pas.

Verifier (et noter la version dans le runbook) :

```bash
cloudflared --version
```

> La version du **connecteur** est celle du compose (`cloudflare/cloudflared:2026.11.2`, figee par tag et digest), pas celle du paquet apt : les deux peuvent differer sans consequence.

### 1.4 — Installer les outils

```bash
sudo apt-get install -y jq curl git tmux python3 age shellcheck
```

> `python3` est present par defaut sur Debian mais explicite ici : les jobs planifies
> Spark (controles quotidiens, notifications) en dependent — stdlib uniquement,
> aucun pip requis. `age` chiffre les secrets dans les sauvegardes (etape 3.b). `shellcheck`
> sert a `selftest-install.sh` (section « Verifier le kit lui-meme ») : sans lui, le selftest
> affiche `INFO  shellcheck absent : non joue` et passe quand meme, la ligne `OK    shellcheck sans remarque` manque.

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
cp ~/spark-kit/deploy/compose.runners.yml ~/infra/compose.runners.yml
cp ~/spark-kit/deploy/env.example ~/infra/env.example
cp -R ~/spark-kit/deploy/config ~/infra/
chmod +x ~/infra/config/postgres/init-db.sh
cp ~/spark-kit/deploy/scripts/*.sh ~/infra/scripts/
chmod +x ~/infra/scripts/*.sh
```

Ce que ces copies posent :

| Fichier dans `~/infra/` | Role |
|---|---|
| `compose.yml` | La stack (Postgres, n8n, NocoDB, Caddy, et cloudflared sous le profil `tunnel`), images figees par tag **et** digest, plafond memoire et healthcheck sur chaque service |
| `compose.runners.yml` | Override optionnel : n8n en mode task runner externe (sidecar `runners`), a n'utiliser qu'avec le profil `runners` apres le banc d'[`UPGRADES.md`](UPGRADES.md) |
| `env.example` | Gabarit du `.env` (toute variable lue par le compose y figure) |
| `config/postgres/init-db.sh` | Cree les bases et utilisateurs separes (`n8n`, `nocodb`) au premier demarrage |
| `config/caddy/Caddyfile` | Reverse proxy interne (3 vhosts), pas de TLS (Cloudflare s'en charge) ; en-tetes de securite et journal d'acces JSON (snippet `securite`), page de maintenance (snippet `maintenance`, drapeau `config/caddy/MAINTENANCE`), `404` pour tout `Host` inconnu |
| `config/caddy/sites.d/` | Vhosts additionnels du site, un fichier `.caddy` par vhost (vide au depart), qui importent `maintenance` et `securite` |
| `scripts/init-env.sh` | Cree le `.env` avec des secrets URL-safe (`--sync` : complete un `.env` existant avec les variables nouvelles du kit) |
| `scripts/tunnel-config.sh` | Ecrit la configuration cloudflared du site depuis le `.env` (etape 4), jamais a la main |
| `scripts/cloudflared-host-guard.sh` | Garde « un seul connecteur » de la variante hote (`ExecCondition=` de `spark-cloudflared.service`) : l'unit reste inactive si le profil `tunnel` est pose ou si un conteneur `spark-cloudflared-1` existe, meme arrete ; ne sert pas en variante conteneur |
| `scripts/n8n-releve.sh`, `scripts/restore-n8n.sh` | Releve avant/apres d'une montee de version n8n et restauration de la base + du volume n8n depuis un jeu de sauvegarde (retour arriere), voir [`UPGRADES.md`](UPGRADES.md) |
| `scripts/check-env.sh` | Verifie, par nom et sans afficher de valeur, que les variables obligatoires du `.env` sont renseignees (etapes 2.3 et 7) ; ne regarde que le fichier, jamais l'environnement du shell |
| `scripts/backup.sh`, `scripts/restore-test.sh` | Sauvegarde et test de restauration (etape 3.b), un seul exemplaire de chacun a la fois (verrou) |
| `scripts/pin-digests.sh` | Releve ou controle les digests des images (compose et `mcp-n8n.sh`) |
| `scripts/mcp-n8n.sh` | Lance le serveur MCP n8n a la demande pour Claude Code (image figee par tag + digest), voir [CLAUDE-CODE.md](CLAUDE-CODE.md) |
| `scripts/lib.sh` | Fonctions communes (sourcees par les autres scripts) |
| `scripts/selftest-install.sh` | Verifie le kit : se lance **depuis le kit** (`~/spark-kit/deploy/scripts/selftest-install.sh`), la copie dans `~/infra/scripts/` s'arrete avec un message qui renvoie au kit |

Verifier que chaque fichier monte par le compose existe bien (un fichier absent serait remplace par un repertoire vide au demarrage, sans erreur) :

```bash
cd ~/infra
for f in compose.yml compose.runners.yml env.example config/postgres/init-db.sh config/caddy/Caddyfile config/caddy/sites.d/.keep; do
  [ -f "$f" ] && echo "OK   $f" || echo "FAIL $f"
done
```

### 2.3 — Generer le .env

```bash
~/infra/scripts/init-env.sh --prefix <prefix> --domain <domain> ~/infra/.env
```

> **Remplacer `<prefix>` et `<domain>`** par les vraies valeurs. Le script copie `deploy/env.example`,
> renseigne le site, genere les 6 secrets d'infrastructure (5 mots de passe et cles, plus le jeton du
> sidecar runner ; alphabet URL-safe `A-Za-z0-9` : jamais `base64`, qui produit des `+/=` incompatibles
> avec certaines configs) et pose `SPARK_UID`/`SPARK_GID` (l'utilisateur `spark`, sous lequel tournera
> le conteneur cloudflared). Le fichier est cree en `600`. Les champs tunnel, sauvegarde et cles API
> restent vides : ils sont remplis aux etapes 3.b, 4 et 6.

Verifier la configuration, sans afficher les secrets :

```bash
cd ~/infra
out=$(docker compose config -q 2>&1); [ -z "$out" ] && echo "compose: OK" || { echo "$out"; false; }
~/infra/scripts/check-env.sh
```

`compose: OK` ne s'affiche que si `docker compose config` n'a **rien** ecrit : un avertissement `variable is not set` (code de retour 0 pourtant) est affiche a la place et la commande echoue. Compose ne dit rien d'une variable **presente mais vide** (`NOM=`) : `check-env.sh` verifie une a une celles qui doivent avoir une valeur (`SPARK_PREFIX`, `SPARK_DOMAIN`, les 6 secrets, `SPARK_UID`, `SPARK_GID`) et affiche `OK   NOM` ou `FAIL NOM absent ou vide`, jamais la valeur. Il juge la valeur telle que le shell la **resout**, debarrassee des guillemets et des espaces : `NOM=`, `NOM=''`, `NOM="  "` ou une ligne absente sont vides ; une valeur d'un seul caractere est renseignee. Code de retour 1 s'il y a au moins un `FAIL` (toutes les variables sont affichees, il ne s'arrete pas au premier). Il **ne regarde que le fichier** (charge dans un environnement vide) : une variable exportee dans le shell ne compense pas une ligne absente.

> **Le `.env` est source comme du shell** (`. .env`) par les scripts du kit, et par `docker compose` avec des regles proches. Toute valeur ajoutee a la main qui contient `$`, un accent grave ou une espace doit etre entre **guillemets simples** : `SPARK_ALERT_WEBHOOK='https://acme.example/hook?token=a$b'`. Les secrets generes par `init-env.sh` (`A-Za-z0-9`) n'en ont pas besoin.

### 2.4 — Points cles du compose

Le `compose.yml` est commente ; l'essentiel :

- Caddy ecoute sur `127.0.0.1:18080` — pas accessible depuis le reseau. Avec le profil `tunnel` (etape 4), cloudflared tourne **dans le compose** et vise `http://caddy:80` sur le reseau interne : le port hote ne sert plus qu'aux sondes locales
- PostgreSQL cree des **utilisateurs separes** (n8n, nocodb) avec des mots de passe distincts ; `init-db.sh` ne rejoue jamais sur un volume existant (changer un mot de passe ensuite = `ALTER USER`)
- NocoDB utilise `NC_DB_JSON` (objet) et non `NC_DB` (URL) — evite les crashloops si le password contient des caracteres speciaux
- **Toutes les images sont figees par tag et digest** (jamais `:latest`) : un `pull` surprise = migration
  de schema sans retour arriere, et une **restauration de sauvegarde exige la meme version
  que la source** (vecu chez une PME : un serveur en `:latest` face a une prod
  figee sur une version plus ancienne — a realigner avant tout transfert de donnees). Monter une version
  = suivre la fiche d'[`UPGRADES.md`](UPGRADES.md) (jamais un simple changement de tag : banc sur copie, retour arriere ecrit)
- **`mem_limit` sur chaque service**, chacun par une variable du `.env` : `N8N_MEM_LIMIT` (1g), `NOCODB_MEM_LIMIT` (900m), `PG_MEM_LIMIT` (512m), `CADDY_MEM_LIMIT` (128m), `CLOUDFLARED_MEM_LIMIT` (128m, profil `tunnel`), `N8N_RUNNERS_MEM_LIMIT` (512m, profil `runners`) : sans plafond, une rafale d'imports pousse un
  service a evincer les autres, et c'est Postgres que le noyau tue en premier (incidents OOM vecus chez une PME). Pour n8n, le tas Node est borne sous le plafond : `N8N_HEAP_MB + N8N_RUNNERS_HEAP_MB + ~200 Mio <= N8N_MEM_LIMIT`, soit par defaut `608 + 192 + 200 = 1000 Mio` sous `1g` (1024 Mio)
- **n8n** : module `insights` desactive (un workflow execute puis supprime en moins de 30 s empoisonnait son tampon, n8n ralentissait chaque jour), retention des executions a 7 jours / 150 000 (`execution_data` representait l'essentiel de la base), task runner **interne** par defaut (le sidecar `runners` est une option bancee, voir `UPGRADES.md`), `N8N_PROXY_HOPS=2` (Cloudflare → cloudflared → Caddy ; une valeur trop basse donne la meme IP a tous les utilisateurs et fausse le limiteur de connexions). Jamais de `N8N_CONCURRENCY_PRODUCTION_LIMIT` sans banc de charge
- **Healthcheck sur chaque service** : Postgres (`pg_isready`), n8n (`/healthz/readiness`, le seul qui dise vrai : `/healthz` repond `ok` avec une base morte), NocoDB (`/api/v1/health`), Caddy (un vhost reel, avec `Host` et lecture du corps). `docker compose ps` affiche `(healthy)` quand tout est pret ; n8n a 2 minutes de grace (`start_period`) parce que les migrations d'une montee de version prennent de l'ordre d'une minute et qu'il ne faut **pas** le redemarrer pendant
- Le repertoire `config/caddy/` est monte en entier : on peut remplacer le Caddyfile, poser un fichier dans `sites.d/` ou le drapeau `MAINTENANCE` (503 sur tous les vhosts, `UPGRADES.md`) puis `caddy reload`, sans redemarrer le conteneur. Tant que `sites.d/` ne contient aucun fichier `.caddy` (c'est le cas apres l'installation : seul `.keep` s'y trouve), Caddy ecrit a chaque demarrage, a chaque `validate` et a chaque `reload` un avertissement `No files matching import glob pattern` avec le motif `/etc/caddy/sites.d/*.caddy` : **attendu, sans gravite**, il disparait au premier vhost pose. Au demarrage, `docker compose logs caddy` montre aussi `HTTP/2 skipped because it requires TLS` et `HTTP/3 skipped because it requires TLS` : attendus eux aussi, Caddy ne sert que du HTTP en interne, le TLS est chez Cloudflare
- Les **en-tetes de securite** (`SECURITY.md` §2.2), le **journal d'acces JSON** et le **CORS NocoDB** sont poses par le Caddyfile du kit : rien a ajouter sur le site. Un `Host` inconnu recoit `404`
- Journaux des conteneurs bornes (`json-file`, 5 x 20 Mo par service)

---

## Etape 3 — Lancer la stack

Toujours en tant qu'utilisateur `spark` :

```bash
cd ~/infra
docker compose up -d
```

Attendre ~30 secondes, puis verifier. La sonde lit un **marqueur dans le corps** de la reponse (`/healthz/readiness` de n8n, qui ne repond `ok` que si la base est jointe ; `/api/v1/health` de NocoDB) : un code `200` seul ne prouve pas le routage. Un `Host` inconnu doit recevoir `404`.

```bash
cd ~/infra
(  # sous-shell : le .env est lu ici et n'est PAS exporte dans le shell interactif (voir l'encart de l'etape 3.b)
  set -a && . ./.env && set +a
  [ -n "$SPARK_PREFIX" ] && [ -n "$SPARK_DOMAIN" ] || { echo "FAIL .env non charge (SPARK_PREFIX/SPARK_DOMAIN vides)"; exit 1; }
  probe() {  # service, chemin, marqueur attendu dans le corps
    body=$(curl -s -m 10 -H "Host: ${SPARK_PREFIX}-$1.${SPARK_DOMAIN}" \
      "http://127.0.0.1:${SPARK_HOST_HTTP_PORT:-18080}$2" 2>/dev/null || true)
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

Les services tournent et repondent via Caddy sur `127.0.0.1:18080`, mais ne sont pas encore accessibles depuis l'exterieur. La colonne `IMAGE` affiche chaque image telle que le `compose.yml` la fige, **tag suivi du digest** (`postgres:16.16-alpine@sha256:...`, `n8nio/n8n:2.49.6@sha256:...`, `nocodb/nocodb:2026.04.5@sha256:...`, `caddy:2.11.9-alpine@sha256:...`). La colonne `STATUS` passe a `(healthy)` pour les **quatre** services : tout de suite pour Postgres, en moins de 2 minutes pour n8n, NocoDB et Caddy (`health: starting` entre-temps est normal : periode de grace des healthchecks). `cloudflared` n'apparait pas encore : il demarre avec le profil `tunnel` a l'etape 4.

> `docker compose logs n8n` montre au demarrage **trois lignes attendues** (n8n 2.49.6, runner interne) :
> 1. `(node:7) DeprecationWarning: Calling client.query() when the client is already executing a query is deprecated and will be removed in pg@9.0.` (pilote PostgreSQL embarque dans n8n, rien a faire) ;
> 2. `Failed to start Python task runner in internal mode. because Python 3 is missing from this system.` : l'image n8n n'embarque pas Python, le **node Code en Python n'est disponible qu'avec le sidecar** (profil `runners`, qui l'embarque) ; en mode interne, seul le JavaScript est disponible, et c'est voulu ;
> 3. `There is a deprecation related to your n8n setup` suivie de `N8N_RUNNERS_MODE -> Internal task runner mode is deprecated` : le kit garde le runner interne par defaut (un processus de moins, une memoire bornee ensemble) ; le mode externe est le profil `runners`, a adopter apres le banc d'[`UPGRADES.md`](UPGRADES.md).
>
> Puis `Registered runner "JS Task Runner"`. Toute autre ligne `deprecation` ou `error` est a lire.

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
sudo systemctl enable --now spark-compose.service
systemctl is-active spark-compose.service   # attendu : active
```

> Le fichier `spark-compose.service` est fourni dans `deploy/linux/systemd/` **du kit** (`/opt/spark/spark-kit`). Il lance `docker compose up -d` au demarrage du serveur en tant qu'utilisateur `spark`, et refuse de demarrer si `~/infra/.env` ou `compose.yml` manque (le fichier absent est nomme dans `journalctl -u spark-compose.service`). `enable --now` l'active tout de suite : `up -d` est idempotent, la stack deja lancee n'est pas touchee. Avec un simple `enable`, le service resterait `inactive` jusqu'au prochain reboot et l'etape 7 afficherait `compose: FAIL`.

> ⚠️ **Appliquer un changement = `sudo systemctl reload spark-compose.service`** (ou, dans le shell `spark`, `cd ~/infra && docker compose up -d`). `reload` rejoue `docker compose up -d --remove-orphans` (`ExecReload`) : idempotent, seuls les services dont la definition a change sont recrees, un service arrete est relance, et le meme garde-fou qu'au demarrage s'applique (`.env` ou `compose.yml` absent : `reload` refuse et le journal nomme le fichier). Deux commandes a **ne pas** utiliser pour cela : `systemctl start`, qui ne fait **rien** sur une unit deja `active` (systemd ne relance pas un service actif, le changement n'est pas applique) ; `systemctl restart`, qui passe par `ExecStop`, soit un `docker compose down` qui **coupe le site** le temps du redemarrage. Si `.env` ou `compose.yml` manque au moment d'un `restart`, l'unit saute volontairement le `down` (les conteneurs restent en place, journal : `docker compose down NON execute`), puis echoue au demarrage : une config cassee ne coupe pas le site, mais `systemctl status` est `failed` jusqu'a correction. Sortir de l'etat `failed`, et seulement pour cela : `sudo systemctl reset-failed spark-compose.service && sudo systemctl start spark-compose.service` (`reset-failed` efface l'etat `failed` et le compteur de relances ; l'unit du kit pose `StartLimitIntervalSec=0` pour que `start` ne soit jamais refuse avec `start request repeated too quickly`, `reset-failed` reste utile sur une unit installee avant cette ligne).

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

> **Ce que le test de restauration prouve, et ce qu'il ne prouve pas.** `restore-test.sh` dechiffre les identifiants n8n de la copie avec la `N8N_ENCRYPTION_KEY` du **`.env` courant** de `~/infra/`, pas avec celle contenue dans l'archive `secrets-<stamp>.tar.age` du meme jeu (il ne l'ouvre jamais : la cle privee `age` n'est pas sur la machine). Il prouve donc que la cle en service lit la base sauvegardee ; il ne prouve pas que l'archive de secrets est lisible et a jour. Verifier l'archive **periodiquement, hors machine** (poste d'administration, apres `rclone copy` d'un jeu recent et du `.env` courant, ou en session SSH avec la cle privee lue depuis le coffre, jamais ecrite sur le serveur) : dechiffrer, puis comparer la cle de l'archive a celle du `.env` **sans afficher ni l'une ni l'autre** :
>
> ```bash
> # Poste d'administration, dans un repertoire de travail : secrets-<stamp>.tar.age, une copie du .env
> # courant du site (chmod 600) et la cle privee exportee du coffre (spark-backup.key, chmod 600).
> tmp=$(mktemp -d)
> age -d -i spark-backup.key -o "$tmp/secrets.tar" secrets-<stamp>.tar.age \
>   && tar xf "$tmp/secrets.tar" -C "$tmp" && [ -s "$tmp/env" ] && [ -s "$tmp/n8n-config" ] \
>   && [ "$(grep '^N8N_ENCRYPTION_KEY=' "$tmp/env" | sha256sum)" = "$(grep '^N8N_ENCRYPTION_KEY=' .env | sha256sum)" ] \
>   && echo "archive OK : N8N_ENCRYPTION_KEY identique au .env courant" \
>   || echo "ECART : archive illisible, incomplete ou cle differente"
> rm -rf "$tmp" && shred -u spark-backup.key .env
> ```
>
> `ECART` avec une archive recente = la cle du `.env` a change sans nouvelle sauvegarde, ou la cle privee du coffre n'est pas celle du `BACKUP_AGE_RECIPIENT` : a traiter avant toute montee de version. Rythme conseille : a chaque rotation de la cle privee ou de `BACKUP_AGE_RECIPIENT`, et au moins une fois par trimestre, note dans le runbook du site.

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
- `backup.sh` ecrit un **jeu** a un meme horodatage `<stamp>` : `pg_dumpall-<stamp>.sql.gz`, un `vol-<volume>-<stamp>.tgz` par volume hors Postgres (`n8n_data`, `nocodb_data`, `caddy_data`, `caddy_config`, `caddy_logs`), `secrets-<stamp>.tar.age`, et termine par `sauvegarde ... complete`. La retention (`BACKUP_KEEP_DAYS`, 14 jours) supprime les jeux entiers, jamais un fichier isole.
- `restore-test.sh` demarre un Postgres jetable avec la meme image, rejoue le dump, affiche `restauration rejouee : 1 erreur(s), toutes attendues` (le role `postgres` existe deja), les comptes de bases, de tables et de migrations n8n, puis compte les identifiants n8n dans la copie. **A ce stade il n'y en a aucun** (le premier acces n8n est l'etape 6) : le script affiche `AVERTISSEMENT : aucun identifiant n8n dans la base, dechiffrement non verifie`, puis `test de restauration OK`, et sort en code 0. Le controle de dechiffrement ne porte sur rien tant qu'un identifiant n'existe pas ; l'etape 6 en cree un et rend ce controle obligatoire.
- `backup.sh` ecrit `backups/LAST_OK` et `restore-test.sh` ecrit `backups/RESTORE_TEST_OK` (un horodatage chacun, uniquement en fin de succes : `cat ~/infra/backups/LAST_OK ~/infra/backups/RESTORE_TEST_OK`).
- `backup.sh` refuse d'ecrire quoi que ce soit si `BACKUP_AGE_RECIPIENT` est vide ou n'est pas une cle `age1...` valide (ou si `age` manque) : une sauvegarde sans ses secrets n'est pas une sauvegarde. Chaque fichier est produit en `.part` et renomme seulement quand tout est controle, secrets et volumes d'abord, dump en dernier : le dump le plus recent (celui que `restore-test.sh` prend) a toujours son jeu complet.
- Un seul `backup.sh` et un seul `restore-test.sh` a la fois : un deuxieme lancement pendant le premier sort en code 2 avec `deja en cours d'execution (verrou ...)`, sans rien toucher ni alerter.
- `restore-test.sh` dechiffre avec la `N8N_ENCRYPTION_KEY` du **`.env` courant**, jamais avec celle de l'archive `secrets-*.tar.age` (encart de 3.b.1 : verification periodique de l'archive hors machine). Un chemin de dump passe en argument doit exister : `~/infra/scripts/restore-test.sh /chemin/inexistant.sql.gz` sort `ERREUR: dump /chemin/inexistant.sql.gz introuvable`, code 2, sans se rabattre sur le dump le plus recent.
- `restore-test.sh` lit les images (tag + digest) dans `compose.yml` via `docker compose config` : il n'exige pas que la stack tourne. Il refuse d'abord un dump illisible ou **tronque** (derniere ligne `PostgreSQL database cluster dump complete` absente : code 2, alerte), et supprime en fin de course le conteneur jetable **avec son volume** (`docker rm -v`) : `docker volume ls` compte autant de volumes avant qu'apres, le timer quotidien ne remplit pas le disque.
- Si `restore-test.sh` sort `base n8n vide` ou `relation "migrations" does not exist`, le dump a ete pris pendant que n8n creait encore ses tables (premier demarrage) : attendre la sonde `-n8n OK` de l'etape 3, relancer `backup.sh`, puis `restore-test.sh`.

> **`RESTORE_TEST_REQUIRE_CREDENTIAL`** (dans `.env`, `0` par defaut). A `1`, une base sans identifiant n8n fait **echouer** le test de restauration (code 2, alerte) au lieu d'un avertissement. A activer en production une fois l'etape 6 faite : c'est ce qui garantit que la cle `N8N_ENCRYPTION_KEY` sauvegardee dechiffre bien ce qu'il y a en base. Pour l'essayer tout de suite : `RESTORE_TEST_REQUIRE_CREDENTIAL=1 ~/infra/scripts/restore-test.sh` doit sortir en erreur « aucun identifiant n8n dans la base ».

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

> **Alerte d'echec : `SPARK_ALERT_WEBHOOK`.** Quand `backup.sh` ou `restore-test.sh` echoue (code 2), il ecrit `ALERTE [hote] script: message — ERREUR: <derniere ligne ERREUR>` sur stderr (donc dans `journalctl -u spark-backup.service` / `-u spark-restore-test.service`) et, si `SPARK_ALERT_WEBHOOK` est renseigne, envoie le meme contenu en POST JSON (`{host, script, message, error, ts, status}`) a cette URL (webhook n8n d'un autre site, Slack, Teams, etc.). C'est vrai **des la premiere erreur**, y compris quand le script s'arrete avant d'avoir commence : `.env` absent, `N8N_ENCRYPTION_KEY` ou `BACKUP_AGE_RECIPIENT` manquante, `age` desinstalle. Sans `.env` lisible, le webhook n'est connu que s'il est aussi pose dans l'unit (`sudo systemctl edit spark-backup.service`, bloc `[Service]`, `Environment=SPARK_ALERT_WEBHOOK=https://...`) ; la ligne `ALERTE`, elle, sort toujours dans le journal. La ligne ERREUR nomme un fichier ou une variable, jamais une valeur. Le renseigner dans `~/infra/.env` (`SPARK_ALERT_WEBHOOK=https://...`). Pour verifier le circuit sans rien casser : `BACKUP_AGE_RECIPIENT=age1invalide ~/infra/scripts/backup.sh` doit sortir en code 2 avec `ERREUR: BACKUP_AGE_RECIPIENT invalide`, l'alerte en stderr, et n'ecrire aucune archive dans `backups/`.
>
> **Priorite environnement > `.env`, et le piege qui va avec.** Pour les scripts du kit comme pour `docker compose`, une variable deja posee dans l'environnement (`Environment=` dans l'unit, ligne de commande) **l'emporte** sur le `.env`, y compris sur une ligne vide `SPARK_ALERT_WEBHOOK=`. Consequence : si vous chargez le `.env` dans votre shell interactif (`set -a; . ./.env; set +a`) puis modifiez le fichier (`nano`, `sed`), les scripts lances **depuis ce shell** continuent de voir les anciennes valeurs exportees — par exemple `RESTORE_TEST_REQUIRE_CREDENTIAL=0` alors que le fichier dit `1`. C'est pourquoi les sondes de ce guide lisent le `.env` dans un **sous-shell** `( set -a; . ./.env; ... )` qui n'exporte rien. Si un `.env` a quand meme ete charge dans le shell courant, quitter et rouvrir une session `spark` (`exit`, puis `sudo -iu spark`) avant de relancer un script.

---

## Etape 4 — Ouvrir le tunnel Cloudflare

Le tunnel Cloudflare cree une connexion sortante securisee entre le serveur et Cloudflare. Le trafic arrive en HTTPS chez CF, transite par le tunnel chiffre, et atterrit sur Caddy en HTTP. **Aucun port entrant a ouvrir, aucun certificat a gerer.** Le connecteur `cloudflared` tourne **dans le compose** (service `cloudflared`, profil `tunnel`), sur le reseau interne de la stack, vers `http://caddy:80` ; il n'y a pas de service systemd a part : `spark-compose.service` le relance au demarrage avec le reste.

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

### 4.3 — Renseigner le tunnel dans le .env

```bash
nano ~/infra/.env
```

Completer (toujours dans le shell `spark`), **sans toucher a `COMPOSE_PROFILES` pour l'instant** (il est pose en 4.4, apres la generation et la validation de la configuration) :

```
SPARK_TUNNEL_ID=<UUID affiche ci-dessus>
SPARK_TUNNEL_DIR=/opt/spark/.cloudflared
CF_API_TOKEN=<token avec scope Zone:DNS:Edit>
CF_ZONE_ID=<ID de la zone parente>
```

> `SPARK_TUNNEL_DIR` est le repertoire que `cloudflared login` et `tunnel create` viennent de remplir (`cert.pem`, `<UUID>.json`) ; le compose le monte **en lecture seule** dans le conteneur, qui tourne sous l'utilisateur `spark` (`SPARK_UID`/`SPARK_GID`, poses a l'etape 2.3) et lit donc ces fichiers en `600` sans `chown`. La variante hote (encart de 4.6) n'a pas de variable propre : le chemin de `config-spark.yml` est code dans l'unit systemd.

### 4.4 — Generer et valider la configuration du tunnel, puis activer le profil

```bash
~/infra/scripts/tunnel-config.sh
cat /opt/spark/.cloudflared/config.yml
```

Attendu : `config.yml ecrit (container) : tunnel <UUID>, ingress -> http://caddy:80`, puis le fichier : `tunnel`, `credentials-file: /etc/cloudflared/<UUID>.json` (chemin **dans** le conteneur), trois `hostname` vers `http://caddy:80` et le `http_status:404` final. Le script refuse d'ecrire si `<UUID>.json` manque ou si `SPARK_TUNNEL_ID` n'est pas un UUID ; il se relance apres tout changement du `.env` (`--check` dit si le fichier est a jour). Un vhost ajoute dans `sites.d/` s'ajoute a l'ingress par `SPARK_TUNNEL_EXTRA_HOSTS='nom.complet.<domain>'` dans le `.env` (ligne presente, vide, dans `env.example`), puis `tunnel-config.sh` de nouveau.

Valider l'ingress avec l'image du compose (aucune connexion a Cloudflare, aucun jeton requis ; `--profile tunnel` parce que le profil n'est pas encore dans le `.env`) :

```bash
cd ~/infra
docker compose --profile tunnel run --rm --no-deps cloudflared tunnel --config /etc/cloudflared/config.yml ingress validate
```

Attendu : `Validating rules from /etc/cloudflared/config.yml` puis `OK`. **Seulement maintenant**, activer le profil et verifier la coherence :

```bash
sed -i 's/^COMPOSE_PROFILES=.*/COMPOSE_PROFILES=tunnel/' ~/infra/.env
~/infra/scripts/check-env.sh | tail -1
```

Attendu : `OK   COMPOSE_PROFILES coherent (tunnel)`. `COMPOSE_PROFILES=tunnel` fait entrer le service `cloudflared` dans tout `docker compose up -d`, y compris celui de `spark-compose.service` au demarrage et le `reload`. Il est pose **apres** `tunnel-config.sh` et la validation : pose avant, un `reload` ou un reboot entre les deux creerait le conteneur sans `config.yml` et il bouclerait en redemarrage (`open /etc/cloudflared/config.yml: no such file`). `check-env.sh` refuse (`FAIL COMPOSE_PROFILES : profil tunnel sans .../config.yml`) un `.env` dans cet etat.

### 4.5 — Creer les DNS

```bash
cloudflared tunnel route dns spark-<prefix> <prefix>-n8n.<domain>
cloudflared tunnel route dns spark-<prefix> <prefix>-app.<domain>
cloudflared tunnel route dns spark-<prefix> <prefix>-db.<domain>
```

### 4.6 — Lancer le connecteur

```bash
cd ~/infra
docker compose up -d
sleep 10
docker compose ps cloudflared --format "table {{.Name}}\t{{.Image}}\t{{.Status}}"
curl -s -m 5 http://127.0.0.1:2000/ready; echo
```

Attendu : `spark-cloudflared-1` `Up` (pas `Restarting`), puis `{"status":200,"readyConnections":4,...}` : `readyConnections` superieur a 0 est le signe que le tunnel est etabli. `docker compose logs cloudflared` montre `Registered tunnel connection` (quatre fois). Le port `127.0.0.1:2000` (`SPARK_TUNNEL_METRICS_PORT`) n'est joignable que depuis le serveur : c'est la sonde locale du tunnel.

> ⚠️ **Un seul connecteur.** Le paquet apt peut avoir cree/active son propre `cloudflared.service` (config dans `/etc/cloudflared/`) ; deux connecteurs sur deux configs differentes se disputent le tunnel. Verifier qu'aucun service hote ne tourne : `systemctl is-active cloudflared.service spark-cloudflared.service` (attendu : `inactive` deux fois) puis, si l'un est `active` ou `enabled` (`systemctl list-unit-files | grep cloudflared`), `sudo systemctl disable --now <unit>` (depuis le compte administrateur). Vecu chez une PME : l'installation avait fini sur le service du paquet, fonctionnel mais non documente.

> **Retirer ou changer de connecteur.** Vider `COMPOSE_PROFILES` dans le `.env` **ne retire pas** un conteneur `cloudflared` deja cree : il survit au `reload` et au reboot (`restart: always`) et continue de retenter le tunnel. Le retrait est toujours explicite : `cd ~/infra && docker compose --profile tunnel stop cloudflared && docker compose --profile tunnel rm -f cloudflared`, puis `COMPOSE_PROFILES=` dans le `.env`. Verifier ensuite `docker compose --profile tunnel ps cloudflared` (vide).

> **Variante « cloudflared sur l'hote »** (binaire apt + unit systemd), si le site la prefere : `COMPOSE_PROFILES` vide (et, si le conteneur a deja tourne, le retrait ci-dessus d'abord), `~/infra/scripts/tunnel-config.sh --host` (ecrit `/opt/spark/.cloudflared/config-spark.yml`, ingress vers `http://localhost:18080` ; ce chemin est celui que l'unit du kit lit), puis `sudo cp /opt/spark/spark-kit/deploy/linux/systemd/spark-cloudflared.service /etc/systemd/system/ && sudo systemctl daemon-reload && sudo systemctl enable --now spark-cloudflared.service`. Jamais les deux a la fois : l'unit **reste inactive** (garde `ExecCondition=` → `~/infra/scripts/cloudflared-host-guard.sh`, copie avec les autres scripts a l'etape 2.2) tant que le profil `tunnel` est dans le `.env` **ou** qu'un conteneur `spark-cloudflared-1` existe, **meme arrete** (au reboot, Docker le relance apres l'unit : verifier seulement « il tourne » laissait les deux connecteurs demarrer ensemble). Le refus n'est pas un echec : pas de boucle `Restart=`, l'unit ne prend pas la main quand le conteneur s'arrete un instant ; elle est reessayee au prochain `systemctl start` ou au boot. La cause est dans `journalctl -u spark-cloudflared.service` (ligne `spark-cloudflared.service : ... un seul connecteur a la fois, l'unit hote reste inactive`, puis `Skipped due to 'exec-condition'`) ; les journaux de cloudflared lui-meme sont au meme endroit (`StandardOutput=journal`, pas de fichier dans `~/infra/logs/` pour cette variante). Controle qu'un seul connecteur tourne, a refaire apres toute bascule **et apres un reboot** : `systemctl is-active spark-cloudflared.service` (`active` en variante hote, `inactive` sinon) et `docker compose --profile tunnel ps cloudflared --format '{{.Name}} {{.Status}}'` (une ligne `Up` en conteneur, rien sinon) : **exactement l'un des deux**. La bascule hote → conteneur d'un site existant est une fiche d'[`UPGRADES.md`](UPGRADES.md).
>
> *Test de la garde au reboot* (serveur de recette, une fois) : les deux connecteurs volontairement actives (`COMPOSE_PROFILES=tunnel` + conteneur cree, et `sudo systemctl enable spark-cloudflared.service`), `sudo reboot`, puis : `systemctl is-active spark-cloudflared.service` → `inactive` ; `journalctl -b -u spark-cloudflared.service | grep -c 'un seul connecteur'` → `1` ; `docker compose --profile tunnel ps cloudflared --format '{{.Status}}'` → une ligne `Up` ; `systemctl show -p NRestarts spark-cloudflared.service` → `NRestarts=0`. Puis `sudo systemctl disable spark-cloudflared.service` (variante conteneur) ou le retrait du conteneur et du profil (variante hote). C'est le scenario de l'etape 8 pour un site qui garde les deux fichiers installes.

### 4.7 — Verifier l'acces HTTPS

```bash
cd ~/infra
(  # sous-shell : rien n'est exporte dans le shell interactif
  set -a && . ./.env && set +a
  for s in n8n app db; do
    printf '%s-%s.%s : ' "$SPARK_PREFIX" "$s" "$SPARK_DOMAIN"
    curl -sI -m 15 "https://${SPARK_PREFIX}-${s}.${SPARK_DOMAIN}" | head -1
  done
)
```

Les trois doivent repondre en HTTPS avec un status 200 ou 302.

```bash
exit   # quitter le shell spark
```

---

## Etape 5 — Durcir (recommande)

Les etapes 5.1 et 5.2 se font depuis le compte **administrateur** (vous l'etes apres le `exit` de la fin de l'etape 4.7 ; sinon, `exit` d'abord), 5.3 en tant que `spark`.

### 5.1 — Mises a jour automatiques

```bash
sudo apt-get install -y unattended-upgrades
sudo dpkg-reconfigure -plow unattended-upgrades
```

### 5.2 — Cloudflare Access

Configurer une application Access devant les 3 sous-domaines pour empecher l'acces anonyme. Sans elle, les pages de login n8n/NocoDB sont publiques.

Documentation detaillee : [`templates/docs/cf-access.md`](https://github.com/spark-kit/templates/blob/main/docs/cf-access.md).

### 5.3 — Verifier les en-tetes de securite et le CORS

Les en-tetes de [`SECURITY.md`](SECURITY.md) §2.2, le journal d'acces et le CORS NocoDB (§2.3) sont **poses par le Caddyfile du kit** (snippet `securite`, vhost `-db`) : rien a editer. Verifier, en tant que `spark` :

```bash
sudo -iu spark
```

```bash
cd ~/infra
(  set -a && . ./.env && set +a
  for s in n8n app db; do
    echo "=== ${SPARK_PREFIX}-$s.${SPARK_DOMAIN} ==="
    curl -sI -m 15 "https://${SPARK_PREFIX}-$s.${SPARK_DOMAIN}/" \
      | grep -iE "^(strict-transport|x-content-type|x-frame|referrer|permissions|access-control-allow-origin|server|x-powered-by)"
  done
)
```

Attendu, sur chaque vhost : `strict-transport-security: max-age=63072000; includeSubDomains`, `x-content-type-options: nosniff`, `x-frame-options` (`DENY` sur `-n8n` et `-db`, `SAMEORIGIN` sur `-app`), `referrer-policy`, `permissions-policy` ; **aucune** ligne `server:` ni `x-powered-by:` ; sur `-db`, `access-control-allow-origin: https://<prefix>-app.<domain>` (pas `*`). Derriere Cloudflare Access (5.2), la reponse est une redirection `302` : les en-tetes du site ne sont visibles qu'apres authentification, tester alors en local avec `-H "Host: ..."` sur `http://127.0.0.1:18080/`, comme le fait `selftest-install.sh --up`.

Un vhost ajoute par le site dans `~/infra/config/caddy/sites.d/<nom>.caddy` recoit les memes en-tetes en important les snippets du kit (fichier en tabulations, format `caddy fmt`) :

```caddy
http://<nom>.<domain> {
	import maintenance
	import securite
	header >X-Frame-Options "DENY"
	reverse_proxy <service>:<port>
}
```

Puis `docker compose exec caddy caddy validate --config /etc/caddy/Caddyfile` (attendu : `Valid configuration` ; l'avertissement `No files matching import glob pattern` disparait des qu'un fichier `.caddy` existe) et `docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile`. Ajouter le nom a l'ingress du tunnel (`SPARK_TUNNEL_EXTRA_HOSTS`, etape 4.4) et au DNS (4.5).

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

### Creer un identifiant n8n et rendre son dechiffrement obligatoire

Une cle API n'est **pas** un identifiant (*credential*) n8n. Creer dans n8n un premier identifiant, meme de test : Credentials > Add credential > *Header Auth*, nom `spark-restore-test`, n'importe quelle valeur. C'est ce que le test de restauration dechiffre chaque nuit sur la copie pour prouver que la cle sauvegardee est la bonne.

Puis rendre l'absence d'identifiant fatale pour le test de restauration :

```bash
sed -i 's/^RESTORE_TEST_REQUIRE_CREDENTIAL=.*/RESTORE_TEST_REQUIRE_CREDENTIAL=1/' ~/infra/.env
grep -c '^RESTORE_TEST_REQUIRE_CREDENTIAL=1$' ~/infra/.env   # attendu : 1
```

> Si ce shell a charge le `.env` avec `set -a; . ./.env` (ce que le guide evite : les sondes le font en sous-shell), la variable exportee `RESTORE_TEST_REQUIRE_CREDENTIAL=0` l'emporterait sur le fichier et le test ci-dessous resterait un avertissement : dans ce cas, `exit` puis `sudo -iu spark` avant de continuer (encart de l'etape 3.b).

Relancer, puis rejouer sauvegarde et test de restauration : le controle de dechiffrement doit afficher `identifiants n8n : 1 exporte(s), 1 dechiffre(s)` (au moins), plus d'avertissement :

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
systemctl is-active spark-backup.timer spark-restore-test.timer

echo "=== Containers ==="
sudo -u spark docker compose -f /opt/spark/infra/compose.yml ps \
  --format "table {{.Name}}\t{{.Status}}"

echo "=== Tunnel (connecteur) ==="
curl -s -m 5 http://127.0.0.1:2000/ready; echo

echo "=== Caddy → services (lu sous spark : .env est en 600) ==="
sudo -u spark bash -c '
  /opt/spark/infra/scripts/check-env.sh SPARK_PREFIX SPARK_DOMAIN >/dev/null || { echo "  FAIL .env non charge (SPARK_PREFIX/SPARK_DOMAIN absents ou vides)"; exit 1; }
  set -a; . /opt/spark/infra/.env; set +a
  probe() {
    body=$(curl -s -m 10 -H "Host: ${SPARK_PREFIX}-$1.${SPARK_DOMAIN}" \
      "http://127.0.0.1:${SPARK_HOST_HTTP_PORT:-18080}$2" 2>/dev/null || true)
    case "$body" in
      *"$3"*) printf "  %-6s OK\n" "-$1" ;;
      *) printf "  %-6s FAIL (%s : corps « %.60s »)\n" "-$1" "$2" "$body"; return 1 ;;
    esac
  }
  probe n8n /healthz/readiness "\"status\":\"ok\""
  probe db  /api/v1/health "\"message\":\"OK\""
  echo "=== Tunnel HTTPS ==="
  curl -sI -m 10 "https://${SPARK_PREFIX}-n8n.${SPARK_DOMAIN}" | head -1
'
```

Attendu, bloc par bloc :

- `=== Services systemd ===` : `active` puis `compose: OK` ; puis la ligne des timers, qui affiche **`active` deux fois** (une par timer, `systemctl is-active` ecrit un etat par unit, il n'ecrit jamais `OK`) ;
- `=== Containers ===` : 5 conteneurs `Up` (`spark-cloudflared-1` compris), les quatre autres `(healthy)` au bout de 2 minutes au plus ;
- `=== Tunnel (connecteur) ===` : `{"status":200,"readyConnections":4,...}` (`readyConnections` > 0) ;
- `=== Caddy → services ===` : `-n8n   OK` et `-db    OK` ;
- `=== Tunnel HTTPS ===` : une ligne de statut, `HTTP/2 200` ou `HTTP/2 302` (Cloudflare Access).

Tout autre texte (`FAIL`, `inactive`, `failed`, `Restarting`, `Exited`, `unhealthy`, une sonde `FAIL`) designe le service a verifier. Le bloc Caddy tourne sous `spark` parce que `.env` est en `600` : lance par l'administrateur, `. /opt/spark/infra/.env` echouerait en silence, les variables resteraient vides et la sonde interrogerait `Host: -n8n.` — d'ou le garde-fou `check-env.sh SPARK_PREFIX SPARK_DOMAIN` (valeur resolue, sans guillemets ni espaces). Si un service manque, verifier :

```bash
sudo systemctl status spark-compose.service
sudo -u spark docker compose -f /opt/spark/infra/compose.yml logs --since 5m cloudflared n8n
```

> **Avant l'etape 4** (test de reboot fait sur une stack sans tunnel, par exemple sur un serveur de recette) : 4 conteneurs seulement (pas de `cloudflared`, le profil n'est pas actif), **rien** sous `=== Tunnel (connecteur) ===` (connexion refusee sur le port 2000, `curl` n'ecrit rien) ni sous `=== Tunnel HTTPS ===` (le domaine ne pointe nulle part) : **normal**. Tout le reste (`active` et `compose: OK`, les deux timers `active`, 4 conteneurs `Up (healthy)`, sondes `-n8n` et `-db` `OK`) doit etre la. Site en **variante hote** (unit `spark-cloudflared.service`) : ajouter `systemctl is-active spark-cloudflared.service` au premier bloc, attendu `active`, et aucun `spark-cloudflared-1` sous `=== Containers ===` (un seul connecteur, encart de l'etape 4.6). Si l'unit est `inactive` apres le reboot, `journalctl -b -u spark-cloudflared.service` dit pourquoi : la garde a trouve le profil `tunnel` dans le `.env` ou un conteneur `spark-cloudflared-1` (meme arrete) et a laisse le conteneur etre le connecteur ; c'est le comportement attendu quand les deux sont installes (test de la garde au reboot, encart de 4.6).

---

## Mettre a jour la stack depuis le kit

Le kit evolue ; le site ne bouge que volontairement. Procedure :

```bash
sudo -iu spark
```

```bash
cd ~/spark-kit && git pull --ff-only
diff -u ~/infra/compose.yml ~/spark-kit/deploy/compose.yml
diff -u ~/infra/compose.runners.yml ~/spark-kit/deploy/compose.runners.yml
diff -u ~/infra/env.example ~/spark-kit/deploy/env.example
diff -ru ~/infra/config ~/spark-kit/deploy/config
diff -ru ~/infra/scripts ~/spark-kit/deploy/scripts
~/infra/scripts/pin-digests.sh --check ~/infra/compose.yml
```

Lire le diff : les seules differences attendues sont celles que le site a faites lui-meme (fichiers `sites.d/`, drapeau `MAINTENANCE`) ; les scripts ne se modifient pas sur le site, `diff -ru ~/infra/scripts ~/spark-kit/deploy/scripts` doit etre vide apres recopie (`cp ~/spark-kit/deploy/scripts/*.sh ~/infra/scripts/ && chmod +x ~/infra/scripts/*.sh`). Un `.env` qui n'a pas une variable nouvelle d'`env.example` se complete par `~/infra/scripts/init-env.sh --sync ~/infra/.env` (ajoute les lignes manquantes a la fin, valeurs du gabarit, secrets nouveaux generes, n'y touche pas sinon), puis `check-env.sh`. **Un changement de tag d'image est une montee de version** : ne pas faire `cp` du compose et `up -d` a la volee, suivre la fiche correspondante d'[`UPGRADES.md`](UPGRADES.md) (test de restauration date, releve avant, drapeau de maintenance, sauvegarde, bascule du compose entier, verification, et retour arriere ecrit avant de commencer). Jamais de `pull` sans l'avoir decide. Les units systemd se recopient de la meme facon (`sudo cp .../deploy/linux/systemd/spark-*.{service,timer} /etc/systemd/system/ && sudo systemctl daemon-reload`). Appliquer un changement de `compose.yml` ou du `.env` : `sudo systemctl reload spark-compose.service` (ou `cd ~/infra && docker compose up -d` dans le shell `spark`) — pas `start`, qui ne fait rien sur une unit active, jamais `restart`, qui coupe le site (etape 3).

> **Site installe avec le kit precedent** (n8n `2.19.4`, Caddyfile sans snippets, en-tetes poses a la main a l'ancienne etape 5.3, `NC_CORS_ALLOWED_ORIGINS` ajoute au compose a l'ancienne 5.4, cloudflared en unit systemd) : la montee est la fiche **n8n 2.19.4 → 2.49.6** d'[`UPGRADES.md`](UPGRADES.md), qui commence par la fiche Caddy (nouveau Caddyfile : les en-tetes et le CORS du site deviennent redondants, le fichier du kit les remplace tel quel, `caddy validate` puis `reload`), puis la bascule du compose entier (le bloc `NC_CORS_ALLOWED_ORIGINS` disparait avec lui, Caddy porte le CORS). Le tunnel reste sur l'hote tant que la fiche « cloudflared hote → conteneur » n'a pas ete jouee.

> **Site installe avec une version encore anterieure du guide** (fichiers recopies a la main en heredoc) : l'arborescence etait `~/infra/docker-compose.yml`, `~/infra/config/Caddyfile` (fichier monte seul) et des images en tags flottants ; il n'y avait ni `env.example` ni `sites.d/`, et `scripts/` existait mais etait vide. Faire d'abord cette transition **a versions egales** (le compose du kit precedent, n8n `2.19.4`, est dans l'historique git du kit : `git -C ~/spark-kit log --oneline -- deploy/compose.yml`), puis la fiche n8n d'`UPGRADES.md` : jamais deux changements dans la meme fenetre. Transition, stack en marche, dans le shell `spark` et depuis `~/infra`, apres une sauvegarde manuelle (`docker compose exec -T postgres pg_dumpall -U postgres | gzip > ~/pg_dumpall-avant-transition.sql.gz`) :
> 1. `mkdir -p ~/infra/scripts` (absent ou vide selon l'age du site), puis les copies de l'etape 2.2 (`compose.yml`, `env.example`, `config/caddy/`, `scripts/*.sh` sont des chemins nouveaux ; seul `config/postgres/init-db.sh` est remplace par la version du kit, sans effet : il ne rejoue jamais sur un volume existant) ;
> 2. reporter dans `~/infra/config/caddy/Caddyfile` ce que le site avait ajoute a l'ancien `config/Caddyfile` (en-tetes 5.3, CORS). Valider le **nouveau** fichier avant qu'il soit monte (le conteneur en service ne voit encore que l'ancien `config/Caddyfile` : un `docker compose exec caddy caddy validate` validerait l'ancien), avec l'image Caddy que le nouveau compose fige et les variables du `.env` lues en sous-shell :
>    ```bash
>    (  set -a && . ./.env && set +a
>       docker run --rm -v "$HOME/infra/config/caddy:/etc/caddy:ro" -e SPARK_PREFIX -e SPARK_DOMAIN \
>         "$(docker compose -f compose.yml config --images | grep '^caddy:')" \
>         caddy validate --config /etc/caddy/Caddyfile )
>    ```
>    attendu : `Valid configuration` ; puis reporter dans `compose.yml` les ajouts du site a `docker-compose.yml` (le CORS NocoDB n'en fait plus partie : le Caddyfile du kit le porte) ;
> 3. lire `diff -u docker-compose.yml compose.yml` : seuls les digests, les mineures figees des tags flottants (`postgres:16-alpine` → `16.16-alpine`, `caddy:2-alpine` → `2.11.9-alpine`), le montage du repertoire `./config/caddy` et les commentaires doivent differer (voir `CHANGELOG.md`) ; un autre ecart est une anomalie a comprendre avant d'aller plus loin. Les volumes nommes sont les memes (`spark_postgres_data`, ...), le projet reste `spark` : aucune donnee ne bouge ;
> 4. `docker compose -f compose.yml up -d` (Compose recree les conteneurs dont la definition a change, les volumes sont conserves), sondes de l'etape 3, puis ranger **tout de suite** les anciens fichiers hors de `infra/` : `mv docker-compose.yml ~/docker-compose.yml.avant-transition && mv config/Caddyfile ~/Caddyfile.avant-transition` (le Caddyfile en service est desormais `config/caddy/Caddyfile`). Tant que `docker-compose.yml` et `compose.yml` coexistent, tout `docker compose` lance sans `-f` (le votre, et celui de l'**ancienne unit systemd au reboot**) affiche `Found multiple config files with supported names` et prend `compose.yml` : les etapes 1 a 3 utilisent `-f` pour cette raison, et aucun reboot ne doit avoir lieu entre la copie de l'etape 1 et ce rangement ;
> 5. etape 2.3 (`check-env.sh` sur le `.env` existant, qui garde ses secrets ; ajouter a la main les variables nouvelles de `env.example` : `BACKUP_*`, `SPARK_ALERT_WEBHOOK`, `RESTORE_TEST_REQUIRE_CREDENTIAL`) ; etape 3 « Installer le service systemd » : recopier l'unit du kit (`sudo cp`, `daemon-reload`), l'unit deja active reste active et gagne `ExecReload` ; desormais un changement s'applique par `sudo systemctl reload spark-compose.service`, pas `restart` ; puis etape 3.b (sauvegardes).

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

### `systemctl status spark-compose.service` est `failed`, les conteneurs tournent

**Cause** : `systemctl restart` (ou `start`) alors que `~/infra/.env` ou `compose.yml` manque : l'unit refuse de demarrer (`ExecStartPre`) et, au `restart`, saute volontairement le `docker compose down` pour ne pas couper le site (journal : `docker compose down NON execute`).
**Solution** : remettre le fichier manquant (`.env` depuis la derniere archive `secrets-*.tar.age` si besoin), puis `sudo systemctl reset-failed spark-compose.service && sudo systemctl start spark-compose.service` : c'est le **seul** cas ou `start` sert, pour sortir de l'etat `failed`. Sans `reset-failed`, plusieurs `start` rapproches sur une unit encore en `failed` peuvent etre refuses avec `start request repeated too quickly` (`StartLimitBurst`) ; l'unit du kit desactive cette limite (`StartLimitIntervalSec=0`), mais une unit copiee avant cette ligne l'a encore.

### Un changement de `compose.yml` ou du `.env` n'est pas applique

**Cause** : `sudo systemctl start spark-compose.service` sur une unit deja `active (exited)` : systemd ne relance pas un service actif, `docker compose up -d` n'a pas ete rejoue.
**Solution** : `sudo systemctl reload spark-compose.service` (rejoue `up -d --remove-orphans`, avec le garde-fou `.env`/`compose.yml`), ou dans le shell `spark` : `cd ~/infra && docker compose up -d`. Verifier : `docker compose ps` (le service modifie a ete recree, `Up` depuis quelques secondes). Jamais `restart` (etape 3). Une unit copiee avant l'ajout de `ExecReload` repond `Job type reload is not applicable` : recopier l'unit du kit (section « Mettre a jour la stack »).

### n8n affiche "secure cookie" error

**Cause** : `X-Forwarded-Proto https` n'est pas propage.
**Solution** : verifier que le Caddyfile contient `header_up X-Forwarded-Proto https` dans chaque bloc `reverse_proxy`.

### n8n repond 503 `Database is not ready` (ou `/healthz/readiness` rouge) apres un incident Postgres

**Cause** : Postgres a ete arrete, tue (OOM) ou redemarre ; n8n ne retablit **jamais** son pool de connexions tout seul (vecu chez une PME).
**Solution** : `cd ~/infra && docker compose restart n8n` une fois Postgres `healthy`. Si Postgres a ete tue par le noyau (`dmesg | grep -i oom`), relire les plafonds memoire du `.env` (`*_MEM_LIMIT`, `N8N_HEAP_MB`).

### n8n met longtemps a repondre apres une mise a jour

**Cause** : migrations de base au premier demarrage de la nouvelle version (`docker compose logs n8n` : `Migrations in progress, please do NOT stop the process`). De l'ordre d'une minute, plus sur une grosse base.
**Solution** : **attendre**, ne pas redemarrer (le healthcheck du kit accorde 2 minutes de grace). Un redemarrage pendant une migration est le pire des cas : la montee se fait avec la fiche d'[`UPGRADES.md`](UPGRADES.md), drapeau de maintenance pose.

### Tout repond 503 `Maintenance en cours`

**Cause** : le drapeau `~/infra/config/caddy/MAINTENANCE` existe (pose pour une intervention, oublie ensuite). Seul `/healthz/readiness` reste servi.
**Solution** : `rm ~/infra/config/caddy/MAINTENANCE && cd ~/infra && docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile`, et `rm /opt/spark/MAINTENANCE` si les timers doivent reprendre.

### `spark-cloudflared-1` est `Restarting`, ou le tunnel ne monte pas

**Symptome** : `docker compose logs cloudflared` montre `Tunnel credentials file '/etc/cloudflared/<UUID>.json' doesn't exist or is not a file`, `permission denied`, ou `yaml: unmarshal errors`.
**Causes** : `SPARK_TUNNEL_DIR` ne pointe pas sur le repertoire de `cloudflared tunnel create` ; `SPARK_TUNNEL_ID` ne correspond pas au `.json` present ; `SPARK_UID`/`SPARK_GID` ne sont pas ceux du proprietaire du repertoire (fichiers en `600`) ; `config.yml` edite a la main.
**Solution** : `~/infra/scripts/tunnel-config.sh --check` (il nomme ce qui manque), corriger le `.env`, relancer `tunnel-config.sh`, puis `docker compose up -d`. Un journal `open /etc/cloudflared/config.yml: no such file or directory` = profil pose avant `tunnel-config.sh` (etape 4.4) : generer la config, `up -d`. Sans compte Cloudflare ni tunnel cree (serveur de recette), laisser `COMPOSE_PROFILES` vide : en premiere installation le conteneur n'est pas cree et le reste de la stack n'en depend pas ; mais si le conteneur a deja ete cree une fois, vider le profil ne le retire pas (il survit au `reload` et au reboot) : `docker compose --profile tunnel stop cloudflared && docker compose --profile tunnel rm -f cloudflared` (encart de l'etape 4.6).

### Deux connecteurs cloudflared tournent (conteneur et unit hote)

**Symptome** : `systemctl is-active spark-cloudflared.service` affiche `active` **et** `docker compose --profile tunnel ps cloudflared` montre une ligne `Up` ; les journaux des deux montrent des connexions qui se font et se defont.
**Cause** : variante hote activee sans avoir retire le conteneur du profil `tunnel`, ou profil remis sans arreter l'unit. L'unit du kit **reste inactive** si le profil `tunnel` est dans le `.env` ou si un conteneur `spark-cloudflared-1` existe, meme arrete (garde `ExecCondition`, `scripts/cloudflared-host-guard.sh`, cause dans `journalctl -u spark-cloudflared.service`) ; le compose, lui, ne verifie rien : poser le profil pendant que l'unit tourne cree bien le second connecteur. Une unit installee avec un kit precedent (garde `ExecStartPre` sur `docker ps`) laissait aussi passer le cas du reboot : recopier l'unit du kit (`sudo cp ... && sudo systemctl daemon-reload`).
**Solution** : choisir, puis retirer l'autre : conteneur → `sudo systemctl disable --now spark-cloudflared.service` ; hote → `docker compose --profile tunnel stop cloudflared && docker compose --profile tunnel rm -f cloudflared` et `COMPOSE_PROFILES=` dans le `.env`, puis `sudo systemctl start spark-cloudflared.service` (la garde ne reessaie pas d'elle-meme).

### UFW semble ne pas bloquer Docker

**Cause** : Docker manipule iptables directement. Les conteneurs qui publient des ports sur `0.0.0.0` contournent UFW.
**Impact** : nul ici — Caddy publie sur `127.0.0.1` uniquement, et le trafic externe passe par le tunnel Cloudflare (connexion sortante).

### Verifier le kit lui-meme

Sur une machine avec Docker, `~/spark-kit/deploy/scripts/selftest-install.sh --up` rejoue les copies de l'etape 2 dans un repertoire temporaire, valide le compose et le Caddyfile, passe les scripts a `shellcheck` (installe a l'etape 1.4 ; sans lui, une ligne `INFO  shellcheck absent : non joue` et une ligne `OK` de moins), demarre la stack sous un projet separe (`spark-selftest`, port 18090) et la detruit. Attendu : `== Resultat : 0 echec(s)` et code 0 ; une ligne `FAIL` nomme ce qui ne va pas. Utile avant d'appliquer une mise a jour du kit a un site.

---

**La stack tourne, le tunnel est ouvert, les sauvegardes sont planifiees et testees, les cles API sont en place.** Suite : configurer Claude Code → [CLAUDE-CODE.md](CLAUDE-CODE.md).

Les **jobs planifies metier** du site (controles quotidiens, notifications) s'installent ensuite depuis le repo client, sur le modele des units `spark-backup` / `spark-restore-test` du kit (`ExecCondition` sur le drapeau `MAINTENANCE`).
