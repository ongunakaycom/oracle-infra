# Always Free koruması: ücretli bir kaynak devreye girdiği anda alarm üretir.
#
# OCI bütçeleri tenancy (root) compartment'ında tanımlanır ve hedef olarak
# proje compartment'ını izler. Tutar 1 USD seçildiği için %1 ACTUAL eşiği
# pratikte "herhangi bir ücret tahakkuk etti" anlamına gelir.
locals {
  budget_enabled = length(var.budget_alert_emails) > 0

  budget_alert_rules = local.budget_enabled ? {
    actual = {
      type      = "ACTUAL"
      threshold = 1
      message   = "Always Free disi harcama tespit edildi. Terraform plan ve OCI Cost Analysis ekranini kontrol edin."
    }
    forecast = {
      type      = "FORECAST"
      threshold = 100
      message   = "Always Free butcesi tahmini olarak asilacak. Kaynaklari gozden gecirin."
    }
  } : {}
}

resource "oci_budget_budget" "always_free" {
  count = local.budget_enabled ? 1 : 0

  compartment_id = var.tenancy_ocid
  target_type    = "COMPARTMENT"
  targets        = [var.compartment_id]

  amount       = var.budget_amount_usd
  reset_period = "MONTHLY"
  display_name = "always-free-guard"
  description  = "Always Free sinirlarini asan harcamalari erken yakalamak icin Terraform tarafindan yonetilir."

  freeform_tags = {
    "managed-by" = "terraform"
    "purpose"    = "always-free-guard"
  }
}

resource "oci_budget_alert_rule" "always_free" {
  for_each = local.budget_alert_rules

  budget_id      = oci_budget_budget.always_free[0].id
  type           = each.value.type
  threshold      = each.value.threshold
  threshold_type = "PERCENTAGE"
  recipients     = join(",", var.budget_alert_emails)
  message        = each.value.message
  display_name   = "always-free-${each.key}"
}
