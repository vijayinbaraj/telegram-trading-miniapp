#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="${PROJECT_DIR:-$HOME/final_code/02_Crypto_app/DEV/telegram_trading_bot_miniapp}"
ENV_FILE="$PROJECT_DIR/.env"

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

[[ -d "$PROJECT_DIR" ]] || fail "Project directory not found: $PROJECT_DIR"
[[ -f "$ENV_FILE" ]] || fail ".env file not found: $ENV_FILE"
command -v python3 >/dev/null 2>&1 || fail "python3 is required."
command -v curl >/dev/null 2>&1 || fail "curl is required."

# Load the project's .env without printing its contents.
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

: "${TELEGRAM_BOT_TOKEN:?TELEGRAM_BOT_TOKEN is missing from .env}"
: "${PUBLIC_BASE_URL:?PUBLIC_BASE_URL is missing from .env}"
: "${TELEGRAM_WEBHOOK_SECRET:?TELEGRAM_WEBHOOK_SECRET is missing from .env}"

# Telegram secret_token accepts 1-256 characters from this character set.
if [[ ! "$TELEGRAM_WEBHOOK_SECRET" =~ ^[A-Za-z0-9_-]{1,256}$ ]]; then
    fail "TELEGRAM_WEBHOOK_SECRET has an invalid format. Use 1-256 characters: A-Z, a-z, 0-9, _ or -."
fi

# Basic URL validation and normalize trailing slash.
if [[ ! "$PUBLIC_BASE_URL" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?$ ]]; then
    fail "PUBLIC_BASE_URL must be an HTTPS base URL without a path."
fi

WEBHOOK_URL="${PUBLIC_BASE_URL%/}/telegram/webhook"
TELEGRAM_API="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}"

printf 'Configuring Telegram webhook: %s\n' "$WEBHOOK_URL"

SET_RESPONSE="$(curl --fail --silent --show-error --max-time 30 \
    -X POST "${TELEGRAM_API}/setWebhook" \
    --data-urlencode "url=${WEBHOOK_URL}" \
    --data-urlencode "secret_token=${TELEGRAM_WEBHOOK_SECRET}")" \
    || fail "Telegram setWebhook request failed. Check internet access and bot configuration."

if ! printf '%s' "$SET_RESPONSE" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    print("ERROR: Telegram returned invalid JSON.")
    sys.exit(1)
if not data.get("ok"):
    print("ERROR: Telegram rejected setWebhook:", data.get("description", "Unknown error"))
    sys.exit(1)
print("Telegram accepted the webhook configuration.")
'; then
    exit 1
fi

INFO_RESPONSE="$(curl --fail --silent --show-error --max-time 30 \
    "${TELEGRAM_API}/getWebhookInfo")" \
    || fail "Could not retrieve Telegram webhook information."

printf '%s' "$INFO_RESPONSE" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    print("ERROR: Telegram returned invalid webhook information.")
    sys.exit(1)
if not data.get("ok"):
    print("ERROR: getWebhookInfo failed:", data.get("description", "Unknown error"))
    sys.exit(1)
result = data.get("result", {})
url = result.get("url", "")
expected = sys.argv[1]
print("Configured webhook URL:", url or "NOT CONFIGURED")
print("Pending updates:", result.get("pending_update_count", 0))
print("Last delivery error:", result.get("last_error_message", "None"))
if url != expected:
    print("ERROR: The configured webhook URL does not match the expected URL.")
    sys.exit(1)
print("Webhook verification successful.")
' "$WEBHOOK_URL"

echo "Telegram webhook is configured and verified."
