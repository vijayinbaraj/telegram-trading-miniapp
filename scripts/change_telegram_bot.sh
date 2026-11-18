#!/usr/bin/env bash
set -Eeuo pipefail

# Update Telegram bot profile, credentials, webhook secret, and Docker services.
# Run from anywhere; the project root is detected relative to this script or
# can be supplied with --project-dir.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/compose.yml" || -f "$SCRIPT_DIR/docker-compose.yml" || -f "$SCRIPT_DIR/compose.yaml" || -f "$SCRIPT_DIR/docker-compose.yaml" ]]; then
  PROJECT_DIR="$SCRIPT_DIR"
else
  PROJECT_DIR="$(dirname -- "$SCRIPT_DIR")"
fi
TOKEN=""
BOT_NAME=""
DESCRIPTION=""
SHORT_DESCRIPTION=""
WEBHOOK_URL=""
SKIP_RESTART=0

usage() {
  cat <<'USAGE'
Usage:
  ./change_telegram_bot.sh --token TOKEN --webhook-url URL [options]

Required:
  --token TOKEN                 New BotFather token
  --webhook-url URL             Full HTTPS webhook URL for this bot

Optional:
  --name TEXT                   Bot display name (setMyName)
  --description TEXT            Bot description (setDescription)
  --short-description TEXT      Bot short description (setShortDescription)
  --project-dir DIR             Project directory containing docker-compose.yml and .env
  --skip-restart                Update Telegram + .env, but do not restart Docker
  -h, --help                    Show this help

Example:
  ./change_telegram_bot.sh \
    --token '123456:NEW_TOKEN' \
    --name 'My Crypto Trading Assistant' \
    --description 'Automated crypto trading platform' \
    --short-description 'Crypto trading assistant' \
    --webhook-url 'https://YOUR-API-DOMAIN/your-existing-webhook-path'

Note: Create the bot and change its @username in @BotFather. This script
updates the display name/descriptions; Telegram does not expose bot creation
or username changes through its Bot API.
USAGE
}

while (($#)); do
  case "$1" in
    --token) TOKEN="${2:?Missing value for --token}"; shift 2 ;;
    --webhook-url) WEBHOOK_URL="${2:?Missing value for --webhook-url}"; shift 2 ;;
    --name) BOT_NAME="${2:?Missing value for --name}"; shift 2 ;;
    --description) DESCRIPTION="${2:?Missing value for --description}"; shift 2 ;;
    --short-description) SHORT_DESCRIPTION="${2:?Missing value for --short-description}"; shift 2 ;;
    --project-dir) PROJECT_DIR="${2:?Missing value for --project-dir}"; shift 2 ;;
    --skip-restart) SKIP_RESTART=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$TOKEN" ]] || { echo 'ERROR: --token is required.' >&2; exit 2; }
[[ -n "$WEBHOOK_URL" ]] || { echo 'ERROR: --webhook-url is required; provide the existing webhook endpoint.' >&2; exit 2; }
[[ "$WEBHOOK_URL" == https://* ]] || { echo 'ERROR: Telegram webhook URL must use HTTPS.' >&2; exit 2; }

PROJECT_DIR="$(cd -- "$PROJECT_DIR" && pwd)"
ENV_FILE="$PROJECT_DIR/.env"
[[ -f "$ENV_FILE" ]] || { echo "ERROR: .env not found at $ENV_FILE" >&2; exit 1; }
command -v curl >/dev/null || { echo 'ERROR: curl is required.' >&2; exit 1; }
command -v python3 >/dev/null || { echo 'ERROR: python3 is required.' >&2; exit 1; }
command -v openssl >/dev/null || { echo 'ERROR: openssl is required.' >&2; exit 1; }

# Validate token and obtain bot identity before changing anything.
API="https://api.telegram.org/bot${TOKEN}"
ME="$(curl --fail --silent --show-error "$API/getMe")" || { echo 'ERROR: Telegram getMe request failed.' >&2; exit 1; }
python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get("ok") and d.get("result",{}).get("is_bot") else 1)' <<<"$ME" || {
  echo 'ERROR: Telegram rejected this token or it is not a bot token.' >&2; exit 1;
}
BOT_USERNAME="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["result"].get("username", "unknown"))' <<<"$ME")"

# Telegram webhook secret_token accepts 1-256 characters from this alphabet.
WEBHOOK_SECRET="$(openssl rand -hex 32)"

telegram_call() {
  local method="$1"; shift
  local response
  response="$(curl --fail --silent --show-error --request POST "$API/$method" "$@")" || {
    echo "ERROR: Telegram API request failed: $method" >&2; exit 1;
  }
  python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get("ok") else 1)' <<<"$response" || {
    echo "ERROR: Telegram API returned an unsuccessful result for $method:" >&2
    python3 -c 'import json,sys; print(json.load(sys.stdin).get("description", "Unknown Telegram API error"))' <<<"$response" >&2
    exit 1
  }
  printf 'OK: %s\n' "$method"
}

[[ -z "$BOT_NAME" ]] || telegram_call setMyName --data-urlencode "name=$BOT_NAME"
[[ -z "$DESCRIPTION" ]] || telegram_call setDescription --data-urlencode "description=$DESCRIPTION"
[[ -z "$SHORT_DESCRIPTION" ]] || telegram_call setShortDescription --data-urlencode "short_description=$SHORT_DESCRIPTION"

telegram_call setWebhook \
  --data-urlencode "url=$WEBHOOK_URL" \
  --data-urlencode "secret_token=$WEBHOOK_SECRET"

# Safely replace/add only these two .env keys; preserve all other settings.
BOT_TOKEN_VALUE="$TOKEN" WEBHOOK_SECRET_VALUE="$WEBHOOK_SECRET" ENV_FILE_PATH="$ENV_FILE" python3 <<'PY'
import os, re, tempfile
from pathlib import Path
p = Path(os.environ['ENV_FILE_PATH'])
updates = {
    'TELEGRAM_BOT_TOKEN': os.environ['BOT_TOKEN_VALUE'],
    'TELEGRAM_WEBHOOK_SECRET': os.environ['WEBHOOK_SECRET_VALUE'],
}
lines = p.read_text().splitlines()
seen = set()
out = []
for line in lines:
    match = re.match(r'^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=', line)
    if match and match.group(1) in updates:
        key = match.group(1)
        if key not in seen:
            out.append(f'{key}={updates[key]}')
            seen.add(key)
    else:
        out.append(line)
for key, value in updates.items():
    if key not in seen:
        out.append(f'{key}={value}')
content = '\n'.join(out) + '\n'
fd, tmp = tempfile.mkstemp(prefix='.env.', dir=str(p.parent))
try:
    with os.fdopen(fd, 'w') as f:
        f.write(content)
    os.chmod(tmp, 0o600)
    os.replace(tmp, p)
finally:
    if os.path.exists(tmp):
        os.unlink(tmp)
PY
chmod 600 "$ENV_FILE"
echo "Updated .env (TELEGRAM_BOT_TOKEN and TELEGRAM_WEBHOOK_SECRET only)."

if ((SKIP_RESTART == 0)); then
  if [[ -f "$PROJECT_DIR/compose.yml" ]]; then COMPOSE_FILE="$PROJECT_DIR/compose.yml"
  elif [[ -f "$PROJECT_DIR/docker-compose.yml" ]]; then COMPOSE_FILE="$PROJECT_DIR/docker-compose.yml"
  elif [[ -f "$PROJECT_DIR/compose.yaml" ]]; then COMPOSE_FILE="$PROJECT_DIR/compose.yaml"
  elif [[ -f "$PROJECT_DIR/docker-compose.yaml" ]]; then COMPOSE_FILE="$PROJECT_DIR/docker-compose.yaml"
  else echo 'ERROR: Docker Compose file not found.' >&2; exit 1; fi

  (cd "$PROJECT_DIR" && docker compose --env-file .env -f "$COMPOSE_FILE" up -d --force-recreate telegram-api telegram-worker)
  echo 'Docker services recreated: telegram-api, telegram-worker.'
fi

# Verify webhook using Telegram's API after registration.
WEBHOOK_INFO="$(curl --fail --silent --show-error "$API/getWebhookInfo")"
WEBHOOK_INFO_VALUE="$WEBHOOK_INFO" EXPECTED_WEBHOOK_URL="$WEBHOOK_URL" python3 <<'PY'
import json, os, sys
expected = os.environ["EXPECTED_WEBHOOK_URL"]
data = json.loads(os.environ["WEBHOOK_INFO_VALUE"])
actual = data.get('result', {}).get('url', '')
if not data.get('ok') or actual != expected:
    print('WARNING: Webhook verification did not match the requested URL.', file=sys.stderr)
    print('Expected:', expected, file=sys.stderr)
    print('Actual:  ', actual, file=sys.stderr)
    sys.exit(1)
print('Webhook verified:', actual)
PY

echo
echo "Bot updated successfully: @${BOT_USERNAME}"
echo 'Keep the new token private. Do not paste it into chat or commit .env.'
