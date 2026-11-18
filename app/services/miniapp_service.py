from fastapi import HTTPException
from app.db import fetch_one, fetch_all

def dashboard(user):
    mode = "PAPER" if bool(user["paper_testing"]) else "LIVE"
    return {
        "exchange": "Paper Exchange" if mode == "PAPER" else "Live CoinDCX",
        "mode": mode, "wallet_balance": None, "open_positions": None,
        "active_orders": None, "unrealized_pnl": None,
        "notice": "Identity is connected. Wallet, positions and orders await verified account-scoped adapters.",
        "email": user["email"],
    }

def get_preferences(user):
    row = fetch_one(
        """SELECT trading_alerts,exceptions,account_notifications
           FROM telegram_notification_preferences WHERE user_id=%s AND tenant_id=%s""",
        (user["id"], user["tenant_id"]))
    return row or {"trading_alerts": True, "exceptions": True, "account_notifications": True}

def save_preferences(user, body):
    allowed = {"trading_alerts", "exceptions", "account_notifications"}
    if set(body) - allowed:
        raise HTTPException(400, "Invalid notification preference fields")
    current = get_preferences(user)
    values = {k: bool(body.get(k, current[k])) for k in allowed}
    from app.db import get_conn
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """INSERT INTO telegram_notification_preferences
                   (tenant_id,user_id,trading_alerts,exceptions,account_notifications,updated_at)
                   VALUES (%s,%s,%s,%s,%s,NOW())
                   ON CONFLICT (tenant_id,user_id) DO UPDATE SET
                   trading_alerts=EXCLUDED.trading_alerts, exceptions=EXCLUDED.exceptions,
                   account_notifications=EXCLUDED.account_notifications, updated_at=NOW()""",
                (user["tenant_id"], user["id"], values["trading_alerts"],
                 values["exceptions"], values["account_notifications"]))
            conn.commit()
    return values

def list_alerts(user, event_type=None):
    return fetch_all(
        """SELECT id,event_type,title,message,created_at,read_at
           FROM telegram_notification_events
           WHERE tenant_id=%s AND user_id=%s AND (%s IS NULL OR event_type=%s)
           ORDER BY created_at DESC LIMIT 50""",
        (user["tenant_id"], user["id"], event_type, event_type))
