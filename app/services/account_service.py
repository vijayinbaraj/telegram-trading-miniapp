import hashlib
import secrets
from fastapi import HTTPException
from app.db import get_conn, fetch_all, fetch_one
from app.config import settings


def find_linked_user(telegram_user_id: int):
    rows = fetch_all(
        """SELECT id,email,tenant_id,telegram_chat_id,paper_testing,is_active,google_sub,full_name
           FROM app_user WHERE telegram_chat_id::text=%s LIMIT 2""",
        (str(telegram_user_id),),
    )
    return rows[0] if len(rows) == 1 else None


def registration_status(telegram_user_id: int) -> dict:
    rows = fetch_all(
        "SELECT id,is_active,google_sub FROM app_user WHERE telegram_chat_id::text=%s LIMIT 2",
        (str(telegram_user_id),),
    )
    if len(rows) > 1:
        return {"status": "blocked"}
    if not rows:
        return {"status": "unregistered"}
    if not rows[0]["is_active"]:
        return {"status": "inactive"}
    return {"status": "login"}


def _registration_tenant(cur) -> int:
    # New customers use the configured tenant. Currently DEFAULT_TENANT_ID=110
    # (CoinDCX); this can change when additional exchange tenants are introduced.
    # Never create a tenant or silently fall back to another tenant.
    tenant_id = settings.default_tenant_id
    cur.execute("SELECT id,status FROM tenant WHERE id=%s FOR SHARE", (tenant_id,))
    row = cur.fetchone()
    if not row:
        raise HTTPException(500, f"Registration tenant {tenant_id} is not configured")
    if row[1] != "active":
        raise HTTPException(403, f"Registration tenant {tenant_id} is inactive")
    return row[0]



# Password authentication for the Mini App. PBKDF2-HMAC-SHA256 is provided by
# Python's standard library; no extra runtime dependency is required.
_PASSWORD_ITERATIONS = 310_000


def _hash_password(password: str) -> str:
    """
    TEMPORARY: store the password as plain text to match the existing
    legacy app_user authentication route. Replace with a one-way password
    hash after the Mini App login flow has been verified.
    """
    return password.strip()


def _verify_password(password: str, stored_value: str) -> bool:
    """
    Temporary compatibility:
    - New Mini App registrations: plain-text password_hash.
    - Existing legacy accounts: plain-text password_hash.
    - Earlier Mini App test accounts: PBKDF2 hashes remain verifiable.
    """
    if not password or not stored_value:
        return False

    if stored_value.startswith("pbkdf2_sha256$"):
        try:
            algorithm, iterations, salt_hex, digest_hex = stored_value.split("$", 3)
            if algorithm != "pbkdf2_sha256":
                return False
            rounds = int(iterations)
            if rounds < 100_000 or rounds > 2_000_000:
                return False
            expected = bytes.fromhex(digest_hex)
            actual = hashlib.pbkdf2_hmac(
                "sha256", password.encode("utf-8"), bytes.fromhex(salt_hex), rounds
            )
            return secrets.compare_digest(actual, expected)
        except (ValueError, TypeError, AttributeError):
            return False

    return secrets.compare_digest(password.strip(), stored_value.strip())


def register_password_customer(
    email: str, password: str, telegram_user_id: int, paper_testing: bool
):
    """Create a Gmail/password account linked to the verified Telegram identity."""
    normalized_email = email.strip().lower()
    telegram_id = str(telegram_user_id)
    password_hash = _hash_password(password)

    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """SELECT id FROM app_user
                   WHERE LOWER(email)=%s OR telegram_chat_id::text=%s
                   FOR UPDATE""",
                (normalized_email, telegram_id),
            )
            if cur.fetchone():
                raise HTTPException(
                    409,
                    "An account already exists for this Gmail address or Telegram account. Please log in or contact support.",
                )
            tenant_id = _registration_tenant(cur)
            cur.execute(
                """INSERT INTO app_user
                   (tenant_id,email,password_hash,role,is_active,telegram_chat_id,paper_testing,google_sub)
                   VALUES (%s,%s,%s,'user',TRUE,%s,%s,NULL)
                   RETURNING id,email,tenant_id,telegram_chat_id,paper_testing,is_active,google_sub,full_name""",
                (
                    tenant_id, normalized_email, password_hash, telegram_id,
                    bool(paper_testing),
                ),
            )
            row = cur.fetchone()
            conn.commit()
    columns = [
        "id", "email", "tenant_id", "telegram_chat_id", "paper_testing",
        "is_active", "google_sub", "full_name",
    ]
    return dict(zip(columns, row))


def login_password_customer(email: str, password: str, telegram_user_id: int):
    """Authenticate only when Gmail and the verified Telegram identity match."""
    normalized_email = email.strip().lower()
    row = fetch_one(
        """SELECT id,email,tenant_id,telegram_chat_id,paper_testing,is_active,
                  google_sub,full_name,password_hash
           FROM app_user WHERE LOWER(email)=%s""",
        (normalized_email,),
    )
    if not row:
        raise HTTPException(401, "Invalid Gmail address or password.")
    if str(row["telegram_chat_id"]) != str(telegram_user_id):
        raise HTTPException(
            403,
            "This Gmail address is not linked to the Telegram account that opened the Mini App.",
        )
    if not row["is_active"]:
        raise HTTPException(403, "Your account is inactive. Contact support.")
    if not _verify_password(password, row.get("password_hash") or ""):
        raise HTTPException(
            401,
            "Invalid Gmail address or password. If this account was created with Google, continue with Google.",
        )
    row.pop("password_hash", None)
    return row


def register_google_customer(google: dict, telegram_user_id: int, paper_testing: bool):
    """Register only new identities. Existing app_user password_hash stays NOT NULL."""
    telegram_id = str(telegram_user_id)
    # Legacy Streamlit compares the submitted password with this column. A random
    # digest is intentionally not a usable customer password and does not change that API.
    unusable_password_value = hashlib.sha256(secrets.token_urlsafe(64).encode()).hexdigest()
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT id FROM app_user WHERE google_sub=%s OR LOWER(email)=%s OR telegram_chat_id=%s FOR UPDATE",
                        (google["google_sub"], google["email"], telegram_id))
            if cur.fetchone():
                raise HTTPException(409, "An account already exists for this Google email or Telegram account. Please use Login or contact support.")
            tenant_id = _registration_tenant(cur)
            cur.execute(
                """INSERT INTO app_user
                   (tenant_id,email,password_hash,role,is_active,telegram_chat_id,paper_testing,google_sub,full_name)
                   VALUES (%s,%s,%s,'user',TRUE,%s,%s,%s,%s) RETURNING id,email,tenant_id,telegram_chat_id,paper_testing,is_active,google_sub,full_name""",
                (tenant_id, google["email"], unusable_password_value, telegram_id,
                 bool(paper_testing), google["google_sub"], google.get("full_name") or None),
            )
            row = cur.fetchone()
            conn.commit()
    return dict(zip(["id","email","tenant_id","telegram_chat_id","paper_testing","is_active","google_sub","full_name"], row))


def login_google_customer(google: dict, telegram_user_id: int):
    row = fetch_one(
        """SELECT id,email,tenant_id,telegram_chat_id,paper_testing,is_active,google_sub,full_name
           FROM app_user WHERE google_sub=%s""", (google["google_sub"],))
    if not row:
        # Existing Streamlit customers may link Google only when BOTH independently
        # verified identities match the existing row: verified Google email + Telegram initData ID.
        existing = fetch_one(
            "SELECT id,email,tenant_id,telegram_chat_id,paper_testing,is_active,google_sub,full_name "
            "FROM app_user WHERE LOWER(email)=%s AND telegram_chat_id::text=%s",
            (google["email"], str(telegram_user_id)),
        )
        if existing and existing["is_active"] and not existing.get("google_sub"):
            with get_conn() as conn:
                with conn.cursor() as cur:
                    cur.execute(
                        "UPDATE app_user SET google_sub=%s, full_name=COALESCE(NULLIF(full_name,''),%s) "
                        "WHERE id=%s AND google_sub IS NULL",
                        (google["google_sub"], google.get("full_name") or None, existing["id"]),
                    )
                    if cur.rowcount != 1:
                        raise HTTPException(409, "Google account was linked concurrently. Please try Login again.")
                    conn.commit()
            existing["google_sub"] = google["google_sub"]
            existing["full_name"] = existing.get("full_name") or google.get("full_name")
            return existing
        if existing and not existing["is_active"]:
            raise HTTPException(403, "Your account is inactive. Contact support.")
        email_row = fetch_one("SELECT id FROM app_user WHERE LOWER(email)=%s", (google["email"],))
        if email_row:
            raise HTTPException(403, "This email belongs to an account linked to a different Telegram identity. Contact support.")
        raise HTTPException(404, "No registered account found. Please Register first.")
    if not row["is_active"]:
        raise HTTPException(403, "Your account is inactive. Contact support.")
    if str(row["telegram_chat_id"]) != str(telegram_user_id):
        raise HTTPException(403, "This Google account is not linked to the Telegram account that opened the Mini App.")
    return row
