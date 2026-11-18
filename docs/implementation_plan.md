# Implementation plan

## Phase 1 — identity and bot access
Apply migration, add main-platform link-code route, configure webhook, test `/start` and
`/link CODE`, and confirm only the matching `app_user.telegram_chat_id` can authenticate.

## Phase 2 — read-only dashboard
Inspect actual live `nposition`/order schemas and paper exchange API credentials. Build one
account-scoped adapter selected server-side by `app_user.paper_testing`. Never accept
email, user_id, tenant_id, chat_id or exchange mode from Mini App request data.

## Phase 3 — exchange switching
Implement both live and paper active-order/position checks. Lock the app_user row, check
current exchange exposure, refuse if anything is active, update paper_testing, write an audit
event and use an idempotency key. Re-read exchange mode before each exchange operation.

## Phase 4 — notifications
Publish events from price feed, order picker, order manager and paper exchange through one
notification producer. Store deduplicated events and enqueue delivery. Trading modules should
not call Telegram Bot API directly.

## Phase 5 — plans and production
Use verified payment webhooks and server-side entitlements. Do not expose legacy
`/api/plans/activate` as-is.
