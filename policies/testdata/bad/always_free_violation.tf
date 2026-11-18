# Negatif test fixture for the Always Free policy gate.
#
# Bu dosya bilincli olarak limitleri asar; CI'daki "policy self-test" adimi
# conftest'in bu dosyada FAIL uretmesini bekler. Gercek altyapiya dahil
# edilmez (terraform init/plan bu dizini okumaz, Trivy/KICS taramalari da
# exclude eder).

resource "oci_core_instance" "oversized_arm" {
  compartment_id      = "ocid1.compartment.oc1..example"
  availability_domain = "FVLm:EU-FRANKFURT-1-AD-3"
  shape               = "VM.Standard.A1.Flex"
  display_name        = "oversized-arm"

  shape_config {
    ocpus         = 8
    memory_in_gbs = 48
  }
}

resource "oci_core_instance" "paid_shape" {
  compartment_id      = "ocid1.compartment.oc1..example"
  availability_domain = "FVLm:EU-FRANKFURT-1-AD-3"
  shape               = "VM.Standard.E4.Flex"
  display_name        = "paid-shape"
}

resource "oci_core_volume" "oversized_block" {
  compartment_id      = "ocid1.compartment.oc1..example"
  availability_domain = "FVLm:EU-FRANKFURT-1-AD-3"
  display_name        = "oversized-block"
  size_in_gbs         = 250
}
