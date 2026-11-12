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
    ssh_authorized_keys = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQDXZNHybRtlByH11tvh6OW06NjWrGevV+JGBy1ZNiUxIIBar/ZmTrT6eF5gmDwN87Mw+wylgV46clXMWEIgceTMZ4jAZ5KN0fPdbwj4SU89L47ZwO2SZMKeVQzIWJ0URLT6pCsyLDKoZDpxpYTNl7bSlc8Z03e672kpWVC6077tOyeMdhZFKxVcCus42Fvn+IphnFnDlNXlDht+pYw8zSSmq993wbjkRh3cvqV6Tg2/KhBUqIj9py+J9IO1tNjrKh4tiokhwBovyX43zeg7YYbvU9E7hkMYol6X9kOAQeeWO8BShCYm1rTjbbnOA+llffQgnRyAPaQtedfZEmX9FYSVzGX6QzhZdsmy2QjdGpzKovye4auI2tL+BXK48phzLGMr9lJticeEg2dm4JEvt2YLJB2NEC8hdW6lqynT5pCxogI7xNLkmiTLew4osCR2VOolI1prIdg4NP2At4SlxKgpC5/FVRsSDu2xLdJDfBe/GEe/vnM3Pt/5it91JGZ8J0e/8ecUe7LBXMVt4cIGQ53QkGxCNhGUyeRAoS0eyeIi7J9qL6sLPnvht7C7Whb4LmYt/IOJCy7/kb9nuUowz6qZqsRhGGMix4BqQ0ZfS5QLBpet0Mznus6i2B8jeRcp9MxeZhqkR4M24Ec6gPc52h0qW/DP0lTO8EDKkSuqzgzqww== ongunakay@HUAWEI"
  }

  lifecycle {
    ignore_changes = [
      source_details[0].source_id,
      defined_tags,
      freeform_tags,
    ]
  }
}