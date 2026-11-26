# Travailler avec Claude Code

> Spark est concu pour etre opere avec un agent IA. Ce guide configure l'outillage Claude Code et valide la liaison avec un smoke test.

Pre-requis : stack installee et premier acces fait ([INSTALL.md](INSTALL.md) ou [INSTALL-LINUX.md](INSTALL-LINUX.md)). Retour au [README](README.md) pour le contexte.

**Racine du site.** Les deux parcours n'ont pas la meme arborescence : `~/spark/` sur le Mac (bac a sable), `/opt/spark/` sur Linux (home de l'utilisateur `spark`, qui lance Claude Code). Les commandes ci-dessous ecrivent `$SPARK_ROOT` ; poser une fois par shell :

```bash
SPARK_ROOT=~/spark        # macOS (INSTALL.md)
SPARK_ROOT=/opt/spark     # Linux (INSTALL-LINUX.md), dans le shell de l'utilisateur spark
```

---

## Installer les skills

Les skills donnent a l'agent la doc de reference et le CLI `nocodb.sh` (seul canal d'acces stable a NocoDB pour l'agent). Elles sont embarquees dans le repo templates :

```bash
cd "$SPARK_ROOT/templates/skills"
cp -R nocodb spark-* ~/.claude/skills/
```

> Les skills s'installent dans `~/.claude/skills/` et sont disponibles dans toutes les sessions Claude Code. A faire une seule fois par poste.

Les 7 skills n8n (`n8n-workflow-patterns`, `n8n-node-configuration`, etc.) sont fournies automatiquement par le serveur MCP n8n — pas besoin de les installer separement.

---

## Configurer le MCP n8n

Le MCP n8n est lance **a la demande** par Claude Code (via `docker run`, pas dans le compose — ca economise ~512 Mo de RAM permanente). Le script de connexion est fourni par le kit ; il reste a configurer Claude Code.

Pour NocoDB, **pas de MCP** : l'agent passe par le CLI `nocodb.sh` de la skill `nocodb` (API v3, PAT). Raison : aucun package MCP NocoDB n'est aujourd'hui compatible avec les versions recentes de NocoDB (2026.04.5+) — cf. INC-02. La doc se tient au canal qui fonctionne maintenant.

### Le script wrapper vient du kit

**`infra/scripts/mcp-n8n.sh`** est l'un des scripts de `deploy/scripts/` copies a l'etape 2 des guides (`cp .../deploy/scripts/*.sh infra/scripts/`) : rien a ecrire a la main. Il lit `N8N_API_KEY` dans `infra/.env` (passe au conteneur par `-e N8N_API_KEY`, jamais sur la ligne de commande), rejoint le reseau du projet compose (`<name>_spark`, deduit de `compose.yml`) et lance l'image `ghcr.io/czlonkowski/n8n-mcp`, **figee par tag et digest** comme celles du compose (jamais `:latest`). Verifier qu'il est en place :

```bash
cd "$SPARK_ROOT"
test -x infra/scripts/mcp-n8n.sh && echo "mcp-n8n.sh: OK" || echo "mcp-n8n.sh: ABSENT (refaire l'etape 2 des guides : cp deploy/scripts/*.sh)"
grep -o 'n8n-mcp:[^@"]*' infra/scripts/mcp-n8n.sh     # version figee
```

> Monter la version du MCP = changer la ligne `N8N_MCP_IMAGE` dans `deploy/scripts/mcp-n8n.sh` du kit, puis `deploy/scripts/pin-digests.sh deploy/scripts/mcp-n8n.sh`, puis recopier le script dans `infra/scripts/` (section « Mettre a jour la stack depuis le kit » des guides).

### Creer .mcp.json

Creer `.mcp.json` a la racine du site (`$SPARK_ROOT`, gitignored) — uniquement n8n. C'est un fichier local de Claude Code, pas un fichier d'infra : il reste en heredoc.

```bash
cd "$SPARK_ROOT"
cat > .mcp.json <<'JSON'
{
  "mcpServers": {
    "n8n-mcp": {
      "command": "bash",
      "args": ["infra/scripts/mcp-n8n.sh"]
    }
  }
}
JSON
```

Au demarrage d'une session Claude Code dans ce repo, le MCP n8n apparait automatiquement comme tool provider.

---

## CLI NocoDB

NocoDB est accessible via le CLI `nocodb.sh` de la skill (installe ci-dessus).

Utilisation type (a partager avec l'agent au demarrage d'une session) :

```bash
set -a; source infra/.env; set +a
export NOCODB_TOKEN="$NOCODB_API_TOKEN"
export NOCODB_URL="http://127.0.0.1:${SPARK_HOST_HTTP_PORT:-18080}"
export NOCODB_HOST_HEADER="${SPARK_PREFIX}-db.${SPARK_DOMAIN}"
bash ~/.claude/skills/nocodb/scripts/nocodb.sh workspace:list
# … table:list, field:create, record:list, etc.
unset NOCODB_TOKEN NOCODB_API_TOKEN
```

Le CLI cible `/api/v3/...` avec le header `xc-token`, lit le token via env, ne l'expose jamais en sortie.

> **Pourquoi localhost et pas l'URL publique ?** Si Cloudflare Access est en place, l'URL publique renvoie un 302 vers le login CF. En passant par `127.0.0.1` avec le `Host` header, on reste en local sans traverser CF.

---

## Resume outillage

| Outil | Type | Ce qu'il fait | Ou il vit |
|-------|------|---------------|-----------|
| [`n8n-mcp`](https://github.com/czlonkowski/n8n-mcp) | MCP server | Lire/ecrire workflows, activer, executer | infra/scripts/mcp-n8n.sh (lance a la demande via `docker run`) |
| `nocodb.sh` (skill `nocodb`) | CLI v3 | Lire/ecrire records, schema, tables via API v3 | ~/.claude/skills/nocodb/scripts/ |
| `n8n-*` skills (x7) | Reference | Config nodes, patterns workflow, expressions, code JS/Python, validation | fournies par le MCP n8n |
| `nocodb` skill | Reference | API v3 complete, filtres `where`, CLI bash | ~/.claude/skills/nocodb/ |
| `CLAUDE.md` | Guide agent | Vocabulaire, principes, conventions | racine du repo |

**Regles** :
- n8n : utiliser le MCP pour agir sur les instances live ; ne jamais `curl` quand le MCP peut le faire.
- NocoDB : utiliser le CLI `nocodb.sh` de la skill ; jamais de curl ad-hoc, jamais d'acces direct via `docker exec psql` ou lecture brute de `.env`.
- Skills : pour comprendre la syntaxe et les patterns en amont de l'action.

---

## Installer Claude Code

```bash
npm install -g @anthropic-ai/claude-code
```

Puis lancer une premiere fois pour s'authentifier :

```bash
claude
```

Claude Code ouvre le navigateur pour le login Anthropic. Une fois connecte, quitter avec `/exit` — l'authentification est persistante, les lancements suivants n'en auront plus besoin.

---

## Smoke test

Le smoke test est un test de plomberie automatise : il verifie que **n8n et NocoDB se parlent dans les deux sens** a travers la stack qu'on vient d'installer. Concretement, Claude Code va creer deux tables temporaires dans NocoDB, deux workflows dans n8n, envoyer un "ping" et verifier qu'un "echo" revient. Ca valide 3 routes : ecriture (n8n → NocoDB), chainage (n8n → n8n), lecture (n8n → NocoDB). Si les 3 passent, la stack est operationnelle. Le tout prend ~5 minutes et se nettoie ensuite.

Copier le briefing agent depuis le repo templates, puis ouvrir Claude Code :

```bash
cp "$SPARK_ROOT/templates/CLAUDE.md" "$SPARK_ROOT/CLAUDE.md"
cd "$SPARK_ROOT"
claude
```

Claude Code charge le `CLAUDE.md` a la racine et a acces a toute l'arborescence : `infra/` (stack live), `templates/` (methodologie, scripts, skills), `discovery/` (fiches projet).

Premier prompt a coller :

```
Nouveau site Spark, la plomberie est posee (infra/, tunnel, containers up).
Avant de builder quoi que ce soit :
1. Lis templates/GETTING-STARTED.md et templates/CLAUDE.md — c'est ta reference.
2. Verifie ton outillage : skills installes, MCP n8n connecte, CLI NocoDB fonctionnel.
3. Lance le smoke test dans templates/crash-test/ pour valider la liaison n8n ↔ NocoDB.
Rapport a chaque etape.
```

Le smoke test verifie la liaison n8n ↔ NocoDB (ecriture, chainage workflow, lecture). S'il passe, la stack est operationnelle et l'agent est pret a builder. Detail du test : [`templates/crash-test/README.md`](https://github.com/spark-kit/templates/blob/main/crash-test/README.md).
