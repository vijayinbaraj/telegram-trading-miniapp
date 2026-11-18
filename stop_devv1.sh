#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$HOME/final_code/02_Crypto_app/DEV/telegram_trading_bot_miniapp"
RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp}"
STATE_FILE="$RUNTIME_DIR/telegram_trading_miniapp_${UID}.pids"

cd "$PROJECT_DIR"

echo "========================================"
echo " TELEGRAM MINI APP - DEV SHUTDOWN"
echo "========================================"

START_PID=""
API_PID=""
APP_PID=""
if [[ -f "$STATE_FILE" ]]; then
    # This file is created by start_dev.sh with numeric PID values only.
    START_PID="$(awk -F= '$1=="START_PID" {print $2}' "$STATE_FILE")"
    API_PID="$(awk -F= '$1=="API_PID" {print $2}' "$STATE_FILE")"
    APP_PID="$(awk -F= '$1=="APP_PID" {print $2}' "$STATE_FILE")"
fi

is_pid() { [[ "$1" =~ ^[0-9]+$ ]] && (( "$1" > 1 )); }

if is_pid "$START_PID" && kill -0 "$START_PID" 2>/dev/null; then
    echo "Stopping tunnel supervisor (PID $START_PID)..."
    kill -TERM "$START_PID" 2>/dev/null || true
    for _ in $(seq 1 15); do
        kill -0 "$START_PID" 2>/dev/null || break
        sleep 1
    done
fi

# Fallback cleanup in case the supervisor was already gone or did not reap children.
for pid in "$API_PID" "$APP_PID"; do
    if is_pid "$pid" && kill -0 "$pid" 2>/dev/null; then
        echo "Stopping Cloudflare tunnel (PID $pid)..."
        kill -TERM "$pid" 2>/dev/null || true
    fi
done

rm -f "$STATE_FILE"

echo
echo "Stopping Telegram Mini App Docker services..."
docker compose stop miniapp telegram-api telegram-worker

echo
echo "Remaining project services:"
docker compose ps

echo
echo "========================================"
echo " DEV ENVIRONMENT STOPPED"
echo "========================================"
echo "Cloudflare tunnels and selected Docker services stopped."
echo "Other Docker projects were not touched."
echo "========================================"
