
import hashlib
import hmac
import json
import time
from decimal import Decimal, InvalidOperation

import httpx
from fastapi import HTTPException

from app.config import settings
from app.db import fetch_one
from app.services.exchange_router import ExchangeRouter


def _number(value):
    """Safely convert exchange numeric values to Decimal."""
    try:
        return Decimal(str(value if value is not None else "0"))
    except (InvalidOperation, TypeError, ValueError):
        return Decimal("0")


def _extract_records(data, key):
    """Support both list responses and wrapped exchange responses."""
    if isinstance(data, list):
        return data

    if isinstance(data, dict):
        records = data.get(key, [])
        return records if isinstance(records, list) else []

    return []


def _is_nonzero(value):
    return _number(value) != 0


def _paper_credentials(user):
    """
    Read credentials only for the authenticated app_user.
    Never accept an API key, secret, email or chat_id from the frontend.
    """
    row = fetch_one(
        """
        SELECT coindcx_api_key, coindcx_api_secret
        FROM app_user
        WHERE id = %s
          AND tenant_id = %s
          AND is_active = TRUE
        """,
        (user["id"], user["tenant_id"]),
    )

    if not row:
        raise HTTPException(404, "Account not found.")

    api_key = row.get("coindcx_api_key")
    api_secret = row.get("coindcx_api_secret")

    if not api_key or not api_secret:
        raise HTTPException(
            400,
            "Exchange API credentials are not configured for this account.",
        )

    return api_key, api_secret


def _paper_headers(api_key, api_secret, body):
    # The Paper API verifies the signature against the exact JSON bytes.
    raw_body = json.dumps(
        body,
        separators=(",", ":"),
        ensure_ascii=False,
    ).encode("utf-8")

    signature = hmac.new(
        api_secret.encode("utf-8"),
        raw_body,
        hashlib.sha256,
    ).hexdigest()

    return raw_body, {
        "Content-Type": "application/json",
        "X-AUTH-APIKEY": api_key,
        "X-AUTH-SIGNATURE": signature,
    }


class LiveExchangeAdapter:
    def __init__(self):
        self.base_url = settings.live_backend_base_url.rstrip("/")

    async def _get(self, endpoint, user):
        if not user.get("email"):
            raise HTTPException(400, "Authenticated account email is missing.")

        try:
            async with httpx.AsyncClient(timeout=25.0) as client:
                response = await client.get(
                    f"{self.base_url}{endpoint}",
                    params={"email": user["email"]},
                )
                response.raise_for_status()
                return response.json()

        except httpx.TimeoutException:
            raise HTTPException(504, "Live exchange request timed out.")

        except httpx.HTTPStatusError as exc:
            raise HTTPException(
                502,
                f"Live exchange backend returned HTTP {exc.response.status_code}.",
            )

        except httpx.RequestError:
            raise HTTPException(
                502,
                "Unable to connect to the Live exchange backend.",
            )

        except ValueError:
            raise HTTPException(
                502,
                "Live exchange backend returned invalid JSON.",
            )

    async def positions(self, user):
        data = await self._get("/api/wallets/positions", user)
        return _extract_records(data, "positions")

    async def orders(self, user):
        data = await self._get("/api/wallets/orders", user)
        return _extract_records(data, "orders")


class PaperExchangeAdapter:
    def __init__(self):
        self.base_url = settings.paper_exchange_base_url.rstrip("/")

    async def _post(self, endpoint, user, body):
        api_key, api_secret = _paper_credentials(user)
        raw_body, headers = _paper_headers(api_key, api_secret, body)

        try:
            async with httpx.AsyncClient(timeout=25.0) as client:
                response = await client.post(
                    f"{self.base_url}{endpoint}",
                    content=raw_body,
                    headers=headers,
                )
                response.raise_for_status()
                return response.json()

        except httpx.TimeoutException:
            raise HTTPException(504, "Paper exchange request timed out.")

        except httpx.HTTPStatusError as exc:
            # Avoid returning exchange authentication or internal details.
            raise HTTPException(
                502,
                f"Paper exchange backend returned HTTP {exc.response.status_code}.",
            )

        except httpx.RequestError:
            raise HTTPException(
                502,
                "Unable to connect to the Paper exchange backend.",
            )

        except ValueError:
            raise HTTPException(
                502,
                "Paper exchange backend returned invalid JSON.",
            )

    async def positions(self, user):
        body = {
            "timestamp": int(time.time() * 1000),
            "page": "1",
            "size": "50",
            "margin_currency_short_name": ["USDT", "INR"],
        }

        data = await self._post(
            "/exchange/v1/derivatives/futures/positions",
            user,
            body,
        )

        return _extract_records(data, "positions")

    async def orders(self, user):
        all_orders = []

        # Paper API requires side. Fetch both sides and combine in memory.
        for side in ("buy", "sell"):
            body = {
                "timestamp": int(time.time() * 1000),
                "status": "open",
                "side": side,
                "page": "1",
                "size": "50",
                "margin_currency_short_name": ["INR", "USDT"],
            }

            data = await self._post(
                "/exchange/v1/derivatives/futures/orders",
                user,
                body,
            )

            all_orders.extend(_extract_records(data, "orders"))

        return all_orders


_exchange_router = ExchangeRouter(
    live_adapter=LiveExchangeAdapter(),
    paper_adapter=PaperExchangeAdapter(),
)


def _adapter_for_user(user):
    try:
        return _exchange_router.for_user(user)
    except RuntimeError as exc:
        raise HTTPException(403, str(exc))


async def get_active_positions(user):
    adapter = _adapter_for_user(user)
    records = await adapter.positions(user)

    if user.get("paper_testing"):
        # Paper positions must be open and have a non-zero active quantity.
        active = [
            row for row in records
            if str(row.get("exit_status", "")).lower() == "open"
            and _is_nonzero(row.get("active_pos"))
        ]
    else:
        # Live wallet response does not expose exit_status.
        active = [
            row for row in records
            if _is_nonzero(row.get("active_pos"))
        ]

    return {
        "ok": True,
        "exchange": "PAPER" if user.get("paper_testing") else "LIVE",
        "count": len(active),
        "positions": active,
    }


async def get_active_orders(user):
    adapter = _adapter_for_user(user)
    records = await adapter.orders(user)

    active = []

    for row in records:
        if str(row.get("status", "")).lower() != "open":
            continue

        # Paper responses expose remaining_quantity.
        if user.get("paper_testing"):
            if _number(row.get("remaining_quantity")) <= 0:
                continue

        # The current Live wallets.py response does not expose
        # remaining_quantity, so status=open is the available filter.
        elif row.get("remaining_quantity") is not None:
            if _number(row.get("remaining_quantity")) <= 0:
                continue

        active.append(row)

    return {
        "ok": True,
        "exchange": "PAPER" if user.get("paper_testing") else "LIVE",
        "count": len(active),
        "orders": active,
    }
