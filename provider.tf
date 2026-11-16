terraform {
  required_version = ">= 1.10.0"

  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 6.0"
    }
  }

  # %100 Ücretsiz OCI Object Storage + Native State Locking
  backend "s3" {
    bucket                      = "terraform-state-bucket"
    key                         = "prod/terraform.tfstate"
    region                      = "eu-frankfurt-1"
    endpoints = {
      s3 = "https://fr78sbhgohlv.compat.objectstorage.eu-frankfurt-1.oraclecloud.com"
    }
    skip_region_validation      = true
    skip_credentials_validation = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true
    use_path_style              = true
    use_lockfile                = true
  }
}

provider "oci" {
  tenancy_ocid     = var.tenancy_ocid
  user_ocid        = var.user_ocid
  fingerprint      = var.fingerprint
  private_key_path = var.private_key_path
  region           = var.region
}
