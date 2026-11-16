resource "oci_bastion_bastion" "prod_bastion" {
  bastion_type     = "STANDARD"
  compartment_id   = var.compartment_id
  target_subnet_id = var.subnet_id
  name             = "bastion-enterprise-prod"
  client_cidr_block_allow_list = ["0.0.0.0/0"] # Dilerseniz kendi şirket/ev IP aralığınızla kısıtlayabilirsiniz
}
