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

### 1.4 — Installer les outils

```bash
sudo apt-get install -y jq curl git tmux python3 age
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
| `scripts/check-env.sh` | Verifie, par nom et sans afficher de valeur, que les variables obligatoires du `.env` sont renseignees (etapes 2.3 et 7) ; ne regarde que le fichier, jamais l'environnement du shell |
| `scripts/backup.sh`, `scripts/restore-test.sh` | Sauvegarde et test de restauration (etape 3.b), un seul exemplaire de chacun a la fois (verrou) |
| `scripts/pin-digests.sh` | Releve ou controle les digests des images (compose et `mcp-n8n.sh`) |
| `scripts/mcp-n8n.sh` | Lance le serveur MCP n8n a la demande pour Claude Code (image figee par tag + digest), voir [CLAUDE-CODE.md](CLAUDE-CODE.md) |
| `scripts/lib.sh` | Fonctions communes (sourcees par les autres scripts) |
| `scripts/selftest-install.sh` | Verifie le kit : se lance **depuis le kit** (`~/spark-kit/deploy/scripts/selftest-install.sh`), la copie dans `~/infra/scripts/` s'arrete avec un message qui renvoie au kit |

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
out=$(docker compose config -q 2>&1); [ -z "$out" ] && echo "compose: OK" || { echo "$out"; false; }
~/infra/scripts/check-env.sh
```

`compose: OK` ne s'affiche que si `docker compose config` n'a **rien** ecrit : un avertissement `variable is not set` (code de retour 0 pourtant) est affiche a la place et la commande echoue. Compose ne dit rien d'une variable **presente mais vide** (`NOM=`) : `check-env.sh` verifie une a une celles qui doivent avoir une valeur (`SPARK_PREFIX`, `SPARK_DOMAIN` et les 5 secrets) et affiche `OK   NOM` ou `FAIL NOM absent ou vide`, jamais la valeur. Il juge la valeur telle que le shell la **resout**, debarrassee des guillemets et des espaces : `NOM=`, `NOM=''`, `NOM="  "` ou une ligne absente sont vides ; une valeur d'un seul caractere est renseignee. Code de retour 1 s'il y a au moins un `FAIL` (toutes les variables sont affichees, il ne s'arrete pas au premier). Il **ne regarde que le fichier** (charge dans un environnement vide) : une variable exportee dans le shell ne compense pas une ligne absente.

> **Le `.env` est source comme du shell** (`. .env`) par les scripts du kit, et par `docker compose` avec des regles proches. Toute valeur ajoutee a la main qui contient `$`, un accent grave ou une espace doit etre entre **guillemets simples** : `SPARK_ALERT_WEBHOOK='https://acme.example/hook?token=a$b'`. Les secrets generes par `init-env.sh` (`A-Za-z0-9`) n'en ont pas besoin.

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
- Le repertoire `config/caddy/` est monte en entier : on peut remplacer le Caddyfile ou poser un fichier dans `sites.d/` puis `caddy reload`, sans redemarrer le conteneur. Tant que `sites.d/` ne contient aucun fichier `.caddy` (c'est le cas apres l'installation : seul `.keep` s'y trouve), Caddy ecrit a chaque demarrage, a chaque `validate` et a chaque `reload` un avertissement `No files matching import glob pattern` avec le motif `/etc/caddy/sites.d/*.caddy` : **attendu, sans gravite**, il disparait au premier vhost pose. Au demarrage, `docker compose logs caddy` montre aussi `HTTP/2 skipped because it requires TLS` et `HTTP/3 skipped because it requires TLS` : attendus eux aussi, Caddy ne sert que du HTTP en interne, le TLS est chez Cloudflare

---

## Etape 3 — Lancer la stack

Toujours en tant qu'utilisateur `spark` :

```bash
cd ~/infra
docker compose up -d
```

Attendre ~30 secondes, puis verifier. La sonde lit un **marqueur dans le corps** de la reponse (`/healthz` de n8n, `/api/v1/health` de NocoDB) : Caddy repond `200` avec un corps vide a tout `Host` qu'il ne connait pas, un code `200` seul ne prouverait donc pas le routage.

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
  probe n8n /healthz '"status":"ok"'
  probe db  /api/v1/health '"message":"OK"'
)
docker compose ps --format "table {{.Name}}\t{{.Image}}\t{{.Status}}"
```

Les services tournent et repondent via Caddy sur `127.0.0.1:18080`, mais ne sont pas encore accessibles depuis l'exterieur. La colonne `IMAGE` affiche chaque image telle que le `compose.yml` la fige, **tag suivi du digest** (`postgres:16.16-alpine@sha256:...`, `n8nio/n8n:2.19.4@sha256:...`, `nocodb/nocodb:2026.04.5@sha256:...`, `caddy:2.11.9-alpine@sha256:...`), et `postgres` doit etre `healthy`.

> **Limite connue.** Un `Host` inconnu (`curl -H "Host: nimporte.quoi" http://127.0.0.1:18080/`) recoit aujourd'hui `200` et un corps vide, pas un `404` : d'ou les sondes par marqueur. L'attrape-tout `404` du Caddyfile vient avec un lot suivant du kit.

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
- `backup.sh` ecrit un **jeu** a un meme horodatage `<stamp>` : `pg_dumpall-<stamp>.sql.gz`, un `vol-<volume>-<stamp>.tgz` par volume hors Postgres (`n8n_data`, `nocodb_data`, `caddy_data`, `caddy_config`), `secrets-<stamp>.tar.age`, et termine par `sauvegarde ... complete`. La retention (`BACKUP_KEEP_DAYS`, 14 jours) supprime les jeux entiers, jamais un fichier isole.
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

Les etapes 5.1 et 5.2 se font depuis le compte **administrateur** (vous l'etes apres le `exit` de la fin de l'etape 4.7 ; sinon, `exit` d'abord), 5.3 et 5.4 en tant que `spark`.

### 5.1 — Mises a jour automatiques

```bash
sudo apt-get install -y unattended-upgrades
sudo dpkg-reconfigure -plow unattended-upgrades
```

### 5.2 — Cloudflare Access

Configurer une application Access devant les 3 sous-domaines pour empecher l'acces anonyme. Sans elle, les pages de login n8n/NocoDB sont publiques.

Documentation detaillee : [`templates/docs/cf-access.md`](https://github.com/spark-kit/templates/blob/main/docs/cf-access.md).

### 5.3 — Headers de securite Caddy

Repasser en `spark` pour editer les fichiers du site :

```bash
sudo -iu spark
```

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

Le bloc est indente en **tabulations**, comme le reste du Caddyfile du kit (format `caddy fmt`). Valider **avant** de recharger, puis recharger Caddy (le repertoire est monte : l'edition en place est vue par le conteneur) :

```bash
cd ~/infra
docker compose exec caddy caddy validate --config /etc/caddy/Caddyfile
docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile
```

Le `validate` ecrit quelques lignes JSON de niveau `info` et se termine par `Valid configuration` ; c'est cette derniere ligne qui compte. Deux lignes de niveau `warn` sont **attendues et sans gravite** :

- `No files matching import glob pattern` avec `"pattern":"/etc/caddy/sites.d/*.caddy"` : `sites.d/` ne contient encore aucun fichier `.caddy` (seul `.keep`), l'`import` du Caddyfile ne trouve rien. Elle apparait aussi a chaque `caddy reload` et dans `docker compose logs caddy` a chaque demarrage, et disparait au premier vhost pose dans `sites.d/` ;
- `Caddyfile input is not formatted` : seulement si le bloc a ete colle en espaces au lieu de tabulations ; il fonctionne quand meme (`caddy fmt --overwrite` le remet au format).

Toute autre ligne `warn` ou `error`, ou l'absence de `Valid configuration`, est une erreur a corriger avant le `reload`.

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
systemctl is-active spark-cloudflared.service && echo "cloudflared: OK" || echo "cloudflared: FAIL"
systemctl is-active spark-backup.timer spark-restore-test.timer

echo "=== Containers ==="
sudo -u spark docker compose -f /opt/spark/infra/compose.yml ps \
  --format "table {{.Name}}\t{{.Status}}"

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
  probe n8n /healthz "\"status\":\"ok\""
  probe db  /api/v1/health "\"message\":\"OK\""
  echo "=== Tunnel HTTPS ==="
  curl -sI -m 10 "https://${SPARK_PREFIX}-n8n.${SPARK_DOMAIN}" | head -1
'
```

Attendu, bloc par bloc :

- `=== Services systemd ===` : `active` puis `compose: OK` ; `active` puis `cloudflared: OK` ; puis la ligne des timers, qui affiche **`active` deux fois** (une par timer, `systemctl is-active` ecrit un etat par unit, il n'ecrit jamais `OK`) ;
- `=== Containers ===` : 4 conteneurs `Up` (`spark-postgres-1` avec `(healthy)`) ;
- `=== Caddy → services ===` : `-n8n   OK` et `-db    OK` ;
- `=== Tunnel HTTPS ===` : une ligne de statut, `HTTP/2 200` ou `HTTP/2 302` (Cloudflare Access).

Tout autre texte (`FAIL`, `inactive`, `failed`, `Restarting`, `Exited`, une sonde `FAIL`) designe le service a verifier. Le bloc Caddy tourne sous `spark` parce que `.env` est en `600` : lance par l'administrateur, `. /opt/spark/infra/.env` echouerait en silence, les variables resteraient vides et la sonde interrogerait `Host: -n8n.` — d'ou le garde-fou `check-env.sh SPARK_PREFIX SPARK_DOMAIN` (valeur resolue, sans guillemets ni espaces). Si un service manque, verifier :

```bash
sudo systemctl status spark-compose.service
sudo journalctl -u spark-cloudflared.service --since "5 min ago"
```

> **Avant l'etape 4** (test de reboot fait sur une stack sans tunnel, par exemple sur un serveur de recette) : `inactive` puis `cloudflared: FAIL`, et **rien** sous `=== Tunnel HTTPS ===` (la ligne reste vide : `curl` n'obtient aucune reponse, le domaine ne pointe nulle part) sont **normaux**, le service `spark-cloudflared` n'existe pas encore. Tout le reste (`active` et `compose: OK`, les deux timers `active`, 4 conteneurs `Up`, sondes `-n8n` et `-db` `OK`) doit etre la.

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
diff -ru ~/infra/scripts ~/spark-kit/deploy/scripts
~/infra/scripts/pin-digests.sh --check ~/infra/compose.yml
```

Lire le diff : les seules differences attendues sont celles que le site a faites lui-meme (en-tetes 5.3, CORS 5.4, fichiers `sites.d/`) ; les scripts ne se modifient pas sur le site, `diff -ru ~/infra/scripts ~/spark-kit/deploy/scripts` doit etre vide apres recopie (`cp ~/spark-kit/deploy/scripts/*.sh ~/infra/scripts/ && chmod +x ~/infra/scripts/*.sh`). Un changement de tag d'image est une **montee de version** : sauvegarde + test de restauration reussis et dates d'abord, puis `cp` du fichier concerne, `docker compose up -d`, verification. Jamais de `pull` sans l'avoir decide. Les units systemd se recopient de la meme facon (`sudo cp .../deploy/linux/systemd/spark-*.{service,timer} /etc/systemd/system/ && sudo systemctl daemon-reload`). Appliquer un changement de `compose.yml` ou du `.env` : `sudo systemctl reload spark-compose.service` (ou `cd ~/infra && docker compose up -d` dans le shell `spark`) — pas `start`, qui ne fait rien sur une unit active, jamais `restart`, qui coupe le site (etape 3).

> **Site installe avec une version anterieure du guide** (fichiers recopies a la main en heredoc) : l'arborescence etait `~/infra/docker-compose.yml`, `~/infra/config/Caddyfile` (fichier monte seul) et des images en tags flottants ; il n'y avait ni `env.example` ni `sites.d/`, et `scripts/` existait mais etait vide. Transition, stack en marche, dans le shell `spark` et depuis `~/infra`, apres une sauvegarde manuelle (`docker compose exec -T postgres pg_dumpall -U postgres | gzip > ~/pg_dumpall-avant-transition.sql.gz`) :
> 1. `mkdir -p ~/infra/scripts` (absent ou vide selon l'age du site), puis les copies de l'etape 2.2 (`compose.yml`, `env.example`, `config/caddy/`, `scripts/*.sh` sont des chemins nouveaux ; seul `config/postgres/init-db.sh` est remplace par la version du kit, sans effet : il ne rejoue jamais sur un volume existant) ;
> 2. reporter dans `~/infra/config/caddy/Caddyfile` ce que le site avait ajoute a l'ancien `config/Caddyfile` (en-tetes 5.3, CORS). Valider le **nouveau** fichier avant qu'il soit monte (le conteneur en service ne voit encore que l'ancien `config/Caddyfile` : un `docker compose exec caddy caddy validate` validerait l'ancien), avec l'image Caddy que le nouveau compose fige et les variables du `.env` lues en sous-shell :
>    ```bash
>    (  set -a && . ./.env && set +a
>       docker run --rm -v "$HOME/infra/config/caddy:/etc/caddy:ro" -e SPARK_PREFIX -e SPARK_DOMAIN \
>         "$(docker compose -f compose.yml config --images | grep '^caddy:')" \
>         caddy validate --config /etc/caddy/Caddyfile )
>    ```
>    attendu : `Valid configuration` ; puis reporter dans `compose.yml` les ajouts du site a `docker-compose.yml` (CORS 5.4) ;
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

### UFW semble ne pas bloquer Docker

**Cause** : Docker manipule iptables directement. Les conteneurs qui publient des ports sur `0.0.0.0` contournent UFW.
**Impact** : nul ici — Caddy publie sur `127.0.0.1` uniquement, et le trafic externe passe par le tunnel Cloudflare (connexion sortante).

### Verifier le kit lui-meme

Sur une machine avec Docker, `~/spark-kit/deploy/scripts/selftest-install.sh --up` rejoue les copies de l'etape 2 dans un repertoire temporaire, valide le compose et le Caddyfile, demarre la stack sous un projet separe (`spark-selftest`, port 18090) et la detruit. Utile avant d'appliquer une mise a jour du kit a un site.

---

**La stack tourne, le tunnel est ouvert, les sauvegardes sont planifiees et testees, les cles API sont en place.** Suite : configurer Claude Code → [CLAUDE-CODE.md](CLAUDE-CODE.md).

Les **jobs planifies metier** du site (controles quotidiens, notifications) s'installent ensuite depuis le repo client, sur le modele des units `spark-backup` / `spark-restore-test` du kit (`ExecCondition` sur le drapeau `MAINTENANCE`).
