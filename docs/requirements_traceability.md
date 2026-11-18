# Requirements traceability

| ID | Requirement | Included location | Remaining production work |
|---|---|---|---|
| UX-01 | New user Start only | Bot keyboard/dispatcher boundary | Persist registration state |
| UX-02 | Register/Login | Auth service boundary | Email provider + secure link |
| UX-03 | Persistent Alerts/Settings | Bot keyboard | Complete callback dispatcher |
| UX-04 | Alerts and exceptions | Mini App screens + notification service boundary | Connect event store |
| UX-05 | Four settings options | Mini App + bot keyboard | Connect settings APIs |
| MINI-01 | Mini App React/TS | frontend/ | Configure public HTTPS hosting |
| MINI-02 | Telegram SDK | frontend/src | Test in Telegram clients |
| MINI-03 | initData validation | app/services/telegram_auth.py | Add tests, rate limits, session store |
| EX-01 | Live/Paper selection | Mini App screen + exchange router boundary | API, DB transaction, active-position guard |
| EX-02 | app_user.paper_testing | Exchange service boundary | Connect existing schema |
| TEN-01 | Tenant isolation | Service boundaries | Tenant-scoped repository/RLS |
| SUB-01 | Plans/entitlements | Plan screen + service boundary | Connect subscription DB |
| PAY-01 | Payment | Service boundary | Gateway checkout + signed webhooks |
| OPS-01 | Async notifications | Celery task boundary | Rate limits, retry_after, dedupe |
| SEC-01 | Webhook security | Telegram route | Verify Telegram secret header config |
| SEC-02 | Credential security | README | KMS/encryption/rotation |
| ADM-01 | Admin console | Not included | Build restricted admin UI/API |
| QA-01 | Acceptance tests | docs/acceptance_criteria.md | Implement automated integration tests |
