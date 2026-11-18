# Telegram Trading Bot + Mini App — Integrated scaffold v0.4

Adapted to the supplied five-project backend. Runs beside `ai_trading_platform_v8` and uses
existing `aimycryptov15` PostgreSQL and Redis network. It does not create a second customer
database or Redis service.

## Features
- Google ID-token registration and login bound to validated Telegram Mini App identity.
- Seven-day database-backed sessions; session tokens are stored as SHA-256 digests.
- Registration stores Google subject, verified email, name, Telegram ID and `paper_testing` in `app_user`.
- Existing Streamlit `/auth/register` and `/auth/login` routes and `password_hash` column are not modified.
- Telegram bot keyboard states: Register + Login; Login only; Dashboard + Alerts.
- Profile supports optional CoinDCX API credentials and optional customer Telegram bot token.
- Profile connectivity tests verify CoinDCX authentication and Telegram bot delivery.
- Live exchange adapter selection is blocked unless deployment enables Live, both CoinDCX credentials exist, and a successful connectivity test is recorded.
- Protected dashboard, alerts and alert preferences retained.

## Integration
Main platform: `ai_trading_platform_v8` (port 8009).
Telegram API: port 8010.
PostgreSQL: existing `aimycryptov15`.
Redis: existing Docker network `ai_trading_network`.

## Setup
1. Review `migrations/002_google_registration_profile.sql` and apply it to `aimycryptov15`.
2. Copy `.env.example` to `.env`; set a strong `APP_SECRET_KEY`, DB password, platform bot token, webhook secret, Google OAuth client ID and HTTPS URLs.
3. Set the same Google OAuth client ID as `VITE_GOOGLE_CLIENT_ID` in the frontend build environment.
4. Configure Google Identity Services with the authorized JavaScript origin for the Mini App domain.
5. Confirm Docker network is named `ai_trading_network`.
6. Build and start API, worker and frontend.
7. Configure Telegram webhook at `/telegram/webhook` with the configured `secret_token`.
8. Test first-time registration, existing-account Google linking (email + Telegram ID must both match), seven-day sessions, logout and bot keyboard transitions.
9. Configure optional CoinDCX credentials and test connectivity. Configure an optional customer Telegram bot and test delivery (customer must first press Start on that bot).

## Security
Never ask users to send passwords or exchange API secrets in Telegram.
`app_user.paper_testing` is the exchange-mode source of truth. Live mode remains disabled by
deployment configuration. Existing legacy auth stores and compares plaintext passwords; harden
it before public exposure. Existing wallet and plan routes are not called. Exchange switching
returns HTTP 503 until the live and paper active-order/position guard is implemented.

This is an integration scaffold. Live order execution and exchange switching remain disabled until the existing order/position safety adapters are integrated and independently tested.


### Registration tenant

Set `DEFAULT_TENANT_ID=110` in `.env` for the current CoinDCX client onboarding. New registrations use this active tenant; existing users are not moved. When additional exchanges are introduced, this setting can be changed or replaced with an explicit exchange-to-tenant selection flow.
