resource "google_project_service" "fraud_apis" {
  for_each = toset([
    "pubsub.googleapis.com",
    "firestore.googleapis.com",
    "cloudfunctions.googleapis.com",
    "run.googleapis.com",
    "cloudbuild.googleapis.com"
  ])

  project = var.project_id
  service = each.value
  disable_on_destroy = false
}