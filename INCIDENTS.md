# Spark Kit — Archive des incidents

> Chaque fail rencontré sur un déploiement Spark est archivé ici. Les exemples utilisent un nom de site fictif **`acme`** sur le domaine **`acme.example`** pour préserver la confidentialité des sites réels — substituer par le vrai project name côté client (cf. `name:` du `docker-compose.yml`).
> But : éviter qu'un nouveau site rencontre deux fois le même piège, et nourrir la check-list du bootstrap.
>
> Format par incident : symptôme → diagnostic (avec commandes utiles) → cause racine → fix immédiat → fix structurel → leçons exploitables (cases à cocher dans le code).

---

## INC-2026-08-06 — Les étiquettes sortent en ZPL brut : le démarrage automatique avait perdu la configuration

**Site** : anonymisé (`acme` / `acme.example`) — pseudo-API n8n → serveur d'impression local → étiqueteuse ZPL (TSC en USB)
**Sévérité** : high (impression d'étiquettes à l'arrêt en pleine production ; l'atelier ne peut plus identifier les appareils)
**Statut** : ✅ résolu (cause racine corrigée, plus 4 défauts adjacents découverts en chemin)

### Symptôme
Un matin, l'atelier : *« on n'arrive plus à imprimer, les étiquettes sortent en ZPL »* — du **code en clair sur du papier** au lieu d'une étiquette. Un poste touché ; les autres normaux. Question posée à l'agent : *« est-ce qu'on a touché à ce workflow hier ? »*

### Diagnostic
**D'abord établir que le logiciel est hors de cause** — trois regards, dix minutes :
```bash
# 1. Les fichiers d'impression ont-ils bougé ? (18 fichiers modifiés la veille, aucun ici)
git log --since=<hier> --name-only --format='' | sort -u | grep -iE "print|zpl|label"
git log -1 --format='%h %ad %s' -- infra/print-server/     # → 9 jours plus tôt

# 2. Le workflow qui génère l'étiquette a-t-il bougé ? (updatedAt via l'API n8n)
curl -s -H "X-N8N-API-KEY: $KEY" "$N8N/api/v1/workflows?limit=250" | jq -r \
  '.data[] | select(.name|test("label|print")) | "\(.updatedAt) \(.name)"'   # → 2 semaines

# 3. Le ZPL produit MAINTENANT est-il correct ? (le contrôle qui tranche)
curl -s "$APP/webhook/api/wms/dossier/label?dossier_id=25" | jq -r .zpl | head -c 80
# ^XA^PW612^LL156^FO24,12^A0N,33,30^FD…  → bien formé, ^XA…^XZ, pas de BOM
```
Les trois sont propres → **la cause est en aval du logiciel**. Le détail décisif est venu de l'utilisateur : *« le poste a eu l'installation de `install-autostart.bat` hier, avant le redémarrage d'aujourd'hui »*. Et plus tard, une seconde précision qui a déplacé la faute : *« les imprimantes sont toujours en USB »*.

### Cause racine
**Le raccourci de démarrage automatique lançait le serveur sans son argument `--printer`**, alors que l'opérateur, lui, le lançait à la main **avec**. Le serveur est donc parti en auto-détection pour la première fois.

Et l'auto-détection **sondait le réseau AVANT de regarder l'imprimante locale** :
```python
def detect_printer():
    for ip in ["192.168.1.50", "192.168.1.100", "192.168.0.50"]:   # réseau d'abord…
        if connect(ip, 9100): return {"mode": "tcp", "host": ip}
    return chercher_imprimante_windows()                            # …USB ensuite
```
Sur un parc **100 % USB**, cette sonde ne peut jamais trouver la bonne imprimante : au mieux rien, au pire celle d'un tiers. Presque toutes les imprimantes réseau écoutent le port 9100 — une multifonction bureau a reçu le ZPL et l'a imprimé en texte.

**Quatre défauts adjacents, chacun bénin seul, découverts en corrigeant :**
1. `pythonw` (sans console) **masquait** la ligne qui annonçait pourtant la mauvaise cible ;
2. en mode `tcp` il n'y a pas de nom d'imprimante → pas de dpi déduit → **le rescaling 300→203 restait inactif** : même en tapant la bonne étiqueteuse, le format aurait été faux. Seconde panne qui attendait son tour ;
3. la page d'installation servait des **copies** des fichiers, restées à la version fautive : un poste qui réinstallait **réinstallait la panne** ;
4. le tutoriel lui-même présentait l'auto-détection comme la voie normale et disait « double-cliquer sur le .bat » — donc **sans argument**. La documentation enseignait le scénario de la panne.

### Fix immédiat
Tuer le processus, relancer à la main avec la cible explicite (`--printer "<nom de la file Windows>"`). Impression rétablie en une commande.

### Fix structurel
- **Ordre de recherche inversé** : imprimante locale (USB) d'abord, réseau seulement si aucune locale **et** si l'appareil distant s'identifie comme parlant ZPL (`~HI`, Host Identification). Avec cet ordre, l'incident n'aurait pas eu lieu même sans `--printer`.
- **`~HI` comme garde** : « ça écoute sur 9100 » ≠ « c'est une étiqueteuse ». Bonus : la réponse porte le modèle, donc le dpi — ce qui corrige aussi le défaut n°2.
- **Le `.bat` exige la cible** (argument ou saisie, avec la liste des imprimantes détectées), **refuse de s'installer sans elle**, et **vérifie après coup** en interrogeant `/status` : un raccourci qui existe ne prouve pas qu'il imprime au bon endroit.
- **Journal fichier** à côté du script, puisque le lancement sans console mange stdout.
- **Copies resynchronisées** + un README qui dit qu'elles sont des copies et où est la source.
- **Page « Diagnostic impression »** dans le front : le serveur n'écoutant que sur le `localhost` du poste, personne à distance ne peut l'observer — mais le navigateur de ce poste, si. La page teste la chaîne et produit un rapport copiable à envoyer. Un opérateur non technique ouvre un lien et colle le résultat.

### Leçons exploitables (à porter dans Spark)
- [x] `spark-stack-ops` : C7 — vérifier un endpoint sur son **corps**, pas sur son code HTTP.
- [ ] **Un outil qui automatise un lancement doit transporter TOUTE la configuration du lancement manuel qu'il remplace** — sinon il n'automatise pas, il remplace une commande juste par une commande différente. Et il doit le **prouver** (vérification post-installation), pas le promettre.
- [ ] **Chercher le local avant le distant.** Un service qui tourne sur la machine de l'utilisateur doit regarder cette machine en premier. L'ordre d'une auto-détection est une décision de conception, pas un détail d'implémentation.
- [ ] **Une auto-détection doit identifier ce qu'elle a trouvé**, pas se contenter d'un port ouvert. Demander « qui es-tu ? » quand le protocole le permet.
- [ ] **Un service lancé sans console doit écrire un journal fichier** — sinon le seul message qui explique la panne est produit et perdu.
- [ ] **Fichiers dupliqués = drift silencieux** (même classe qu'INC-2026-05-30) : toute copie servie au téléchargement doit porter un README qui désigne la source, et être resynchronisée dans le même commit que la source.
- [ ] **Relire la doc après un incident** : ici elle enseignait littéralement le geste fautif.
- [ ] Fournir au bootstrap une **page de diagnostic** par service local (imprimante, douchette) : elle transforme un dépannage à distance impossible en un lien à ouvrir.

### Temps réel
Signalement ~1 h après l'ouverture de l'atelier → logiciel mis hors de cause en ~10 min → cause racine identifiée dès que l'utilisateur a mentionné l'installation de la veille → correctifs et page de diagnostic livrés dans la foulée.

---

## INC-2026-08-05 — Patch d'un workflow n8n actif par l'API : endpoint HS 2 min, puis patch fantôme

**Site** : anonymisé (`acme` / `acme.example`) — pseudo-API n8n → NocoDB, canal REST v1 (pas de MCP)
**Sévérité** : medium (un endpoint de liste consommé par 3 écrans atelier répond « Error in workflow » pendant ~2 min, en pleine journée de production ; aucune donnée corrompue)
**Statut** : ✅ résolu (restauration par PUT du backup, puis re-patch corrigé)

### Symptôme
Deux pièges enchaînés dans le même patch, avec des symptômes opposés :
1. **L'endpoint tombe** — `POST /webhook/api/wms/pieces` → `{"message":"Error in workflow"}` (HTTP 500) juste après un PUT qui « avait marché » (200, workflow relu, nodes bien présents).
2. **Puis le patch semble sans effet** — après correction et nouveau PUT, l'exécution n'enchaîne toujours que les **anciens** nodes. Le `GET /api/v1/workflows/{id}` montre pourtant les 8 nodes et les bonnes connexions.

### Diagnostic
L'outil n°1 reste l'exécution, pas le workflow :
```bash
# 1. Quel node a échoué, et avec quel message
curl -s -H "Host: acme-n8n.acme.example" -H "X-N8N-API-KEY: $KEY" \
  "http://127.0.0.1:18080/api/v1/executions?limit=1&workflowId=$WF&includeData=true" \
  | python3 -c "import json,sys; e=json.load(sys.stdin)['data'][0]; \
      rd=e['data']['resultData']; print(rd.get('lastNodeExecuted'), rd.get('error',{}).get('message'))"
# → Fetch Sans Type  Credentials not found        <-- piège 1

# 2. Quels nodes ont RÉELLEMENT tourné (vs ceux que le GET montre)
#    → runData ne contient que Webhook, Fetch, Format, Respond : les 4 nouveaux n'ont jamais couru
```

### Cause racine
Deux propriétés de l'API n8n, aucune des deux visible à la relecture du workflow :
- **`nodeCredentialType` seul ne suffit pas.** Un node HTTP créé à la main avec
  `authentication: predefinedCredentialType` + `nodeCredentialType: '<type>'` n'a **aucune credential attachée** : l'objet `credentials` est un champ **à part** (`{'<type>': {'id': …, 'name': …}}`), absent par défaut. Le node paraît correct partout sauf à l'exécution.
- **Un PUT qui change le GRAPHE n'est pas rechargé par l'instance active.** Un PUT de *paramètres* est actif immédiatement (c'est la règle connue) ; dès qu'on **ajoute des nodes ou des connexions**, l'instance active continue de servir l'ancien graphe. On patche, on teste, rien ne change — et on cherche le bug dans son propre code.

### Fix immédiat
Restauration par PUT du backup pris avant le patch (le workflow était sauvegardé en fichier au préalable) : endpoint nominal en une commande, ~2 min d'indisponibilité au total.

### Fix structurel
- Recopier l'objet `credentials` d'un node voisin qui fonctionne, dans le script de patch.
- **`POST /deactivate` puis `POST /activate`** systématiquement après un changement de graphe — dans le script, pas dans la tête.
- Script de patch en deux temps : **`--dry-run` par défaut**, `--execute` explicite ; et **assertions sur l'état de départ** (nom du workflow, présence des nodes attendus, code exact des Code nodes modifiés, connexions attendues) → un patch qui échoue bruyamment sur un état inattendu vaut mieux qu'un patch qui « réussit » sur un workflow qui a bougé.

### Leçons exploitables (à porter dans Spark)
- [x] `spark-n8n-pseudo-api` : W25 (PUT de graphe ≠ actif) + W26 (`credentials` obligatoire) + le garde-fou backup/assertions/dry-run.
- [ ] Bootstrap : fournir un squelette `patch-<workflow>.py` (GET → assertions → modif → dry-run/execute → deactivate/activate) plutôt que de laisser chaque site le réinventer.
- [ ] Vérifier qu'un patch a bien pris **par une exécution**, jamais par la relecture du workflow.

### Temps réel
Détection immédiate (test de l'endpoint juste après le patch) → restauration < 2 min → cause racine du piège n°2 comprise ~20 min plus tard.

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
