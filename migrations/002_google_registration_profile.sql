-- Apply to the DEV database aimycryptov15 only after reviewing the target DB.
-- Existing app_user.password_hash is deliberately unchanged for Streamlit compatibility.
ALTER TABLE public.app_user
    ADD COLUMN IF NOT EXISTS google_sub TEXT,
    ADD COLUMN IF NOT EXISTS full_name TEXT,
    ADD COLUMN IF NOT EXISTS exchange_connection_status VARCHAR(16) NOT NULL DEFAULT 'untested',
    ADD COLUMN IF NOT EXISTS exchange_verified_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS telegram_connection_status VARCHAR(16) NOT NULL DEFAULT 'untested',
    ADD COLUMN IF NOT EXISTS telegram_verified_at TIMESTAMPTZ;

CREATE UNIQUE INDEX IF NOT EXISTS uq_app_user_google_sub
    ON public.app_user (google_sub)
    WHERE google_sub IS NOT NULL;

CREATE INDEX IF NOT EXISTS ix_user_session_active_user_expiry
    ON public.user_session (user_id, expires_at);
