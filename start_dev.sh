
#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$HOME/final_code/02_Crypto_app/DEV/telegram_trading_bot_miniapp"
cd "$PROJECT_DIR"

LOG_DIR="$(mktemp -d)"
API_LOG="$LOG_DIR/api-tunnel.log"
APP_LOG="$LOG_DIR/app-tunnel.log"

API_PID=""
APP_PID=""

cleanup() {
    local exit_code=$?
    trap - EXIT INT TERM

    echo
    echo "Stopping Cloudflare tunnels..."

    [[ -n "$API_PID" ]] && kill "$API_PID" 2>/dev/null || true
    [[ -n "$APP_PID" ]] && kill "$APP_PID" 2>/dev/null || true

    [[ -n "$API_PID" ]] && wait "$API_PID" 2>/dev/null || true
    [[ -n "$APP_PID" ]] && wait "$APP_PID" 2>/dev/null || true

    if [[ "$exit_code" -ne 0 ]]; then
        echo "Script exited with status $exit_code."
        echo "Cloudflare logs retained at: $LOG_DIR"
        [[ -f "$API_LOG" ]] && { echo "--- API tunnel log ---"; tail -n 40 "$API_LOG"; }
        [[ -f "$APP_LOG" ]] && { echo "--- Mini App tunnel log ---"; tail -n 40 "$APP_LOG"; }
    else
        rm -rf "$LOG_DIR"
    fi

    echo "Tunnels stopped. Docker containers were left running."
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

update_env() {
    python3 - "$PROJECT_DIR/.env" "$1" "$2" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
key = sys.argv[2]
value = sys.argv[3]

lines = path.read_text().splitlines() if path.exists() else []
prefix = key + "="

lines = [line for line in lines if not line.startswith(prefix)]
lines.append(f"{key}={value}")

path.write_text("\n".join(lines) + "\n")
print(f"Updated {key}")
PY
}

wait_for_local() {
    local url="$1"
    local label="$2"

    echo "Waiting for $label..."

    for i in $(seq 1 60); do
        if curl -fsS --max-time 5 "$url" >/dev/null 2>&1; then
            echo "$label is ready."
            return 0
        fi
        sleep 2
    done

    fail "$label did not become ready: $url"
}

wait_for_public() {
    local url="$1"
    local label="$2"
    local code=""

    echo "Waiting for public $label..."

    for i in $(seq 1 40); do
        code="$(curl -sS -o /dev/null -w "%{http_code}" --max-time 10 "$url" 2>/dev/null || true)"

        if [[ "$code" == "200" ]]; then
            echo "$label publicly accessible: HTTP 200"
            return 0
        fi

        echo "Attempt $i/40: HTTP ${code:-connection error}; retrying..."
        sleep 3
    done

    fail "$label did not become publicly accessible. Last HTTP status: ${code:-unknown}"
}

start_tunnel() {
    local port="$1"
    local logfile="$2"
    local label="$3"

    echo "Starting $label Cloudflare tunnel..."

    cloudflared tunnel --no-autoupdate \
        --url "http://localhost:$port" \
        >"$logfile" 2>&1 &

    local pid=$!
    local url=""
    local registered=0

    for i in $(seq 1 90); do
        url="$(grep -oE 'https://[a-zA-Z0-9-]+\.trycloudflare\.com' "$logfile" | head -n 1 || true)"

        if grep -q 'Registered tunnel connection' "$logfile"; then
            registered=1
        fi

        if [[ -n "$url" && "$registered" -eq 1 ]]; then
            echo "$label tunnel registered."
            echo "$label URL: $url"
            echo "$pid"
            echo "$url"
            return 0
        fi

        if ! kill -0 "$pid" 2>/dev/null; then
            cat "$logfile"
            fail "$label Cloudflare tunnel stopped unexpectedly."
        fi

        sleep 2
    done

    cat "$logfile"
    fail "Timed out waiting for $label Cloudflare URL."
}

echo "========================================"
echo " TELEGRAM MINI APP - DEV STARTUP"
echo "========================================"

command -v docker >/dev/null || fail "Docker not installed."
command -v cloudflared >/dev/null || fail "cloudflared not installed."
command -v curl >/dev/null || fail "curl not installed."
command -v python3 >/dev/null || fail "python3 not installed."

[[ -f .env ]] || fail ".env file missing."
[[ -f docker-compose.yml || -f compose.yaml || -f compose.yml || -f docker-compose.yaml ]] \
    || fail "Docker Compose file not found."

[[ -f scripts/set_webhook.sh ]] || fail "scripts/set_webhook.sh missing."

# 1. Start API and worker
echo
echo "STEP 1: Starting Docker API and worker..."

docker compose up -d telegram-api telegram-worker

wait_for_local "http://localhost:11010/health/live" "Local API"

# 2. Start API tunnel
echo
echo "STEP 2: Starting API tunnel..."

API_RESULT="$(start_tunnel 11010 "$API_LOG" "API")"
API_PID="$(echo "$API_RESULT" | tail -n 2 | head -n 1)"
API_URL="$(echo "$API_RESULT" | tail -n 1)"

update_env "PUBLIC_BASE_URL" "$API_URL"
update_env "VITE_API_BASE_URL" "$API_URL"

# 3. Restart API and worker with updated environment
echo
echo "STEP 3: Reloading API configuration..."

docker compose up -d --force-recreate telegram-api telegram-worker

wait_for_local "http://localhost:11010/health/live" "Updated API"

# 4. Build frontend with the current API URL
echo
echo "STEP 4: Building Mini App with current API URL..."

docker compose build miniapp

# 5. Start Mini App
echo
echo "STEP 5: Starting Mini App..."

docker compose up -d miniapp

wait_for_local "http://localhost:8080/" "Local Mini App"

# 6. Start Mini App tunnel
echo
echo "STEP 6: Starting Mini App tunnel..."

APP_RESULT="$(start_tunnel 8080 "$APP_LOG" "Mini App")"
APP_PID="$(echo "$APP_RESULT" | tail -n 2 | head -n 1)"
APP_URL="$(echo "$APP_RESULT" | tail -n 1)"

update_env "MINI_APP_URL" "$APP_URL"

# 7. Reload API with final configuration
echo
echo "STEP 7: Reloading API with Mini App URL..."

docker compose up -d --force-recreate telegram-api telegram-worker

wait_for_local "http://localhost:11010/health/live" "Final API"

# 8. Test public URLs
echo
echo "STEP 8: Testing public URLs..."

wait_for_public "$API_URL/health/live" "Public API"
wait_for_public "$APP_URL/" "Public Mini App"

# 9. Configure Telegram webhook
echo
echo "STEP 9: Configuring Telegram webhook..."

set -a
source .env
set +a

bash scripts/set_webhook.sh

echo
echo "========================================"
echo " DEV ENVIRONMENT READY"
echo "========================================"
echo "API URL:     $API_URL"
echo "Mini App:    $APP_URL"
echo "API Docs:    $API_URL/docs"
echo
echo "Keep this terminal open while testing."
echo "Press Ctrl+C to stop the tunnels."
echo "Docker containers will remain running."
echo "========================================"

# Keep script alive while tunnels are running
while kill -0 "$API_PID" 2>/dev/null && kill -0 "$APP_PID" 2>/dev/null; do
    sleep 5
done

fail "A Cloudflare tunnel stopped unexpectedly."
