# Spark Kit — Archive des incidents

> Chaque fail rencontré sur un déploiement Spark est archivé ici. Les exemples utilisent un nom de site fictif **`acme`** sur le domaine **`acme.example`** pour préserver la confidentialité des sites réels — substituer par le vrai project name côté client (cf. `name:` du `docker-compose.yml`).
> But : éviter qu'un nouveau site rencontre deux fois le même piège, et nourrir la check-list du bootstrap.
>
> Format par incident : symptôme → diagnostic (avec commandes utiles) → cause racine → fix immédiat → fix structurel → leçons exploitables (cases à cocher dans le code).

---

## INC-2026-06-30 — QR code ZPL n'encode qu'une seule lettre (préfixe `^FD` manquant sur `^BQ`)

**Site** : anonymisé (site Spark imprimant des étiquettes QR via une pseudo-API n8n → imprimante ZPL, ici TSC TE310 en émulation ZPL)
**Sévérité** : medium (étiquettes physiques imprimées mais QR illisible/faux → traçabilité cassée en atelier ; pas de panne stack)
**Statut** : 🟢 résolu (préfixe ajouté + vérifié par décodage)

### Symptôme
- Le QR **s'affiche** à taille normale sur l'étiquette, donc on ne soupçonne pas la donnée.
- Au scan, il ne rend qu'**un seul caractère** au lieu du code attendu. Exemple vécu : data voulue `3NEW` → le QR décode `W`.
- Le ZPL généré ressemblait à : `…^FO454,12^BQN,2,4^FD3NEW^FS…` (QR `^BQ` + `^FD<data>` brut).

### Diagnostic
Rendre + **décoder** le ZPL hors imprimante (l'œil ne suffit pas — un renderer tolérant masque le bug) :
```bash
# 1. Rendre le ZPL en PNG via Labelary (12dpmm = 300dpi ; adapter au DPI réel)
ZPL='^XA^PW612^LL156^FO454,12^BQN,2,4^FD3NEW^FS^XZ'
curl -s --data-binary "$ZPL" \
  "https://api.labelary.com/v1/printers/12dpmm/labels/2.04x0.52/0/" -o /tmp/q.png

# 2. DÉCODER le QR (le rendu visuel ne révèle pas le contenu)
curl -s -F "file=@/tmp/q.png" "https://api.qrserver.com/v1/read-qr-code/"
# ^FD3NEW    -> {"data":"W"}      <-- bug reproduit
# ^FDMA,3NEW -> {"data":"3NEW"}   <-- corrigé
```
⚠️ **Piège dans le piège** : Labelary est *tolérant* et affiche un QR d'apparence normale même pour le ZPL cassé. Seul le **décodage** distingue bon/mauvais. Ne jamais valider un QP/code-barre à l'œil.

### Cause racine
La syntaxe QR de ZPL (`^BQ`) impose que le champ `^FD` **commence par 2 caractères de contrôle suivis d'une virgule** : `^FD<niveau_correction><mode>,<data>`.
- `<niveau_correction>` ∈ `L`(~7%) `M`(~15%) `Q`(~25%) `H`(~30%)
- `<mode>` = `A` (automatique, recommandé) ou `M` (manuel)

Sans ce préfixe, le firmware (TSC TE310 / Zebra) **consomme les premiers caractères de la donnée comme codes de contrôle** et n'encode que le reliquat → d'où « une seule lettre ». Le préfixe **n'est pas encodé** dans le QR : `^FDMA,3NEW` → le symbole contient exactement `3NEW`, pas `MA,3NEW`. (C'est aussi pourquoi un QR « correct » paraît plus dense : il porte enfin toute la donnée + la redondance de correction d'erreur, pas de l'info en plus.)

### Fix immédiat
Préfixer le `^FD` de **tout** `^BQ` : `^FD<data>` → `^FDMA,<data>` (Medium + Auto, défaut robuste pour une étiquette manipulée).
```diff
- zpl += `^FO454,12^BQN,2,4^FD${code}^FS`;
+ zpl += `^FO454,12^BQN,2,4^FDMA,${code}^FS`;
```
À répliquer partout où le ZPL est construit : node(s) « Build Response » n8n **et** tout self-test du print-server (les copies divergent vite).

### Fix structurel
- Helper unique de génération QR (`qrField(data, ecc='M', mode='A')`) plutôt que de la concat `^FD` éparpillée → un seul endroit où le préfixe est garanti.
- **Definition-of-done d'une étiquette = scan réussi**, pas « ça s'imprime ». Ajouter une étape décode (Labelary + read-qr) au script E2E du module impression.
- Idem code-barres 1D : `^BC`/`^BE`… ont chacun leurs contraintes de `^FD` (Mod-10/Mod-43, longueur) — un code qui « s'imprime » peut rester invalide au scan.

### Leçons exploitables
- [ ] `^BQ` (QR) : `^FD` **toujours** préfixé `<ECC><mode>,` (ex. `MA,`) — jamais la donnée brute.
- [ ] Le préfixe est du contrôle consommé par l'imprimante, **pas** encodé dans le symbole.
- [ ] Valider un QR/code-barre par **décodage**, jamais à l'œil (les renderers tolérants masquent le bug).
- [ ] Chercher toutes les constructions ZPL avant de clore : `grep -rn '\^BQ\|\^BC\|\^FD' --include='*.js' --include='*.py' --include='*.json'` (fronts, workflows exportés, print-server).

---

## INC-2026-05-30 — Briefing agent `CLAUDE.md` dupliqué dans 2 repos → drift silencieux

**Site** : transverse (gouvernance kit, pas un site précis)
**Sévérité** : low (pas de panne runtime ; dette documentaire qui dégrade le briefing agent au fil du temps)
**Statut** : 🟢 résolu (source de vérité unique actée + repos réconciliés)

### Symptôme
- Un gabarit `CLAUDE.md` quasi identique existait à la fois dans `spark-kit/spark-kit` (235 lignes) et `spark-kit/templates` (247 lignes).
- Les deux avaient **divergé sans que personne ne s'en aperçoive** : `templates` portait la « Règle d'or » (skills à charger + 3 pièges N3/W3/C1 en tête), `spark-kit` portait la section « Sécurité de l'exposition externe » + le lien `SECURITY.md`. **Aucun n'était un sur-ensemble de l'autre.**
- Conséquence : selon le repo copié pour amorcer un nouveau site, l'agent héritait d'un briefing amputé d'une moitié des bonnes pratiques.

### Diagnostic
```bash
# Repérer toutes les copies du gabarit
find ~/projects -iname CLAUDE.md -not -path '*/.git/*'

# Diff des deux génériques amont — révèle les blocs non-recoupés
diff ~/projects/spark-kit/CLAUDE.md ~/projects/spark-templates/CLAUDE.md

# Dater la divergence (quel repo a bougé sans que l'autre suive)
for d in spark-kit spark-templates; do
  git -C ~/projects/$d log -1 --format="%ci %s" -- CLAUDE.md
done
```

### Cause racine
**Un même artefact maintenu dans deux repos diverge toujours** : aucune contrainte ne force la synchro, donc chaque amélioration ponctuelle (sécurité côté kit, règle d'or côté templates) reste locale. Le README de `templates` désignait pourtant déjà le gabarit comme sa responsabilité (« Template du briefing agent à copier dans chaque repo entreprise ») — la copie dans `spark-kit` était une duplication non nécessaire, `spark-kit` étant le repo d'**installation** (boot stack), pas d'usage agent.

### Fix immédiat
Réconcilier puis dédupliquer, en désignant **`spark-kit/templates/CLAUDE.md` comme source de vérité unique** :
1. Porter dans `templates` les blocs que seul `spark-kit` avait (section sécurité, liens requalifiés `spark-kit/SECURITY.md`).
2. Remonter au passage les leçons génériques mûries sur un site live (ici : piège « Endpoints derrière CF Access » — fronts en relatif / scripts host via Caddy local + Host header / bypass `127.0.0.1`), en remplaçant le spécifique par des placeholders `<prefix>`/`<domain>`.
3. Réduire `spark-kit/CLAUDE.md` à un **stub-pointeur** vers templates (le kit garde `SECURITY.md`/`INCIDENTS.md`/`ROADMAP.md`).

### Fix structurel
Modèle de flux à respecter pour tout briefing agent :
```
spark-kit/templates/CLAUDE.md   ← gabarit canonique (UNIQUE)
        │ copié + spécialisé à l'install
        ▼
<site>/CLAUDE.md                ← instance live, découvre les leçons
        │ leçons génériques remontées par PR
        ▲
spark-kit/   ← SECURITY.md / INCIDENTS.md / ROADMAP.md (jamais de copie du gabarit)
```
Les distinctions instance↔gabarit (network `acme_spark` vs `spark_spark`, hostnames `acme-*` vs `<prefix>-*`) sont de la **spécialisation attendue**, pas du drift.

### Leçons exploitables
- [ ] Ne jamais dupliquer un gabarit (`CLAUDE.md`, `.env.example`, Caddyfile type…) dans deux repos : une seule source, les autres pointent.
- [ ] Toute amélioration générique découverte sur un site se remonte dans `templates`, pas seulement dans l'instance.
- [ ] Audit périodique : `find ~/projects -iname CLAUDE.md` + `diff` entre copies amont → toute divergence non triviale = drift à réconcilier.

---

## INC-2026-05-19 — MCP `nocodb-mcp` retourne Forbidden malgré un PAT valide

**Site** : anonymisé (site Spark avec NocoDB 2026.04.5+)
**Sévérité** : medium (MCP NocoDB inutilisable côté agent ; CLI reste disponible)
**Statut** : 🟡 mitigé (fallback CLI sanctionné) — fix structurel à faire (changement de package MCP)

### Symptôme
- Toute requête `mcp__nocodb-mcp__*` (même `list_bases`) retourne :
  ```
  MCP error -32603: NocoDB error: Forbidden - Unauthorized access
  ```
- Le PAT a été régénéré, le wrapper MCP relancé, le hash du token comparé entre `.env` et l'env du container MCP → identique.
- Même token, en curl direct contre `https://<site>-db.<domain>/api/v3/meta/workspaces` → `HTTP 200`.

### Diagnostic
```bash
# 1. Confirmer que le token est valide côté v3 (sans l'afficher)
set -a; source infra/.env; set +a
curl -sS -o /dev/null -w "HTTP %{http_code}\n" \
  -H "xc-token: $NOCODB_API_TOKEN" \
  https://<site>-db.<domain>/api/v3/meta/workspaces
unset NOCODB_API_TOKEN
# → HTTP 200 (PAT OK)

# 2. Confirmer que le container MCP a bien le même token (hash compare)
docker exec <mcp-container> sh -c 'printf "%s" "$NOCODB_API_TOKEN" | sha256sum | cut -c1-16'
# Comparer avec le hash calculé côté .env

# 3. Inspecter le package MCP installé
docker exec <mcp-container> sh -c 'grep -rE "xc-token|/api/v[0-9]+/" /usr/local/lib/node_modules/@*/nocodb-mcp/dist/ | head'
# → si "/api/v1/db/meta/projects" ou "/api/v2/meta/..." → INCOMPATIBLE
```

### Cause racine
Le package NPM `@andrewlwn77/nocodb-mcp@0.2.2` cible les endpoints **v1/v2** de NocoDB :
- `list_bases` → `GET /api/v1/db/meta/projects`
- `create_table`, `add_column`, etc. → `/api/v2/meta/...`

Or NocoDB 2026.04.5+ **rejette les PAT (`nc_pat_...`) sur v1/v2** — uniquement v3 les accepte (cf. mémoire `feedback-nocodb-api-workspace-scoping`). Le package MCP est donc structurellement incompatible avec les NocoDB récents. C'est un piège silencieux parce que l'erreur ressemble à un problème d'auth.

### Fix immédiat
Basculer sur le **CLI `nocodb.sh`** de la skill `nocodb` (`~/.claude/skills/nocodb/scripts/nocodb.sh`) — il cible nativement `/api/v3/...`, lit le token depuis env, ne l'expose jamais en sortie.

```bash
set -a; source infra/.env; set +a
export NOCODB_TOKEN="$NOCODB_API_TOKEN"
export NOCODB_URL="https://<site>-db.<domain>"
bash ~/.claude/skills/nocodb/scripts/nocodb.sh workspace:list
# … toutes les ops table:*, field:*, record:* derrière
unset NOCODB_TOKEN NOCODB_API_TOKEN
```

### Fix structurel
Remplacer le package MCP dans `infra/config/nocodb-mcp/Dockerfile` par :
- Une version plus récente de `@andrewlwn77/nocodb-mcp` qui supporterait v3 (à vérifier dans le registre).
- OU un autre package MCP communautaire compatible v3.
- OU un fork patché. Au minimum, viser : `xc-token` header + endpoints `/api/v3/meta/...` et `/api/v3/data/...`.

Avant de merger, ajouter un test smoke `nc_pat` → `list_bases` dans `validate-*.sh`.

### Leçons exploitables (à porter dans Spark)

- [ ] **Bootstrap** : tester le MCP NocoDB immédiatement après le 1er `docker compose up` avec un appel `list_bases`. Si Forbidden alors que la curl directe sur v3 marche → MCP incompatible, basculer doc agent sur CLI.
- [ ] **Compose template** : épingler une version du package MCP qui est connue compatible v3, pas la dernière en blind.
- [ ] **Doc agent** (`CLAUDE.md`) : règle "ne jamais curl quand un MCP peut le faire" doit avoir une exception explicite "**sauf si le MCP est structurellement cassé** — auquel cas le CLI bundlé dans la skill est le canal sanctionné". Sinon l'agent boucle.
- [ ] **Diag rapide à préserver** : pour vérifier la validité d'un PAT NocoDB sans l'exposer, la commande `curl -sS -o /dev/null -w "HTTP %{http_code}\n" -H "xc-token: $TOK" .../api/v3/meta/workspaces` est le bon premier réflexe.

### Temps réel
- Détection → diagnostic complet : ~40 min (le faux problème "auth qui ne marche pas" a fait perdre du temps avant qu'on grep le source du package)
- Diagnostic → fix immédiat (bascule CLI) : ~5 min
- Fix structurel : non fait (open task)

---

## INC-2026-05-05 — NocoDB crashloop, 502 sur `<site>-db.<domain>`

**Site** : anonymisé (1er site Spark déployé)
**Sévérité** : medium (1 service public KO, autres services OK)
**Statut** : ✅ résolu — mitigé structurellement (`NC_DB_JSON` + alphabet secret URL-safe à enforcer)

### Symptôme
- `https://acme-db.acme.example/` répond `HTTP 502` (Caddy ne joint pas l'upstream)
- `docker-compose ps` : `acme-nocodb-1   Restarting (1) X seconds ago`, en boucle ~60 s
- Trois autres services (n8n, postgres, kuma) : OK

### Diagnostic
```bash
docker logs acme-nocodb-1 --tail 80
# → "error: password authentication failed for user \"nocodb\"" (PG code 28P01)
```

Le rôle existe pourtant côté Postgres :
```bash
docker exec acme-postgres-1 psql -U postgres -tAc \
  "SELECT rolname FROM pg_roles WHERE rolname IN ('nocodb','n8n');"
# → n8n / nocodb (les deux existent)
```

Test direct de l'auth `nocodb` avec le password du `.env` (depuis l'intérieur du container postgres pour ne pas exposer le secret) :
```bash
docker exec acme-postgres-1 bash -c \
  'PGPASSWORD="$NOCODB_DB_PASSWORD" psql -h 127.0.0.1 -U nocodb -d nocodb -tAc "SELECT 1;"'
# → 1   (auth OK avec le password brut !)
```

Donc le password du `.env` est correct côté Postgres, mais NocoDB envoie autre chose. Test du contenu :
```bash
docker exec acme-postgres-1 bash -c 'echo -n "$NOCODB_DB_PASSWORD" | tr -dc "&=+%/?# " | wc -c'
# → 4   (4 caractères URL-spéciaux dans le password)
```

### Cause racine
**Combinaison de deux problèmes** :

1. La conf NocoDB utilisait le format URL `NC_DB="pg://postgres:5432?u=nocodb&p=${NOCODB_DB_PASSWORD}&d=nocodb"` — qui **URL-décode** le password avant de l'envoyer à Postgres.
2. `openssl rand -base64 24` (utilisé pour générer `NOCODB_DB_PASSWORD`) peut produire des caractères URL-spéciaux (`&`, `=`, `+`, `/`, `%`...). Cette fois-ci, 4 d'entre eux étaient présents.

Résultat : Postgres reçoit un password tronqué/déformé après URL-decode → `password authentication failed`. n8n n'était pas affecté parce qu'il prend le password en env var directe (`DB_POSTGRESDB_PASSWORD`), pas via URL.

**Facteur aggravant** : `init-db.sh` ne s'exécute **qu'au tout premier démarrage du volume `postgres_data`** (vide). Si le `.env` est régénéré après coup, le rôle `nocodb` côté Postgres garde son ancien password — drift silencieux.

### Fix immédiat
1. Resynchroniser le password du rôle Postgres avec celui du `.env`, **sans exposer le secret côté host** (utiliser l'env var déjà présente dans le container postgres) :
   ```bash
   docker exec acme-postgres-1 bash -c '
     printf "ALTER USER nocodb WITH ENCRYPTED PASSWORD '\''%s'\'';\n" "$NOCODB_DB_PASSWORD" \
     | psql -U postgres -v ON_ERROR_STOP=1
   '
   ```
2. ⚠️ À ce stade, NocoDB crashait encore — le password aligné côté PG ne suffisait pas, parce que NocoDB continuait à URL-décoder.

### Fix structurel
Remplacement de `NC_DB` (URL) par `NC_DB_JSON` (objet JSON, pas de URL-decode) dans `docker-compose.yml` :
```yaml
NC_DB_JSON: '{"client":"pg","connection":{"host":"postgres","port":5432,"user":"nocodb","password":"${NOCODB_DB_PASSWORD}","database":"nocodb"}}'
```
→ `docker-compose up -d nocodb` → `App started successfully` → `https://acme-db.acme.example` répond 200.

### Leçons exploitables (à porter dans Spark)

- [ ] **Bootstrap** (Phase 3) : générer les secrets avec un alphabet **URL-safe ET JSON-safe** : `tr -dc 'A-Za-z0-9-_' </dev/urandom | head -c 32`. Bannir `openssl rand -base64` pour tout secret destiné à transiter dans un endroit qui pourrait l'interpréter (URL, JSON inline, query string).
- [ ] **Compose template** : pour toute conf passant par une URL (`NC_DB`, `DATABASE_URL`, `REDIS_URL`...), préférer le format objet quand l'app le supporte. Si pas le choix, URL-encoder explicitement le password.
- [ ] **Bootstrap health-check** (Phase 3) : ne pas se contenter de `docker-compose up -d --wait`. Tester l'auth applicative **réelle** de chaque service vers sa base après le up, pas juste l'existence du rôle.
- [ ] **Doc opérateur** : si on régénère un password dans `.env` après le 1er boot, il faut **explicitement** un `ALTER USER` côté Postgres — `init-db.sh` ne se rejouera jamais. À documenter dans une procédure "rotation de secrets".
- [ ] **Diag rapide à préserver** : la commande `printf '%s' "$X" | tr -dc "&=+%/?# " | wc -c` est utile pour traquer ce genre de bug sans exposer la valeur. Garder ce pattern dans les runbooks.

### Temps réel
- Détection → diagnostic complet : ~5 min (logs explicites)
- Diagnostic → fix immédiat : ~2 min (mais insuffisant)
- Fix immédiat → fix structurel : ~5 min (`NC_DB_JSON`)
- **Total** : ~15 min — court parce que les logs Postgres étaient lisibles. Sans ça (ex: si Caddy avait masqué le 502 derrière un retry), aurait pu durer beaucoup plus.

---

## INC-(antérieur, capturé dans le wiki) — Containers Spark exit code 0 / restart loop ~60s

**Source** : `spark-vault/wiki/topics/architecture-technique.md` §1.3 ("Symptômes d'un Colima sous-dimensionné")
**Statut** : ✅ leçon déjà intégrée au sizing Colima du bootstrap (à coder en Phase 3)

### Symptôme (synthèse du wiki)
- Containers exit avec **code 0** (pas 137/OOM) et restartent en boucle ~60 s, sans stack trace
- n8n logs : `Last session crashed` répété, `Task runner connection attempt failed with status code 403`
- Postgres logs : `Database connection timed out` puis `recovered` cycliques, `Connection reset by peer`
- `OOMKilled=false` partout — masque la vraie cause

### Cause racine
Colima VM sous-dimensionnée : sur un host 8 GB unified avec LLM local concurrent (Ollama 7B ≈ 5 GB working set) + macOS + apps, il restait < 2 GiB pour la VM Colima. Le kernel-OOM-killer cible les sous-processus enfants (le runner n8n, le client Postgres...) plutôt que le container parent → exit 0 silencieux.

### Diag rapide
```bash
docker run --rm alpine free -h
# Si "available" < 200 MB côté VM Colima → c'est la mémoire.
```

### Fix
```bash
colima stop
colima start --cpu N --memory G --disk 100
# unless-stopped relance les containers tout seul
```

### Leçons exploitables (à porter dans Spark)
- [ ] **Bootstrap** (Phase 3) : sizing adaptatif au host. 16+ GB → 6 GB Colima. 8 GB → 4 GB max. (Déjà spécifié §3.2 archi.)
- [ ] **Doc opérateur** : Spark productif **incompatible** avec un host < 16 GB qui fait tourner un LLM local concurrent. À mettre dans le pré-requis du `spark-new-site.sh`.
- [ ] **Diag** : `docker run --rm alpine free -h` doit être le **premier réflexe** face à un crashloop sans stack trace. À mettre en commentaire dans `spark-bootstrap.sh` et runbook.

---

## Template d'incident (à copier pour les prochains)

```markdown
## INC-YYYY-MM-DD — <titre court>

**Site** : <site> / <domain>
**Sévérité** : low / medium / high / critical
**Statut** : 🔴 ouvert / 🟡 mitigé / ✅ résolu

### Symptôme
<ce qu'on voyait depuis l'extérieur>

### Diagnostic
<commandes utilisées, dans l'ordre, avec leur output significatif>

### Cause racine
<la vraie cause — pas le symptôme déguisé en cause>

### Fix immédiat
<ce qui a remis le service en route>

### Fix structurel
<ce qui empêche la récurrence>

### Leçons exploitables (à porter dans Spark)
- [ ] action concrète sur le code/bootstrap/doc
- [ ] ...

### Temps réel
<détection → résolution>
```
