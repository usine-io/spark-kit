# CLAUDE.md — repo `spark-kit` (meta / installation)

> Ce repo est **le kit Spark** : installation de la stack + artefacts meta. Il n'embarque PAS le briefing agent complet.

## Source de verite du briefing agent

Le gabarit CLAUDE.md a copier dans chaque repo entreprise est **canonique dans le repo templates** :

- `spark-kit/templates` → `CLAUDE.md` (le seul gabarit a jour)

Ne pas recreer ici une copie du briefing : elle redivergerait. Toute amelioration generalisable se porte dans `spark-kit/templates/CLAUDE.md`.

## Ce que `spark-kit` contient

| Fichier | Role |
|---------|------|
| `README.md` | Installation de la stack (Mac Mini, Colima, compose, tunnel) |
| `SECURITY.md` | Standard de durcissement, modele de menace, audit recurrent |
| `INCIDENTS.md` | Incidents transverses (INC-AAAA-MM-JJ) |
| `ROADMAP.md` | Roadmap du kit |

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
