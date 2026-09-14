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

### Correctif appliqué, et ce qu'il change (mesuré)

Branche `poc/openai-compat-single-action`, commit `12ded5cae` : le paramètre est envoyé à
tout endpoint OpenAI-compatible, avec repli sur 400 (l'équivalent SDK du `drop_params` de
LiteLLM). `make pre-push` vert 9/9.

| Run | Rejets « one action per response » | Durée | Issue |
| --- | --- | --- | --- |
| avant correctif | 3 | ~80 s | conclusion hors sujet (mauvais namespace) |
| après correctif, run A | non mesuré (sortie tronquée) | 382 s | **cause racine correcte** |
| après correctif, run B | **2** | 237 s | bloqué, rend la main à l'utilisateur |

**Le correctif ne supprime pas les rejets sur vLLM**, conformément à la mesure directe
ci-dessus : vLLM accepte le paramètre sans l'appliquer. Il reste juste — il aligne le
transport SDK sur le transport LiteLLM et sert tout endpoint qui honore le paramètre —
mais le levier pour ce POC est le **modèle et son parser**, pas OpenSRE.

La variance entre deux runs identiques est forte (cause racine correcte vs abandon),
ce qui est le vrai signal sur la tenue d'un 14B dans cette boucle agent.

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

## 6bis. Transport Mattermost — livré et vérifié en vrai

Branche `poc/openai-compat-single-action`, commits `24de1eb24` (intégration) et
`34d4dab48` (transport). `make pre-push` 9/9 sur chacun.

Vérifié gateway démarré contre Mattermost 10.5 :

| Étape | Résultat |
| --- | --- |
| `component mattermost: websocket connected` | ✅ |
| Réponse humaine dans le fil de l'alerte → tour agent réel | ✅ `turn done` en 87 s |
| Réponse écrite **dans le fil** (`root_id`) | ✅ vérifié côté serveur |
| Post placeholder **édité en place** | ✅ `edit_at` non nul |
| `opensre health` voit Mattermost | ✅ `Connected to Mattermost as @opensre` |

**Choix de conception : WebSocket, pas slash command.** Le bot compose vers
l'extérieur, donc le gateway n'a besoin d'aucune route HTTP entrante, d'aucune
adresse publique, et d'aucune entrée dans
`MM_SERVICESETTINGS_ALLOWEDUNTRUSTEDINTERNALCONNECTIONS`. Cela supprime tout le
problème « Mattermost doit joindre le cluster » du plan §5.3 — le NodePort 30080
et la slash command `/sre` deviennent inutiles pour le chemin de démo.

**L'unité de conversation est le fil, pas l'utilisateur** : clé de session
`channel:root_id`, verrou par fil. Deux incidents dans deux fils tournent en
parallèle avec des sessions séparées.

**Les approbations sont refusées par construction** : les boutons interactifs de
Mattermost rappellent un endpoint HTTP que ce transport n'a délibérément pas.
Chaque outil sous approbation est refusé et la raison est écrite dans le fil.

### Deux prérequis d'environnement découverts en test réel

1. **`ORGANIZATION_ID` est obligatoire.** Sans lui, tout transport chat refuse le
   tour (`PrincipalResolutionError: no organization is configured`). Ce n'est pas
   propre à Mattermost — Telegram échouerait pareil. Ajouté au `.env` du POC.
2. **Le runner partagé exige une requête de metering liée.** Un tour sans
   `bound_turn_metering` meurt sur
   `RuntimeError: gateway turn has no bound metering request`. Trouvé en test
   réel, pas par les tests unitaires : c'est exactement ce que le test live
   servait à attraper.

### L'historique d'un fil peut empoisonner tous ses tours suivants

Symptôme : l'agent répondait « aucun pod dans le namespace demo » alors que le pod
tournait, que `KUBECONFIG_NAMESPACE=demo` était bien dans l'environnement du
process, et que la config résolue portait `demo`.

**Cause : la conversation, pas le câblage.** Un tour précédent de ce fil avait
conclu « aucun pod », et chaque tour suivant répétait cette conclusion depuis
l'historique au lieu d'appeler à nouveau l'outil — en 27 s, sans appel d'outil.

Démonstration en deux temps, même gateway, même environnement :

| Fil | Session | Réponse |
| --- | --- | --- |
| fil existant | `ee3b9a44` (réutilisée) | « aucun pod dans demo » — faux |
| **fil neuf** | `f438b169` (neuve) | `broken-app-6d595ccf46-g7mzs`, Ready `False`, **36 redémarrages** — exact |
| fil existant après **`/new`** | `9e8e25c1` (rotée) | liste complète et exacte du pod |

**Les outils fonctionnent parfaitement à travers le gateway.** Rien à corriger
côté câblage : ni le namespace injecté, ni le kubeconfig, ni le profil de
process. `/new` est le remède, et ce test valide au passage le chemin de rotation
de session du transport.

Conséquence opérationnelle pour la démo : **une mauvaise conclusion en début de
fil contamine le fil entier**. Sur un modèle 14B qui se trompe une fois sur deux
(§3), cela veut dire qu'il faut ouvrir un fil neuf par incident, et savoir taper
`/new` quand un fil part de travers.

## 6ter. Surface OpenAI-compatible — livrée, Open WebUI branché

Commit `ae8c6806e`. `make pre-push` 9/9, 16 tests.

| Vérification (gateway démarré) | Résultat |
| --- | --- |
| `component openai_compat: serving /v1` | ✅ |
| `GET /v1/models` avec clé | ✅ un modèle `opensre` |
| `GET /v1/models` sans clé | ✅ **401** |
| Complétion non-streamée → cluster réel | ✅ pod listé, **38 redémarrages** |
| Streaming SSE | ✅ **9 frames de progression** nommant les vrais outils |
| `/stop`, `/new` (JSON **et** SSE) | ✅ |
| Open WebUI voit le modèle `opensre` | ✅ depuis son conteneur |

**C'est un transport, pas une route de `gateway/web`** : il lie le turn runner
et la sortie de tour, ce que la surface web s'interdit explicitement. Le
listener Events API de Slack est dans son propre paquet transport pour la même
raison — le docstring du dépôt le dit mot pour mot.

Le tour tourne sur un thread d'exécuteur et publie sa progression dans une file
que la réponse draine. C'est ce qui permet d'afficher chaque appel d'outil
pendant que le tour tourne encore, et ce qui fait qu'un tour lent ne bloque
jamais le listener.

**La clé d'API est obligatoire**, pas optionnelle-avec-avertissement : un
endpoint sans clé ferait tourner des tours d'agent pour quiconque atteint le
port. Pas de clé = *non configuré*, donc ignoré au démarrage.

Open WebUI (profil `ui`) expose deux endpoints : `opensre` (l'agent) et le vLLM
direct (le même modèle sans agent autour) — de quoi comparer « modèle seul » et
« modèle + OpenSRE ». Régler le *task model* sur le vLLM direct dans l'UI, sinon
chaque génération de titre déclenche une investigation.

### Une leçon de méthode

Trois tests réels d'affilée ont accusé un bug déjà corrigé : un **ancien gateway
tournait encore** et tenait le port, si bien que mes requêtes frappaient le
process d'avant le correctif. Le vrai coupable était mes `pkill -f <motif>`, qui
se tuaient eux-mêmes parce que leur propre ligne de commande contient le motif.
Le nouveau listener, lui, s'est comporté correctement : il a signalé
`failed (could not bind 0.0.0.0:8765)` au lieu de démarrer à moitié.
Vérifier `ss -lptn 'sport = :<port>'` avant de conclure.

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
