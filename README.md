# Spark Kit

**La plomberie numerique pour PME industrielles.**

Spark transforme un serveur de prototypage en plateforme d'orchestration : prototypez des connexions entre vos logiciels existants, automatisez vos flux, donnez a vos equipes des outils qu'elles utilisent vraiment — sans toucher a ce qui marche deja.

Le serveur de prototypage peut etre :
- un **Mac Mini** dans les locaux de l'entreprise (ideal pour demarrer)
- un **poste Linux** sur le reseau local
- un **VPS heberge** chez un prestataire (Ecritel, OVH, Scaleway...)

Spark vous permet de creer des prototypes a plusieurs etages :
- Browser extensions : decuplez la puissance de vos logiciels web
- Automatisation simple : interconnexion de logiciels
- Automatisation + Data : travail sur des donnees metier deportees
- Automatisation + Data + nouveau logiciel : POC d'integration avec le legacy
- Automatisation + Data + code HTML : creation de POCs web complets

```
  Logiciels metier (CRM, ERP, WMS, facturation, support...)
                       |  source de verite business — INTOUCHABLE
                       |  API / webhook / export CSV
                       v
  ┌──────────────────────────────────────┐
  │  Spark  (serveur de prototypage)     │
  │                                      │
  │  n8n       pont controle entre les   │
  │            logiciels existants       │
  │     ↕                                │
  │  NocoDB    tables de travail,        │
  │            ecrans metier,            │
  │            donnees qui n'existaient  │
  │            nulle part avant          │
  │     ↕                                │
  │  Equipes   utilisent NocoDB          │
  │            comme outil quotidien     │
  └──────────────────────────────────────┘
```

Spark ne remplace rien. Le CRM reste. L'ERP reste. Le fichier Excel qui marche depuis 2012 reste. Spark les fait parler entre eux — et le jour ou vous deciderez d'en changer un, les connexions seront deja cartographiees. Les secrets des logiciels connectes sont chiffres dans le coffre-fort natif de n8n — pas de mots de passe en clair dans des fichiers.

---

## Commencer

Spark se lit comme **3 briques empilables** : une solution technique qui tourne en 30 min, puis deux briques optionnelles qui la rendent exploitable en production.

### Brique 1 — la solution technique · 4 etapes, 30 minutes

```
1. Preparer le serveur   Docker, cloudflared, outils      ~10 min
2. Configurer le site    .env, docker-compose               ~5 min
3. Lancer la stack       docker compose up -d               ~5 min
4. Ouvrir le tunnel      cloudflared + DNS Cloudflare      ~10 min
   ─────────────────────────────────────────────────────
   → n8n et NocoDB accessibles en HTTPS depuis n'importe ou
```

### Briques 2 & 3 — pour passer en production (optionnelles)

```
+ Securite      CF Access + headers Caddy + CORS NocoDB     ~60-90 min   recommande des qu'il y a de la donnee reelle
+ Sauvegarde    backup 3-2-1 : dump + volumes + drill de    ~45-60 min   recommande (offsite = +~25 min)
                restore + offsite rclone (provider au choix)
```

### Guides d'installation

Choisir le guide selon le serveur de prototypage :

| Guide | Serveur | Contenu |
|-------|---------|---------|
| **[INSTALL.md](INSTALL.md)** | Mac Mini (macOS + Colima) | Homebrew, Colima, LaunchAgents, etapes 1→4, depannage |
| **[INSTALL-LINUX.md](INSTALL-LINUX.md)** | Serveur Linux / VPS (Debian 12+, Ubuntu 22.04+) | Docker CE, systemd, etapes 1→7, depannage |
| **[CLAUDE-CODE.md](CLAUDE-CODE.md)** | Tous | Configurer Claude Code (skills, MCP n8n, CLI NocoDB, smoke test) |

> Les deux guides d'installation aboutissent a la meme stack. La suite (CLAUDE-CODE.md) est commune.

---

## Stack

| Composant | Role | Pourquoi celui-la |
|-----------|------|-------------------|
| **n8n** | Orchestration, workflows, connexion entre logiciels | Open source, 400+ connecteurs, code quand il faut |
| **NocoDB** | Base de donnees visuelle (comme Airtable, en local) | Les non-devs peuvent creer des vues et des formulaires |
| **PostgreSQL 16** | Base relationnelle (n8n + NocoDB, users separes) | Un seul backup couvre tout |
| **Caddy** | Reverse proxy + serveur de fichiers | Route le trafic, sert les apps metier statiques |
| **Cloudflare Tunnel** | Acces HTTPS distant | TLS gere par Cloudflare, zero cert a gerer, zero port ouvert |

Tout tourne dans Docker — via **Colima** sur macOS, nativement sur Linux.

**Securite des secrets** : les identifiants des systemes connectes (API keys, tokens, mots de passe) sont stockes dans le coffre-fort de credentials natif de n8n, chiffres par `N8N_ENCRYPTION_KEY`. Pas de fichier `.env` sauvage avec des secrets metier — le `.env` ne contient que les secrets d'infrastructure de la stack elle-meme.

---

## Qui fait quoi

Spark implique 4 roles. Dans une petite structure, une seule personne peut cumuler les 4 — mais les casquettes restent distinctes.

| Role | Ce qu'il fait | Ce qu'il touche |
|------|--------------|-----------------|
| **Admin / infra** | Installe le serveur, Docker, le tunnel. Gere le `.env` et les backups. | Terminal, `docker compose`, fichiers de config |
| **Gestionnaire de credentials** | Configure les connexions aux logiciels metier (API keys, OAuth2) dans le coffre-fort n8n. | `<prefix>-n8n.<domain>` > Settings > Credentials |
| **Builder** | Concoit et construit les POCs avec Claude Code : tables, workflows, pages HTML. | Claude Code + MCP, n8n, NocoDB, repo Git |
| **Utilisateur final** | Utilise les outils construits : formulaires, dashboards, vues NocoDB. | `<prefix>-app.<domain>` et `<prefix>-db.<domain>` uniquement |

L'utilisateur final ne va **jamais** sur `-n8n`. S'il a besoin de quelque chose, il le demande — le builder le construit.

Le guide complet des roles (matrice d'acces, documentation par profil) est dans [`BIENVENUE.md`](https://github.com/spark-kit/templates/blob/main/BIENVENUE.md) du repo templates.

---

## Pre-requis

### Serveur de prototypage

| | Mac Mini (macOS) | Serveur Linux / VPS |
|---|---------|------------|
| **OS** | macOS 14+ (Sonoma) | Debian 12+ / Ubuntu 22.04+ |
| **CPU** | Apple Silicon (M1+) | 4 vCPU |
| **RAM** | 8 Go (16 Go recommande) | 4 Go (8 Go recommande) |
| **Stockage** | 50 Go libres | 50 Go |
| **Reseau** | Ethernet LAN | SSH + HTTPS sortant (port 443) |

### Cloudflare (obligatoire)

- Compte Cloudflare (gratuit)
- Un domaine dont les nameservers pointent vers Cloudflare

Le tunnel Cloudflare est le seul moyen d'obtenir du HTTPS propre sans infrastructure externe. Sans lui, n8n refuse les cookies securises et devient quasi inutilisable.

---

## Architecture

```
                    Internet
                       │
                       ▼
              Cloudflare Edge (HTTPS)
                       │
                 tunnel chiffre (sortant)
                       │
                       ▼
┌──────────────────────────────────────────────┐
│         Serveur de prototypage (Spark)        │
│                                              │
│   cloudflared (service systeme)              │
│        │                                     │
│        ▼ http://127.0.0.1:18080              │
│   ┌─────────┐                                │
│   │  Caddy   │ reverse proxy + file_server   │
│   └────┬─────┘                               │
│        │                                     │
│   -n8n │  -app (webhooks)  -app (/apps/*)    │
│    ┌───▼──────────▸┐       ┌──────────────┐  │
│    │     n8n       │       │  apps/ (html)│  │
│    │     :5678     │       │  file_server │  │
│    └───────┬───────┘       └──────────────┘  │
│            │          -db                    │
│            │    ┌───────────┐                │
│            │    │  NocoDB   │                │
│            │    │  :8080    │                │
│            │    └─────┬─────┘                │
│            │          │                      │
│            │    ┌─────▼─────────────────┐    │
│            │    │    PostgreSQL 16      │    │
│            └───▸│    users: n8n, nocodb │    │
│                 └───────────────────────┘    │
│                                              │
│   Volumes: n8n_data, nocodb_data,            │
│   postgres_data, caddy_*                     │
└──────────────────────────────────────────────┘
```

**Choix structurants** :
- Caddy ecoute sur `127.0.0.1` uniquement — pas d'acces reseau direct, tout passe par le tunnel
- Cloudflare gere le TLS et les certificats — zero config cote serveur
- Utilisateurs PostgreSQL separes (n8n, nocodb) avec mots de passe distincts
- `restart: unless-stopped` → les conteneurs redemarrent apres un reboot (LaunchAgent sur macOS, systemd sur Linux)
- Images Docker epinglees (pas de `latest` sauf NocoDB)
- Secrets metier dans le coffre n8n Credentials, pas dans des fichiers `.env`

---

## Vocabulaire

| Terme | Sens |
|-------|------|
| **Spark** | Le kit / template — ce projet |
| **Site** | Un deploiement Spark concret : 1 serveur, 1 entreprise, 1 domaine |
| **`SPARK_PREFIX`** | Slug par-site qui forme les hostnames (`<prefix>-<service>.<domain>`) |
| **`-n8n`** | Sous-domaine editeur/admin — acces reserve au builder |
| **`-app`** | Sous-domaine equipes — webhooks n8n + apps metier statiques (`/apps/*`) |
| **`-db`** | Sous-domaine NocoDB — vues, formulaires, data pour les equipes |
| **Pattern A** | Tunnel Cloudflare local-managed (config YAML sur le serveur, pas sur le dashboard CF) |
| **Playbook** | Brique d'integration assemblable (workflow n8n + tables NocoDB + config) |

---

## Organisation du projet

**Deux repos GitHub** dans l'organisation `spark-kit` :

| Repo | Contenu |
|------|---------|
| **spark-kit** (ce repo) | Meta : README, installation, SECURITY.md, INCIDENTS.md, ROADMAP.md |
| **templates** | Methodologie, scripts setup, skills Claude Code, smoke test |

**Sur le serveur**, les deux repos se retrouvent dans le dossier de travail (`~/spark/` sur macOS, `/opt/spark/` sur Linux) :

```
$SPARK_HOME/                          ← dossier de travail sur le serveur
├── templates/                        ← clone de spark-kit/templates (read-only)
│   ├── setup-skeleton/               scripts de setup avances (securite, backup)
│   ├── crash-test/                   smoke test
│   ├── skills/                       skills Claude Code specifiques Spark
│   ├── docs/                         runbooks (Caddy, CF Access, cloudflared)
│   ├── CLAUDE.md                     gabarit agent a copier/adapter
│   └── BIENVENUE.md, GETTING-STARTED.md, prd-template.md...
├── infra/                            ← stack live (docker-compose, .env, config)
│   ├── .env                          secrets (gitignore)
│   ├── docker-compose.yml
│   ├── config/
│   ├── apps/
│   ├── scripts/
│   ├── logs/
│   └── backups/
└── discovery/                        ← fiches logiciel, PRD, questionnaires
```

---

## Philosophie

Spark est ne d'une conviction : **les petites entreprises meritent l'industrie 4.0**.

Siemens et Dassault Systemes ont construit l'usine connectee pour les grands groupes. Les PME de 10 a 100 personnes n'ont ni le budget ni les equipes pour ca. Spark est leur porte d'entree.

- **Pas a pas, pas big bang** — on resout un probleme concret en une semaine, puis un autre
- **Side-stack** — on ne touche pas au systeme qui tourne, on pose un deuxieme cerveau a cote
- **La donnee reste dans l'entreprise** — serveur local ou VPS dedie, pas de cloud mutualise
- **La plomberie avant l'IA** — connecter les logiciels existants est le prerequis, l'IA viendra apres
- **Les secrets au coffre** — les credentials metier dans n8n, pas dans des fichiers

---

## Roadmap & decisions

Le suivi detaille de la templatification, les decisions d'architecture et les questions ouvertes sont dans [`ROADMAP.md`](ROADMAP.md).

Les incidents de production et leurs lecons sont archives dans [`INCIDENTS.md`](INCIDENTS.md).

---

*Spark Kit est un projet [Atelier B](https://github.com/spark-kit). Licence a definir.*
