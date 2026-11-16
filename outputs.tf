output "instance_public_ip" {
  description = "Sunucunun genel IP adresi"
  value       = oci_core_instance.existing_instance.public_ip
}

output "instance_private_ip" {
  description = "Sunucunun özel ağ IP adresi"
  value       = oci_core_instance.existing_instance.private_ip
}
