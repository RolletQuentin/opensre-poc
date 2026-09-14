# RECON — Phase 0

Reconnaissance exécutée le **2026-09-14** contre `Tracer-Cloud/opensre` @ `0012697ed`
(clone local `/home/quentin/Projects/opensre`, branche `main`).

Légende : **[OK]** vérifié conforme au plan · **[FAUX]** hypothèse du plan invalidée par le code ·
**[ADAPTER]** le plan reste faisable mais la mise en œuvre change · **[À VOIR]** non tranché.

---

## 1. Machine de dev

| Élément | Valeur relevée |
| --- | --- |
| OS | Arch Linux, kernel 7.2.4-arch1-2, x86_64 |
| GPU | **NVIDIA GeForce RTX 4060 Ti, 16380 MiB**, driver 610.57.04 |
| Docker | 29.7.2 · Compose 5.5.1 |
| kind | 0.33.0-alpha · **`kubectl` absent du PATH sous ce nom** (voir ci-dessous) |
| helm | v4.3.0 |
| uv | 0.8.4 (`.tool-versions` demande 0.11.11) |
| jq | 1.8.2 |
| Python hôte | 3.14.7 (le projet demande `>=3.12`, `.tool-versions` épingle 3.13.11) |

### Outils manquants (à installer avant les phases 2+)

- **`kustomize`** — absent. `kubectl -k` suffit si `kubectl` est présent, sinon installer.
- **`mmctl`** — absent. Nécessaire pour `scripts/mattermost-bootstrap.sh` (§5.1 du plan),
  ou bootstrap par API REST à la place.
- **`amtool`** — absent. Nécessaire pour le critère de la phase 4 ; l'API Alertmanager
  (`POST /api/v2/alerts`) via `curl` est un substitut acceptable.
- **`kubectl`** — la sonde `kubectl version --short` n'a rien renvoyé ; `kubectl config
  get-contexts` fonctionne, donc le binaire existe mais n'accepte plus `--short`.
  **Présent, pas de problème.**

### Cluster et réseau Docker — écart notable

- **Un cluster kind `homelab` existe déjà** (`homelab-control-plane`, `homelab-worker`,
  kindest/node v1.36.1). Contexte `kind-homelab`. Le contexte courant est `admin@homelab`
  (le vrai homelab, hors POC).
  → **Ne pas réutiliser ni recréer ce cluster.** Le POC crée un cluster `opensre` distinct.
  Conséquence : les deux clusters partageront le réseau Docker `kind`, ce qui est supporté
  mais impose de vérifier qu'aucun NodePort/IP ne se chevauche.
- Réseau `kind` : déjà créé, **dual-stack**.
  - `IPAM.Config[0]` = `fc00:f853:ccd:e793::/64` (**IPv6**)
  - `IPAM.Config[1]` = `172.18.0.0/16` (IPv4, gateway `172.18.0.1`)
  - **[ADAPTER]** La commande du plan §1.1
    `docker network inspect kind -f '{{(index .IPAM.Config 0).Subnet}}'` renvoie le **préfixe
    IPv6**, pas `172.18.0.0/16`. Utiliser :
    ```bash
    docker network inspect kind -f '{{json .IPAM.Config}}' | jq -r '.[] | select(.Subnet|test(":")|not) | .Subnet'
    ```
  - Occupé : `172.18.0.2` (homelab-worker), `172.18.0.3` (homelab-control-plane).
    La plage `172.18.200.0/24` proposée par le plan est libre → **conservée**.

### Modèle vLLM retenu

16 Go de VRAM → **`Qwen/Qwen3-14B-AWQ`**, `--tool-call-parser hermes`,
`--reasoning-parser qwen3`, `--served-model-name opensre-reasoning`,
`--max-model-len 32768`, `--gpu-memory-utilization 0.90`.
C'est la limite basse pour un agent à outils (le plan le dit) : **la validation
fonctionnelle se fait d'abord avec un provider hébergé**, le vLLM sert à mesurer l'écart.

---

## 2. Dépôts et branches

**[ADAPTER]** Le plan §0.3 suppose `upstream` + `perso`. L'état réel :

```
origin  git@github.com:RolletQuentin/opensre.git   (fetch/push)
```

Un seul remote, qui est **le fork personnel**. Il manque le remote amont.
À faire avant la phase 2 :

```bash
git remote add upstream https://github.com/Tracer-Cloud/opensre.git
git remote rename origin perso     # ou garder "origin" et adapter le plan
git fetch upstream
```

`opensre-poc/` n'existait pas — **créé** par cette phase, non versionné vers un remote pour l'instant.

---

## 3. Dockerfile et profils de process

**[OK, plus riche que prévu]** Le `Dockerfile` racine gère **trois** modes via `MODE` :

| `MODE` | Commande | Notes |
| --- | --- | --- |
| `web` (défaut) | `uvicorn gateway.web.webapp:app --host 0.0.0.0 --port ${PORT:-8000}` | health + `/alerts` |
| `gateway` | `opensre gateway start --foreground` | web **+** transports chat **+** scheduler |
| `scheduler` | `opensre cron start --service` | — |

- Base `python:3.12-slim`, install par **`pip install ".[postgresql]"`** (pas `uv`).
- User non-root **déjà présent** (`opensre`, uid/gid 1000), `HOME=/home/opensre`,
  zone inscriptible `/workspace`. → l'étape « ajouter un USER non-root » du plan §4.2 est **inutile**.
- `EXPOSE 8000`, `HEALTHCHECK` sur `/health` en mode web.
- **`kubectl` n'est pas dans l'image** — mais l'intégration Kubernetes n'en a pas besoin (§7).

### Décision de design revue

Le plan §0.4.1 dit « le déployable = le profil web/gateway ». Le code impose de trancher :
**`MODE=gateway` est le bon choix**, pas `MODE=web`. Raison en §5.

---

## 4. `gateway/web/` — routes réelles

`gateway/web/` ne contient que 4 modules (`webapp.py`, `startup.py`, `web_server.py`, `__init__.py`).

| Route | Méthode | Source | Auth |
| --- | --- | --- | --- |
| `/`, `/health`, `/ok` | GET | `webapp.py` | aucune |
| `/readyz` | GET | `webapp.py` | aucune |
| `/healthz` | GET | `infrastructure/alert_intake.py` | aucune |
| **`/alerts`** | POST | `infrastructure/alert_intake.py` | voir ci-dessous |

`/health` renvoie `{ok, version, llm_configured, env}` et **503** si le LLM n'est pas
configuré (`LLMSettings.from_env()` lève) — utile comme probe de config.

**[FAUX]** Le plan §0.1 décrit `gateway/web/` comme « health, intake d'alertes,
**investigations asynchrones** ». Il n'y a **aucune** route d'investigation asynchrone,
aucun endpoint de statut, aucun store d'investigations.

### Auth de `/alerts`

`require_local_or_token()` dans `infrastructure/alert_intake.py` :

1. Si `OPENSRE_ALERT_LISTENER_TOKEN` est défini → exige `Authorization: Bearer <token>`,
   comparaison `hmac.compare_digest`, sinon **401**.
2. Sinon → n'accepte que `127.0.0.1` / `::1` / `localhost`, sinon **403**
   (« set OPENSRE_ALERT_LISTENER_TOKEN to accept non-loopback callers »).

**[FAUX]** Le plan §4.5/§6 invente `OPENSRE_WEBHOOK_TOKEN`. Le nom réel est
**`OPENSRE_ALERT_LISTENER_TOKEN`**. Et il est **obligatoire** dès que l'appelant n'est pas
loopback — ce qui est le cas d'Alertmanager tournant dans un conteneur Compose.

### Schéma accepté par `/alerts`

`core/domain/alerts/inbox.IncomingAlert`, qui hérite de `StrictConfigModel`
(`extra="forbid"`, avec suggestion de champ proche en cas de typo) :

```python
class IncomingAlert(StrictConfigModel):
    text: str                      # seul champ requis
    alert_name: str | None = None
    severity: str | None = None
    source: str | None = None
    received_at: datetime | None = None   # rempli automatiquement si absent
```

**[FAUX]** Le mapping riche du plan §6.1.5 (`title`, `description`, `service`, `namespace`,
`url`, `raw`) **échouera en 400** : ces champs n'existent pas et le modèle les refuse.
Le payload Alertmanager doit être **aplati dans `text`** (Markdown ou texte structuré),
avec `alert_name` / `severity` / `source="alertmanager"` en métadonnées.

---

## 5. BLOQUANT — `/alerts` n'investigue rien en `MODE=web`

C'est la découverte la plus importante de cette phase.

`POST /alerts` fait exactement une chose : `inbox.put(alert)` dans un
**`AlertInbox` en mémoire de process** (`deque` bornée à 256, éviction FIFO), puis renvoie
`202 {"queued": true, "queue_depth": n}`.

Recherche exhaustive des consommateurs de cette file (`iter_pending`, `pop_nowait`,
`get_current_inbox`) :

| Consommateur | Chemin | Ce qu'il fait |
| --- | --- | --- |
| **REPL interactif** | `surfaces/interactive_shell/runtime/background/workers.py` (`_alert_watcher`) → `surfaces/interactive_shell/ui/alerts/drain_and_render_incoming()` | **affiche** les alertes dans la console au début du tour |
| `/alerts` slash command | `surfaces/interactive_shell/command_registry/alerts.py` | liste les alertes en attente |
| `gateway/web/startup.py` | — | **installe** une inbox vide, ne la draine jamais |

→ **En `MODE=web` standalone (`uvicorn gateway.web.webapp:app`), les alertes s'empilent
et rien ne les lit.** Aucune investigation n'est déclenchée, aucun rapport n'est produit.

### Conséquences pour la phase 4 du plan

Le scénario « Alertmanager → webhook → investigation → thread Mattermost » **ne peut pas
fonctionner** sur `gateway/web` tel quel. Trois options, par coût croissant :

1. **Ne pas passer par `/alerts`.** Écrire une route dédiée
   (`POST /webhooks/alertmanager`) qui, au lieu d'enfiler, compose un tour et l'exécute
   via `infrastructure.turn_host.TurnRunner`, avec un sink Mattermost.
   ⚠️ `gateway/web/AGENTS.md` dit explicitement « **does not bind a turn runner or turn
   output** ». Le test de bordure `gateway/tests/test_package_borders.py` interdit à
   `gateway.web` d'importer `gateway.transports` et `gateway.startup`, mais **pas**
   `infrastructure.turn_host`. C'est donc techniquement possible et architecturalement
   contestable — un maintainer upstream le refusera probablement.
2. **Draineur côté gateway.** Ajouter dans `gateway/startup.py` un worker qui draine
   l'`AlertInbox` et pousse chaque alerte dans le `TurnRunner`, en réutilisant la file
   existante. Respecte le layering, réutilise `/alerts` tel quel, et bénéficie à tout le
   monde (le `MODE=gateway` devient réellement « alert-driven »). **Option recommandée.**
3. **Faire du transport Mattermost le point d'entrée.** Alertmanager poste dans un canal
   Mattermost via incoming webhook ; le bot OpenSRE réagit à la mention. Le plus proche du
   design existant, mais dépendant du transport entrant (phase 3 du POC).

**Décision proposée : option 2**, avec l'option 3 en secours si le draineur s'avère
intrusif. Cela impose `MODE=gateway` (et non `MODE=web`) comme déployable Kubernetes,
puisque seul le process gateway compose un `TurnRunner`.

---

## 6. LLM — le provider vLLM existe déjà

**[FAUX / très bonne nouvelle]** Le plan consacre toute sa phase 2 à créer un provider
`vllm`. Il existe déjà, sous le nom **`custom-openai`**, et la docstring de
`core/llm/providers/custom_endpoints.py` cite vLLM nommément :

> « These providers let OpenSRE point at an arbitrary base URL — a LiteLLM proxy,
> **vLLM**, LocalAI, or an internal model gateway — with the user's own API key and
> model name. »

Variables d'environnement (présentes dans `.env.example` lignes 194-203 et déclarées dans
`config/constants/llm.py`) :

```bash
LLM_PROVIDER=custom-openai
CUSTOM_OPENAI_BASE_URL=http://vllm.opensre.svc:8000/v1   # doit inclure /v1
CUSTOM_OPENAI_API_KEY=EMPTY
CUSTOM_OPENAI_MODEL=opensre-reasoning
CUSTOM_OPENAI_REASONING_MODEL=opensre-reasoning
CUSTOM_OPENAI_CLASSIFICATION_MODEL=opensre-reasoning
CUSTOM_OPENAI_TOOLCALL_MODEL=opensre-reasoning
```

`custom-openai` est enregistré dans `OPENAI_COMPATIBLE_PROVIDERS`
(`core/llm/providers/openai_compat_providers.py`) et traverse le **même chemin client que
`openrouter` / `deepseek`**. Il existe aussi `custom-anthropic` (SDK Anthropic + base URL).
`log_endpoint_resolution()` trace la résolution en `opensre --debug` avec l'URL **rédigée**
(host seul, jamais le token).

Autre découverte : un provider **`ollama`** de première classe (`OLLAMA_HOST`), et
`OPENSRE_LLM_TRANSPORT=litellm` qui bascule tous les providers API vers LiteLLM
(obligatoire et automatique pour `azure-openai`).

### Ce qui reste à faire (phase 2 réduite)

La phase 2 passe de « écrire un provider » à :

1. **Config seule** : régler `.env`, valider un tour de bout en bout contre vLLM.
2. **Vérifier les paramètres envoyés** à l'endpoint — c'est le vrai risque restant.
   Le plan liste `reasoning_effort`, `strict: true`, `parallel_tool_calls`, `store`,
   `max_completion_tokens` : il faut lire `core/llm/transports/sdk/agent_clients.py` et
   `core/llm/shared/openai_chat_completions.py` + `shared/tool_schema_normalize.py` pour
   savoir lesquels partent sur la branche OpenAI-compatible. **[À VOIR]** — non fait dans
   cette passe, à faire avant le premier tour vLLM.
3. Contribution upstream éventuelle : un alias `vllm` avec des défauts sensés
   (`api_key_default="EMPTY"`) serait un ajout d'une ligne dans
   `OPENAI_COMPATIBLE_PROVIDERS` — utile mais **pas bloquant**.

Documentation de référence dans le dépôt : `core/llm/AGENTS.md` (table complète
« where provider wiring lives » + procédure « Adding a Hosted API Provider »).

---

## 7. Intégrations

### Kubernetes — `integrations/kubernetes/`

- **SDK Python `kubernetes`**, pas de shell-out `kubectl`. (Les seules occurrences de
  « kubectl » sont des commentaires et des descriptions d'outils.)
- Deux chemins d'auth, dans `client.py` :
  - `kubeconfig_path` → `load_kube_config` (gère `KUBECONFIG` multi-fichiers)
  - `kubeconfig` (YAML inline, ex. depuis un secret) → `load_kube_config_from_dict`
- **[ADAPTER] Pas de `load_incluster_config`.** Un pod avec juste son ServiceAccount
  projeté **ne marchera pas**. Il faut fournir un kubeconfig :
  - soit un `initContainer` qui en génère un depuis `/var/run/secrets/.../token` + le CA,
    vers un `emptyDir`, avec `KUBECONFIG` pointé dessus (l'idée du plan §4.4 est **non
    optionnelle**) ;
  - soit un Secret contenant le kubeconfig inline.
- Le client **redacte les valeurs d'env** des workloads (`_WORKLOAD_TYPES`) et supprime
  l'annotation `kubectl.kubernetes.io/last-applied-configuration` avant de renvoyer au LLM.
- **[À VOIR]** liste exacte des verbes/ressources → à extraire de `_RESOURCE_DISPATCH` et
  `tools/__init__.py` avant d'écrire le ClusterRole.

### Alertmanager — `integrations/alertmanager/`

`client.py`, `verifier.py`, `setup.py`, `incident_anchor.py`, `tools/`.
Config via `AlertmanagerIntegrationConfig` : `base_url`, `bearer_token`,
`username`, `password`. Env : `ALERTMANAGER_URL` (`config/constants/alertmanager.py`).
Outil `alertmanager_alerts_tool` → **API v2**, lecture des alertes
active/silenced/inhibited. **Lecture seule, conforme au plan.**

### Grafana — `integrations/grafana/`

Riche : `client.py`, `config.py`, `loki.py`, `tempo.py`, `mimir.py`,
`metric_drafts.py`, `alert_source_detect.py`, plus 6 outils
(`grafana_metrics_tool`, `grafana_logs_tool`, `grafana_traces_tool`,
`grafana_alert_rules_tool`, `grafana_annotations_tool`, `grafana_service_names_tool`).
Env `GRAFANA_INSTANCE_URL` / `GRAFANA_READ_TOKEN` confirmés dans
`config/constants/grafana.py`. Conforme au plan.

### Mattermost — absent, template = Rocket.Chat

**[OK]** Aucun `integrations/mattermost`. Le voisin le plus proche est
`integrations/rocketchat/`, mais **sa structure diffère de ce que le plan annonce**
(le plan dit `config.py` / `client.py` / `verifier.py`) :

```
integrations/rocketchat/
  credentials.py          # ← pas "config.py"
  delivery.py
  verifier.py
  setup.py
  alarms.py
  action_prompt.py
  scheduled_delivery.py
  tools/rocketchat_send_message_tool/{tool,models,delivery,validation,results,constants}.py
```

→ `integrations/mattermost/` doit **copier cette structure**, pas celle du plan.
Note : il y a 83 intégrations ; `integrations/registry.py`, `catalog.py`,
`_catalog_impl.py`, `setup_flow.py` et `verify.py` sont les points d'enregistrement.

### Helm

`OSRE_HELM_INTEGRATION` confirmé (`config/constants/helm.py`). Non nécessaire au POC.

---

## 8. Transports chat — contrat pour Mattermost

**[OK]** Contrat propre et facile à étendre.

```python
# gateway/transports/names.py
class TransportName(StrEnum):
    TELEGRAM = "telegram"; SLACK = "slack"; DISCORD = "discord"; BUZZ = "buzz"

# gateway/transports/registration.py
@dataclass(frozen=True)
class TransportRegistration:
    name: TransportName
    start: TransportStarter          # (…, logger, handler: TurnCallback) -> (worker, settings)
    running_status: str

# gateway/transports/startup.py
TRANSPORTS: tuple[TransportRegistration, ...] = (...)   # ← ajouter une ligne ici
```

Ajouter Mattermost = **un membre d'enum + `gateway/transports/mattermost/startup.py`
(`start_mattermost_worker`) + une ligne dans `TRANSPORTS`**. Le loop de `start_transports`
gère déjà : credentials manquants → `not configured` (pas une erreur), échec → `failed`,
les autres transports démarrent quand même.

Structure à répliquer depuis `gateway/transports/slack/` :
`settings.py`, `startup.py`, `client.py`, `turn_stack.py`,
`processing/{events,dispatcher,security,principal,thread_history,attachments}.py`,
`delivery/{turn_output,turn_stream,approvals,feedback,channel_intro}.py`,
`transport/events_api/{server,receiver,signature}.py`.

### Règles de bordure à respecter (testées)

`gateway/tests/test_package_borders.py` — **les tests du gateway vivent dans
`gateway/tests/`, pas dans `tests/`** (dit par `gateway/AGENTS.md`) :

- les transports sont des pairs : aucun n'importe un autre — **découverte automatique**
  par listage de `gateway/transports/*/__init__.py`, donc un nouveau transport est
  soumis aux règles dès sa création, sans inscription ;
- `gateway.web` n'importe ni `gateway.transports.*` ni `gateway.startup` ;
- `gateway.core` n'importe aucun transport ni `gateway.web`, et **ne nomme aucun vendor
  chat** (`test_core_never_names_a_chat_vendor`) ;
- seul `gateway/core/lifecycle/controller.py` importe `gateway.startup`.

Le `TurnRunner` partagé est `infrastructure/turn_host/turn_runner.py`, le contrat de
sortie `infrastructure/turn_host/turn_output.py` + `turn_callback.py`.

---

## 9. Persistance — le plan surdimensionne

**[FAUX]** `.env.example` déclare bien `DATABASE_URI=` et `REDIS_URI=` (lignes 759-760,
section « Deployment / runtime »), **mais aucun module Python ne lit ces deux noms**.
Ce sont des clés mortes de `.env.example`.

Ce que le code lit réellement :

| Besoin | Mécanisme réel |
| --- | --- |
| Base de données | **`DATABASE_URL`** (`config/constants/gateway.py:DATABASE_URL_ENV`). `open_database()` renvoie `None` si non défini → **le gateway démarre sans Postgres**. Sert aux enregistrements partagés entre réplicas (événements Slack traités, feedback, audit). |
| Bindings de session | **Fichier JSON** sur l'org home (`gateway/core/storage/session/paths.py`), **pas Redis**. |
| Redis | Uniquement une **intégration** (`integrations/redis/`) avec `REDIS_HOST` / `REDIS_PORT` / `REDIS_PASSWORD` / … — un système à observer, pas un backing store d'OpenSRE. |
| Audit d'approbations | Fichier JSONL sur l'org home. |

→ **Simplification pour la phase 3 : ni Postgres ni Redis ne sont requis** pour un POC
mono-réplica. Supprimer `k8s/base/postgres.yaml` et `k8s/base/redis.yaml` du plan, et
prévoir à la place un **PVC pour l'org home** (`OPENSRE_HOME`) afin que les bindings de
session et l'audit survivent aux redémarrages. Ajouter Postgres plus tard si on veut
tester le multi-réplica.

---

## 10. Variables d'environnement — corrections

| Variable du plan | Statut | Correction |
| --- | --- | --- |
| `OPENSRE_NO_TELEMETRY=1` | **[OK]** | Lu par `infrastructure/analytics/provider.py` et `observability/errors/sentry.py`. Comparaison stricte à `"1"`. |
| `OPENSRE_SKIP_GITHUB_LOGIN=1` | **[FAUX]** | **N'existe nulle part dans le code.** Aucune occurrence de `GITHUB_LOGIN`. À retirer de partout. Le gate de premier lancement, s'il existe, porte un autre nom — **[À VOIR]**, mais `MODE=gateway`/`MODE=web` ne passent pas par le shell interactif, donc probablement sans objet. |
| `OPENSRE_WEBHOOK_TOKEN` | **[FAUX]** | → **`OPENSRE_ALERT_LISTENER_TOKEN`** |
| `DATABASE_URI` | **[FAUX]** | → `DATABASE_URL`, et **optionnel** |
| `REDIS_URI` | **[FAUX]** | clé morte, à supprimer |
| `SENTRY_DSN=` (vide) | **[OK]** | couvert aussi par `OPENSRE_NO_TELEMETRY=1` |
| `ENV=development` | **[OK]** | `.env.example` ligne 762 |
| `OPENSRE_MASK_ENABLED` | **[OK]** | `infrastructure/safety/masking/policy.py` |
| `LLM_MAX_TOKENS` | **[OK]** | `config/llm_settings.py` |
| `GRAFANA_INSTANCE_URL`, `GRAFANA_READ_TOKEN` | **[OK]** | `config/constants/grafana.py` |
| `ALERTMANAGER_URL` | **[OK]** | `config/constants/alertmanager.py` |

Bonus utile non prévu par le plan — le listener d'alertes du shell :
`OPENSRE_ALERT_LISTENER_ENABLED` / `_HOST` / `_PORT` / `_TOKEN` (`config/repl_config.py`),
également configurables par `~/.opensre/config.yml`.

---

## 11. CLI — les commandes du plan n'existent pas

**[FAUX]** Le plan §2.4 et §3 s'appuient sur `opensre investigate -i <fixture>`.

- **Il n'y a pas de commande `investigate`.** Commandes réelles :
  `doctor · health · auth · config · integrations · gateway · cron · update · account ·
  runbooks · guardrails · fleet · messaging · sentry · posthog · work · debug ·
  remote-sync · uninstall · version`, plus `ask` (non listée dans l'aide principale).
- **Il n'y a pas de fixture** `tests/e2e/kubernetes/fixtures/datadog_k8s_alert.json`.
- Les docs `docs/investigation-tool-calling.md` et
  `docs/investigation-pipeline-architecture.md` **n'existent pas**.
  Ce qui existe : `docs/ARCHITECTURE.md`, `docs/tool-placement-policy.md`,
  `docs/adding-tools-and-integrations.md`, `docs/alertmanager.mdx`, `docs/api.mdx`,
  `core/llm/AGENTS.md`, `gateway/AGENTS.md`.

### Commandes de validation corrigées (remplacent §2.4)

```bash
cd /home/quentin/Projects/opensre
export OPENSRE_NO_TELEMETRY=1
export KUBECONFIG=~/.kube/config     # contexte kind-opensre

# 1) santé + config LLM
uv run opensre health
uv run opensre doctor

# 2) intégrations
uv run opensre integrations --help          # confirmer le nom du sous-verbe verify
GRAFANA_INSTANCE_URL=http://localhost:3000 GRAFANA_READ_TOKEN=... \
ALERTMANAGER_URL=http://localhost:9093 uv run opensre integrations ...

# 3) un tour agent, baseline hébergée
LLM_PROVIDER=anthropic ANTHROPIC_API_KEY=... \
  uv run opensre ask "quels pods sont unhealthy dans le cluster ?"

# 4) le même tour contre vLLM — AUCUN code à écrire
LLM_PROVIDER=custom-openai \
CUSTOM_OPENAI_BASE_URL=http://localhost:8000/v1 \
CUSTOM_OPENAI_API_KEY=EMPTY \
CUSTOM_OPENAI_MODEL=opensre-reasoning \
CUSTOM_OPENAI_REASONING_MODEL=opensre-reasoning \
CUSTOM_OPENAI_CLASSIFICATION_MODEL=opensre-reasoning \
CUSTOM_OPENAI_TOOLCALL_MODEL=opensre-reasoning \
  uv run opensre ask "quels pods sont unhealthy dans le cluster ?"
```

`opensre ask` accepte `--allowed-tool TOOL` (répétable) et
`--dangerously-bypass-approvals` — utile pour un POC non interactif.

---

## 12. Phase 5 (shim OpenAI-compatible) — contrainte architecturale

Aucune route `/v1/*` n'existe : c'est du greenfield, conforme au plan.

**[ADAPTER]** Mais `gateway/web/AGENTS.md` pose : « Not a chat transport — **does not bind
a turn runner or turn output** ». Un shim `/v1/chat/completions` dans `gateway/web/` est
par nature un binder de `TurnRunner`. Le test de bordure ne l'interdit pas
(`infrastructure.turn_host` n'est pas dans la liste bannie), mais la prose de l'AGENTS.md
si. Deux sorties :

- assumer et documenter (le POC reste local) ;
- ou traiter le shim comme un **transport** (`gateway/transports/openai_compat/`), ce qui
  est cohérent : il reçoit des messages utilisateur et rend un tour. C'est le même
  raisonnement que pour Mattermost. **Recommandé.**

---

## 13. Récapitulatif des impacts sur le plan

| Phase du plan | Impact |
| --- | --- |
| §1 Recon | Fait. `docs/RECON.md` = ce document. |
| §2 Stack Compose | Inchangé, sauf la commande de sous-réseau (§1 ici) et la plage IP confirmée libre. |
| §2.4 Validation CLI | **Réécrit** — voir §11 ici. |
| **§3 Provider vLLM** | **Quasi supprimé** — `custom-openai` existe. Reste : vérifier les paramètres OpenAI non universels envoyés à vLLM. Gain : ~1 phase. |
| §4 Déploiement kind | `MODE=gateway` et non `MODE=web` (§5 ici). Postgres/Redis **supprimés**, PVC org-home ajouté. Dockerfile déjà non-root. kubeconfig généré **obligatoire** (§7 ici). |
| §5 Mattermost | Faisable, contrat de transport propre (§8). Structure d'intégration à calquer sur `rocketchat` réel, pas sur le plan. Tests dans `gateway/tests/`. |
| **§6 Alertmanager** | **Bloqué en l'état** — `/alerts` n'investigue rien (§5 ici). Trancher entre draineur gateway (recommandé) et route dédiée. Schéma `IncomingAlert` à 5 champs, token renommé. |
| §7 Open WebUI | Faisable ; loger le shim dans `transports/` plutôt que `web/` (§12 ici). |
| §8 Démo E2E | Dépend de la résolution du §6. |

### Prochaines actions

1. **Décider** de l'option §5 (draineur gateway vs route dédiée vs Mattermost-first).
2. Lire `core/llm/transports/sdk/agent_clients.py`, `shared/openai_chat_completions.py` et
   `shared/tool_schema_normalize.py` → lister les paramètres envoyés sur la branche
   OpenAI-compatible, pour savoir ce qui cassera sur vLLM.
3. Extraire la liste verbes/ressources de `integrations/kubernetes/` → ClusterRole.
4. Installer `kustomize`, `mmctl`, `amtool`.
5. Ajouter le remote `upstream` au clone OpenSRE.
6. Créer le cluster kind `opensre` (sans toucher à `homelab`) et monter la stack Compose.

---

## 14. Addendum — les deux points « [À VOIR] » tranchés

### 14.1 Paramètres envoyés sur la branche OpenAI-compatible

Lecture de `core/llm/transports/sdk/agent_clients.py`, `shared/openai_responses.py`,
`shared/openai_chat_completions.py`.

**Bonne nouvelle : l'adaptateur est déjà durci pour les endpoints non-OpenAI.** Les
paramètres que le plan §3 voulait retirer sont tous conditionnés à
`api_key_env == "OPENAI_API_KEY"` — or `custom-openai` porte
`api_key_env = "CUSTOM_OPENAI_API_KEY"`.

| Paramètre à risque | Envoyé à vLLM ? | Garde |
| --- | --- | --- |
| Responses API (au lieu de Chat Completions) | **non** | `uses_responses_api()` = `api_key_env == "OPENAI_API_KEY"` **et** `model.startswith("gpt-5.6")` |
| `reasoning: {effort: …}` | **non** | branche Responses uniquement |
| `strict` sur les schémas d'outils | **non** | `responses_tool_specs()`, branche Responses uniquement |
| `parallel_tool_calls: false` | **non** | `_supports_openai_parallel_tool_calls_param(api_key_env)` |
| `store` | **jamais envoyé** | absent du code |
| `response_format` | non (chemin agent) | présent seulement dans `llm_clients.py` pour la sortie structurée |
| `tool_choice: "auto"` | oui | supporté par vLLM avec `--enable-auto-tool-choice` |

Le parsing des tool calls tolère déjà des `arguments` non-JSON ou `null`
(`parse_tool_calls()` → `except json.JSONDecodeError: input_dict = {}`, plus coercition
si ce n'est pas un dict). L'amélioration que le plan §3 demandait **existe déjà**.

**Un seul piège reste — le nom du modèle.** `_openai_max_token_kwarg(model)` choisit
`max_completion_tokens` au lieu de `max_tokens` par **regex sur le nom du modèle** :

```python
_OPENAI_O_SERIES_RE = re.compile(r"(?:^|[^A-Za-z0-9])o\d", re.IGNORECASE)   # o1, o3, …
_OPENAI_GPT5_RE     = re.compile(r"(?:^|[^A-Za-z0-9])gpt-5", re.IGNORECASE)
```

C'est un test sur le **nom**, pas sur le provider. Un `--served-model-name` contenant
un `o` suivi d'un chiffre en début de token (`o1`, `-o3`, `_o4`) ou `gpt-5` ferait
envoyer `max_completion_tokens` à vLLM, qui le rejettera.

→ **Contrainte sur le nom logique du modèle vLLM** : `opensre-reasoning` est sûr
(aucun `o<chiffre>`, aucun `gpt-5`). Ne pas le renommer en quelque chose comme
`qwen3-o1` ou `gpt-5-local`.

**Conclusion : la phase 2 du plan est réduite à de la configuration.** Aucun code
provider n'est nécessaire. La contribution upstream résiduelle et facultative serait
un alias `vllm` dans `OPENAI_COMPATIBLE_PROVIDERS` avec `api_key_default="EMPTY"`.

### 14.2 Surface RBAC réelle de l'intégration Kubernetes

Extraite de `_RESOURCE_DISPATCH` et de tous les appels SDK dans
`integrations/kubernetes/` (`client.py`, `tools/`, `verifier.py`).

Appels effectivement émis : `list_namespace`, `list_node` / `read_node`,
`list_namespaced_pod` / `read_namespaced_pod` / `read_namespaced_pod_log`,
`list_namespaced_event`, `list_namespaced_service` / `read_namespaced_service`,
`list_namespaced_config_map` / `read_namespaced_config_map`,
`read_namespaced_persistent_volume_claim`,
`list_namespaced_deployment` / `read_namespaced_deployment`,
`list_namespaced_stateful_set` / `read_namespaced_stateful_set`,
`list_namespaced_daemon_set` / `read_namespaced_daemon_set`,
`read_namespaced_replica_set`,
`list_namespaced_ingress` / `read_namespaced_ingress`.

**Aucun verbe d'écriture. Aucun accès aux `secrets`.**

Le plan §4.4 demandait en plus `endpoints`, `jobs`, `cronjobs`, `networkpolicies`,
`horizontalpodautoscalers` et `metrics.k8s.io` : **le code ne les appelle pas**.
Le moindre privilège l'emporte → ils sont retirés. Le ClusterRole exact est écrit dans
[`k8s/base/rbac.yaml`](../k8s/base/rbac.yaml).

⚠️ Rappel du §7 : ce ClusterRole ne suffit pas seul — l'intégration n'appelle jamais
`load_incluster_config()`, donc le pod doit recevoir un **fichier kubeconfig** construit
à partir du token de ServiceAccount projeté.

---

## 15. Décision — le workflow d'alerte prévu par OpenSRE (résout le §5)

Question posée : OpenSRE est-il conçu pour **lire une alerte puis pousser dans le chat**
(push), ou pour **lire le chat puis aller chercher l'alerte** (pull) ?

**Réponse : pull.** Trois preuves dans le code.

1. **`core/domain/alerts/__init__.py`** documente l'intention de `/alerts` :
   > « Alert intake HTTP is served by `gateway.web.webapp` `POST /alerts` (**started from
   > the interactive shell when `alert_listener_enabled` is set in REPL config**). »

   `/alerts` est un canal de **notification vers l'humain**, rattaché au REPL.

2. **`drain_and_render_incoming()`** (`surfaces/interactive_shell/ui/alerts/__init__.py`)
   est le seul consommateur de la file, et fait exactement deux choses :
   ```python
   console.print(format_incoming_alert(alert))   # afficher
   session.record_incoming_alert(alert)          # mémoriser dans la session
   ```
   Aucune occurrence de `TurnRunner`, `run_turn`, `submit` ou `enqueue` dans tout le
   package. Une alerte entrante **met le sujet devant l'humain** ; elle ne déclenche rien.

3. **Alertmanager est lu en pull, comme évidence.**
   `integrations/alertmanager/tools/` expose `alertmanager_alerts_tool`, qui interroge
   l'API v2 *pendant un tour* pour corréler l'alerte déclenchante avec les autres signaux.
   Et `integrations/alert_source_catalog.py` enregistre `"alertmanager"` comme *alert
   source* routant vers `("eks", "cloudwatch", "grafana", "cloudtrail", "kubernetes")` —
   du routage d'outils pour une investigation **déjà en cours**, pas un déclencheur.
   `integrations/alertmanager/incident_anchor.py` va dans le même sens : il parse le
   payload webhook v4 pour **ancrer la fenêtre temporelle** d'un incident déjà ouvert
   (`startsAt` le plus ancien), pas pour en ouvrir un.

### Workflow canonique

```
humain (Slack / Telegram / Discord / REPL)
   │  message
   ▼
TurnRunner  ──pull──>  alertmanager_alerts_tool  (API v2)
            ──pull──>  grafana_{metrics,logs,traces}_tool
            ──pull──>  kubernetes tools
   │  réponse
   ▼
même canal / même thread
```

### Conséquence pour le POC — **option 3 retenue (« Mattermost d'abord »)**

- Alertmanager poste dans `#sre-incidents` via un **incoming webhook Mattermost**
  (aucune route OpenSRE impliquée, aucune modification du cœur).
- L'humain répond dans le thread en mentionnant `@opensre`, ou tape `/sre …`.
- Le transport Mattermost compose un tour ; l'agent va lire Alertmanager, Grafana et
  Kubernetes par ses outils, puis répond dans le thread.

Ce que cela change par rapport au plan :

| Plan | Devient |
| --- | --- |
| §6 « route `/webhooks/alertmanager` », branche `poc/alertmanager-intake` | **supprimée**. Le receiver Alertmanager pointe sur le webhook Mattermost. |
| `OPENSRE_ALERT_LISTENER_TOKEN` / mapping `IncomingAlert` | **sans objet** pour le POC. |
| Livrable n°6 du §10 | absorbé par le livrable n°5 (Mattermost). |
| Chemin critique | la **phase Mattermost devient bloquante** pour la démo §8. |
| `MODE` du déployable | **`gateway`** (seul mode qui compose un TurnRunner et héberge les transports). |

`/alerts` reste disponible comme canal de notification si on fait tourner le REPL avec
`OPENSRE_ALERT_LISTENER_ENABLED=1` — utile pour le debug, hors chemin de démo.

---

## 16. Correction du §14.1 — `parallel_tool_calls` est un manque, pas une protection

Le §14.1 concluait que l'adaptateur OpenAI-compatible était « déjà durci » parce qu'il
n'envoie pas `parallel_tool_calls` à un endpoint non-OpenAI. **Mesuré en phase 1, c'est
l'inverse : cette omission casse la boucle agent.**

### Le mécanisme

`core/tool/execution.py:318` impose **exactement une action par réponse**. Si le modèle
en demande plusieurs, rien n'est exécuté :

> `Nothing ran: one action per response, but this response requested 3
> (kubernetes_get_resource, kubernetes_get_events, kubernetes_get_pod_logs).`

Chaque provider doit donc demander au modèle de n'émettre qu'un appel :

| Provider | Ce qui est envoyé | Source |
| --- | --- | --- |
| Anthropic | `tool_choice: {"type":"auto","disable_parallel_tool_use":true}` | `agent_clients.py:59` (`ANTHROPIC_SINGLE_TOOL_CHOICE`) |
| OpenAI | `parallel_tool_calls: false` | `agent_clients.py:666` |
| **custom-openai / vLLM** | **rien** | garde `_supports_openai_parallel_tool_calls_param(api_key_env)` = `api_key_env == "OPENAI_API_KEY"` |

Le commentaire du code dit l'intention explicitement :

> « The runtime executes one action per response (`core.tool.execution`); ask the model
> for one tool call **so the batch is never generated and rejected**. »

`custom-openai` ne le demande jamais. Le modèle groupe donc ses appels, et chaque
réponse groupée est rejetée sans rien exécuter — l'agent brûle ses tours.

### Mesure sur ce POC

Observé sur Qwen3-14B-AWQ + parser `hermes`, sur une seule question : **3 réponses
consécutives rejetées** pour cette raison.

Test direct contre vLLM, même prompt, avec et sans le paramètre :

| Requête | HTTP | Nombre d'appels d'outils renvoyés |
| --- | --- | --- |
| sans `parallel_tool_calls` (ce qu'OpenSRE envoie) | 200 | **3** |
| avec `parallel_tool_calls: false` | 200 | **3** |

→ vLLM **accepte** le paramètre (pas de 400) mais **ne l'applique pas** avec le parser
`hermes`. Lever la garde côté OpenSRE est donc **nécessaire mais pas suffisant**.

### Ce qu'il faut faire

1. **Côté OpenSRE (contribution upstream réelle)** — envoyer `parallel_tool_calls: false`
   à tout endpoint OpenAI-compatible, pas au seul `OPENAI_API_KEY`. Sans risque : un
   endpoint qui ignore le paramètre le tolère (mesuré), et un qui le refuse en 400 se
   traite comme le fallback des marqueurs de cache prompt déjà présent dans le code.
   C'est **la** modification de code que ce POC justifie — et elle est à l'exact opposé
   de ce que le plan §3 prévoyait (« retirer `parallel_tool_calls` »).
2. **Côté modèle** — puisque vLLM n'applique pas le paramètre, il faut soit un parser qui
   le respecte, soit renforcer la consigne « un seul outil à la fois » dans le prompt,
   soit accepter la perte de tours. À arbitrer en phase de mesure.
3. **Piste alternative** — faire tolérer à `core/tool/execution.py` un lot d'actions en
   n'exécutant que la première au lieu de tout rejeter. Plus invasif, change une règle de
   sécurité du runtime : à ne pas tenter sans discussion upstream.

## 17. Le namespace Kubernetes est imposé par la config, pas choisi par l'agent

Symptôme : l'agent interrogé sur `demo` a répondu « aucun pod dans le namespace demo »
alors que le pod y tournait bien.

Cause, dans `core/tool/execution.py:481-487` :

```python
injected = tool.extract_params(tool_sources)
kwargs = {**injected, **tc.input}
protected = frozenset(getattr(tool, "injected_params", ()) or ())
for key, value in injected.items():
    if key in protected and value not in (None, "", []):
        kwargs[key] = value          # la config écrase le choix du modèle
```

Les outils Kubernetes déclarent `injected_params = ["kubeconfig", "kubeconfig_path",
"context", "namespace"]`, et `KubernetesIntegrationConfig.namespace` vaut
`"default"` par défaut, normalisé par `normalize_with_default("default")` — donc
**jamais vide, donc toujours gagnant**.

**Conséquence : l'agent ne peut investiguer qu'un seul namespace, celui de
`KUBECONFIG_NAMESPACE`.** Ce n'est pas une faiblesse du modèle local ; un modèle hébergé
se heurterait exactement au même mur.

Contournement POC : `KUBECONFIG_NAMESPACE=demo` dans `.env`.
Correctif de fond (candidat upstream) : retirer `namespace` de `injected_params` — c'est
un paramètre de *portée*, pas un secret ni un champ de connexion, contrairement à
`kubeconfig` / `kubeconfig_path` / `context` — et ne l'utiliser que comme **défaut** quand
le modèle n'en fournit pas.
