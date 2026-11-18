import hashlib
import hmac
import json
import time
import httpx
from fastapi import HTTPException
from app.db import get_conn, fetch_one

COINDCX_BASE = "https://api.coindcx.com"


def save_profile_credentials(user: dict, api_key: str | None, api_secret: str | None,
                             telegram_token: str | None):
    if bool(api_key) != bool(api_secret):
        raise HTTPException(400, "Enter both CoinDCX API key and API secret, or leave both blank")
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """UPDATE app_user SET
                   coindcx_api_key=CASE WHEN %s IS NULL THEN coindcx_api_key ELSE NULLIF(%s,'') END,
                   coindcx_api_secret=CASE WHEN %s IS NULL THEN coindcx_api_secret ELSE NULLIF(%s,'') END,
                   telegram_token=CASE WHEN %s IS NULL THEN telegram_token ELSE NULLIF(%s,'') END,
                   exchange_connection_status=CASE WHEN %s IS NULL AND %s IS NULL THEN exchange_connection_status ELSE 'untested' END,
                   exchange_verified_at=CASE WHEN %s IS NULL AND %s IS NULL THEN exchange_verified_at ELSE NULL END,
                   telegram_connection_status=CASE WHEN %s IS NULL THEN telegram_connection_status ELSE 'untested' END,
                   telegram_verified_at=CASE WHEN %s IS NULL THEN telegram_verified_at ELSE NULL END
                   WHERE id=%s AND tenant_id=%s""",
                (api_key, api_key, api_secret, api_secret, telegram_token, telegram_token,
                 api_key, api_secret, api_key, api_secret, telegram_token, telegram_token,
                 user["id"], user["tenant_id"]),
            )
            conn.commit()
    return get_profile(user)


def get_profile(user: dict):
    row = fetch_one(
        """SELECT id,email,full_name,telegram_chat_id,paper_testing,
                  coindcx_api_key,telegram_token,
                  exchange_connection_status,exchange_verified_at,
                  telegram_connection_status,telegram_verified_at
           FROM app_user WHERE id=%s AND tenant_id=%s""",
        (user["id"], user["tenant_id"]),
    )
    if not row:
        raise HTTPException(404, "Profile not found")
    key = row.get("coindcx_api_key") or ""
    token = row.get("telegram_token") or ""
    return {
        "id": row["id"], "email": row["email"], "full_name": row.get("full_name"),
        "telegram_chat_id": str(row["telegram_chat_id"]),
        "paper_testing": bool(row["paper_testing"]),
        "coindcx_api_key_masked": (key[:4] + "••••••" + key[-4:]) if len(key) > 8 else ("••••" if key else ""),
        "telegram_bot_configured": bool(token),
        "exchange_connection_status": row.get("exchange_connection_status") or "untested",
        "exchange_verified_at": row.get("exchange_verified_at"),
        "telegram_connection_status": row.get("telegram_connection_status") or "untested",
        "telegram_verified_at": row.get("telegram_verified_at"),
    }


async def test_telegram_connection(user: dict):
    row = fetch_one("SELECT telegram_token,telegram_chat_id FROM app_user WHERE id=%s AND tenant_id=%s",
                    (user["id"], user["tenant_id"]))
    token, chat_id = row["telegram_token"], row["telegram_chat_id"]
    if not token:
        raise HTTPException(400, "Configure your Telegram bot token first")
    base = f"https://api.telegram.org/bot{token}"
    status = "failed"
    try:
        async with httpx.AsyncClient(timeout=12) as client:
            me = await client.get(f"{base}/getMe")
            me.raise_for_status()
            data = me.json()
            if not data.get("ok"):
                raise ValueError("Telegram rejected the bot token")
            bot_name = data.get("result", {}).get("username", "configured bot")
            sent = await client.post(f"{base}/sendMessage", json={
                "chat_id": str(chat_id),
                "text": f"Telegram connectivity test successful. Bot: @{bot_name}"
            })
            sent.raise_for_status()
            if not sent.json().get("ok"):
                raise ValueError("Telegram could not deliver the test message. Start your customer bot first.")
            status = "connected"
        with get_conn() as conn:
            with conn.cursor() as cur:
                cur.execute("UPDATE app_user SET telegram_connection_status='connected',telegram_verified_at=NOW() WHERE id=%s AND tenant_id=%s",
                            (user["id"], user["tenant_id"]))
                conn.commit()
        return {"ok": True, "status": status, "message": "Test message delivered to your Telegram account."}
    except HTTPException:
        raise
    except Exception as exc:
        with get_conn() as conn:
            with conn.cursor() as cur:
                cur.execute("UPDATE app_user SET telegram_connection_status='failed',telegram_verified_at=NULL WHERE id=%s AND tenant_id=%s",
                            (user["id"], user["tenant_id"]))
                conn.commit()
        raise HTTPException(502, "Telegram connectivity test failed. Verify the bot token and confirm that you have started your customer bot.")


async def test_coindcx_connection(user: dict):
    row = fetch_one("SELECT coindcx_api_key,coindcx_api_secret FROM app_user WHERE id=%s AND tenant_id=%s",
                    (user["id"], user["tenant_id"]))
    api_key, api_secret = row["coindcx_api_key"], row["coindcx_api_secret"]
    if not api_key or not api_secret:
        raise HTTPException(400, "CoinDCX API key and API secret are both required for Live trading")
    body = {"timestamp": int(time.time() * 1000)}
    payload = json.dumps(body, separators=(",", ":"))
    signature = hmac.new(api_secret.encode(), payload.encode(), hashlib.sha256).hexdigest()
    try:
        async with httpx.AsyncClient(timeout=15) as client:
            response = await client.request(
                "GET", f"{COINDCX_BASE}/exchange/v1/derivatives/futures/wallets",
                content=payload,
                headers={"Content-Type": "application/json", "X-AUTH-APIKEY": api_key,
                         "X-AUTH-SIGNATURE": signature},
            )
        if response.status_code >= 400:
            raise ValueError(f"CoinDCX returned HTTP {response.status_code}")
        data = response.json()
        if isinstance(data, dict) and (data.get("status") == "error" or data.get("code", 200) not in (200, "200")):
            raise ValueError(str(data.get("message") or "CoinDCX authentication failed"))
        if not isinstance(data, list):
            raise ValueError("CoinDCX returned an unexpected Futures wallet response")
        with get_conn() as conn:
            with conn.cursor() as cur:
                cur.execute("UPDATE app_user SET exchange_connection_status='connected',exchange_verified_at=NOW() WHERE id=%s AND tenant_id=%s",
                            (user["id"], user["tenant_id"]))
                conn.commit()
        return {"ok": True, "status": "connected", "message": "CoinDCX Futures authenticated connectivity verified."}
    except Exception as exc:
        with get_conn() as conn:
            with conn.cursor() as cur:
                cur.execute("UPDATE app_user SET exchange_connection_status='failed',exchange_verified_at=NULL WHERE id=%s AND tenant_id=%s",
                            (user["id"], user["tenant_id"]))
                conn.commit()
        raise HTTPException(502, "CoinDCX Futures connectivity test failed. Verify the API key, API secret and Futures API permissions.")
