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
| `INSTALL-LINUX.md` | Installation Linux (serveur de production) |
| `CLAUDE-CODE.md` | Configuration de Claude Code (skills, MCP, smoke test) |
| `SECURITY.md` | Standard de durcissement, modele de menace, audit recurrent |
| `INCIDENTS.md` | Incidents transverses (INC-AAAA-MM-JJ) |
| `ROADMAP.md` | Roadmap du kit |
| `deploy/` | Fichiers de deploiement Linux (systemd, env.example) |

## Depot public : anonymisation

Ce depot est **public**. Avant tout commit, nom de branche ou texte de PR :

- aucun nom de client, de site, de personne, d'hebergeur ou de fournisseur metier : ecrire « une PME », « un site pilote » ;
- aucune date precise ni chiffre recoupable dans une anecdote (« vecu chez une PME », sans date) ;
- aucune reference a un document interne (rapport, PRD, lecon numerotee, chemin de vault) ;
- aucune IP, aucun domaine reel (utiliser `acme.example`), aucun secret ;
- passer le `grep` : noms interdits (liste tenue hors du depot), IP privees `192\.168|10\.[0-9]+\.|172\.(1[6-9]|2[0-9]|3[01])\.`, dates `2026-(0[1-9]|1[0-2])-[0-9]{2}` hors identifiants `INC-` et journal de la ROADMAP, noms de mois suivis d'une annee.

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
