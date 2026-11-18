-- Apply once to the existing aimycryptov15 database.
CREATE TABLE IF NOT EXISTS telegram_link_codes (
    id BIGSERIAL PRIMARY KEY,
    user_id INTEGER NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,
    code_hash CHAR(64) NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL,
    consumed_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS ix_telegram_link_codes_pending
    ON telegram_link_codes(code_hash,expires_at) WHERE consumed_at IS NULL;

CREATE TABLE IF NOT EXISTS telegram_notification_preferences (
    tenant_id INTEGER NOT NULL,
    user_id INTEGER NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,
    trading_alerts BOOLEAN NOT NULL DEFAULT TRUE,
    exceptions BOOLEAN NOT NULL DEFAULT TRUE,
    account_notifications BOOLEAN NOT NULL DEFAULT TRUE,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (tenant_id,user_id)
);

CREATE TABLE IF NOT EXISTS telegram_notification_events (
    id BIGSERIAL PRIMARY KEY,
    tenant_id INTEGER NOT NULL,
    user_id INTEGER NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,
    event_type VARCHAR(32) NOT NULL,
    title TEXT NOT NULL,
    message TEXT NOT NULL,
    dedupe_key VARCHAR(200),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    read_at TIMESTAMPTZ
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_telegram_notification_event_dedupe
    ON telegram_notification_events(tenant_id,user_id,dedupe_key)
    WHERE dedupe_key IS NOT NULL;
