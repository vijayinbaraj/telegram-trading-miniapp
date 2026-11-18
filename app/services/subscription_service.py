class SubscriptionService:
    async def get_entitlements(self, user_id: str, tenant_id: str):
        raise NotImplementedError  # TODO: plan, expiry, limits, feature entitlements

    async def start_checkout(self, user_id: str, plan_id: str):
        raise NotImplementedError  # TODO: create provider checkout

    async def process_verified_payment_webhook(self, payload: dict, signature: str):
        raise NotImplementedError  # TODO: verify signature, deduplicate and reconcile
