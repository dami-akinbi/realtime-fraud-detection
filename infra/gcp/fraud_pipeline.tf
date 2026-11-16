data "google_project" "current" {
  project_id = var.project_id
}

# 1. Pub/Sub Ingestion Topic & Dead-Letter Topic
resource "google_pubsub_topic" "transactions_dlq" {
  name       = "transactions-dlq-${var.environment}"
  depends_on = [google_project_service.fraud_apis]
}

resource "google_pubsub_topic" "transactions_stream" {
  name       = "transactions-stream-${var.environment}"
  depends_on = [google_project_service.fraud_apis]
}

# 2. Cloud Firestore (Native Mode, Serverless Consumption)
resource "google_firestore_database" "fraud_db" {
  project                 = var.project_id
  name                    = "(default)"
  location_id             = var.region
  type                    = "FIRESTORE_NATIVE"
  delete_protection_state = "DELETE_PROTECTION_DISABLED"
  deletion_policy         = "DELETE"
  depends_on              = [google_project_service.fraud_apis]
}

# 3. Least-Privilege Service Account for the Anomaly Scorer
resource "google_service_account" "scorer_sa" {
  account_id   = "sa-fraud-scorer-${var.environment}"
  display_name = "Fraud Anomaly Scorer Service Account"
}

resource "google_project_iam_member" "scorer_roles" {
  for_each = toset([
    "roles/datastore.user",
    "roles/run.invoker",
    "roles/eventarc.eventReceiver",
    "roles/logging.logWriter"
  ])
  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.scorer_sa.email}"
}

resource "google_project_iam_member" "pubsub_token_creator" {
  project = var.project_id
  role    = "roles/iam.serviceAccountTokenCreator"
  member  = "serviceAccount:service-${data.google_project.current.number}@gcp-sa-pubsub.iam.gserviceaccount.com"
}

# 4. Package & Upload Python Function Source Code
data "archive_file" "scorer_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../../src/scorer"
  output_path = "${path.module}/scorer.zip"
}

resource "google_storage_bucket" "function_source" {
  name                        = "fraud-scorer-src-${data.google_project.current.number}-${var.environment}"
  location                    = var.region
  uniform_bucket_level_access = true
  force_destroy               = true
}

resource "google_storage_bucket_object" "scorer_archive" {
  name   = "scorer-${data.archive_file.scorer_zip.output_md5}.zip"
  bucket = google_storage_bucket.function_source.name
  source = data.archive_file.scorer_zip.output_path
}

# 5. Cloud Functions (2nd Gen) Serverless Anomaly Scorer
resource "google_cloudfunctions2_function" "anomaly_scorer" {
  name        = "fraud-anomaly-scorer-${var.environment}"
  location    = var.region
  description = "Real-time transaction anomaly scorer"

  build_config {
    runtime     = "python311"
    entry_point = "score_transaction"
    source {
      storage_source {
        bucket = google_storage_bucket.function_source.name
        object = google_storage_bucket_object.scorer_archive.name
      }
    }
  }

  service_config {
    max_instance_count    = 3
    min_instance_count    = 0
    available_memory      = "256M"
    timeout_seconds       = 60
    service_account_email = google_service_account.scorer_sa.email
  }

  event_trigger {
    trigger_region        = var.region
    event_type            = "google.cloud.pubsub.topic.v1.messagePublished"
    pubsub_topic          = google_pubsub_topic.transactions_stream.id
    retry_policy          = "RETRY_POLICY_RETRY"
    service_account_email = google_service_account.scorer_sa.email
  }

  depends_on = [
    google_project_service.fraud_apis,
    google_firestore_database.fraud_db,
    google_project_iam_member.scorer_roles,
    google_project_iam_member.pubsub_token_creator
  ]
}

# 6. Log-Based Metric & Alert Policy on High Fraud Velocity
resource "google_logging_metric" "fraud_flagged_metric" {
  name        = "fraud_flagged_count_${var.environment}"
  description = "Counts real-time transactions flagged as fraudulent"
  filter      = "resource.type=\"cloud_run_revision\" AND jsonPayload.event=\"FRAUD_FLAGGED\""

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
  }
}

resource "google_monitoring_alert_policy" "high_fraud_velocity" {
  display_name = "High Fraud Transaction Velocity (${var.environment})"
  combiner     = "OR"

  conditions {
    display_name = "More than 3 fraudulent transactions in 5 minutes"
    condition_threshold {
      filter          = "metric.type = \"logging.googleapis.com/user/${google_logging_metric.fraud_flagged_metric.name}\""
      duration        = "0s"
      comparison      = "COMPARISON_GT"
      threshold_value = 3

      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_SUM"
      }
    }
  }

  depends_on = [google_logging_metric.fraud_flagged_metric]
}

output "gcp_pubsub_topic" {
  value = google_pubsub_topic.transactions_stream.name
}