# Spark Kit — Securite

> Standard de durcissement par defaut pour tout site Spark expose via Cloudflare Tunnel.
> Les exemples utilisent le nom de site fictif **`acme`** sur le domaine **`acme.example`** — substituer par le vrai prefix/domain du site.

---

## 1. Modele de menace

Un site Spark deploye expose typiquement 3 sous-domaines Cloudflare :

| Sous-domaine | Service interne | Surface ouverte si non durci |
|---|---|---|
| `acme-n8n.acme.example` | n8n (UI + REST API) | page login publique, webhooks publics, API exige X-N8N-API-KEY (OK) |
| `acme-app.acme.example` | Caddy → frontends statiques + n8n webhooks | toutes les pages CRM/WMS/... accessibles a un anonyme, tous les `/webhook/api/*` aussi |
| `acme-db.acme.example` | NocoDB (UI + REST API v3) | page login publique, CORS `Access-Control-Allow-Origin: *` par defaut |

**Hypothese d'attaquant** : Internet anonyme. Sans VPN, sans compromission du Mac. Il connait l'URL d'un sous-domaine (devinable via certificate transparency logs, DNS scan de la zone, ou observation d'un frontend qui appelle l'URL).

**Pas joignables depuis Internet** (architecture par defaut) :
- Postgres (reseau Docker interne uniquement)
- Caddy bind `127.0.0.1:18080` (le tunnel CF est l'unique chemin)
- MCP n8n / MCP NocoDB (reseau Docker interne)

**Hors perimetre de ce document** : compromission physique du Mac, supply chain (images Docker), audit des workflows n8n eux-memes.

---

## 2. Defenses par defaut (obligatoires)

### 2.1 Cloudflare Access devant tout vhost UI / app / webhook

**Standard absolu**. Aucune page de login native (n8n, NocoDB) ne doit etre joignable directement depuis Internet. Cloudflare Access (Free tier, jusqu'a 50 users) intercepte la requete et exige une authentification (email-OTP, Google, Microsoft Entra ID, etc.) avant de la transmettre au tunnel.

Couverture minimum :

| Sous-domaine | Policy CF Access |
|---|---|
| `acme-n8n.acme.example` | email/group humain |
| `acme-db.acme.example` | email/group humain + Service Token pour CLI/MCP |
| `acme-app.acme.example` | email/group humain (les browsers auth recoivent un cookie CF — les XHR vers `/webhook/api/*` passent automatiquement) |

**Pattern recommande** : OAuth Microsoft Entra ID (M365) si l'entreprise utilise Microsoft, sinon Google OAuth, sinon email-OTP. Cf. PRD type "Auth via Cloudflare Access".

**Pour les webhooks consommes par des services externes** (pas par browsers humains) : utiliser un **Service Token** CF, transmis par le service en `CF-Access-Client-Id` + `CF-Access-Client-Secret`. Rotation tous les 90 jours.

> Procedure pas-a-pas (dashboard + Terraform), Service Tokens, `cloudflared access`, verif `200→302` et pieges : runbook `spark-templates/docs/cf-access.md`.

### 2.2 Headers de securite cote Caddy

**Source unique : le snippet `(securite)` de [`deploy/config/caddy/Caddyfile`](deploy/config/caddy/Caddyfile)**, importe par chaque vhost du kit (`-n8n`, `-app`, `-db`) et par chaque vhost que le site ajoute dans `sites.d/*.caddy` (`import securite`). Le site n'a **rien a poser a la main** ; un Caddyfile de site qui differe du kit sur ces en-tetes est une derive (`diff -ru spark-kit/deploy/config infra/config`). Valeurs de reference, telles que le snippet les ecrit (sans `preload` sur HSTS : il engage tout le domaine de facon quasi irreversible) :

```caddy
header {
	Strict-Transport-Security "max-age=63072000; includeSubDomains"
	X-Content-Type-Options "nosniff"
	Referrer-Policy "strict-origin-when-cross-origin"
	Permissions-Policy "accelerometer=(), camera=(), geolocation=(), gyroscope=(), magnetometer=(), microphone=(), payment=(), usb=()"
	-X-Powered-By
	-Server
	-Via
}
```

`-Via` retire le `Via: 1.1 Caddy` que `reverse_proxy` ajoute a chaque reponse proxifiee : meme empreinte que `Server`, meme traitement.

`X-Frame-Options` est pose par vhost, hors du snippet : `DENY` sur `-n8n` et `-db` (jamais dans une iframe), `SAMEORIGIN` sur `-app` (les apps du site peuvent s'encadrer entre elles). Il est ecrit avec le prefixe `>` (apres la reponse de l'application) : n8n envoie son propre `X-Frame-Options`, sans `>` le navigateur recevait deux valeurs.

**Les reponses d'erreur aussi.** Caddy n'applique pas un bloc `header` differe (toute suppression `-X` le differe) a une reponse d'erreur : un `404` de `file_server` (`-app`, `/apps/<absent>`) ou un `502` sans amont sortait avec `Server: Caddy` et sans ces en-tetes. Le snippet `(securite)` importe donc dans un `handle_errors` le snippet `(erreurs)` : les memes en-tetes, **plus `X-Frame-Options: DENY`** (le `>X-Frame-Options` du vhost ne s'applique pas dans `handle_errors`, et une page d'erreur ne s'encadre jamais), corps `<code> <libelle>` ; l'attrape-tout `404` des `Host` inconnus porte les memes en-tetes et le meme `DENY` : **aucune reponse du kit, erreur comprise, ne porte `Server` ni `Via`, et toute erreur porte `X-Frame-Options: DENY`**. `selftest-install.sh --up` le verifie sur le `404` d'un `Host` inconnu et sur un `404` de `file_server`.

Notes :
- `auto_https off` (TLS gere par Cloudflare) implique que Caddy ecoute en HTTP — HSTS est neanmoins servi car Cloudflare en re-emet la version HTTPS au browser final.
- Pas de CSP dans le bloc standard : NocoDB et n8n font de l'inline-script et de l'eval, un CSP strict casse leur UI. A ajouter en mode `Content-Security-Policy-Report-Only` si besoin de tester, dans un fichier `sites.d/` ou par vhost, pas dans le snippet.
- `-X-Powered-By` retire le header `Express` envoye par NocoDB (fingerprinting) ; les suppressions different le bloc entier, les valeurs du snippet ecrasent donc celles de l'application.
- Le meme snippet active le **journal d'acces JSON** (`/var/log/caddy/access.log`, volume `caddy_logs`, rotation 50 Mo x 10).
- Un `Host` inconnu recoit `404` (bloc attrape-tout `http://`), plus jamais `200` et un corps vide.
- `trusted_proxies static private_ranges` + `trusted_proxies_strict` (options globales) : Caddy conserve le `X-Forwarded-For` ecrit par Cloudflare quand la requete vient de cloudflared (reseau compose ou `127.0.0.1`) ; sans cela il le remplace par l'IP de cloudflared et n8n (`N8N_PROXY_HOPS=2`) attribue la meme IP a tous les visiteurs. `strict` fait de `request.client_ip` (journal d'acces) l'element le plus a **droite** de l'en-tete qui n'est pas un proxy de confiance, le meme que n8n retient avec `2` ; sans `strict`, c'etait l'element le plus a gauche, forgeable par le visiteur, et le journal pouvait contredire n8n (mesure dans `UPGRADES.md`). Un client sur une plage privee peut forger cet en-tete : c'est pourquoi Caddy n'est joignable que sur `127.0.0.1` et par le tunnel. La reference pour confirmer l'IP d'un visiteur reste `Cf-Connecting-Ip`, ecrit par Cloudflare.

Verification runtime (via le tunnel, ou en local avec `-H "Host: ..."` sur `http://127.0.0.1:18080`) :
```bash
curl -sSI https://acme-n8n.acme.example/ | \
  grep -iE "strict-transport|x-frame|x-content-type|referrer-policy|permissions-policy|^server|x-powered-by"
```
Attendu : les cinq en-tetes, une seule valeur chacun, et ni `Server` ni `X-Powered-By` ; meme chose sur un `404` (`curl -sSI -H "Host: inconnu.acme.example" http://127.0.0.1:18080/`, `X-Frame-Options` excepte : il est pose par vhost). `deploy/scripts/selftest-install.sh --up` fait ce controle sur chaque vhost du kit et sur deux reponses `404`.

### 2.3 Override CORS sur NocoDB

NocoDB renvoie `Access-Control-Allow-Origin: *` par defaut sur tous les paths. Couple a un PAT qui leakerait, un site malveillant pourrait exploiter NocoDB via XHR depuis le browser de la victime.

**Pose par le kit** sur le vhost `-db` du Caddyfile (`deploy/config/caddy/Caddyfile`, source unique), le site n'a rien a ajouter :

```caddy
header >Access-Control-Allow-Origin "https://{$SPARK_PREFIX}-app.{$SPARK_DOMAIN}"
header >Vary "Origin"
```

Effet : seul le frontend Spark (`acme-app.*`) peut consommer l'API NocoDB depuis un browser. Toute autre origine recoit une `Allow-Origin` mismatch — le browser bloque la lecture de la reponse. Le `>` ecrit l'en-tete apres la reponse de NocoDB (il remplace le `*`).

Le CLI `nocodb.sh` n'est pas affecte (CORS est une protection navigateur, pas serveur).

### 2.4 Caddy bind localhost-only

Dans `compose.yml` (source : `deploy/compose.yml`), Caddy doit binder **uniquement** sur `127.0.0.1` :

```yaml
ports:
  - "127.0.0.1:${SPARK_HOST_HTTP_PORT}:80"
```

Sans ce prefixe, Docker bind sur `0.0.0.0` et expose Caddy sur le LAN — bypass possible du tunnel CF, fuite de l'IP origine.

### 2.5 Pas de Uptime Kuma dans le compose client

Un monitoring qui partage le compose des services surveilles ne peut pas detecter sa propre indisponibilite (cercle vicieux Caddy KO → Kuma KO). Le monitoring vit sur un **master Spark separe**, jamais dans le compose client. Pas de sous-domaine `acme-status.*` dans le pattern.

---

## 3. Defenses recommandees (selon le contexte)

- **Cloudflare WAF + Rate Limiting** sur la zone : rate limit serre sur `/login`, `/rest/login`, paths d'auth. Free tier suffisant pour les regles de base.
- **Logs d'acces Caddy persistes** : fournis par le kit (volume `caddy_logs`, `log` JSON dans le snippet `(securite)`, donc sur chaque vhost qui l'importe). Lecture : `docker compose exec caddy sh -c 'tail -n 100 /var/log/caddy/access.log' | jq -r '[.ts, .request.host, .request.method, .request.uri, .status] | @tsv'`. Permet l'investigation post-incident (endpoint x referer x utilisateur).
- **Rotation des secrets infra** tous les 90 jours : `NOCODB_API_TOKEN`, `N8N_API_KEY`, `CF_API_TOKEN`, `N8N_RUNNERS_AUTH_TOKEN` (si le profil `runners` est actif : n8n et le sidecar le lisent tous deux au demarrage). Le `.env` contient les valeurs courantes ; un changement necessite `docker compose up -d` (ou `systemctl reload spark-compose.service`) pour propager.
- **Tunnel en conteneur** (profil `tunnel`, defaut des guides) : cloudflared tourne sans root (uid de l'utilisateur `spark`), sans shell, sans auto-mise a jour (`--no-autoupdate`, version figee par tag + digest), monte le repertoire des identifiants en **lecture seule**, et vise `http://caddy:80` sur le reseau compose : le port hote `127.0.0.1:18080` ne sert plus qu'aux sondes locales. Le repertoire `SPARK_TUNNEL_DIR` (`<id>.json` = secret) reste en `700`/`600`, proprietaire `spark`.
- **Sauvegardes chiffrees et testees** : `deploy/scripts/backup.sh` chiffre `.env` et la config n8n (`age`, cle privee hors machine) ; `deploy/scripts/restore-test.sh` prouve chaque jour que le dernier dump se restaure et qu'un identifiant n8n se dechiffre. La cle privee `age` et `N8N_ENCRYPTION_KEY` vont dans le coffre de l'entreprise, jamais dans la sauvegarde en clair.
- **FileVault** active sur le Mac qui heberge le site (chiffrement disque). Le `.env` est en clair sur le disque, FileVault protege en cas de vol physique.
- **Permissions reduites du CF_API_TOKEN** : `Zone:DNS:Edit` suffit pour creer les enregistrements du tunnel (`cloudflared tunnel route dns`, etape 4 des guides) et pour les scripts d'automatisation DNS prevus par la ROADMAP (`tunnel-up.sh` / `tunnel-down.sh`, pas encore dans le kit). Ne jamais utiliser un token global Account.

---

## 4. Defenses internes deja standard (rappel)

- `.env` gitignored, jamais committe. Verifier `git check-ignore infra/.env` avant tout commit.
- Secrets metier (APIs des logiciels client) dans **n8n > Settings > Credentials**, chiffres par `N8N_ENCRYPTION_KEY`. Pas dans `.env`.
- Users Postgres separes (`n8n`, `nocodb`) avec leur propre mot de passe — pas de partage du `postgres` superuser.
- `N8N_DIAGNOSTICS_ENABLED=false`, `N8N_PERSONALIZATION_ENABLED=false` (eviter les calls telemetrie sortants).
- Generation de secrets avec alphabet URL-safe ET JSON-safe (`A-Za-z0-9-_`, pas `openssl rand -base64` qui peut sortir des `&=+%/`). Cf. INC-01.

---

## 5. Hygiene d'agent

Le `.env` d'un site Spark contient des secrets de tres haut privilege :
- **`CF_API_TOKEN`** (scope `Zone:DNS:Edit`) — peut reecrire les DNS de la zone, prendre la main sur tous les sous-domaines.
- **`N8N_ENCRYPTION_KEY`** — dechiffre tous les credentials n8n (les APIs des logiciels metier de l'entreprise).
- **`NOCODB_API_TOKEN`** (`nc_pat_...`) — acces complet aux bases NocoDB.

Regles operationnelles :

1. **Ne jamais afficher** la valeur d'un secret dans la sortie d'un tool ou un message. Si une commande l'affichait, masquer (`***`) ou ne pas la lancer.
2. **Toujours valider** avec l'utilisateur avant une operation destructive (`docker volume rm`, `DELETE` DNS, suppression de fichier `.env`).
3. **Charger en env, jamais en argv** : `set -a; source infra/.env; set +a` puis `unset` apres usage.
4. **Pas de curl ad-hoc** sur NocoDB — passer par `nocodb.sh` qui ne loggue jamais le token.
5. **Pas de `docker exec postgres psql`** pour lire le `.env` — utiliser le format de variables d'env du container (deja injecte) cf. INC-01.

---

## 6. Audit recurrent — procedure

Probe externe non destructive, executable depuis n'importe quelle machine (idealement tous les 3 mois ou apres un changement infra) :

### 6.1 Headers de securite

```bash
PREFIX=acme
DOMAIN=acme.example
for h in $PREFIX-n8n $PREFIX-app $PREFIX-db; do
  echo "=== $h ==="
  curl -sSI --max-time 10 "https://$h.$DOMAIN/?_t=$(date +%s)" \
    | grep -iE "^(strict-transport|x-content-type|x-frame|referrer|permissions|access-control)"
done
```

Attendu : les 5 headers de securite sur les 3 vhosts. Sur `acme-db`, `Access-Control-Allow-Origin: https://acme-app.acme.example` (pas `*`).

### 6.2 Auth devant chaque sous-domaine

```bash
for h in $PREFIX-n8n $PREFIX-app $PREFIX-db; do
  code=$(curl -sS -o /dev/null -w "%{http_code} -> %{redirect_url}\n" --max-time 10 "https://$h.$DOMAIN/")
  echo "$h : $code"
done
```

Attendu (post-Access) : `302` ou `403` avec redirect vers `*.cloudflareaccess.com`. Si `200` direct sur l'app : Access n'est pas configure.

### 6.3 Webhooks publics

```bash
# Lister les webhooks declares dans le frontend
grep -REho "/webhook/api/[a-zA-Z0-9/_-]+" infra/front-*/ | sort -u

# Pour chaque, tester l'acces anonyme
curl -sS -o /dev/null -w "%{http_code}\n" --max-time 10 \
  "https://$PREFIX-n8n.$DOMAIN/webhook/api/<endpoint>"
```

Attendu (post-Access) : `302`/`403`. Sans Access : `200` + JSON → fuite de donnees business.

### 6.4 API authentification requise

```bash
# n8n
curl -sS -w "HTTP %{http_code}\n" "https://$PREFIX-n8n.$DOMAIN/api/v1/workflows"
# Attendu : 401 avec `X-N8N-API-KEY header required`

# NocoDB
curl -sS -w "HTTP %{http_code}\n" "https://$PREFIX-db.$DOMAIN/api/v3/meta/bases"
# Attendu : 401 `Authentication required - Invalid token`
```

---

## 7. Findings types par site

Liste de findings reutilisables pour l'audit. Severite indicative — a affiner selon contexte business.

| Code | Sev | Description | Test |
|---|---|---|---|
| FX-01 | 🔴 | Webhook n8n public sans auth expose donnees business | curl anonyme `/webhook/api/X` → 200 + JSON |
| FX-02 | 🔴 | Frontends statiques accessibles sans auth | curl `/crm/`, `/wms/`, etc. → 200 sans Access |
| FX-03 | 🔴 | Page login n8n/NocoDB sans CF Access devant | curl `/` → 200 + HTML login |
| FX-04 | 🟠 | Headers securite manquants (Caddyfile du site qui n'importe pas `securite`, ou derive du kit) | `curl -I` sans HSTS / X-Frame / etc. |
| FX-05 | 🟠 | CORS NocoDB ouvert (vhost `-db` qui ne vient pas du kit) | `Access-Control-Allow-Origin: *` dans response |
| FX-06 | 🟠 | Secrets `.env` en clair sur Mac non chiffre | `ls infra/.env` + FileVault status off |
| FX-07 | 🟠 | `CF_API_TOKEN` scope trop large | Token avec scope autre que `Zone:DNS:Edit` |
| FX-08 | 🟠 | Pas de rate limiting CF | aucune rule sur Zone dans dashboard CF |
| FX-09 | 🟡 | Logs d'acces Caddy non persistes (volume `caddy_logs` absent : compose anterieur au kit courant) | `docker compose exec caddy test -s /var/log/caddy/access.log` echoue |
| FX-10 | 🟡 | Fingerprinting `X-Powered-By: Express` cote NocoDB (snippet `securite` absent) | header present dans response |
| FX-11 | 🟡 | Pas de 2FA n8n | n8n CE n'a pas — CF Access est le 2FA |

---

## 8. Liens

- Recettes Caddy (par site) : `infra/docs/caddy.md`
- Incident NocoDB Forbidden (PAT v3) : `INCIDENTS.md` INC-02
- Incident NocoDB crashloop (secret URL-decode) : `INCIDENTS.md` INC-01
- PRD type "Auth Entra ID/M365 via CF Access" : a rediger dans le repo du site, a partir du gabarit PRD de `templates`
- Runbook mise en place CF Access (dashboard + Terraform + Service Tokens) : `spark-templates/docs/cf-access.md`
