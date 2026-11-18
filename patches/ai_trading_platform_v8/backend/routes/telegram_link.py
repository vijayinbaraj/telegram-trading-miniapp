import hashlib
import secrets
from datetime import datetime, timedelta, timezone
from fastapi import APIRouter, Depends
from backend.auth.deps import get_current_user
from backend.core.db import get_conn

router = APIRouter(prefix="/telegram", tags=["telegram-link"])

@router.post("/link-code")
def create_telegram_link_code(user=Depends(get_current_user)):
    code = f"{secrets.randbelow(100_000_000):08d}"
    digest = hashlib.sha256(code.encode()).hexdigest()
    expires = datetime.now(timezone.utc) + timedelta(minutes=10)
    with get_conn() as conn, conn.cursor() as cur:
        cur.execute("UPDATE telegram_link_codes SET consumed_at=NOW() WHERE user_id=%s AND consumed_at IS NULL",
                    (user["id"],))
        cur.execute("INSERT INTO telegram_link_codes(user_id,code_hash,expires_at) VALUES (%s,%s,%s)",
                    (user["id"],digest,expires))
        conn.commit()
    return {"code":code,"expires_in_seconds":600,
            "instruction":"Send /link CODE to your Trading Bot in Telegram."}
