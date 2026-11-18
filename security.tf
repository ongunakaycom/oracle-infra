resource "oci_core_network_security_group" "web_nsg" {
  compartment_id = var.compartment_id
  vcn_id         = var.vcn_id
  display_name   = "nsg-enterprise-web-prod"
}

# HTTP (80) - Sertifika yenileme ve HTTPS yönlendirmesi için
resource "oci_core_network_security_group_security_rule" "allow_http" {
  network_security_group_id = oci_core_network_security_group.web_nsg.id
  direction                 = "INGRESS"
  protocol                  = "6" # TCP
  source                    = "0.0.0.0/0"
  source_type               = "CIDR_BLOCK"

  tcp_options {
    destination_port_range {
      min = 80
      max = 80
    }
  }
}

# HTTPS (443) - Güvenli web trafiği için
resource "oci_core_network_security_group_security_rule" "allow_https" {
  network_security_group_id = oci_core_network_security_group.web_nsg.id
  direction                 = "INGRESS"
  protocol                  = "6" # TCP
  source                    = "0.0.0.0/0"
  source_type               = "CIDR_BLOCK"

  tcp_options {
    destination_port_range {
      min = 443
      max = 443
    }
  }
}

# SSH (22) - Sadece VCN içinden (OCI Bastion Service üzerinden) erişim
resource "oci_core_network_security_group_security_rule" "allow_ssh_internal" {
  network_security_group_id = oci_core_network_security_group.web_nsg.id
  direction                 = "INGRESS"
  protocol                  = "6"           # TCP
  source                    = "10.0.0.0/16" # VCN CIDR bloğunuz
  source_type               = "CIDR_BLOCK"

  tcp_options {
    destination_port_range {
      min = 22
      max = 22
    }
  }
}

# NSG kuralları, subnet'e bağlı Security List kurallarıyla birlikte (additive)
# uygulanır. Security List port 22'yi 0.0.0.0/0 kaynağına açıyorsa NSG'deki
# VCN içi kısıtlama tek başına yeterli olmaz. Aşağıdaki kontrol, canlı ortamda
# unutulmuş bir "public SSH" kuralını plan çıktısında görünür kılar.
data "oci_core_subnet" "target" {
  subnet_id = var.subnet_id
}

data "oci_core_security_lists" "vcn" {
  compartment_id = var.compartment_id
  vcn_id         = var.vcn_id
}

locals {
  subnet_security_list_ids = toset(data.oci_core_subnet.target.security_list_ids)

  security_lists_allowing_public_ssh = [
    for security_list in data.oci_core_security_lists.vcn.security_lists : security_list.display_name
    if contains(local.subnet_security_list_ids, security_list.id) && anytrue([
      for rule in security_list.ingress_security_rules : (
        contains(["6", "all"], rule.protocol) &&
        contains(["0.0.0.0/0", "::/0"], rule.source) &&
        (
          rule.protocol == "all" ||
          anytrue([
            for port_range in try(rule.tcp_options[0].destination_port_range, []) :
            port_range.min <= 22 && port_range.max >= 22
          ])
        )
      )
    ])
  ]
}

output "ssh_security_list_audit_warning" {
  description = "Warns if any attached subnet Security List exposes TCP/22 to 0.0.0.0/0 (see docs/security-remediation.md)"
  value = length(local.security_lists_allowing_public_ssh) == 0 ? "OK: No subnet Security List exposes TCP/22 to 0.0.0.0/0" : "WARNING: Subnet Security List(s) exposing TCP/22 to internet: ${join(", ", local.security_lists_allowing_public_ssh)} — see docs/security-remediation.md"
}
