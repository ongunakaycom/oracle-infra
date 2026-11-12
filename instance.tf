resource "oci_core_instance" "existing_instance" {
  availability_domain = "FVLm:EU-FRANKFURT-1-AD-3"
  compartment_id      = "ocid1.tenancy.oc1..aaaaaaaattfjsgbmgtp7vyck47uyqsdsjd3zbwpnwsll5qst7y7atix3sclq"
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
    subnet_id        = "ocid1.subnet.oc1.eu-frankfurt-1.aaaaaaaai72cq3eyrtfznceszy2f42anocgg4g7zz2xuzigkqfvpstevcnwa"
    assign_public_ip = true
  }

  metadata = {
    ssh_authorized_keys = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQCrNNfGPE672aNzQLNL2+tq2rDPOwyoFKlc1R9Qlgb+iAWRCz11SDiOQqrJcUgcKNKQxkvzLPWkmJOp2xNaOD1zjnvBzlLIMyG8g/QYK0KMyR7Ch43wK13HUcLWwg6qgFwpiJuytgEISKpSWZFvLEAirIPhh51W9Ci9lx5rsefN6lu0NOgjbLmlnX6J3iOvS+ILylwKO//ISmbasaCilIJNeUjcCryHO8mfW0TOflPS6RgGsg/YXHNC7pcwRZH9uRZIxGri+k6l6u0uFeTzZ1Mqg5+nr4Amv5BwHpo/8x/2SGnygvqk2LxK7z0Sp1zkK46YU6NUUPDfr/iHvk09Toq2vit3NHQ7GN4uUoJqJZSNdHfQvtOdz9d2A5jwGL3VvReVIDUFQ+u1v0pxfRNQuxdhKR3uxXULo1DWgx3vdlBgzbLtLNtGMmGUQXvQ0EZS/gtRIMSLnaR4hgqrNJmRy4lmGKO6JIVvxZA277wUc5po70kXeU8nl/O9GtJc8rjzASDiy8DsaBW0aIbvB38LYaDXAP/C78PiIr7D9eWWPFI1a8JJhN2oQ5qCZedoXfsYx1ZkizoN34TvB+mtnFGHxZeu0zvwKYRNOMLGDf4gJeTtgscB3oDYbHrW8HsCqSBnJbKk2c7qHmqjCf5AWIAMS1M+S8bTqkkX0mZ15KOxGz9hWQ== jackmichel@0cf2f7d3bec8"
  }

  lifecycle {
    ignore_changes = [
      source_details[0].source_id,
      defined_tags,
      freeform_tags,
    ]
  }
}