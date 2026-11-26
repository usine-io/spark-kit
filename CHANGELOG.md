# Changelog du kit

Une entree par lot de mise a jour. Les versions d'images sont celles de `deploy/compose.yml` (tag + digest).

## Lot 1 — Source unique de l'infra + sauvegardes

**Ajoute**

- `deploy/compose.yml` : la stack (Postgres, n8n, NocoDB, Caddy) en un seul fichier pour macOS et Linux. Images figees par tag **et** digest : `postgres:16.16-alpine`, `n8nio/n8n:2.19.4`, `nocodb/nocodb:2026.04.5`, `caddy:2.11.9-alpine`. Les tags flottants des guides (`postgres:16-alpine`, `caddy:2-alpine`, `nocodb:latest` cote macOS) sont figes sur la version que le tag servait le jour du lot.
- `deploy/config/caddy/Caddyfile` + `sites.d/` (vhosts additionnels du site, repertoire monte en entier), `deploy/config/postgres/init-db.sh`, `deploy/env.example` (remplace `deploy/linux/env.example`).
- `deploy/scripts/` : `init-env.sh` (`.env` depuis le gabarit, secrets URL-safe), `pin-digests.sh` (releve ou controle des digests, dans le compose et dans les scripts ; refuse une image sans tag ou en `:latest`), `backup.sh` (pre-requis de chiffrement verifies avant toute ecriture, dump controle, tars des volumes hors Postgres, `.env` + config n8n chiffres avec `age` ou `gpg`, fichiers produits en `.part` et renommes en fin de succes), `restore-test.sh` (restauration dans un Postgres jetable de la meme image, comptes, identifiants n8n comptes en SQL puis dechiffres ; base sans identifiant = avertissement et succes, ou echec avec `RESTORE_TEST_REQUIRE_CREDENTIAL=1`), `selftest-install.sh` (rejoue les copies des guides, `compose config`, `caddy validate`, `up`, sondes par marqueur dans le corps ; refuse de tourner depuis la copie `infra/scripts/`), `mcp-n8n.sh` (wrapper du MCP n8n, image `ghcr.io/czlonkowski/n8n-mcp:2.104.0` figee par tag + digest, auparavant un heredoc en `:latest` dans `CLAUDE-CODE.md`), `lib.sh`.
- `deploy/linux/systemd/` : `spark-backup.{service,timer}` (6 h), `spark-restore-test.{service,timer}` (quotidien), tous deux sautes si `/opt/spark/MAINTENANCE` existe ; `spark-compose.service` refuse de demarrer sans `.env` ni `compose.yml` et nomme le fichier manquant dans le journal.
- `deploy/env.example` : `RESTORE_TEST_REQUIRE_CREDENTIAL` (0 a l'installation, 1 en production une fois un identifiant n8n cree).
- Guides : etape « Sauvegardes et test de restauration » (Linux), section « Mettre a jour la stack depuis le kit », depannage « un volume monte est un repertoire vide ». README : deux parcours (Mac bac a sable / Linux production), une seule stack.
- Guides : les sondes HTTP lisent un marqueur dans le corps (`/healthz` de n8n, `/api/v1/health` de NocoDB) et non le seul code `200`, car Caddy repond `200` et corps vide a tout `Host` inconnu ; la limite est ecrite dans les guides en attendant l'attrape-tout `404`. La verification `docker compose config` est bloquante (une variable manquante fait echouer la commande au lieu d'afficher `OK`). Le bloc de controle apres reboot (Linux) lit `.env` sous `spark` et echoue si `SPARK_PREFIX`/`SPARK_DOMAIN` sont vides. Etape 6 (Linux) : creation d'un identifiant n8n de test puis `RESTORE_TEST_REQUIRE_CREDENTIAL=1`.

**Change**

- Les guides **copient** `deploy/` dans `infra/` au lieu de recopier compose, Caddyfile, `init-db.sh` et `.env` en heredoc ; le fichier s'appelle `compose.yml`.
- `docker compose` (plugin v2 ou superieur) est la syntaxe de reference partout ; sur macOS, `cliPluginsExtraDirs` dans `~/.docker/config.json`, avec repli `docker-compose` documente.
- Colima : 4 Go minimum (les plafonds memoire du compose l'exigent).
- Correction du chemin des units systemd (`spark-kit/deploy/linux/systemd/`, pas `templates/`) et de la mention « plugin v2 » (Compose v5.x servi par le depot Docker). `CLAUDE-CODE.md` vaut pour les deux parcours (`$SPARK_ROOT` = `~/spark` sur Mac, `/opt/spark` sur Linux) et ne recopie plus `mcp-n8n.sh` : il vient de `deploy/scripts/`. Guide Linux 1.3 : nom de version lu dans `/etc/os-release` (plus de `lsb_release`, absent d'une Debian minimale).
- `SECURITY.md` et `ROADMAP.md` : `tunnel-up.sh` / `tunnel-down.sh` sont marques « prevus » (absents du kit) ; la procedure en vigueur est `cloudflared tunnel route dns` (etape 4 des guides).
- `deploy/config/caddy/Caddyfile` au format `caddy fmt` (tabulations) : plus d'avertissement « Caddyfile input is not formatted ».
- `CLAUDE.md` : exceptions tolerees au « jamais de heredoc » (plists launchd, `config-spark.yml` de cloudflared, `.mcp.json`), a resorber quand cloudflared passera dans le compose.
- HSTS sans `preload` (`SECURITY.md`, guide Linux).
- `.gitignore` : `backups/`, `*.sql.gz`, `.mcp.json`, `MAINTENANCE`.

**Diff attendu entre l'ancien compose Linux et `deploy/compose.yml`** : digests sur chaque image, `postgres:16-alpine` → `16.16-alpine`, `caddy:2-alpine` → `2.11.9-alpine`, montage du repertoire `./config/caddy` (au lieu du seul fichier `Caddyfile`), commentaires. Cote macOS s'ajoutent `nocodb:latest` → `2026.04.5` et les `mem_limit` (1 Go n8n, 900 Mo NocoDB). Tout autre ecart est une anomalie.

**Non inclus (lots suivants)** : montee de version n8n/Caddy/cloudflared et cloudflared en conteneur (les plists launchd et `config-spark.yml` passeront alors dans `deploy/`), `healthcheck:` compose sur n8n, NocoDB et Caddy, snippets Caddy (`securite`, `maintenance`, attrape-tout 404 : d'ici la, un `Host` inconnu recoit `200` et un corps vide), sortie de NocoDB, PostgreSQL 18, watchdog et `healthcheck.sh`, `OPERATIONS.md`, `UPGRADES.md`, `DATA.md`.
