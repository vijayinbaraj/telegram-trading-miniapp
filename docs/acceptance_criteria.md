# Acceptance criteria

- Unauthenticated users cannot access customer data or protected Mini App endpoints.
- Backend validates Telegram initData HMAC and rejects stale/invalid data.
- A validated Telegram identity is mapped to an existing or approved app_user and tenant.
- Frontend never decides tenant, subscription entitlement, exchange mode or account balance.
- New user sees Start; authenticated user sees persistent Alerts/Settings bot keyboard.
- Alerts include trading events, exceptions and account notifications.
- Settings include exchange, plan, alert preferences and profile.
- Exchange selection requires confirmation and backend active-order/position checks.
- Live mode is disabled until exchange adapter, credentials and risk checks are tested.
- `paper_testing` is updated transactionally and audited.
- Tenant A cannot read or modify Tenant B records.
- Payment entitlements change only after verified, idempotent provider webhooks.
- Notification delivery is queued, deduplicated, rate-limited and retry-aware.
- Backup restoration and operational alerts are tested before launch.
