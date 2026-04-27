# ------------------------------------------------------------------------------
# PATH: ~/infrastructure/main.tf
# ------------------------------------------------------------------------------

# --- Versions ---

terraform {
  required_version = "~> 1.14.0" # Allows 1.14.X versions only.

  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 8.5.0" # Allows 8.5.X versions only.
    }
  }

  backend "oci" {
    bucket    = "tfstate_bucket"
    namespace = "ax99ng5pq6oc"           # Must be hardcoded.
    key       = "free/terraform.tfstate" # Located at tfstate_bucket/free/terraform.tfstate
  }
}

# --- Providers ---

variable "region" { type = string }
variable "tenancy_ocid" { type = string }
variable "user_ocid" { type = string }
variable "private_key_path" { type = string }
variable "fingerprint" { type = string }

provider "oci" {
  auth             = "APIKey"
  region           = var.region
  tenancy_ocid     = var.tenancy_ocid
  user_ocid        = var.user_ocid
  private_key_path = var.private_key_path
  fingerprint      = var.fingerprint
}

# --- Compartment ---

resource "oci_identity_compartment" "free_compartment" {
  compartment_id = var.tenancy_ocid
  name           = "free_compartment"
  description    = "A compartment for resources in the Always Free Tier."

  enable_delete = true
}

# --- Terraform State Bucket ---

data "oci_objectstorage_namespace" "ns" {
  compartment_id = var.tenancy_ocid
}

resource "oci_objectstorage_bucket" "tfstate_bucket" {
  namespace      = data.oci_objectstorage_namespace.ns.namespace
  compartment_id = oci_identity_compartment.free_compartment.id
  name           = "tfstate_bucket"

  object_events_enabled = true
  versioning            = "Enabled"
}
