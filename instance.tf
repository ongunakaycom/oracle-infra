resource "oci_core_instance" "existing_instance" {
  availability_domain = var.availability_domain
  compartment_id      = var.compartment_id
  shape               = "VM.Standard.E2.1.Micro"
  display_name        = "instance-20250409-1817"

  shape_config {
    ocpus         = 1
    memory_in_gbs = 1
  }

  source_details {
    source_type = "image"
    source_id   = "ocid1.image.oc1.eu-frankfurt-1.aaaaaaaanui7v6va7ip6abr7duqcndxvbd2nd3sqqaisfi472us2mjsnq54a"
  }

  create_vnic_details {
    subnet_id        = var.subnet_id
    assign_public_ip = true
    nsg_ids          = [oci_core_network_security_group.web_nsg.id]
  }

  metadata = {
    ssh_authorized_keys = file(var.ssh_public_key_path)
  }

  lifecycle {
    prevent_destroy = true # Yanlışlıkla silinmeye karşı kesin koruma
    ignore_changes = [
      source_details[0].source_id,
      metadata, # SSH key değişiminde VM'in yeniden oluşturulmasını önler
      defined_tags,
      freeform_tags,
    ]
  }
}
