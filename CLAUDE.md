# CLAUDE.md — repo `spark-kit` (meta / installation)

> Ce repo est **le kit Spark** : installation de la stack + artefacts meta. Il n'embarque PAS le briefing agent complet.

## Source de verite du briefing agent

Le gabarit CLAUDE.md a copier dans chaque repo entreprise est **canonique dans le repo templates** :

- `spark-kit/templates` → `CLAUDE.md` (le seul gabarit a jour)

Ne pas recreer ici une copie du briefing : elle redivergerait. Toute amelioration generalisable se porte dans `spark-kit/templates/CLAUDE.md`.

## Ce que `spark-kit` contient

| Fichier | Role |
|---------|------|
| `README.md` | Presentation, stack, roles, prerequis |
| `INSTALL.md` | Installation macOS (Colima) |
| `INSTALL-SANS-NOCODB.md` | Variante macOS sans NocoDB (override `deploy/compose.sans-nocodb.yml`) |
| `INSTALL-LINUX.md` | Installation Linux (serveur de production) |
| `CLAUDE-CODE.md` | Configuration de Claude Code (skills, MCP, smoke test) |
| `SECURITY.md` | Standard de durcissement, modele de menace, audit recurrent |
| `INCIDENTS.md` | Incidents transverses (`INC-NN`, numerotes dans l'ordre chronologique, sans date) |
| `ROADMAP.md` | Roadmap du kit |
| `CHANGELOG.md` | Une entree par lot de mise a jour du kit |
| `UPGRADES.md` | Procedure generale de montee de version et fiches (n8n, Caddy, cloudflared hote → conteneur), retour arriere compris |
| `deploy/` | **Source unique de l'infra** : `compose.yml`, `compose.runners.yml` (override du sidecar runner), `compose.sans-nocodb.yml` (override sans NocoDB), `env.example`, `config/caddy/`, `config/postgres/`, `scripts/` (dont `check-env.sh`, `backup.sh`, `restore-test.sh`, `restore-n8n.sh`, `n8n-releve.sh`, `tunnel-config.sh`, `cloudflared-host-guard.sh`), `linux/systemd/`, `macos/launchd/` |

## Infra : une seule source

L'infra (compose et son override, Caddyfile, init-db, env.example, scripts dont `mcp-n8n.sh`, units systemd, plists launchd) vit **une seule fois** dans `deploy/`. Les guides `INSTALL.md` et `INSTALL-LINUX.md` la **copient** (`cp`, `cp -R`, `sed "s|__HOME__|$HOME|g"` pour les plists) dans l'arborescence `infra/` du site ; ils ne la recopient jamais en heredoc. La configuration cloudflared du site (`config.yml`, identifiant de tunnel) est **generee** par `deploy/scripts/tunnel-config.sh` depuis le `.env`, jamais ecrite a la main. Toute modification d'infra se fait dans `deploy/`, puis :

- `deploy/scripts/selftest-install.sh --up` (rejoue les copies des guides, `docker compose config` sans et avec profils, `caddy validate`, `caddy fmt --diff`, shellcheck, `check-env.sh` dont la coherence des profils, `init-env.sh --sync`, `tunnel-config.sh`, `up`, sondes par marqueur, Host inconnu → 404, en-tetes sur les vhosts et sur les reponses d'erreur (ni `Server`, ni `X-Powered-By`, ni `Via` ; `X-Frame-Options: DENY` sur toute erreur), drapeau `MAINTENANCE`, healthchecks, profil `runners`, `down -v`) ;
- `deploy/scripts/pin-digests.sh --check deploy/compose.yml` et `--check deploy/scripts/mcp-n8n.sh` (les digests sont ceux que les tags servent) ;
- `shellcheck -x deploy/scripts/*.sh deploy/config/postgres/init-db.sh` ;
- `docker run --rm -v "$PWD/deploy/config/caddy:/etc/caddy:ro" caddy:<tag du compose> caddy fmt --diff /etc/caddy/Caddyfile` : le Caddyfile reste au format `caddy fmt` (tabulations). Critere : la sortie ne contient **aucune ligne commencant par `+` ou `-`** (la commande peut sortir en code 0 ou non selon la version, seul le diff compte) ;
- relire les guides pour que chaque chemin cite existe dans `deploy/` ;
- chaque script repond a `--help` par son en-tete complet (tout le bloc de commentaires de tete) et sort en 0 ;
- `deploy/linux/systemd/spark-cloudflared.service` (variante hote) : la garde « un seul connecteur » est `ExecCondition=` → `scripts/cloudflared-host-guard.sh` (profil `tunnel` dans le `.env` ou conteneur `spark-cloudflared-1` existant, meme arrete → unit `inactive` sans boucle `Restart=`), sorties dans le journal (`journalctl -u`). Toute modification se verifie sur une VM avec le test du reboot a deux connecteurs (`INSTALL-LINUX.md`, encart de 4.6).

**Seule exception toleree au « jamais de heredoc »** : `.mcp.json`, fichier local de Claude Code (`CLAUDE-CODE.md`). Tout le reste, scripts, plists et config cloudflared compris, vit dans `deploy/` ou en est genere.

Les images sont figees par tag **et** digest, dans le compose comme dans `mcp-n8n.sh` ; jamais `:latest` (`pin-digests.sh` refuse une image sans tag ou en `:latest`). Une montee de version = changement de tag volontaire + `pin-digests.sh` + fiche d'`UPGRADES.md` bancee (banc sur copie, retour arriere execute une fois) + entree dans `CHANGELOG.md`. Les tags `n8nio/n8n` et `n8nio/runners` changent ensemble.

## Depot public : anonymisation

Ce depot est **public**. Avant tout commit, nom de branche ou texte de PR :

- aucun nom de client, de site, de personne, d'hebergeur ou de fournisseur metier : ecrire « une PME », « un site pilote » ;
- aucune date precise ni chiffre recoupable dans une anecdote (« vecu chez une PME », sans date) ;
- aucune reference a un document interne (rapport, PRD, lecon numerotee, chemin de vault) ;
- aucune IP, aucun domaine reel (utiliser `acme.example`), aucun secret ;
- passer le `grep` : noms interdits (liste tenue hors du depot), IP privees `192\.168|10\.[0-9]+\.|172\.(1[6-9]|2[0-9]|3[01])\.`, dates `2026-(0[1-9]|1[0-2])-[0-9]{2}` hors journal de la ROADMAP (les identifiants d'incident `INC-NN` ne portent pas de date), noms de mois suivis d'une annee.

## Flux des leçons

```
spark-kit/templates/CLAUDE.md   ← gabarit canonique (unique)
        │ copie + specialise a l'install
        ▼
<entreprise>/CLAUDE.md (instance live)   ← decouvre des leçons
        │ leçons generalisables remontees (PR vers templates)
        ▲
spark-kit/   ← SECURITY.md, INCIDENTS.md, ROADMAP.md
```

## Liens

- Templates (gabarits + briefing agent) : https://github.com/spark-kit/templates
- Meta Spark : https://github.com/spark-kit/spark-kit
