from app.config import settings
from app.db import fetch_one

class ExchangeRouter:
    def __init__(self, live_adapter, paper_adapter):
        self.live_adapter = live_adapter
        self.paper_adapter = paper_adapter

    def for_user(self, user):
        # Exchange choice is read from the authenticated app_user record.
        if bool(user.get("paper_testing")):
            return self.paper_adapter
        if not settings.live_trading_enabled:
            raise RuntimeError("Live trading is disabled by deployment configuration")
        # Do not trust credential or verification flags supplied by the caller.
        live_state = fetch_one(
            """SELECT coindcx_api_key,coindcx_api_secret,exchange_connection_status,exchange_verified_at
               FROM app_user WHERE id=%s AND tenant_id=%s AND is_active=TRUE""",
            (user["id"], user["tenant_id"]),
        )
        if (not live_state or not live_state["coindcx_api_key"] or
                not live_state["coindcx_api_secret"] or
                live_state["exchange_connection_status"] != "connected" or
                not live_state["exchange_verified_at"]):
            raise RuntimeError("Live trading requires CoinDCX API key, API secret and a successful connectivity test")
        return self.live_adapter

# Existing live/paper adapters are integrated by the calling platform service.
