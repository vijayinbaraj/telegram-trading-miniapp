-- Short-lived Google OAuth transactions for Telegram Mini App mobile login.
-- Telegram identity is bound to the transaction after validating initData.
-- The transaction ID, state and polling secret are stored as hashes.

CREATE TABLE IF NOT EXISTS public.mobile_google_oauth_transactions (
    id BIGSERIAL PRIMARY KEY,
    transaction_hash CHAR(64) NOT NULL UNIQUE,
    state_hash CHAR(64) NOT NULL UNIQUE,
    poll_secret_hash CHAR(64) NOT NULL,
    telegram_user_id BIGINT NOT NULL,
    code_verifier TEXT NOT NULL,
    nonce VARCHAR(128) NOT NULL,
    purpose VARCHAR(16) NOT NULL CHECK (purpose IN ('login', 'register')),
    paper_testing BOOLEAN NOT NULL DEFAULT FALSE,
    status VARCHAR(16) NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending', 'processing', 'complete', 'failed', 'consumed')),
    user_id INTEGER REFERENCES public.app_user(id) ON DELETE CASCADE,
    expires_at TIMESTAMPTZ NOT NULL,
    completed_at TIMESTAMPTZ,
    consumed_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS ix_mobile_google_oauth_pending
    ON public.mobile_google_oauth_transactions(expires_at)
    WHERE status IN ('pending', 'processing');

CREATE INDEX IF NOT EXISTS ix_mobile_google_oauth_user
    ON public.mobile_google_oauth_transactions(user_id)
    WHERE user_id IS NOT NULL;
