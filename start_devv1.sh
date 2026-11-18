#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$HOME/final_code/02_Crypto_app/DEV/telegram_trading_bot_miniapp"
RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp}"
STATE_FILE="$RUNTIME_DIR/telegram_trading_miniapp_${UID}.pids"
LOG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/telegram-miniapp-tunnels.XXXXXX")"
API_LOG="$LOG_DIR/api-tunnel.log"
APP_LOG="$LOG_DIR/app-tunnel.log"

API_PID=""
APP_PID=""
API_URL=""
APP_URL=""

cd "$PROJECT_DIR"

fail() { echo "ERROR: $*" >&2; exit 1; }

cleanup() {
    local exit_code=$?
    trap - EXIT INT TERM
    echo
    echo "Stopping Cloudflare tunnels..."
    for pid in "$API_PID" "$APP_PID"; do
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            kill -TERM "$pid" 2>/dev/null || true
        fi
    done
    for pid in "$API_PID" "$APP_PID"; do
        if [[ -n "$pid" ]]; then wait "$pid" 2>/dev/null || true; fi
    done
    rm -f "$STATE_FILE"
    if [[ "$exit_code" -ne 0 ]]; then
        echo "Startup stopped with status $exit_code. Logs: $LOG_DIR"
        [[ -f "$API_LOG" ]] && { echo "--- API tunnel ---"; tail -n 35 "$API_LOG"; }
        [[ -f "$APP_LOG" ]] && { echo "--- Mini App tunnel ---"; tail -n 35 "$APP_LOG"; }
    else
        rm -rf "$LOG_DIR"
    fi
    echo "Cloudflare tunnels stopped. Docker containers remain running."
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

command -v docker >/dev/null || fail "Docker is not installed."
command -v cloudflared >/dev/null || fail "cloudflared is not installed."
command -v curl >/dev/null || fail "curl is not installed."
command -v python3 >/dev/null || fail "python3 is not installed."
[[ -f "$PROJECT_DIR/.env" ]] || fail "$PROJECT_DIR/.env is missing."

if [[ -e "$STATE_FILE" ]]; then
    old_start_pid="$(awk -F= '$1=="START_PID" {print $2}' "$STATE_FILE" 2>/dev/null || true)"
    if [[ -n "$old_start_pid" ]] && kill -0 "$old_start_pid" 2>/dev/null; then
        fail "A dev startup script is already running (PID $old_start_pid). Run scripts/stop_dev.sh first."
    fi
    rm -f "$STATE_FILE"
fi

update_env() {
    python3 - "$PROJECT_DIR/.env" "$1" "$2" <<'PY'
import sys
from pathlib import Path
p, key, value = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
lines = p.read_text().splitlines()
prefix = key + "="
found = False
out = []
for line in lines:
    if line.startswith(prefix):
        if not found:
            out.append(f"{key}={value}")
            found = True
    else:
        out.append(line)
if not found:
    out.append(f"{key}={value}")
p.write_text("\n".join(out) + "\n")
PY
    echo "Updated .env: $1"
}

wait_for_local() {
    local url="$1" label="$2" code=""
    echo "Waiting for $label..."
    for _ in $(seq 1 60); do
        code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 "$url" 2>/dev/null || true)"
        [[ "$code" == "200" ]] && { echo "$label is ready (HTTP 200)."; return 0; }
        sleep 2
    done
    fail "$label did not become ready at $url (last HTTP ${code:-unavailable})."
}

wait_for_public() {
    local url="$1" label="$2" expected="$3" code=""
    echo "Checking public $label..."
    for _ in $(seq 1 40); do
        code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "$url" 2>/dev/null || true)"
        [[ "$code" == "$expected" ]] && { echo "$label is reachable (HTTP $code)."; return 0; }
        sleep 3
    done
    fail "$label check failed: $url (expected HTTP $expected, got ${code:-connection error})."
}

start_tunnel() {
    local port="$1" logfile="$2" label="$3" pid="" url="" connected=0
    echo "Starting $label Cloudflare Quick Tunnel..."
    cloudflared tunnel --no-autoupdate --url "http://127.0.0.1:$port" >"$logfile" 2>&1 &
    pid=$!
    if [[ "$label" == "API" ]]; then API_PID="$pid"; else APP_PID="$pid"; fi
    for _ in $(seq 1 90); do
        url="$(grep -oE 'https://[A-Za-z0-9-]+\.trycloudflare\.com' "$logfile" | head -n 1 || true)"
        grep -q 'Registered tunnel connection' "$logfile" && connected=1
        if [[ -n "$url" && "$connected" -eq 1 ]]; then
            if [[ "$label" == "API" ]]; then API_URL="$url"; else APP_URL="$url"; fi
            echo "$label tunnel ready: $url"
            write_state
            return 0
        fi
        if ! kill -0 "$pid" 2>/dev/null; then
            tail -n 60 "$logfile" || true
            fail "$label Cloudflare tunnel exited unexpectedly."
        fi
        sleep 2
    done
    tail -n 60 "$logfile" || true
    fail "Timed out waiting for $label Cloudflare tunnel URL."
}

write_state() {
    cat > "$STATE_FILE" <<STATE
START_PID=$$
API_PID=$API_PID
APP_PID=$APP_PID
STATE
    chmod 600 "$STATE_FILE"
}

register_webhook() {
    echo "Registering Telegram webhook..."
    set -a
    # shellcheck disable=SC1091
    source "$PROJECT_DIR/.env"
    set +a
    export EXPECTED_WEBHOOK_URL="$API_URL/telegram/webhook"
    python3 - <<'PY'
import json, os, urllib.parse, urllib.request, urllib.error

token = os.environ.get("TELEGRAM_BOT_TOKEN", "").strip()
secret = os.environ.get("TELEGRAM_WEBHOOK_SECRET", "").strip()
expected_url = os.environ["EXPECTED_WEBHOOK_URL"]
if not token or not secret:
    raise SystemExit("ERROR: TELEGRAM_BOT_TOKEN or TELEGRAM_WEBHOOK_SECRET is missing from .env")
if len(secret) > 256 or not secret.isascii() or not all(c.isalnum() or c in "_-" for c in secret):
    raise SystemExit("ERROR: TELEGRAM_WEBHOOK_SECRET must contain only A-Z, a-z, 0-9, _ or - and be at most 256 characters")

def call(method, data=None):
    url = f"https://api.telegram.org/bot{token}/{method}"
    body = urllib.parse.urlencode(data).encode() if data is not None else None
    req = urllib.request.Request(url, data=body)
    try:
        with urllib.request.urlopen(req, timeout=30) as response:
            result = json.load(response)
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", "replace")
        raise SystemExit(f"Telegram {method} failed (HTTP {e.code}): {detail}")
    if not result.get("ok"):
        raise SystemExit(f"Telegram {method} failed: {result}")
    return result

result = call("setWebhook", {
    "url": expected_url,
    "secret_token": secret,
    "allowed_updates": json.dumps(["message", "callback_query"]),
})
print("setWebhook: SUCCESS" if result.get("result") else "setWebhook returned false")
info = call("getWebhookInfo")["result"]
actual = info.get("url", "")
print("Webhook URL:", actual)
print("Pending updates:", info.get("pending_update_count", 0))
print("Last delivery error:", info.get("last_error_message") or "None")
if actual != expected_url:
    raise SystemExit("ERROR: Telegram reports a different webhook URL")
PY
}

echo "========================================"
echo " TELEGRAM MINI APP - DEV STARTUP"
echo "========================================"

# 1. Start backend services.
echo
echo "STEP 1/9: Starting API and worker..."
docker compose up -d telegram-api telegram-worker
wait_for_local "http://127.0.0.1:11010/health/live" "Local API"

# 2. Start API tunnel and publish its URL to backend/frontend configuration.
echo
echo "STEP 2/9: Starting API tunnel..."
start_tunnel 11010 "$API_LOG" "API"
update_env "PUBLIC_BASE_URL" "$API_URL"
update_env "VITE_API_BASE_URL" "$API_URL"

# 3. Recreate backend so it reads the current public API URL.
echo
echo "STEP 3/9: Reloading API and worker configuration..."
docker compose up -d --force-recreate telegram-api telegram-worker
wait_for_local "http://127.0.0.1:11010/health/live" "Updated API"

# 4. Build frontend with the current API URL.
echo
echo "STEP 4/9: Building Mini App..."
docker compose build miniapp

# 5. Start frontend.
echo
echo "STEP 5/9: Starting Mini App..."
docker compose up -d miniapp
wait_for_local "http://127.0.0.1:8080/" "Local Mini App"

# 6. Start frontend tunnel and update its URL.
echo
echo "STEP 6/9: Starting Mini App tunnel..."
start_tunnel 8080 "$APP_LOG" "Mini App"
update_env "MINI_APP_URL" "$APP_URL"

# 7. Recreate backend so Telegram/Mini App links use the current frontend URL.
echo
echo "STEP 7/9: Reloading backend with Mini App URL..."
docker compose up -d --force-recreate telegram-api telegram-worker
wait_for_local "http://127.0.0.1:11010/health/live" "Final API"

# 8. Verify both public endpoints and webhook route protection.
echo
echo "STEP 8/9: Verifying public endpoints..."
wait_for_public "$API_URL/health/live" "Public API health" "200"
wait_for_public "$APP_URL/" "Public Mini App" "200"
wait_for_public "$API_URL/telegram/webhook" "Webhook route protection" "405"

# 9. Register webhook automatically against the current API tunnel URL.
echo
echo "STEP 9/9: Setting Telegram webhook..."
register_webhook

write_state
echo
echo "========================================"
echo " DEV ENVIRONMENT READY"
echo "========================================"
echo "API URL:       $API_URL"
echo "Mini App URL:  $APP_URL"
echo "Mini App link: $APP_URL"
echo "API Docs:      $API_URL/docs"
echo "Webhook:       $API_URL/telegram/webhook"
echo
echo "Both tunnels are temporary Quick Tunnels."
echo "Keep this terminal open. Press Ctrl+C to stop tunnels."
echo "Docker containers will remain running."
echo "========================================"

while kill -0 "$API_PID" 2>/dev/null && kill -0 "$APP_PID" 2>/dev/null; do sleep 5; done
fail "A Cloudflare tunnel stopped unexpectedly."
