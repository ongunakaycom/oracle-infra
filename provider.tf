terraform {
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 5.0"
    }
  }
  required_version = ">= 1.5.0"
}

provider "oci" {
  tenancy_ocid     = "ocid1.tenancy.oc1..aaaaaaaattfjsgbmgtp7vyck47uyqsdsjd3zbwpnwsll5qst7y7atix3sclq"
  user_ocid        = "ocid1.user.oc1..aaaaaaaasbakzmvvcnfchwnflihxeiwa5tjtphdnochm25k6cc7xihku5iaa"
  fingerprint      = "30:5c:ce:bf:da:7b:ab:f0:c4:c9:9e:c1:0b:b9:04:ef"
  private_key_path = "/home/ongunakay/.oci/oci_api_key.pem"
  region           = "eu-frankfurt-1"
}