
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
    """
    Extract records from direct lists and common API response wrappers.

    Supported examples:
      [ {...}, {...} ]
      {"positions": [ ... ]}
      {"data": {"positions": [ ... ]}}
      {"data": [ ... ]}
      {"result": {"items": [ ... ]}}

    Only known wrapper keys are traversed so unrelated response fields are
    not mistaken for position/order records.
    """
    if isinstance(data, list):
        return [row for row in data if isinstance(row, dict)]

    if not isinstance(data, dict):
        return []

    # First check the requested collection key, case-insensitively.
    wanted = key.lower()
    for response_key, value in data.items():
        if str(response_key).lower() == wanted:
            if isinstance(value, list):
                return [row for row in value if isinstance(row, dict)]
            nested = _extract_records(value, key)
            if nested:
                return nested

    # Then traverse conventional response-envelope keys.
    wrapper_keys = ("data", "result", "items", "records", "payload", "response")
    for wrapper_key in wrapper_keys:
        value = data.get(wrapper_key)
        if isinstance(value, (dict, list)):
            records = _extract_records(value, key)
            if records:
                return records

    # Some APIs return {"data": [...]} without naming the collection.
    for wrapper_key in wrapper_keys:
        value = data.get(wrapper_key)
        if isinstance(value, list):
            return [row for row in value if isinstance(row, dict)]

    return []


def _is_nonzero(value):
    return _number(value) != 0


def _first_value(row, *keys):
    for key in keys:
        value = row.get(key)
        if value is not None and value != "":
            return value
    return None


def _inr_per_usdt():
    """Return the current INR value of one USDT from the shared database."""
    row = fetch_one(
        """
        SELECT rate
        FROM exchange_platform.paper_wallet_conversion_rates
        WHERE base_currency = 'INR'
          AND quote_currency = 'USDT'
        ORDER BY updated_at DESC
        LIMIT 1
        """
    )
    rate = _number(row.get("rate")) if row else Decimal("0")
    if rate <= 0:
        raise HTTPException(503, "INR/USDT conversion rate is unavailable.")
    return rate


def _position_currency(row):
    """Resolve settlement/margin currency without guessing from base asset."""
    currency = _first_value(
        row,
        "margin_currency_short_name", "margin_currency", "settlement_currency",
        "quote_currency", "pnl_currency", "currency_short_name",
    )
    if currency:
        value = str(currency).strip().upper()
        if value in {"INR", "USDT"}:
            return value

    pair = _first_value(row, "pair", "symbol", "market")
    if pair:
        symbol = str(pair).strip().upper().replace("-", "_")
        if symbol.endswith("_USDT") or symbol.endswith("USDT"):
            return "USDT"
        if symbol.endswith("_INR") or symbol.endswith("INR"):
            return "INR"
    return None


def _extract_wallet_records(data, assume_inr=False):
    """Accept wallet arrays and single-wallet objects returned by Paper APIs."""
    records = _extract_records(data, "wallets")
    if records:
        return records

    def find_wallet(value):
        if isinstance(value, dict):
            if any(k in value for k in (
                "currency_short_name", "currency", "asset", "total_balance",
                "available_balance", "balance", "locked_balance",
            )):
                wallet = dict(value)
                if assume_inr and not _first_value(
                    wallet, "currency_short_name", "currency", "asset"
                ):
                    wallet["currency_short_name"] = "INR"
                return [wallet]
            for key in ("data", "result", "payload", "response", "wallet"):
                if key in value:
                    found = find_wallet(value[key])
                    if found:
                        return found
        elif isinstance(value, list):
            for entry in value:
                found = find_wallet(entry)
                if found:
                    return found
        return []

    return find_wallet(data)


def _normalize_position(row, inr_per_usdt=None):
    item = dict(row)
    quantity = _first_value(item, "active_pos", "quantity", "position_qty", "size")
    side = _first_value(item, "side", "position_side", "position_type")
    if not side and quantity is not None:
        qty = _number(quantity)
        if qty:
            side = "LONG" if qty > 0 else "SHORT"
    if side:
        side_text = str(side).strip().upper()
        item["side"] = (
            "LONG" if side_text in {"BUY", "B", "LONG"}
            else "SHORT" if side_text in {"SELL", "S", "SHORT"}
            else side_text
        )

    pnl = _first_value(
        item, "unrealized_pnl", "unrealizedPnl", "unrealized_profit",
        "unrealizedProfit", "pnl", "unrealized_pl"
    )
    # Preserve the existing fallback calculation when the exchange omits P&L.
    # The signed position quantity determines long/short direction as before.
    if pnl is None:
        entry = _first_value(item, "avg_price", "entry_price", "average_price")
        mark = _first_value(item, "mark_price", "markPrice", "last_price")
        if quantity is not None and entry is not None and mark is not None:
            pnl = (_number(mark) - _number(entry)) * _number(quantity)

    currency = _position_currency(item)
    print(
        "PNL_CURRENCY_DEBUG:",
        {
            "pair": item.get("pair"),
            "margin_currency_short_name": item.get("margin_currency_short_name"),
            "margin_currency": item.get("margin_currency"),
            "settlement_currency": item.get("settlement_currency"),
            "pnl_currency": item.get("pnl_currency"),
            "raw_pnl": pnl,
            "detected_currency": currency,
        },
        flush=True,
    )
    # if pnl is not None:
    #     pnl_value = _number(pnl)
    #     if currency == "USDT":
    #         if inr_per_usdt is None:
    #             inr_per_usdt = _inr_per_usdt()
    #         pnl_value *= inr_per_usdt
    #         currency = "INR"
    #     item["unrealized_pnl"] = str(pnl_value)
    #     item["unrealized_pnl_currency"] = currency or "UNKNOWN"
    # else:
    #     item["unrealized_pnl"] = None
    #     item["unrealized_pnl_currency"] = currency or "UNKNOWN"
    # All position unrealized P&L values are denominated in USDT.
    if pnl is not None:
        pnl_value = _number(pnl)

        if inr_per_usdt is None:
            inr_per_usdt = _inr_per_usdt()

        pnl_value *= inr_per_usdt

        item["unrealized_pnl"] = str(pnl_value)
        item["unrealized_pnl_currency"] = "INR"
    else:
        item["unrealized_pnl"] = None
        item["unrealized_pnl_currency"] = "INR"
    return item


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

    async def wallets(self, user):
        data = await self._get("/api/wallets/balances", user)
        return _extract_wallet_records(data, assume_inr=False)


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

    async def wallets(self, user):
        body = {"timestamp": int(time.time() * 1000)}
        data = await self._post(
            "/exchange/v1/derivatives/futures/wallet",
            user,
            body,
        )
        return _extract_wallet_records(data, assume_inr=True)

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
        active = []
        for row in records:
            exit_status = row.get("exit_status")
            if exit_status is not None and str(exit_status).strip().lower() not in {
                "open", "active"
            }:
                continue
            if _is_nonzero(row.get("active_pos")):
                active.append(row)
    else:
        active = [row for row in records if _is_nonzero(row.get("active_pos"))]

    # Fetch once per response only when at least one position is USDT-settled.
    # rate = None
    # if any(_position_currency(row) == "USDT" for row in active):
    #     rate = _inr_per_usdt()
    rate = _inr_per_usdt() if active else None
    normalized = [_normalize_position(row, rate) for row in active]
    return {
        "ok": True,
        "exchange": "PAPER" if user.get("paper_testing") else "LIVE",
        "count": len(normalized),
        "positions": normalized,
    }


async def get_wallet_balances(user):
    adapter = _adapter_for_user(user)
    wallets = await adapter.wallets(user)
    cleaned = []
    total_inr = Decimal("0")
    rate = None

    for wallet in wallets:
        currency = str(_first_value(
            wallet, "currency_short_name", "currency", "asset"
        ) or "UNKNOWN").upper()
        # Prefer total wallet equity; fall back to balance, then available.
        balance = _first_value(
            wallet, "total_balance", "balance", "available_balance"
        )
        locked = _first_value(
            wallet, "locked_balance", "locked", "reserved_balance"
        )
        balance_value = _number(balance)
        locked_value = _number(locked)
        wallet_item = {
            "currency": currency,
            "balance": str(balance_value),
            "locked_balance": str(locked_value),
        }

        if currency == "INR":
            total_inr += balance_value
            wallet_item["balance_inr"] = str(balance_value)
            wallet_item["locked_balance_inr"] = str(locked_value)
        elif currency == "USDT":
            if rate is None:
                rate = _inr_per_usdt()
            converted = balance_value * rate
            converted_locked = locked_value * rate
            total_inr += converted
            wallet_item["balance_inr"] = str(converted)
            wallet_item["locked_balance_inr"] = str(converted_locked)
        cleaned.append(wallet_item)

    return {
        "ok": True,
        "exchange": "PAPER" if user.get("paper_testing") else "LIVE",
        "wallets": cleaned,
        "wallet_balance_inr": str(total_inr) if cleaned else None,
        "wallet_balance_currency": "INR",
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
