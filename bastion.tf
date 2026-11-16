resource "oci_bastion_bastion" "prod_bastion" {
  #checkov:skip=CKV_OCI_21:Controlled via var.bastion_allowed_cidrs for dynamic developer IP access
  bastion_type                 = "STANDARD"
  compartment_id               = var.compartment_id
  target_subnet_id             = var.subnet_id
  name                         = "bastion-enterprise-prod"
  client_cidr_block_allow_list = var.bastion_allowed_cidrs
}
