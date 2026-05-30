# Runbook — Mettre une application derrière Cloudflare Access

> Companion opérationnel de [`SECURITY.md`](SECURITY.md) §2.1.
> Exemples anonymisés : domaine `acme.example`, team `acme.cloudflareaccess.com`.
> Remplacer par le `{$SPARK_DOMAIN}` du client, `{$SPARK_PREFIX}` par le préfixe du site, et les emails par ceux de l'équipe.

CF Access = couche d'**identité** posée au bord de Cloudflare, **devant un hostname public**. Un anonyme ne reçoit plus l'app mais un `302` vers un mur de login (SSO ou code email). C'est ce qui ferme les pages de login exposées (n8n, NocoDB…) et les écrans/webhooks non authentifiés (cf. findings types `FX-01`..`FX-03`).

---

## 0. Le principe en une image — les « deux portes »

```
Porte 1 (publique, humain)
  Navigateur → Cloudflare edge [CF Access 🔒 302] → tunnel → reverse-proxy → service

Porte 2 (interne, machine/agent)
  Conteneur A ──(réseau Docker interne)──► http://service:port
            ne sort jamais de la machine → jamais vu par CF Access
```

**Conséquence clé** : protéger un hostname **ne casse pas** les appels conteneur-à-conteneur (un MCP, un worker, un script interne qui tape `http://service:port`). CF Access ne voit que le trafic qui passe par le bord Cloudflare.

À l'inverse, tout **client externe légitime** (CLI sur un laptop, autre serveur, callback d'un SaaS) passe par la porte 1 → il lui faut un moyen de franchir Access (cf. §5 Service Tokens).

---

## 1. Choisir le bon contrôle selon l'appelant

| Appelant | Exemple | Contrôle |
|---|---|---|
| **Humain via navigateur** | écrans internes, UI admin (n8n, NocoDB) | **CF Access** + IdP (SSO) ou One-time PIN |
| **Machine externe (M2M)** | callback d'un SaaS, autre serveur, CLI headless | **Service Token** Access (§5), ou clé applicative au niveau du service |
| **Machine interne (même hôte)** | MCP, worker, script conteneur | **rien à faire** — passe par le réseau interne, hors Access |

> ⚠️ CF Access (SSO interactif) ne convient **pas** à une machine : prévoir un Service Token.

---

## 2. Pré-requis

- Compte **Cloudflare Zero Trust** activé (gratuit jusqu'à 50 users).
- Le hostname est **déjà exposé** (tunnel cloudflared ou DNS proxifié orange-cloud).
- Un **IdP** branché (Entra ID, Google…) **ou** rien → fallback **One-time PIN** (code envoyé par email, zéro config, parfait pour un test).

---

## 3. Procédure A — Dashboard (rapide, 1 app / test) ✅ recommandé pour démarrer

1. **Zero Trust → Access → Applications → Add an application → Self-hosted**
2. **Application domain** : `acme-n8n` . `acme.example` (sous-domaine à protéger)
3. **Policy** : Action **Allow** → Include → **Emails** = adresses autorisées
   (ou *Emails ending in* `@acme.example` pour toute l'équipe ; pour un test, une seule adresse)
4. **Identity provider** : l'IdP du client, sinon **One-time PIN**
5. **Save**

Réversible à 100 % : supprimer l'application Access = retour à l'état non protégé.

---

## 4. Procédure B — Terraform (IaC, pour généraliser / capitaliser kit)

Pour reproduire d'un client à l'autre et versionner. Surdimensionné pour un seul test, pertinent dès qu'on protège plusieurs hostnames.

```hcl
resource "cloudflare_zero_trust_access_application" "n8n" {
  account_id       = var.cf_account_id
  name             = "acme n8n"
  domain           = "acme-n8n.acme.example"
  type             = "self_hosted"
  session_duration = "24h"
}

resource "cloudflare_zero_trust_access_policy" "n8n_team" {
  account_id     = var.cf_account_id
  application_id = cloudflare_zero_trust_access_application.n8n.id
  name           = "Équipe Acme"
  decision       = "allow"
  precedence     = 1
  include { email_domain = ["acme.example"] }   # ou email = ["alice@acme.example"]
}
```

**Token API requis** : scope **`Access: Apps and Policies — Edit`** (+ `Access: Organizations, Identity Providers — Read`).
⚠️ Un token `Zone:DNS:Edit` (celui des tunnels) **ne suffit pas** — créer un token dédié.

---

## 5. Laisser passer une machine / un CLI — Service Tokens

Quand un appelant **non-humain** doit franchir Access (CLI headless, autre serveur, sonde de monitoring) :

1. **Zero Trust → Access → Service Auth → Service Tokens → Create** → récupérer `Client ID` + `Client Secret`.
2. Dans la **policy** de l'app : ajouter un include **Service Token** (Action *Service Auth*).
3. L'appelant envoie deux en-têtes :
   ```bash
   curl https://acme-db.acme.example/... \
     -H "CF-Access-Client-Id: <id>.access" \
     -H "CF-Access-Client-Secret: <secret>"
   ```
   Rotation des Service Tokens tous les **90 jours** (cf. `SECURITY.md` §3).

Alternative pour un usage interactif depuis un poste : **`cloudflared access`** (même binaire que le tunnel) :
```bash
cloudflared access login  https://acme-n8n.acme.example   # auth + cache du token
cloudflared access curl   https://acme-n8n.acme.example/...  # curl auto-authentifié
cloudflared access token  https://acme-n8n.acme.example    # récupère le JWT à injecter
```

> 💡 Si un CLI maison tape une app passée derrière Access (ex. le CLI NocoDB sur `acme-db`), il **cassera** (302 au lieu de 200) tant qu'on ne lui donne pas un Service Token. À provisionner **en même temps** que l'app Access.

---

## 6. Vérification (avant / après)

```bash
DOMAIN=acme.example   # = {$SPARK_DOMAIN}
for h in acme-n8n acme-app acme-db; do   # = {$SPARK_PREFIX}-{n8n,app,db}
  printf "%-14s : " "$h"
  curl -sS -o /dev/null -w "HTTP %{http_code} -> %{redirect_url}\n" --max-time 10 "https://$h.$DOMAIN/"
done
```

- **Avant** : `HTTP 200` (anonyme atteint l'app).
- **Après (protégé)** : `HTTP 302 -> https://acme.cloudflareaccess.com/cdn-cgi/access/login/...`
- Dans un navigateur : écran de login CF **avant** l'app.

Vérifier aussi que l'**outillage interne reste vert** (un MCP / worker qui tape `http://service:port` doit continuer à répondre — preuve que la porte 2 est intacte).

---

## 7. Rollback

Supprimer l'application Access (dashboard) ou `terraform destroy` la ressource → retour immédiat au `200`. Aucun impact sur le tunnel ni le DNS.

---

## 8. Pièges à connaître

- **CF Access ≠ déménagement d'URL.** On ajoute un hostname à une policy ; on ne déplace pas `acme-n8n.acme.example` vers `acme-app.acme.example/n8n`. Aucun reroutage, aucun changement de reverse-proxy.
- **Rate-limit ≠ CF Access.** Le rate-limit ralentit le bruteforce d'une page login ; il ne couvre pas les endpoints **sans** login (webhooks, écrans statiques) et n'arrête pas le credential-stuffing. CF Access supprime la surface. Les deux sont complémentaires.
- **Ordre d'opérations sur une app *live*** : protéger un hostname coupe l'accès anonyme **immédiatement**. Le faire dans une fenêtre prévue + prévenir l'équipe. Provisionner les Service Tokens des machines **avant** de couper.
- **Session duration** : trop courte = re-login fréquent ; 24h est un bon défaut interne.

---

## 9. Audit récurrent

Rejouer le bloc §6 (= `SECURITY.md` §6.2) tous les 3 mois ou après tout changement infra. Tous les hostnames censés être protégés doivent répondre `302 → *.cloudflareaccess.com` ; tout `200` inattendu = régression.
