import argparse
import json
import random
import time
import uuid
from datetime import datetime, timezone

NORMAL_CATEGORIES = ["grocery", "coffee_shop", "cloud_saas", "transit", "utilities"]
HIGH_RISK_CATEGORIES = ["crypto_exchange", "wire_transfer", "luxury_jewelry", "online_gaming"]


def build_transaction(force_fraud: bool) -> dict:
    tx_id = f"tx-demo-{uuid.uuid4().hex[:8]}"
    account_id = f"acct-{random.randint(100, 999)}"

    if force_fraud:
        amount = round(random.uniform(5500.00, 14500.00), 2)
        category = random.choice(HIGH_RISK_CATEGORIES)
        is_international = True
    else:
        amount = round(random.uniform(8.50, 450.00), 2)
        category = random.choice(NORMAL_CATEGORIES)
        is_international = False

    return {
        "transaction_id": tx_id,
        "account_id": account_id,
        "amount": amount,
        "currency": "USD",
        "merchant_category": category,
        "is_international": is_international,
        "timestamp": datetime.now(timezone.utc).isoformat(),
    }


def publish_gcp(project_id: str, topic_id: str, events: list[dict]) -> None:
    from google.cloud import pubsub_v1

    publisher = pubsub_v1.PublisherClient()
    topic_path = publisher.topic_path(project_id, topic_id)
    futures = []

    for event in events:
        payload = json.dumps(event).encode("utf-8")
        futures.append(publisher.publish(topic_path, payload))

    for future in futures:
        future.result(timeout=30)

    print(f"[GCP] Published {len(events)} transactions to {topic_path}")


def publish_azure(namespace_fqdn: str, eventhub_name: str, events: list[dict]) -> None:
    from azure.eventhub import EventData, EventHubProducerClient
    from azure.identity import DefaultAzureCredential

    credential = DefaultAzureCredential()
    producer = EventHubProducerClient(
        fully_qualified_namespace=namespace_fqdn,
        eventhub_name=eventhub_name,
        credential=credential,
    )

    with producer:
        batch = producer.create_batch()
        for event in events:
            batch.add(EventData(json.dumps(event)))
        producer.send_batch(batch)

    print(f"[Azure] Published {len(events)} transactions to {namespace_fqdn}/{eventhub_name}")


def main() -> None:
    parser = argparse.ArgumentParser(description="Multicloud synthetic fraud traffic generator")
    parser.add_argument("--target", choices=["both", "gcp", "azure"], default="both")
    parser.add_argument("--count", type=int, default=10)
    parser.add_argument("--fraud-ratio", type=float, default=0.4)
    parser.add_argument("--gcp-project", default="damis-project-01")
    parser.add_argument("--gcp-topic", default="transactions-stream-dev")
    parser.add_argument("--azure-namespace", default="")
    parser.add_argument("--azure-eventhub", default="evh-transactions-dev")
    args = parser.parse_args()

    events = [
        build_transaction(force_fraud=(random.random() < args.fraud_ratio))
        for _ in range(args.count)
    ]
    fraud_count = sum(1 for e in events if e["is_international"] and e["amount"] > 5000)
    print(f"Generated {len(events)} synthetic transactions ({fraud_count} high-risk fraud alerts expected).")

    if args.target in ("both", "gcp"):
        publish_gcp(args.gcp_project, args.gcp_topic, events)

    if args.target in ("both", "azure"):
        if not args.azure_namespace:
            raise ValueError("--azure-namespace is required when targeting Azure (e.g. ehns-fraud-dev-xxxx.servicebus.windows.net)")
        publish_azure(args.azure_namespace, args.azure_eventhub, events)

    time.sleep(2)


if __name__ == "__main__":
    main()