variable "tenancy_ocid" {
  type        = string
  description = "OCI Tenancy OCID"
}

variable "user_ocid" {
  type        = string
  description = "OCI User OCID"
}

variable "fingerprint" {
  type        = string
  description = "OCI API Key Fingerprint"
}

variable "private_key_path" {
  type        = string
  description = "Path to OCI API Private Key"
  default     = "~/.oci/oci_api_key.pem"
}

variable "region" {
  type        = string
  description = "OCI Region"
  default     = "eu-frankfurt-1"
}

variable "compartment_id" {
  description = "OCI Tenancy veya Proje Compartment OCID"
  type        = string
}

variable "availability_domain" {
  description = "Sunucunun bulunduğu Availability Domain"
  type        = string
  default     = "FVLm:EU-FRANKFURT-1-AD-3"
}

variable "subnet_id" {
  description = "Sunucunun bağlı olduğu Subnet OCID"
  type        = string
}

variable "vcn_id" {
  description = "Mevcut VCN OCID (NSG kuralları için)"
  type        = string
}

variable "ssh_public_key" {
  description = "Compute instance için SSH Public Key içeriği"
  type        = string
  default     = ""
}

variable "bastion_allowed_cidrs" {
  description = "OCI Bastion servisine bağlanmasına izin verilen CIDR blokları (Kendi IP adresinizle sınırlayın)"
  type        = list(string)
  default     = ["89.168.99.211/32"] # Güvenlik için kendi IP adresinizle güncelleyin
}
