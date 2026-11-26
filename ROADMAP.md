# Spark Kit — Roadmap

> Suivi de la templatification, decisions d'architecture, questions ouvertes.
> Derniere mise a jour : 2026-05-11.

---

## Etat actuel (au 2026-05-06)

### Deja template-friendly
- Stack `docker-compose.yml` parametree par variables (host/domain/prefix/port)
- Reverse-proxy Caddy lit ses vhosts depuis `${SPARK_PREFIX}` / `${SPARK_DOMAIN}`
- `.env.example` couvre les 10 variables necessaires
- Scripts `tunnel-up.sh` / `tunnel-down.sh` idempotents, edition par bloc marque
- Pattern A (local-managed) verrouille et documente
- Postgres + n8n + NocoDB + Caddy fonctionnels
- Cloudflare Tunnel (pattern A, local-managed) integre des le deploiement

### Encore hardcode / a template-iser
- `name: <legacy-site>` dans compose → prefixe les **volumes** et les **containers**
- Prefixe `<LEGACY>_*` sur toutes les vars d'env (compose, Caddyfile, scripts, `.env.example`)
- Markers `# >>> <legacy-site>-begin` / `# <<< <legacy-site>-end` dans le YAML cloudflared
- Commentaires `.env.example` parlent du nom du 1er site

### Manquant
- `scripts/spark-bootstrap.sh` (host setup automatise) — spec dans le doc archi, pas encore implemente
- `scripts/spark-new-site.sh` (helper creation nouveau site)
- Strategie backup (3-2-1 decrite dans le doc archi, aucun script)
- Tests / linting `.env` / health-check post-up

---

## Roadmap par phase

Phases ordonnees par dependance. On peut continuer a bosser sur les sites en production pendant la majorite des phases ; les seules a risque pour la prod sont 1+2 (rename + volumes), a faire ensemble.

### Phase 0 — Capture des decisions ← on est ici

### Phase 1 — Rename in-place `<LEGACY>_*` → `SPARK_*`

Bloque par Phase 2 (sinon perte des volumes Docker des deploiements live).

A faire dans le repo de chaque site qui traine le prefixe legacy :
- [ ] `name: <legacy-site>` → `name: spark` dans `docker-compose.yml`
- [ ] `<LEGACY>_*` → `SPARK_*` dans `docker-compose.yml`, `config/Caddyfile`, `scripts/tunnel-*.sh`, `.env.example`, `.env`
- [ ] Markers `<legacy-site>-begin/end` → `spark-begin/end` dans `scripts/tunnel-*.sh`
- [ ] Reecriture des commentaires `.env.example` et messages d'erreur des scripts

### Phase 2 — Volumes externes (deliaison donnees / nom projet)

`docker-compose` v2 prefixe les volumes nommes par `name:` du projet. Renommer `name:` cree des volumes vides et orphelinise les donnees existantes.

Deux options :
- **(a) `external: true` + nom litteral preserve** — zero downtime, zero migration. Le prefixe legacy traine sur disque mais c'est cosmetique.
- **(b) Migration one-shot** via container alpine (`cp -a`). Plus propre mais downtime + risque.

**Recommandation** : (a) pour debloquer Phase 1 sans risque.

### Phase 3 — `scripts/spark-bootstrap.sh` (host setup)

Implementer le script du doc archi, avec les corrections post-incident :
- [ ] Generation de secrets URL-safe (`A-Za-z0-9` uniquement, pas de `base64`)
- [ ] Sizing Colima adaptatif (16 GB+ → 6 GB ; 8 GB → 4 GB)
- [ ] Idempotence (relancable, ne casse pas un `.env` existant)
- [ ] Health-check final (4 services HTTP repondent)

### Phase 4 — `scripts/spark-new-site.sh`

```
./scripts/spark-new-site.sh <site> <domain> [<tunnel-config-path>]
```

- Creation tunnel : `cloudflared tunnel create spark-<site>`
- Generation `.env` avec secrets URL-safe
- Lance `tunnel-up.sh` → routes + CNAMEs
- Lance `docker compose up -d`

Pre-requis manuel : `cloudflared login` (1x par compte CF).

### Phase 5 — Distribution

Options a trancher :
- **GitHub template repo** (`gh repo create --template spark-template`) — simple, git-natif
- **Branch `template` du repo actuel** — un seul lieu, mais melange code de site et template
- **Cookiecutter / copier** — templatification avec substitution de variables

**Preference** : GitHub template repo separe.

---

## Couche methodologique — playbooks par client

Axe orthogonal aux phases 1-5 (infrastructure). Ici : le moteur qui transforme les besoins d'un client en playbooks Spark deployables.

### Flux cible

```
  Doc logiciels legacy + questionnaire onboarding
           │
           ▼
  Ingestion structuree (fiches-logiciel)
           │
           ▼
  PRD du POC a construire
           │
           ▼
  Assemblage de playbooks Spark
           │
           ▼
  Deploiement & iteration
```

### Chantier A — Patterns d'integration → futur repo `spark-kit/playbooks`

Briques assemblables :
- `n8n-nocodb-bridge` — CRUD, webhooks NocoDB → n8n
- `legacy-api-pull` — polling API legacy → NocoDB
- `legacy-csv-import` — import periodique CSV → NocoDB
- `n8n-webhook-out` — NocoDB row change → API externe
- `secrets-vault` — convention credentials n8n

### Chantier B — Methodologie → repo `spark-kit/templates`

Pipeline consultant/agent pour transformer une decouverte client en livrable :
- `templates/README.md` — vue d'ensemble du pipeline
- `templates/ingest-legacy-docs.md` — ingestion de doc legacy → fiche-logiciel
- `templates/prd-template.md` — gabarit PRD POC
- `templates/poc-from-prd.md` — du PRD → playbooks → implementation (bloque par chantier A)

### Chantier C — Outillage Claude (skills + MCP)

**Skills** (reference API) : 7 skills n8n + 1 skill NocoDB.

**Outillage live** : MCP `n8n-mcp` embarque dans le docker-compose de chaque site ; NocoDB s'utilise via le CLI `nocodb.sh` de la skill (pas de MCP NocoDB integre — l'ecosysteme n'est pas stable contre NocoDB 2026.04.5+, cf. INC-02 dans `INCIDENTS.md`).

### Priorite

Chantier B — la methodologie est l'os du projet. A et C s'enrichissent naturellement a l'occasion d'un premier vrai POC.

---

## Decisions figees

| Decision | Raison |
|----------|--------|
| **NocoDB via `NC_DB_JSON`** | `NC_DB` (format URL) crashloop si chars speciaux dans le password. Incident INC-01 d'`INCIDENTS.md`. |
| **Cloudflare Tunnel pattern A** (local-managed) | Evite saturation dashboard CF sur N sites. |
| **Single-level subdomain** `<prefix>-<service>.<domain>` | Universal SSL gratuit ne couvre pas wildcard 2 niveaux. |
| **Postgres unique** n8n + NocoDB | Un `pg_dumpall` couvre tout. |
| **Caddy `tls internal`** (LAN) + CF (public) | Pas d'exposition directe internet. |
| **`X-Forwarded-Proto https` force** + `N8N_PROXY_HOPS=2` | Sinon n8n refuse les cookies securises derriere proxy. |
| **Secrets URL-safe** `A-Za-z0-9` | Lecon incident NocoDB. |
| **Colima sizing adaptatif** | 8 GB → 4 GiB ; 16 GB+ → 6+ GiB. |
| **Volumes Docker nommes** | Backup unifiee, pas de bind-mounts pour les donnees. |
| **`SPARK_PREFIX` ≠ "Spark"** | La kit = Spark, le prefixe par-site = slug client libre. |

---

## Questions ouvertes

- [ ] **Multi-tenant local** : 1 Mac = plusieurs sites Spark ? Mon avis : non par defaut (1 Mac = 1 site = l'esprit usine).
- [ ] **Perimetre backup** : scripts `pg_dumpall` + `rclone` dans la template, ou au site ?
- [ ] **Versioning n8n workflows** : Git local + push GitHub prive. Provisoire, a figer avant Phase 4.
- [ ] **Repo `spark-template` separe vs branche** : voir Phase 5.

---

## Journal

| Date | Phase | Action |
|------|-------|--------|
| 2026-05-06 | 0 | Creation du document roadmap et de `INCIDENTS.md` |
| 2026-05-06 | 0 | Cadrage couche methodologique : role des composants + 3 chantiers A/B/C |
| 2026-05-06 | B | Chantier B amorce : `methodology/README.md` + `ingest-legacy-docs.md` + `prd-template.md` |
| 2026-05-06 | — | Migration vers org GitHub `spark-kit`, extraction methodologie vers repo `templates` |
| 2026-05-06 | — | Anonymisation des references au 1er site |
| 2026-05-11 | 0 | Separation README (guide d'installation) / ROADMAP (suivi interne) |
