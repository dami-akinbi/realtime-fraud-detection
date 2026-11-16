import base64
import json
import logging
from datetime import datetime, timezone
import functions_framework
from google.cloud import firestore

logging.basicConfig(level=logging.INFO)
db = firestore.Client()

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

@functions_framework.cloud_event
def score_transaction(cloud_event):
    raw_data = cloud_event.data["message"]["data"]
    payload = json.loads(base64.b64decode(raw_data).decode("utf-8"))

    tx_id = payload.get("transaction_id", "unknown")
    is_fraud, reasons = evaluate_transaction(payload)

    record = {
        "transaction_id": tx_id,
        "account_id": payload.get("account_id", "unknown"),
        "amount": float(payload.get("amount"), 0),
        "currency": payload.get("currency", "USD"),
        "merchant_category": payload.get("merchant_category", "general"),
        "is_international": bool(payload.get("is_international", False)),
        "is_fraud": is_fraud,
        "flag_reasons": reasons,
        "processed_at": datetime.now(timezone.utc).isoformat(),
    }

    if is_fraud:
        db.collection("fraud_alerts").documents(tx_id).set(record)
        logging.warning(json.dumps({"event": "FRAUD_FLAGGED", **record}))
    else:
        logging.info(json.dumps({"event": "TRANSACTION_CLEARED", "transaction_id": tx_id}))
