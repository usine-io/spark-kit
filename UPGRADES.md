# Montees de version — procedure generale et fiches

> Une montee de version n'est **jamais** un simple changement de tag dans `compose.yml`. Chaque composant a sa fiche : ce qu'on releve avant, comment on bascule, comment on verifie, et **comment on revient en arriere** — ecrit et teste avant de commencer. Les mesures citees viennent du banc du kit (VM de test Debian 12, 4 vCPU / 8 Go, base n8n synthetique : 2 workflows actifs, 1 identifiant, quelques executions) ; un site les refait sur une **copie complete** de sa base avant la production.

Conventions : les commandes se lancent en tant qu'utilisateur `spark`, depuis `~/infra` (`$SPARK_HOME/infra` : `/opt/spark/infra` sur Linux, `~/spark/infra` sur macOS) ; `~/spark-kit` designe le clone du kit (`~/spark/spark-kit` sur macOS). Chaque bloc commence par `hostname` et dit ce qu'il doit afficher : **on s'arrete au premier ecart**.

---

## 1. Procedure generale

| Etape | Quoi | Outil du kit |
|---|---|---|
| 0 | **Pre-requis** : test de restauration vert et date de moins de 24 h ; kit a jour ; `CHANGELOG.md` du lot lu ; fenetre convenue avec les utilisateurs | `cat ~/infra/backups/RESTORE_TEST_OK`, `git -C ~/spark-kit pull --ff-only` |
| 1 | **Scripts et config Caddy** du nouveau kit d'abord (ils ne migrent rien) : `cp` des scripts, `cp -R deploy/config`, `caddy validate` avec l'image du **nouveau** compose, `caddy reload` | fiche Caddy (§4) |
| 2 | **Releve avant**, stack en service (latences comprises) | `scripts/n8n-releve.sh --out backups/releve-avant.txt` |
| 3 | **Pause** : drapeau des jobs planifies (`/opt/spark/MAINTENANCE` sur Linux) + drapeau Caddy (`config/caddy/MAINTENANCE`, 503 partout sauf `/healthz/readiness`) + `caddy reload` ; puis **sauvegarde**, dans le meme bloc ; copie du `compose.yml` en service | `scripts/backup.sh`, `cp compose.yml backups/compose-avant.yml` |
| 4 | **Bascule** : compose **entier** du nouveau lot (jamais le seul `image:`), `.env` complete, `config -q`, `check-env.sh`, `pin-digests.sh --check`, `up -d` (ou `systemctl reload spark-compose.service`), attente de la readiness **sans redemarrer** | `scripts/init-env.sh --sync .env` |
| 5 | **Verification** : releve apres et comparaison, journaux sans depreciation non traitee, rejeu E2E (smoke test du site), retrait des drapeaux | `scripts/n8n-releve.sh --compare` |
| 6 | **Retour arriere** si un critere echoue : fiche du composant. Pour n8n : base et volume restaures depuis le jeu de l'etape 3, compose de l'etape 3 remis | `scripts/restore-n8n.sh <stamp> --confirm --expect-migrations N` |

Regles :
- **Une montee a la fois.** Jamais n8n et un changement de schema metier dans la meme fenetre ; jamais deux composants dans la meme fenetre (n8n puis, une autre fois, Postgres).
- **Le releve « avant » vit dans le meme bloc que la sauvegarde** ; `n8n-releve.sh --compare` refuse de conclure sans lui.
- **Le drapeau de maintenance reste pose jusqu'a la verification complete** : une ecriture faite dans n8n entre la sauvegarde et un retour arriere est perdue.
- Les latences se mesurent **avant la pause** (en maintenance, tout repond 503). Un site remplace les trois endpoints temoins par defaut par les siens : `SPARK_RELEVE_ENDPOINTS="stock=app:/webhook/api/stock?limit=10 ..."` dans le `.env` (GET en 2xx, `nom=service:chemin`).
- Criteres de la comparaison : migrations `apres >= avant` (`==` au retour arriere), IDs de workflows actifs identiques un par un, chaque latence `apres <= 2 x avant + 50 ms`.
- Images figees par tag **et** digest : une fiche commence par un `CHANGELOG.md` qui dit quel tag change, et `pin-digests.sh --check` doit etre vert avant `up -d`.

---

## 2. Fiche n8n — 2.19.4 → 2.49.6 (et toute montee 2.x → 2.x)

### Ce que le banc du kit a mesure

| Mesure | Valeur (banc du kit, base synthetique) |
|---|---|
| Node.js embarque | `v24.x` (2.19.4) → **`v26.13.0`** (2.49.6) : ligne majeure differente, a relire dans les notes de version des nodes communautaires du site s'il y en a |
| Migrations de base | **201**, a sens unique (`SELECT count(*) FROM migrations` : 168 → 369), de `AddJweKeyIndexesToDeploymentKey...` a `AddMigrationReportScopeToCustomInstanceRoles...` |
| Readiness (`/healthz/readiness` via Caddy) | 13 s sur le banc (base synthetique) ; compter de l'ordre d'une minute et plus sur une base chargee (`execution_data`) : `start_period` du healthcheck = 120 s, **ne pas redemarrer pendant** |
| Memoire n8n (cgroup) | **pic 690-810 Mio** (`memory.peak`) pendant les migrations, sur trois bancs (690, 756 et 806 Mio, soit jusqu'a **79 % de `N8N_MEM_LIMIT=1g`** avec une base de quelques executions) ; ≈ 400-650 Mio au repos ensuite (2.19.4 : ≈ 340 Mio sur la meme base, soit **+80 a +300 Mio**). Un site reel passe `N8N_MEM_LIMIT=1536m` et `N8N_HEAP_MB=1024` **le temps de la montee** : la marge de 1g est trop faible des que `execution_data` pese |
| Workflows actifs | memes IDs avant et apres ; rejeu E2E (webhook → chainage → lecture) vert |
| Journal au demarrage | trois lignes **attendues et acceptees** : `N8N_RUNNERS_MODE -> Internal task runner mode is deprecated` (le kit garde le runner interne par defaut, le mode externe est le profil `runners`, §2.7) ; `(node:7) DeprecationWarning: Calling client.query() when the client is already executing a query is deprecated and will be removed in pg@9.0` (pilote `pg` embarque, sans action) ; `Failed to start Python task runner in internal mode ... Python 3 is missing` (l'image n8n n'embarque pas Python : le node Code en Python n'existe **qu'avec le sidecar**, profil `runners`, qui l'embarque ; en mode interne seul le JavaScript est disponible). Toute autre ligne `deprecation` est a traiter avant de retirer les drapeaux |
| Variables changees par le kit | `WEBHOOK_URL` → `N8N_WEBHOOK_URL` (l'ancienne declenche un avertissement de depreciation) ; `N8N_USER_MANAGEMENT_DISABLED` retiree (n'existe plus) ; `N8N_RUNNERS_TASK_TIMEOUT=300` fige (le defaut passera a 60 s) ; limites du node Compression figees aux futures valeurs ; `N8N_UNVERIFIED_PACKAGES_ENABLED=false` |
| Retour arriere | execute une fois sur le banc : base `n8n` recreee depuis le dump (section n8n seule), volume restaure, `count(*) FROM migrations` revenu a 168, 2.19.4 pret, E2E vert |

### `N8N_PROXY_HOPS` : la mesure et la valeur retenue

n8n applique `trust proxy = N8N_PROXY_HOPS` (Express) pour trouver l'IP du client dans `X-Forwarded-For` : elle sert au limiteur de connexions (`/rest/login`), a la liste blanche d'IP des webhooks et aux journaux. Mesure du kit **derriere Caddy seul**, avec un webhook dont la liste blanche d'IP ne contient que `203.0.113.9` (l'option compare l'IP que n8n retient ; `200` = n8n a retenu `203.0.113.9`, `403` = une autre), requetes envoyees sur `127.0.0.1:18080` avec `Host` et un `X-Forwarded-For` forge :

| `N8N_PROXY_HOPS` | sans en-tete | `XFF: 203.0.113.9` | `XFF: 203.0.113.9, 198.51.100.7` |
|---|---|---|---|
| 1 | 403 | 403 | 403 (IP retenue = client TCP de Caddy) |
| **2** | 403 | **200** | 403 (IP retenue = dernier element de l'en-tete) |
| 3 | 403 | 200 | 200 (un saut de plus) |

Trois constats :
1. **Sans `trusted_proxies` dans Caddy, rien de tout cela n'existe** : Caddy 2.11 remplace l'en-tete `X-Forwarded-For` d'un client qu'il ne connait pas par l'IP TCP de ce client (premiere mesure du banc : 403 partout, quel que soit `N8N_PROXY_HOPS`). Le Caddyfile du kit declare donc `servers { trusted_proxies static private_ranges }` : cloudflared (conteneur du reseau compose, ou `127.0.0.1` en variante hote) est de confiance, Caddy conserve l'en-tete ecrit par Cloudflare et y ajoute le saut de cloudflared. Les seuls clients de Caddy sont cloudflared et les sondes locales ; un client sur une plage privee peut forger l'en-tete, c'est accepte et c'est pourquoi Caddy reste lie a `127.0.0.1`.
2. Avec `trusted_proxies`, le compte est celui attendu : `1` = l'IP TCP du client de Caddy (cloudflared : tous les visiteurs partagent la meme IP, le limiteur de connexions se declenche pour tout le monde, vecu), `2` = l'IP ecrite par le proxy precedent, c'est-a-dire **le visiteur tel que Cloudflare l'ecrit**.
3. Le journal d'acces Caddy (`/var/log/caddy/access.log`) montre `request.remote_ip` (IP TCP du client de Caddy) et `request.client_ip` (l'IP que Caddy retient). **Sans `trusted_proxies_strict`, `client_ip` est l'element le plus a gauche de `X-Forwarded-For`, donc forgeable** : premiere mesure du banc, `XFF: 203.0.113.9, 198.51.100.7` donnait `client_ip=203.0.113.9` alors que n8n (`2`) retenait `198.51.100.7` — un journal qui contredit n8n ne prouve rien. Le Caddyfile du kit pose donc aussi **`trusted_proxies_strict`** : `client_ip` devient l'IP la plus a **droite** qui n'est pas un proxy de confiance, c'est-a-dire la meme que n8n retient avec `2` (mesure rejouee, meme en-tete : `client_ip=198.51.100.7`, n8n 403 pour `203.0.113.9` : d'accord). Le journal Caddy et n8n lisent alors l'en-tete de la meme facon et peuvent se confirmer l'un l'autre.

**Valeur du kit : `N8N_PROXY_HOPS=2`** (variable du `.env`, defaut 2 dans le compose), pour le chemin Cloudflare → cloudflared → Caddy → n8n. Non mesure avec un tunnel reel (le banc n'a pas de compte Cloudflare) : **a confirmer sur le premier site**, avec une methode qui ne depend pas d'un en-tete forgeable :

1. depuis un poste **hors du reseau du serveur**, noter son IP publique (`curl -s https://icanhazip.com` ou l'equivalent de l'entreprise) ;
2. dans n8n, un webhook de test durable dont la liste blanche d'IP ne contient que cette IP ; l'appeler **sans** en-tete `X-Forwarded-For` ajoute (`curl -s -o /dev/null -w '%{http_code}\n' https://<prefix>-app.<domain>/webhook/<test>`) : `200` = n8n retient l'IP du poste (valeur `2` correcte), `403` = il retient autre chose (relire `trusted_proxies` et la valeur) ;
3. le meme appel vu par Caddy : `docker compose exec caddy sh -c 'tail -n 50 /var/log/caddy/access.log' | jq -c 'select(.request.uri|test("<test>")) | {client_ip: .request.client_ip, remote_ip: .request.remote_ip, xff: .request.headers["X-Forwarded-For"], cf: .request.headers["Cf-Connecting-Ip"]}'` : `client_ip` et `Cf-Connecting-Ip` (ecrit par Cloudflare, non forgeable par le visiteur) doivent tous deux etre l'IP du poste, `remote_ip` celle de cloudflared.

`Cf-Connecting-Ip` est la reference : si `client_ip` ou la decision de n8n s'en ecartent, la valeur de `N8N_PROXY_HOPS` ou la liste des proxies de confiance est fausse, quel que soit ce que dit `X-Forwarded-For`.

### 2.1 Pre-requis

```bash
hostname
cd ~/infra
cat backups/RESTORE_TEST_OK                                    # < 24 h, sinon : scripts/backup.sh && scripts/restore-test.sh
cd ~/spark-kit && git pull --ff-only && git log -1 --format='%h %s' && cd ~/infra
grep -n 'image: n8nio/n8n' ~/spark-kit/deploy/compose.yml      # le tag cible, avec son digest
docker run --rm --entrypoint node "$(sed -n 's/^[[:space:]]*image:[[:space:]]*\(n8nio\/n8n:[^[:space:]]*\).*/\1/p' ~/spark-kit/deploy/compose.yml)" -v
```

Attendu : un horodatage recent, le commit du lot, la ligne `image: n8nio/n8n:2.49.6@sha256:...`, `v26.13.0`. Noter la version de Node dans le runbook : un changement de ligne majeure (24 → 26) est une raison de rejouer le smoke test du site avec attention sur les nodes Code.

### 2.2 Scripts et Caddy du nouveau kit (fiche Caddy, §4)

```bash
hostname
cd ~/infra
cp ~/spark-kit/deploy/scripts/*.sh scripts/ && chmod +x scripts/*.sh
cp -R ~/spark-kit/deploy/config ./ && chmod +x config/postgres/init-db.sh
(  set -a && . ./.env && set +a
   docker run --rm -v "$PWD/config/caddy:/etc/caddy:ro" -e SPARK_PREFIX -e SPARK_DOMAIN \
     "$(sed -n 's/^[[:space:]]*image:[[:space:]]*\(caddy:[^[:space:]]*\).*/\1/p' ~/spark-kit/deploy/compose.yml)" \
     caddy validate --config /etc/caddy/Caddyfile )
docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile
( set -a && . ./.env && set +a; curl -s -o /dev/null -w 'Host inconnu -> %{http_code}\n' -H "Host: inconnu.$SPARK_DOMAIN" "http://127.0.0.1:${SPARK_HOST_HTTP_PORT:-18080}/" )
```

Attendu : `Valid configuration` (l'avertissement `No files matching import glob pattern` est normal tant que `sites.d/` est vide), puis `Host inconnu -> 404`. Site venu du kit precedent : le nouveau Caddyfile **remplace** celui du site, en-tetes 5.3 et CORS compris (ils sont dans le kit) ; les fichiers `sites.d/` du site restent et doivent importer `maintenance` et `securite`.

### 2.3 Releve avant, pause, sauvegarde (un seul bloc)

```bash
hostname
cd ~/infra
scripts/n8n-releve.sh --out backups/releve-avant.txt
touch /opt/spark/MAINTENANCE config/caddy/MAINTENANCE          # macOS : seulement config/caddy/MAINTENANCE
docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile
( set -a && . ./.env && set +a; U="http://127.0.0.1:${SPARK_HOST_HTTP_PORT:-18080}"
  printf 'maintenance : -n8n %s, -app webhook %s, readiness %s (attendu 503 503 200)\n' \
    "$(curl -s -o /dev/null -w '%{http_code}' -H "Host: $SPARK_PREFIX-n8n.$SPARK_DOMAIN" "$U/rest/settings")" \
    "$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Host: $SPARK_PREFIX-app.$SPARK_DOMAIN" "$U/webhook/x")" \
    "$(curl -s -o /dev/null -w '%{http_code}' -H "Host: $SPARK_PREFIX-n8n.$SPARK_DOMAIN" "$U/healthz/readiness")" )
cp compose.yml backups/compose-avant.yml
scripts/backup.sh
ls -1t backups/pg_dumpall-*.sql.gz | head -1
```

Attendu : le releve (lignes `migrations=`, `workflows_active=`, `latence_*_ms=` **toutes numeriques** ; un `?` = endpoint hors service, corriger avant d'aller plus loin), `503 503 200`, `sauvegarde <stamp> complete`, puis le nom du dump : **noter `<stamp>`** (`AAAAMMJJ-HHMMSS`), c'est le jeu du retour arriere. `compose-avant.yml` est le compose exact qu'il faudra remettre.

### 2.4 Bascule

```bash
hostname
cd ~/infra
cp ~/spark-kit/deploy/compose.yml compose.yml
cp ~/spark-kit/deploy/compose.runners.yml compose.runners.yml
cp ~/spark-kit/deploy/env.example env.example
scripts/init-env.sh --sync .env
out=$(docker compose config -q 2>&1); [ -z "$out" ] && echo "compose: OK" || { echo "$out"; false; }
scripts/check-env.sh
scripts/pin-digests.sh --check compose.yml
docker compose up -d                       # Linux, en exploitation : sudo systemctl reload spark-compose.service
( set -a && . ./.env && set +a; U="http://127.0.0.1:${SPARK_HOST_HTTP_PORT:-18080}"; t0=$(date +%s)
  for i in $(seq 1 150); do
    case "$(curl -s -m 5 -H "Host: $SPARK_PREFIX-n8n.$SPARK_DOMAIN" "$U/healthz/readiness")" in *'"status":"ok"'*) echo "readiness OK apres $(( $(date +%s) - t0 )) s"; break ;; esac
    sleep 2
  done )
docker compose logs n8n 2>&1 | grep -ciE 'finished migration'
docker compose logs n8n 2>&1 | grep -iE 'deprecat|python' | grep -v 'Starting migration' | cut -c1-200
for i in $(seq 1 60); do   # attente de sante : les QUATRE services healthy avant tout releve ou rejeu
  hs="$(docker compose ps --format '{{.Service}}={{.Health}}' postgres n8n nocodb caddy | sort | tr '\n' ' ')"
  case "$hs" in *unhealthy*) echo "$hs"; break ;; esac
  [ "$(printf '%s\n' $hs | grep -c '=healthy$')" -eq 4 ] && { echo "healthy : $hs"; break; }
  sleep 5
done
```

Attendu : `.env complete : ...` (ou `deja a jour`), `compose: OK`, onze `OK` de `check-env.sh` (les dix variables et `COMPOSE_PROFILES coherent`), `OK : digests ... conformes`, `readiness OK apres N s` (N < 300 ; sinon **ne pas redemarrer**, lire `docker compose logs -f n8n` : `Migrations in progress, please do NOT stop the process`), le nombre de migrations jouees (201 pour 2.19.4 → 2.49.6), comme seules lignes `deprecat`/`python` les trois listees plus haut (`N8N_RUNNERS_MODE`, `pg@9.0`, `Python 3 is missing`), puis `healthy : caddy=healthy n8n=healthy nocodb=healthy postgres=healthy` (jusqu'a 5 minutes : `start_period` de n8n 120 s, Caddy 150 s). **Le `up -d` recree les quatre conteneurs**, Postgres compris (`mem_limit`, `shm_size`, `logging`, healthcheck sont nouveaux dans sa definition) : la base redemarre, n8n attend qu'elle soit `healthy` (`depends_on`) avant de migrer, NocoDB et Caddy sont recrees aussi (healthcheck, volume `caddy_logs`). Quelques dizaines de secondes d'indisponibilite, couvertes par la maintenance ; **ne rien relever ni rejouer avant la ligne `healthy`** : NocoDB `Up 2 seconds` repond encore 502 et un smoke test joue trop tot echoue pour rien (vecu sur le banc).

Mode runner externe (profil `runners`) : **pas dans la meme fenetre**. Il se bance ensuite, stack a jour (§2.7).

### 2.5 Verification et fin de maintenance

```bash
hostname
cd ~/infra
rm -f config/caddy/MAINTENANCE /opt/spark/MAINTENANCE
docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile
scripts/n8n-releve.sh --out backups/releve-apres.txt
scripts/n8n-releve.sh --compare backups/releve-avant.txt backups/releve-apres.txt
docker compose ps --format 'table {{.Name}}\t{{.Image}}\t{{.Status}}'
```

Attendu : `COMPARAISON OK` (migrations `168 -> 369`, memes workflows actifs, latences sous le seuil), quatre services `Up (healthy)` (n8n peut afficher `health: starting` jusqu'a 2 minutes). Puis le **rejeu E2E du site** (smoke test, un webhook de production en lecture) ; une `ReferenceError` dans un node Code ne se voit qu'a l'execution reelle. Noter dans le runbook : date, `<stamp>`, nombre de migrations, readiness, pic memoire (`docker compose exec n8n cat /sys/fs/cgroup/memory.peak`).

Si un critere echoue et ne s'explique pas en quelques minutes : retour arriere (§2.6), **drapeaux remis d'abord**.

### 2.6 Retour arriere (execute une fois sur le banc du kit)

Jamais un simple changement de tag : 2.19.4 demarre sans rien dire sur une base migree par 2.49.6 (et `N8N_DISABLED_MODULES` avec un module inconnu de l'ancienne version la ferait s'arreter). Le retour arriere restaure **la base n8n et le volume `n8n_data`** depuis le jeu `<stamp>` de l'etape 2.3, avec le compose de l'epoque.

```bash
hostname
cd ~/infra
touch /opt/spark/MAINTENANCE config/caddy/MAINTENANCE && docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile
cp backups/compose-avant.yml compose.yml
grep -o 'n8nio/n8n:[^@]*' compose.yml                          # attendu : l'ancien tag (2.19.4)
scripts/restore-n8n.sh <stamp>                                  # plan seulement, rien n'est fait
scripts/restore-n8n.sh <stamp> --confirm --expect-migrations $(sed -n 's/^migrations=//p' backups/releve-avant.txt)
docker compose up -d                                            # postgres, caddy et nocodb recrees sur l'ancienne definition
( set -a && . ./.env && set +a; U="http://127.0.0.1:${SPARK_HOST_HTTP_PORT:-18080}"   # attente de sante avant tout releve
  for i in $(seq 1 90); do
    a="$(curl -s -m 5 -H "Host: $SPARK_PREFIX-n8n.$SPARK_DOMAIN" "$U/healthz/readiness")"; b="$(curl -s -m 5 -H "Host: $SPARK_PREFIX-db.$SPARK_DOMAIN" "$U/api/v1/health")"
    case "$a:$b" in *'"status":"ok"'*:*'"message":"OK"'*) echo "n8n et nocodb prets"; break ;; esac; sleep 2
  done )
rm -f config/caddy/MAINTENANCE /opt/spark/MAINTENANCE && docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile
scripts/n8n-releve.sh --out backups/releve-retour.txt
scripts/n8n-releve.sh --compare backups/releve-avant.txt backups/releve-retour.txt --rollback
```

Ce que fait `restore-n8n.sh` : `docker compose stop n8n`, extraction de la **seule section `n8n`** du `pg_dumpall` (rejouer le dump entier sur un cluster vivant dupliquerait les lignes des autres bases), `DROP DATABASE n8n WITH (FORCE)` + `CREATE DATABASE n8n OWNER n8n`, rejeu avec `ON_ERROR_STOP=1` (zero erreur toleree), volume `n8n_data` vide puis restaure du tar (cle de chiffrement et donnees binaires), `docker compose up -d n8n` avec le compose **en place**, attente de la readiness, controle du nombre de migrations. Attendu : `n8n pret (2.19.4), 168 migrations`, `restauration n8n du jeu <stamp> terminee`, puis `n8n et nocodb prets` (le `up -d` qui suit recree Postgres, NocoDB et Caddy sur l'ancienne definition : la base redemarre, NocoDB met quelques secondes a repondre, **ne pas relever ni rejouer avant**), et `COMPARAISON OK` (`migrations : 168 = 168 (retour arriere complet)`). Le controle `--expect-migrations` est la garde : si le compose en place est encore le nouveau, n8n remigre la base restauree et le script sort `369 migrations apres restauration, 168 attendues (le compose.yml en place n'est pas celui du lot vise ?)`, code 2, avec une alerte qui dit que n8n est **pret mais a remigre** (la base restauree est de nouveau au nouveau schema) — remettre le bon compose et rejouer la restauration depuis le meme jeu. L'alerte nomme toujours la phase atteinte (rien de modifie / n8n arrete, base a verifier / n8n relance, readiness a verifier / remigre).

Puis le rejeu E2E du site sur l'ancienne version, et le runbook : ce qui a echoue, pour la prochaine tentative. Les executions et modifications faites entre la sauvegarde et le retour arriere sont perdues : c'est pour cela que la maintenance restait posee.

### 2.7 Option : runner externe (profil `runners`), banc avant adoption

Le sidecar `n8nio/runners` (meme tag que n8n, toujours) execute les nodes Code hors du processus n8n : memoire decouplee, et c'est le mode que n8n 3.x imposera. Le kit le livre en option parce qu'il ajoute un service et un jeton, et parce que le gain se mesure. Banc, stack a jour et hors fenetre de montee :

```bash
hostname
cd ~/infra
scripts/n8n-releve.sh --out backups/releve-interne.txt
docker compose -f compose.yml -f compose.runners.yml --profile runners up -d
sleep 30
docker compose --profile runners ps --format 'table {{.Name}}\t{{.Status}}'
docker compose --profile runners logs runners 2>&1 | tail -5
docker stats --no-stream --format 'table {{.Name}}\t{{.MemUsage}}' | grep -E 'n8n|runners'
```

Attendu : `spark-runners-1` `Up` (pas `Restarting`), un journal du sidecar qui se connecte au broker (`http://n8n:5679`), puis un **node Code execute avec succes** (smoke test du site, ou un workflow de test durable — jamais un workflow jetable cree puis supprime, qui empoisonne le module insights), `scripts/n8n-releve.sh --out backups/releve-externe.txt` et `--compare backups/releve-interne.txt backups/releve-externe.txt` sans ecart de latence. Banc du kit (deux bancs) : le sidecar demarre et s'enregistre, le smoke test (deux nodes Code) passe en mode externe, memoire n8n au repos inchangee (≈ 450 Mio), sidecar **7-12 Mio au repos** et ≈ 90 Mio juste apres l'execution de nodes Code (les runners JS et Python sont lances a la demande). C'est aussi le seul mode ou le node Code en **Python** existe (l'image n8n n'embarque pas Python, le sidecar si).

Adoption : dans `.env`, `COMPOSE_PROFILES=tunnel,runners` **et** `COMPOSE_FILE=compose.yml:compose.runners.yml` (decommenter la ligne `#COMPOSE_FILE=...` : `init-env.sh --sync` l'ajoute, commentee, a un `.env` du kit precedent qui ne l'a pas ; `check-env.sh` **echoue** si le profil est pose sans cette ligne, ou la ligne sans le profil), puis `check-env.sh`, puis `docker compose up -d` (ou `systemctl reload spark-compose.service`) : l'unit systemd, `backup.sh` et `restore-test.sh` lisent les deux fichiers. Le profil `runners` **sans** `COMPOSE_FILE` demarre un sidecar que n8n, reste en mode interne, n'utilise jamais ; `COMPOSE_FILE` **sans** le profil met n8n en mode externe sans sidecar et les nodes Code echouent. Retour : retirer les deux lignes, `docker compose -f compose.yml -f compose.runners.yml --profile runners stop runners && docker compose -f compose.yml -f compose.runners.yml --profile runners rm -f runners` (retirer un profil du `.env` ne retire pas un conteneur deja cree), `docker compose up -d` (n8n revient en mode interne). Rotation de `N8N_RUNNERS_AUTH_TOKEN` : nouvelle valeur dans `.env`, `up -d` (les deux services la relisent).

### 2.8 Preparer n8n 3.x (plus tard, fiche a ecrire quand la stable sera publiee)

A sens unique, Docker obligatoire, runner externe impose (§2.7 d'abord), `~/.n8n/binaryData` → `~/.n8n/storage`, nodes legacy retires. Lire le rapport de migration de n8n (Settings → Migration Report) sur la 2.49 avant toute chose ; sauvegarde complete ; meme procedure que ci-dessus, retour arriere = restauration uniquement.

---

## 3. Fiche PostgreSQL

**Mineure** (16.x → 16.y, meme majeure) : changement de tag dans le compose du kit, `pin-digests.sh`, procedure generale (releve, pause, sauvegarde, `up -d`, readiness de n8n, comparaison, retrait des drapeaux). Les mineures ne changent pas le format des donnees ; le retour arriere est le compose precedent (le cluster reste lisible par la mineure precedente de la meme majeure).

**Majeure** (16 → la prochaine version majeure de PostgreSQL, voir `ROADMAP.md`) : fiche a part, livree avec cette montee dans le kit (dump avec le client de la version cible, volume neuf, garde contre un cluster 16 monte sur une image plus recente). Ne pas tenter avant.

---

## 4. Fiche Caddy

Caddy ne porte pas de donnees : une montee = nouveau tag + nouveau Caddyfile du kit, validee avant d'etre servie.

```bash
hostname
cd ~/infra
cp -R ~/spark-kit/deploy/config ./
(  set -a && . ./.env && set +a
   docker run --rm -v "$PWD/config/caddy:/etc/caddy:ro" -e SPARK_PREFIX -e SPARK_DOMAIN \
     "$(sed -n 's/^[[:space:]]*image:[[:space:]]*\(caddy:[^[:space:]]*\).*/\1/p' ~/spark-kit/deploy/compose.yml)" \
     caddy validate --config /etc/caddy/Caddyfile )
```

Attendu : `Valid configuration`. **Toujours valider avec l'image de la version cible** : la serie 2.11 est plus stricte que les precedentes (en-tetes de requete limites a 16 Kio, en-tetes contenant `.` ou `_` ignores, hote invalide → 400, `request_body max_size` → 413, conflit `client_auth` = erreur de Caddyfile). Un fichier `sites.d/` du site qui passait avant peut echouer ici : le corriger avant le reload.

- Caddyfile seul (meme tag) : `docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile`. Le repertoire est monte : l'edition **en place** est vue par le conteneur ; un `mv` sur le repertoire lui-meme ne l'est pas.
- Nouveau tag : `cp ~/spark-kit/deploy/compose.yml compose.yml` puis `docker compose up -d caddy` (quelques secondes d'indisponibilite : le faire en meme temps qu'une fiche n8n, sous maintenance, ou a une heure creuse).
- Verification : sondes de l'etape 3 du guide (`/healthz/readiness` avec marqueur, Host inconnu → 404), en-tetes sur chaque vhost (`SECURITY.md` §2.2), `docker compose exec caddy test -s /var/log/caddy/access.log`.
- Retour arriere : ancien Caddyfile (`git -C ~/spark-kit show <commit precedent>:deploy/config/caddy/Caddyfile > config/caddy/Caddyfile`) et, pour un tag, `backups/compose-avant.yml` ; `validate` puis `reload` / `up -d caddy`.

---

## 5. Fiche cloudflared — hote → conteneur (profil `tunnel`)

Site installe avec cloudflared sur l'hote (unit `spark-cloudflared.service` sur Linux, LaunchAgent sur macOS, config `config-spark.yml` ecrite a la main). Le kit fait tourner le connecteur dans le compose : `cloudflare/cloudflared:2026.11.2` fige par tag et digest, sans auto-mise a jour (`--no-autoupdate`), non root, identifiants montes en lecture seule, ingress vers `http://caddy:80` sur le reseau de la stack. Sans compte Cloudflare, rien de cette fiche ne s'exerce ; le banc du kit a verifie la config generee (`cloudflared tunnel ingress validate` par `docker compose run --rm --no-deps cloudflared ...`), l'image (version `2026.11.2`, digest, utilisateur `65532`, `docker compose run --rm --no-deps cloudflared --version`), et le comportement sans tunnel valide : fichier d'identifiants absent → le processus sort avec `Tunnel credentials file ... doesn't exist or is not a file` ; fichier present mais invalide → le conteneur reste `Up` et retente en boucle (`ERR Register tunnel error from server side`). Dans les deux cas, rien n'est expose et le reste de la stack ne depend pas de lui (n8n, Caddy, Postgres restent `healthy`). Sans profil `tunnel`, il n'est pas cree.

1. **`.env`** : `SPARK_TUNNEL_ID=<UUID>` (deja la), `SPARK_TUNNEL_DIR=/opt/spark/.cloudflared` (macOS : `/Users/<compte>/.cloudflared`, chemin absolu), `SPARK_UID`/`SPARK_GID` (poses par `init-env.sh --sync` : l'utilisateur proprietaire du repertoire), `COMPOSE_PROFILES=tunnel`. Les fichiers `<UUID>.json` et `cert.pem` restent ou `cloudflared tunnel create` les a mis.
2. **Config conteneur** : `scripts/tunnel-config.sh` ecrit `<SPARK_TUNNEL_DIR>/config.yml` (`service: http://caddy:80`, `credentials-file: /etc/cloudflared/<UUID>.json`, memes hostnames que `config-spark.yml` ; les hostnames supplementaires du site passent par `SPARK_TUNNEL_EXTRA_HOSTS`). Valider : `docker compose run --rm --no-deps cloudflared tunnel --config /etc/cloudflared/config.yml ingress validate` → `OK`.
3. **Bascule** (quelques secondes de coupure) : `sudo systemctl disable --now spark-cloudflared.service` (macOS : `launchctl unload ~/Library/LaunchAgents/com.spark.cloudflared.plist`), puis `docker compose up -d`, puis `curl -s http://127.0.0.1:2000/ready` → `{"status":200,"readyConnections":4,...}` et `curl -sI https://<prefix>-app.<domain>/healthz/readiness | head -1` → `HTTP/2 200` (ou `302` derriere Access).
4. **Retour arriere** : `COMPOSE_PROFILES=` dans `.env`, **puis le retrait explicite du conteneur** : `docker compose --profile tunnel stop cloudflared && docker compose --profile tunnel rm -f cloudflared` (vider le profil ne retire pas un conteneur deja cree : il survivrait au `reload` et au reboot, `restart: always`, et retenterait le tunnel a cote du connecteur hote), puis `sudo systemctl enable --now spark-cloudflared.service` (ou `launchctl load ...`). L'unit hote **refuse de demarrer** tant que le conteneur `spark-cloudflared-1` tourne (`ExecStartPre`, cause dans `journalctl -u spark-cloudflared.service`). `config-spark.yml` n'a pas bouge (regenerable par `tunnel-config.sh --host`).
5. Verifier qu'**un seul** connecteur tourne, dans les deux sens de bascule : `systemctl is-active spark-cloudflared.service cloudflared.service` (attendu `inactive` deux fois en conteneur ; `active` pour `spark-cloudflared` seulement en variante hote) et `docker compose --profile tunnel ps cloudflared --format '{{.Name}} {{.Status}}'` (une ligne `Up` en conteneur, rien en variante hote). Noter la version du connecteur dans le runbook : c'est desormais celle du compose.

Montee de version de cloudflared ensuite : tag + digest dans le compose du kit (`CHANGELOG.md`), `docker compose up -d cloudflared`, `/ready` en moins d'une minute ; retour = compose precedent. Le binaire apt/brew de l'hote ne sert plus qu'aux commandes d'administration et n'a pas besoin d'etre a la meme version.
