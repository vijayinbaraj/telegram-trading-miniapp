# v0.4 Google registration and profile connectivity status

## Implemented in this working copy
- Google ID-token verification (issuer, audience, expiry, verified email).
- Telegram Mini App initData validation and strict Google/Telegram identity binding.
- New `/miniapp/register` and `/miniapp/login` endpoints.
- Existing Streamlit auth routes and `app_user.password_hash` are untouched. Google-only users receive an unusable random digest in the mandatory legacy field.
- Existing Streamlit accounts can link Google only when verified Google email AND Telegram identity both match the existing `app_user` row.
- Seven-day opaque sessions persisted in `user_session`; only SHA-256 token digests are stored.
- Logout revokes the database session.
- Telegram keyboard states are updated after registration, login and logout.
- Profile credential save and Telegram/CoinDCX connectivity test endpoints.
- Live adapter selection checks deployment flag, credentials and successful exchange connectivity status.
- Migration adds Google subject, full name and connectivity status/timestamps. `paper_testing` already exists and is not re-added.

## Required before runtime testing
- Apply `migrations/002_google_registration_profile.sql` to `aimycryptov15`.
- Configure backend `GOOGLE_CLIENT_ID` and frontend `VITE_GOOGLE_CLIENT_ID` with the same Google OAuth client ID.
- Configure `TELEGRAM_BOT_TOKEN`, webhook secret, DB password and a strong application secret.
- Build frontend with the Vite variables.
- Confirm the customer Telegram bot has been started by the customer before testing message delivery.

## Still intentionally disabled / limitations
- Exchange switching remains HTTP 503 until active orders and positions are checked safely.
- The existing exchange adapter is still a scaffold; Live execution must be wired through `ExchangeRouter` and the account-specific CoinDCX adapter.
- The CoinDCX connectivity test uses the authenticated Futures wallets endpoint as a read-only credential test; it does not prove every Futures permission or order permission.
- Existing Streamlit profile endpoints are not modified.
- No MFA in this release.
