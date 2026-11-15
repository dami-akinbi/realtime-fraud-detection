terraform {
  required_version = ">= 1.6.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }

  backend "gcs" {
    bucket = "tfstate-fraud-dami-akinbi"
    prefix = "fraud-detection/dev"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}
