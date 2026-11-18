# Deployment checklist

- [ ] Public HTTPS domain for Mini App and API.
- [ ] Set Telegram bot menu button or web_app inline button to Mini App URL.
- [ ] Configure BotFather domain and allowed HTTPS origin as required.
- [ ] Store secrets in protected environment/secret manager.
- [ ] Validate Telegram Mini App initData server-side; issue short-lived app session.
- [ ] Add authenticated dependencies to all protected Mini App routes.
- [ ] Configure PostgreSQL migrations, backups and restore tests.
- [ ] Configure Redis/Celery workers and exactly one Beat scheduler.
- [ ] Configure Telegram webhook secret header.
- [ ] Add structured logs, metrics, tracing and error monitoring.
- [ ] Add rate limiting, request size limits and idempotency.
- [ ] Test Android, iOS and Telegram Desktop.
- [ ] Load test expected order and notification event rates.
- [ ] Keep live trading disabled until exchange and risk tests pass.
