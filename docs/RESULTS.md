# RESULTS — mesures

Machine : Arch Linux, RTX 4060 Ti 16 Go (15,6 Gio utilisables, ~0,9 Go pris par le bureau).
OpenSRE @ `0012697ed`. Dernière mise à jour : 2026-09-14.

Statut : **phase 1 terminée** (stack de dev + validation CLI). Phases 3 à 5 non entamées.

---

## 1. Ce qui fonctionne bout en bout

| Chaîne | Statut | Mesure |
| --- | --- | --- |
| broken-app → kube-state-metrics → Prometheus | ✅ | `up{job="kube-state-metrics"} == 1`, scrape 15s |
| règle `KubePodCrashLooping` → Alertmanager | ✅ | `firing` ~2 min après le début du crash-loop |
| Alertmanager → Mattermost `#sre-incidents` | ✅ | post ~20 s après `firing` (`group_wait: 30s`) |
| vLLM sert Qwen3-14B-AWQ en OpenAI-compatible | ✅ | `max_model_len: 32768`, démarrage ~45 s à chaud |
| vLLM émet des tool calls | ✅ | `finish_reason: tool_calls`, arguments JSON valides |
| `opensre health` : alertmanager, grafana, kubernetes | ✅ | 3 PASSED, 0 FAILED |
| `opensre ask` → tour agent complet contre vLLM | ⚠️ | aboutit, mais voir §3 |

Aucune ligne de code OpenSRE n'a été écrite pour brancher vLLM : `LLM_PROVIDER=custom-openai`
suffit (RECON.md §6).

## 2. Configuration vLLM retenue, et pourquoi

Trois tentatives avant d'obtenir un moteur qui démarre :

| # | Config | Résultat |
| --- | --- | --- |
| 1 | 32768 ctx, KV fp16, util 0.90, CUDA graphs | ❌ `5.00 GiB KV cache needed, 4.10 GiB available` |
| 2 | 32768 ctx, KV **fp8**, util 0.92, CUDA graphs | ❌ `CUDA out of memory` à la capture des graphes |
| 3 | **32768 ctx, KV fp8, util 0.90, `--enforce-eager`** | ✅ |

Un 14B AWQ sur 16 Go tient **seulement** en fp8 + eager. Le mode eager coûte en débit
(pas de CUDA graphs), mais c'est la différence entre un moteur qui démarre et un OOM.
Marge résiduelle : quasi nulle. Un 8B laisserait de la place pour les CUDA graphs.

## 3. Le blocage réel : une action par réponse

**C'est le résultat principal du POC.**

`core/tool/execution.py:318` n'exécute rien si le modèle demande plus d'une action :

> `Nothing ran: one action per response, but this response requested 3
> (kubernetes_get_resource, kubernetes_get_events, kubernetes_get_pod_logs).`

Chaque provider doit demander au modèle de n'en émettre qu'une — Anthropic reçoit
`disable_parallel_tool_use: true`, OpenAI reçoit `parallel_tool_calls: false`. **Un
endpoint OpenAI-compatible ne reçoit rien**, la garde étant
`api_key_env == "OPENAI_API_KEY"`.

Mesuré sur une seule question : **3 réponses consécutives rejetées**, soit autant de tours
perdus.

Test direct sur vLLM, même prompt, 3 outils proposés :

| Requête | HTTP | Appels renvoyés |
| --- | --- | --- |
| sans `parallel_tool_calls` (ce qu'OpenSRE envoie aujourd'hui) | 200 | 3 |
| avec `parallel_tool_calls: false` | 200 | 3 |

→ vLLM **accepte** le paramètre mais **ne l'applique pas** avec le parser `hermes`.
Corriger OpenSRE est nécessaire mais **ne suffira pas** : il faudra aussi un parser qui
respecte la contrainte, ou un durcissement de la consigne dans le prompt.

Ceci **inverse** l'hypothèse du plan §3, qui prévoyait de *retirer* `parallel_tool_calls`
pour vLLM. Détail complet : RECON.md §16.

## 4. Deuxième blocage : le namespace est imposé

L'agent interrogé sur `demo` répond « aucun pod dans le namespace demo » alors que le pod
y tourne. Les outils Kubernetes déclarent `namespace` dans `injected_params`, et la config
le force à `"default"` — valeur jamais vide, donc toujours prioritaire sur le choix du
modèle (RECON.md §17).

**L'agent ne peut investiguer qu'un seul namespace à la fois.** Indépendant du modèle :
un modèle hébergé se heurterait au même mur. Contournement : `KUBECONFIG_NAMESPACE`.

## 5. Budget de contexte — la vraie contrainte de dimensionnement

**Prompt système + schémas d'outils = ~20 900 tokens**, mesuré par le refus de vLLM :

> `This model's maximum context length is 24576 tokens and your request has 20881 input tokens`

Conséquences :

- un contexte de 24k est **inutilisable** : il reste 3,7k pour la conversation ;
- à 32k il reste **~11,9k** pour l'historique et les sorties d'outils, ce qui est peu dès
  que l'on lit des logs de pod ;
- c'est le **contexte**, pas le nombre de paramètres, qui dimensionne le GPU pour OpenSRE.

Tous les outils sont envoyés à chaque appel, quelle que soit la question.

## 6. Latence observée

| Opération | Durée |
| --- | --- |
| Démarrage vLLM, modèle en cache | ~45 s |
| Téléchargement Qwen3-14B-AWQ (à froid) | 9,4 Go |
| Un tour `opensre ask` (plusieurs appels d'outils, eager) | 70–80 s |
| `opensre health` (61 intégrations sondées) | ~30 s |

## 7. À faire ensuite

1. **Baseline hébergée** — rejouer la même question avec `LLM_PROVIDER=anthropic` pour
   séparer ce qui relève du modèle local de ce qui relève d'OpenSRE. Les §3 et §4 sont
   déjà démontrés indépendants du modèle ; reste à mesurer la qualité du diagnostic.
2. **Correctif `parallel_tool_calls`** — envoyer le paramètre à tout endpoint
   OpenAI-compatible. C'est la contribution upstream que ce POC justifie.
3. **Tester un 8B** (`Qwen3-8B-AWQ`) — retrouver les CUDA graphs et de la marge mémoire,
   et voir si la perte de qualité est acceptable.
4. **Phase 3 (Mattermost)**, désormais sur le chemin critique de la démo (RECON.md §15).

## 8. Ce qui n'est pas mesuré

Qualité du diagnostic vs baseline hébergée · tokens consommés par tour (non instrumenté) ·
débit eager vs CUDA graphs · tenue sous plusieurs tours concurrents.
