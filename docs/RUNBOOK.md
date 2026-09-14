# RUNBOOK — démarrer, tester, débugger le POC

Tout tourne sur la machine de dev. Le homelab de production n'est pas concerné ; le
cluster kind du POC s'appelle **`opensre`** et le cluster `homelab` ne doit jamais être
la cible (`kubectl config use-context kind-opensre`, ou le kubeconfig dédié ci-dessous).

## Prérequis

Installés et vérifiés : Docker 29 + Compose 5, kind 0.33, kubectl, helm, uv, jq,
`nvidia-container-toolkit` (testé par `docker run --rm --gpus all nvidia/cuda:… nvidia-smi`).

Manquants au moment de la reconnaissance, à installer avant les phases suivantes :
`kustomize`, `amtool`. (`mmctl` n'est **pas** nécessaire : il est embarqué dans l'image
Mattermost et les scripts l'appellent via `docker exec`.)

## Démarrage à froid

```bash
cd ~/Projects/opensre-poc
cp .env.example .env           # puis renseigner les mots de passe
./scripts/up.sh                # cluster kind + stack Compose + kube-state-metrics
./scripts/mattermost-bootstrap.sh   # admin, team, canal, bot, webhook, /sre -> .env
./scripts/grafana-bootstrap.sh      # service account Viewer + token -> .env
docker compose -f compose/docker-compose.yml restart alertmanager   # prend le webhook
./scripts/smoke.sh
```

Les trois scripts sont **idempotents** : les relancer ne duplique rien et réutilise les
jetons déjà présents dans `.env`.

Profils Compose optionnels : `--profile logs` (Loki), `--profile ui` (Open WebUI).

## Ce qui écoute où

| Service | Depuis la machine | Depuis un conteneur / un pod |
| --- | --- | --- |
| vLLM | http://localhost:8000/v1 | `http://vllm:8000/v1` · `172.18.200.10` |
| Mattermost | http://localhost:8065 | `http://mattermost:8065` · `172.18.200.21` |
| Prometheus | http://localhost:9090 | `http://prometheus:9090` · `172.18.200.30` |
| Alertmanager | http://localhost:9093 | `http://alertmanager:9093` · `172.18.200.31` |
| Grafana | http://localhost:3000 | `http://grafana:3000` · `172.18.200.32` |
| Open WebUI | http://localhost:3001 | `172.18.200.40` |
| kube-state-metrics | http://localhost:9091/metrics | `http://opensre-control-plane:30081` |
| Gateway OpenSRE (phase 3) | http://localhost:8080 | `http://opensre-control-plane:30080` |

Le réseau Docker `kind` est partagé par les deux clusters kind et par la stack Compose.
Il est **dual-stack** : `IPAM.Config[0]` est le préfixe IPv6, l'IPv4 est en `[1]`.

```bash
docker network inspect kind -f '{{json .IPAM.Config}}' \
  | jq -r '.[] | select(.Subnet|test(":")|not) | .Subnet'     # -> 172.18.0.0/16
```

## Lancer l'agent contre le cluster

Un kubeconfig dédié, réduit au seul contexte `kind-opensre`, évite de viser le homelab
par accident :

```bash
kubectl config view --raw --minify --context kind-opensre > kubeconfig-opensre.yaml
```

```bash
cd ~/Projects/opensre
set -a; . ~/Projects/opensre-poc/.env; set +a
export KUBECONFIG=~/Projects/opensre-poc/kubeconfig-opensre.yaml
export CUSTOM_OPENAI_BASE_URL=http://localhost:8000/v1

uv run opensre health          # alertmanager / grafana / kubernetes doivent être PASSED
uv run opensre ask \
  --allowed-tool kubernetes_list_pods \
  --allowed-tool kubernetes_describe_pod \
  --allowed-tool kubernetes_get_events \
  --allowed-tool kubernetes_get_pod_logs \
  "Pourquoi broken-app redemarre-t-il ?"
```

⚠️ **zsh ne découpe pas les variables non quotées.** Construire les `--allowed-tool`
dans une variable puis l'insérer sans quotes ne marche pas (`Got unexpected extra
argument`). Passer par un tableau bash, ou écrire les options en dur.

⚠️ **`KUBECONFIG_NAMESPACE` impose le namespace à l'agent** — il ne peut pas en changer
de lui-même (voir RECON.md §17). Le régler sur le namespace à investiguer.

## Provoquer une alerte

```bash
kubectl --context kind-opensre apply -f k8s/demo/broken-app.yaml
```

Chronologie observée : CrashLoopBackOff en ~1 min, règle `pending` puis `firing` en ~2 min
(`for: 1m`), post Mattermost après `group_wait: 30s`. Compter **~3 min** de bout en bout.

Forcer une alerte sans attendre :

```bash
curl -sS -X POST http://localhost:9093/api/v2/alerts -H 'Content-Type: application/json' -d '[{
  "labels":{"alertname":"PocTest","namespace":"demo","severity":"critical"},
  "annotations":{"summary":"test","description":"declenchement manuel"},
  "startsAt":"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"}]'
```

## Débugger

```bash
# Logs
docker compose -f compose/docker-compose.yml logs -f vllm alertmanager
kubectl --context kind-opensre -n demo logs deploy/broken-app --previous

# Où la chaîne d'alerte casse
curl -sS http://localhost:9090/api/v1/rules | jq -r '.data.groups[].rules[]|"\(.name)\t\(.state)"'
curl -sS http://localhost:9093/api/v2/alerts | jq -c '.[]|{a:.labels.alertname,s:.status.state}'
docker logs poc-alertmanager | grep -i notify

# Une requête Prometheus depuis le shell : toujours -G --data-urlencode,
# sinon les { } " du sélecteur cassent l'URL.
curl -sS -G http://localhost:9090/api/v1/query --data-urlencode 'query=up{job="kube-state-metrics"}'

# vLLM
curl -sS http://localhost:8000/v1/models | jq
docker logs poc-vllm | grep -iE "OutOfMemory|ValueError|KV cache"
nvidia-smi --query-gpu=memory.used,memory.total --format=csv
```

### Pannes rencontrées et leur cause

| Symptôme | Cause | Correctif |
| --- | --- | --- |
| vLLM : `5.00 GiB KV cache is needed, … available 4.10 GiB` | 14B AWQ + 32k en fp16 ne tient pas en 16 Go | `--kv-cache-dtype fp8` |
| vLLM : `CUDA out of memory` à la capture des graphes | la capture CUDA graph réclame ~1 Go absent | `--enforce-eager` |
| OpenSRE : `'max_tokens' is too large … 20881 input tokens` | les schémas d'outils pèsent ~20,9k tokens | contexte 32768 + `LLM_MAX_TOKENS=2048` |
| `Nothing ran: one action per response` | `parallel_tool_calls` n'est pas envoyé aux endpoints non-OpenAI | RECON.md §16 — correctif upstream |
| Agent : « aucun pod dans demo » alors qu'il y en a | `namespace` est un `injected_param` | `KUBECONFIG_NAMESPACE=demo` — RECON.md §17 |
| L'agent répète une réponse fausse dans un fil | l'historique du fil, pas le câblage — il ne rappelle plus l'outil | taper `/new` dans le fil, ou en ouvrir un neuf |
| `PrincipalResolutionError: no organization is configured` | `ORGANIZATION_ID` absent | le déclarer dans `.env` — tout transport chat en a besoin |
| `gateway turn has no bound metering request` | le tour n'est pas enveloppé dans `bound_turn_metering` | bug de transport, pas de config |
| Alerte qui se résout alors que le pod casse toujours | fenêtre de 5 min < backoff max de 5 min | fenêtres à 15m / 10m |
| Message Alertmanager sur une seule ligne | bloc YAML replié `>-` | bloc littéral `|-` |
| Alertmanager n'atteint pas Mattermost | `.env` contient l'URL `localhost`, inatteignable du conteneur | écrire `http://mattermost:8065/...` dans le fichier lu par Alertmanager |
| Mattermost refuse d'appeler la slash command | IP interne non autorisée | `MM_SERVICESETTINGS_ALLOWEDUNTRUSTEDINTERNALCONNECTIONS` |
| `mmctl` : `This command cannot be run in local mode` | bots / tokens / webhooks exigent une session | API REST en tant qu'admin |
| slash command introuvable à la relecture | les commandes intégrées masquent la recherche | `?custom_only=true` |

## Parler à l'agent depuis Mattermost

Le transport se connecte en **WebSocket sortant** : rien à exposer, pas de
NodePort, pas de slash command.

```bash
cd ~/Projects/opensre
set -a; . ~/Projects/opensre-poc/.env; set +a
export KUBECONFIG=~/Projects/opensre-poc/kubeconfig-opensre.yaml
export CUSTOM_OPENAI_BASE_URL=http://localhost:8000/v1
export MATTERMOST_ALLOWED_USERS=<id du compte Mattermost autorisé>
export PORT=8099          # le 8080 du plan sert au gateway dans kind
uv run opensre gateway start --foreground
```

Attendre `component mattermost: websocket connected`, puis répondre dans le fil
de l'alerte sur http://localhost:8065. L'agent édite un post placeholder dans ce
même fil pendant tout le tour.

Récupérer l'id d'un compte :

```bash
curl -sS -H "Authorization: Bearer $MATTERMOST_BOT_TOKEN" \
  "$MATTERMOST_URL/api/v4/users/username/$MM_ADMIN_USERNAME" | jq -r .id
```

## Arrêt / remise à zéro

```bash
docker compose -f compose/docker-compose.yml --env-file .env down          # garde les volumes
docker compose -f compose/docker-compose.yml --env-file .env down -v       # efface tout
kind delete cluster --name opensre        # JAMAIS --name homelab
```

Le cache Hugging Face (volume `opensre-poc_hf-cache`, ~9,4 Go pour Qwen3-14B-AWQ)
survit à `down` mais pas à `down -v` : le supprimer impose un re-téléchargement.
