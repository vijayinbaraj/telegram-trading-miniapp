import hashlib
import hmac
import json
import time
from urllib.parse import parse_qsl
from app.config import settings

def validate_init_data(init_data: str):
    if not settings.telegram_bot_token or not init_data:
        return None
    try:
        values = {}
        for key, value in parse_qsl(init_data, keep_blank_values=True, strict_parsing=True):
            if key in values:
                return None
            values[key] = value
        received_hash = values.pop("hash", None)
        if not received_hash:
            return None
        auth_date = int(values.get("auth_date", "0"))
        now = int(time.time())
        if auth_date <= 0 or auth_date > now + 30:
            return None
        if now - auth_date > settings.telegram_initdata_max_age_seconds:
            return None
        check_string = "\n".join(f"{k}={v}" for k, v in sorted(values.items()))
        secret = hmac.new(b"WebAppData", settings.telegram_bot_token.encode(), hashlib.sha256).digest()
        expected = hmac.new(secret, check_string.encode(), hashlib.sha256).hexdigest()
        if not hmac.compare_digest(expected, received_hash):
            return None
        user = json.loads(values.get("user", "{}"))
        if not user.get("id"):
            return None
        return {"telegram_user_id": int(user["id"]),
                "first_name": str(user.get("first_name", ""))[:128],
                "username": user.get("username")}
    except (ValueError, TypeError, json.JSONDecodeError):
        return None
