#!/usr/bin/env bash
# Provision Mattermost for the POC and write the resulting credentials to .env.
#
# Two APIs are used on purpose:
#   - mmctl --local (unix socket, no auth) for the bootstrap that needs no
#     session: the first admin, the team, the channel.
#   - the REST API as that admin for everything local mode refuses (bots,
#     tokens, webhooks, slash commands).
#
# Idempotent: every step tolerates "already exists".
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
[[ -f .env ]] || { echo "missing .env" >&2; exit 1; }
set -a; . ./.env; set +a

MM=${MM_URL:-http://localhost:8065}
CONTAINER=${MM_CONTAINER:-poc-mattermost}
# Where Mattermost will POST slash commands. Reachable from the Mattermost
# container over the shared "kind" network; NodePort 30080 of the kind node.
SLASH_URL=${MM_SLASH_URL:-http://opensre-control-plane:30080/gateway/mattermost/slash}

mmc() { docker exec "$CONTAINER" /mattermost/bin/mmctl --local "$@"; }
say() { printf '==> %s\n' "$*"; }

# Replace or append KEY=VALUE in .env.
put_env() {
  local key=$1 value=$2
  if grep -q "^${key}=" .env; then
    python3 - "$key" "$value" <<'PY'
import pathlib, sys
key, value = sys.argv[1], sys.argv[2]
p = pathlib.Path(".env")
lines = p.read_text().splitlines()
p.write_text("\n".join(f"{key}={value}" if l.startswith(f"{key}=") else l for l in lines) + "\n")
PY
  else
    printf '%s=%s\n' "$key" "$value" >> .env
  fi
}

# --- 1. admin, team, channel (local mode) ----------------------------------
say "admin user"
mmc user create --email "$MM_ADMIN_EMAIL" --username "$MM_ADMIN_USERNAME" \
    --password "$MM_ADMIN_PASSWORD" --system-admin 2>&1 | tail -1 || true
say "team $MM_TEAM"
mmc team create --name "$MM_TEAM" --display-name "SRE" --email "$MM_ADMIN_EMAIL" 2>&1 | tail -1 || true
mmc team users add "$MM_TEAM" "$MM_ADMIN_USERNAME" >/dev/null 2>&1 || true
say "channel $MM_CHANNEL"
mmc channel create --team "$MM_TEAM" --name "$MM_CHANNEL" \
    --display-name "SRE Incidents" 2>&1 | tail -1 || true

# --- 2. admin session (REST) ----------------------------------------------
say "authenticating as $MM_ADMIN_USERNAME"
SESSION=$(curl -sS -i -X POST "$MM/api/v4/users/login" -H 'Content-Type: application/json' \
  -d "$(jq -nc --arg u "$MM_ADMIN_USERNAME" --arg p "$MM_ADMIN_PASSWORD" \
        '{login_id:$u, password:$p}')" \
  | awk 'BEGIN{IGNORECASE=1}/^token:/{print $2}' | tr -d '\r')
[[ -n "$SESSION" ]] || { echo "Mattermost login failed" >&2; exit 1; }
api() { curl -sS -H "Authorization: Bearer $SESSION" -H 'Content-Type: application/json' "$@"; }

TEAM_ID=$(api "$MM/api/v4/teams/name/$MM_TEAM" | jq -r .id)
CH_ID=$(api "$MM/api/v4/teams/$TEAM_ID/channels/name/$MM_CHANNEL" | jq -r .id)
ADMIN_ID=$(api "$MM/api/v4/users/username/$MM_ADMIN_USERNAME" | jq -r .id)
say "team=$TEAM_ID channel=$CH_ID"

# --- 3. bot + access token -------------------------------------------------
say "bot @opensre"
BOT_ID=$(api -X POST "$MM/api/v4/bots" \
  -d '{"username":"opensre","display_name":"OpenSRE","description":"POC SRE agent"}' \
  | jq -r '.user_id // empty')
if [[ -z "$BOT_ID" ]]; then
  BOT_ID=$(api "$MM/api/v4/users/username/opensre" | jq -r '.id // empty')
fi
[[ -n "$BOT_ID" ]] || { echo "could not create or find bot @opensre" >&2; exit 1; }

# The bot must be a team and channel member to post.
api -X POST "$MM/api/v4/teams/$TEAM_ID/members" \
    -d "$(jq -nc --arg t "$TEAM_ID" --arg u "$BOT_ID" '{team_id:$t, user_id:$u}')" >/dev/null
api -X POST "$MM/api/v4/channels/$CH_ID/members" \
    -d "$(jq -nc --arg u "$BOT_ID" '{user_id:$u}')" >/dev/null

BOT_TOKEN=${MATTERMOST_BOT_TOKEN:-}
if [[ -n "$BOT_TOKEN" ]] \
   && api "$MM/api/v4/users/me" -H "Authorization: Bearer $BOT_TOKEN" >/dev/null 2>&1; then
  say "reusing the bot token already in .env"
else
  BOT_TOKEN=$(api -X POST "$MM/api/v4/users/$BOT_ID/tokens" \
    -d '{"description":"opensre-poc"}' | jq -r '.token // empty')
fi
[[ -n "$BOT_TOKEN" ]] || { echo "could not mint a bot token" >&2; exit 1; }

# --- 4. incoming webhook (Alertmanager -> channel) -------------------------
say "incoming webhook for Alertmanager"
HOOK_ID=$(api "$MM/api/v4/hooks/incoming?team_id=$TEAM_ID&per_page=200" \
  | jq -r '.[] | select(.display_name=="Alertmanager") | .id' | head -1)
if [[ -z "$HOOK_ID" ]]; then
  HOOK_ID=$(api -X POST "$MM/api/v4/hooks/incoming" \
    -d "$(jq -nc --arg c "$CH_ID" --arg u "$ADMIN_ID" \
          '{channel_id:$c, user_id:$u, display_name:"Alertmanager",
            description:"Prometheus alerts for the POC"}')" | jq -r '.id // empty')
fi
[[ -n "$HOOK_ID" ]] || { echo "could not create the incoming webhook" >&2; exit 1; }
HOOK_URL="$MM/hooks/$HOOK_ID"

# --- 5. /sre slash command -------------------------------------------------
# Points at the OpenSRE gateway, which does not exist until the Mattermost
# transport lands (POC phase 3). Created now so .env is complete.
say "/sre slash command -> $SLASH_URL"
SLASH_TOKEN=$(api "$MM/api/v4/commands?team_id=$TEAM_ID&custom_only=true" \
  | jq -r 'if type=="array" then (.[] | select(.trigger=="sre") | .token) else empty end' | head -1)
if [[ -z "$SLASH_TOKEN" ]]; then
  SLASH_TOKEN=$(api -X POST "$MM/api/v4/commands" \
    -d "$(jq -nc --arg t "$TEAM_ID" --arg u "$SLASH_URL" \
          '{team_id:$t, trigger:"sre", method:"P", url:$u,
            display_name:"OpenSRE", description:"Ask the OpenSRE agent",
            username:"opensre", auto_complete:true,
            auto_complete_hint:"<question>",
            auto_complete_desc:"Ask the OpenSRE agent about this incident"}')" \
    | jq -r '.token // empty')
fi

# --- 6. persist ------------------------------------------------------------
put_env MATTERMOST_URL               "$MM"
put_env MATTERMOST_WEBHOOK_URL       "$HOOK_URL"
put_env MATTERMOST_BOT_TOKEN         "$BOT_TOKEN"
put_env MATTERMOST_DEFAULT_CHANNEL_ID "$CH_ID"
put_env MATTERMOST_SLASH_TOKEN       "${SLASH_TOKEN:-}"

# Alertmanager reads the webhook URL from a file (it does not expand env vars),
# and it calls it from inside its container -- so it gets the Compose service
# name, not the browser-facing localhost URL that goes in .env.
HOOK_URL_INTERNAL="${MM_INTERNAL_URL:-http://mattermost:8065}/hooks/$HOOK_ID"
printf '%s' "$HOOK_URL_INTERNAL" > compose/alertmanager/mattermost_webhook_url

echo
say "done. Wrote MATTERMOST_* to .env"
echo "    webhook  $HOOK_URL  (in-cluster: $HOOK_URL_INTERNAL)"
echo "    channel  $MM_TEAM/$MM_CHANNEL ($CH_ID)"
echo "    slash    /sre -> $SLASH_URL $([[ -n ${SLASH_TOKEN:-} ]] && echo '(token stored)' || echo '(NOT created)')"
echo
echo "Reload Alertmanager so it picks up the webhook URL:"
echo "    docker compose -f compose/docker-compose.yml restart alertmanager"
