
#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$HOME/final_code/02_Crypto_app/DEV/telegram_trading_bot_miniapp"

cd "$PROJECT_DIR"

echo "========================================"
echo " TELEGRAM MINI APP - DEV SHUTDOWN"
echo "========================================"

# Stop only the containers belonging to this project
echo
echo "Stopping Telegram Mini App services..."

docker compose stop miniapp telegram-api telegram-worker

echo
echo "Checking remaining service status..."

docker compose ps

echo
echo "========================================"
echo " DEV ENVIRONMENT STOPPED"
echo "========================================"
echo "Docker services stopped."
echo "Cloudflare tunnels must be stopped separately"
echo "if they were started in independent terminals."
echo "========================================"
