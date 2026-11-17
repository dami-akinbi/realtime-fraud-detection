import json
import logging
import os
from datetime import datetime, timezone
import azure.functions as func
from azure.cosmos import CosmosClient

app = func.FunctionApp()

HIGH_RISK_CATEGORIES = {"crypto_exchange", "wire_transfer", "gambling"}


def evaluate_transaction(tx: dict) -> tuple[bool, list[str]]:
    reasons = []
    amount = float(tx.get("amount", 0))
    is_international = bool(tx.get("is_international", False))
    category = str(tx.get("merchant_category", "")).lower()

    if amount > 5000:
        reasons.append("HIGH_AMOUNT_OVER_5000")
    if is_international and amount > 1500:
        reasons.append("INTERNATIONAL_VELOCITY_THRESHOLD")
    if category in HIGH_RISK_CATEGORIES:
        reasons.append(f"HIGH_RISK_CATEGORY:{category}")

    return (len(reasons) > 0), reasons


@app.event_hub_message_trigger(
    arg_name="azeventhub",
    event_hub_name="evh-transactions-dev",
    connection="EventHubConnectionString",
)
def score_transaction(azeventhub: func.EventHubEvent):
    payload = json.loads(azeventhub.get_body().decode("utf-8"))
    tx_id = payload.get("transaction_id", "unknown")
    is_fraud, reasons = evaluate_transaction(payload)

    record = {
        "id": tx_id,
        "transaction_id": tx_id,
        "account_id": payload.get("account_id", "unknown"),
        "amount": float(payload.get("amount", 0)),
        "currency": payload.get("currency", "USD"),
        "merchant_category": payload.get("merchant_category", "general"),
        "is_international": bool(payload.get("is_international", False)),
        "is_fraud": is_fraud,
        "flag_reasons": reasons,
        "processed_at": datetime.now(timezone.utc).isoformat(),
    }

    if is_fraud:
        client = CosmosClient.from_connection_string(os.environ["CosmosDbConnectionString"])
        container = client.get_database_client("frauddb").get_container_client("fraud_alerts")
        container.upsert_item(record)
        logging.warning(json.dumps({"event": "FRAUD_FLAGGED", **record}))
    else:
        logging.info(json.dumps({"event": "TRANSACTION_CLEARED", "transaction_id": tx_id}))