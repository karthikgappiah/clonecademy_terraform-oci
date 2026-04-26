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
}

# --- Providers ---

provider "oci" {
  config_file_profile = "clonecademy"
}

# --- Hello World ---

data "oci_identity_regions" "all_regions" {}

output "all_regions" {
  value = data.oci_identity_regions.all_regions.regions
}
