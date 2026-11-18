# OCI Always Free guardrails for this Terraform root module.
#
# Evaluated by Conftest/OPA from the Layer 3 CI job:
#   conftest test --combine --parser hcl2 --policy policies *.tf
#
# Because of --combine, `input` is an array with one parsed document per
# Terraform file. Nothing is resolved against the OCI API, so the gate runs
# on pull requests without cloud credentials.
package main

import rego.v1

always_free := {
	"arm_ocpus":      4,
	"arm_memory_gb":  24,
	"micro_instances": 2,
	"block_storage_gb": 200,
}

# Only shapes covered by the OCI Always Free tier may be declared.
allowed_instance_shapes := {
	"VM.Standard.E2.1.Micro",
	"VM.Standard.A1.Flex",
}

documents := [contents |
	some document in input
	contents := object.get(document, "contents", {})
]

resources(type) := [object.union(body, {"__address__": sprintf("%s.%s", [type, name])}) |
	some doc in documents
	some name, instances in object.get(object.get(doc, "resource", {}), type, {})
	some body in instances
]

instances := resources("oci_core_instance")

shape_of(instance) := object.get(instance, "shape", "")

name_of(instance) := object.get(instance, "display_name", object.get(instance, "__address__", "unnamed"))

shape_config_of(instance) := config if {
	configs := object.get(instance, "shape_config", [])
	count(configs) > 0
	config := configs[0]
}

# ---------------------------------------------------------------------------
# Compute: paid shapes are rejected outright.
# ---------------------------------------------------------------------------
deny contains msg if {
	some instance in instances
	shape := shape_of(instance)
	not shape in allowed_instance_shapes
	msg := sprintf(
		"OCI free-tier: instance '%s' declares shape '%s'; only %v are covered by Always Free.",
		[name_of(instance), shape, allowed_instance_shapes],
	)
}

# ---------------------------------------------------------------------------
# Compute: at most 2 VM.Standard.E2.1.Micro instances.
# ---------------------------------------------------------------------------
micro_instances := [instance |
	some instance in instances
	shape_of(instance) == "VM.Standard.E2.1.Micro"
]

deny contains msg if {
	count(micro_instances) > always_free.micro_instances
	msg := sprintf(
		"OCI free-tier: %d VM.Standard.E2.1.Micro instances declared, Always Free allows %d.",
		[count(micro_instances), always_free.micro_instances],
	)
}

# ---------------------------------------------------------------------------
# Compute: Ampere A1 limits (4 OCPU / 24 GB) per instance and in total.
# ---------------------------------------------------------------------------
arm_instances := [instance |
	some instance in instances
	shape_of(instance) == "VM.Standard.A1.Flex"
]

deny contains msg if {
	some instance in arm_instances
	not shape_config_of(instance)
	msg := sprintf(
		"OCI free-tier: A1.Flex instance '%s' must declare shape_config with ocpus and memory_in_gbs.",
		[name_of(instance)],
	)
}

deny contains msg if {
	some instance in arm_instances
	config := shape_config_of(instance)
	not is_number(object.get(config, "ocpus", null))
	msg := sprintf(
		"OCI free-tier: A1.Flex instance '%s' must declare a numeric shape_config.ocpus.",
		[name_of(instance)],
	)
}

deny contains msg if {
	some instance in arm_instances
	config := shape_config_of(instance)
	not is_number(object.get(config, "memory_in_gbs", null))
	msg := sprintf(
		"OCI free-tier: A1.Flex instance '%s' must declare a numeric shape_config.memory_in_gbs.",
		[name_of(instance)],
	)
}

deny contains msg if {
	some instance in arm_instances
	config := shape_config_of(instance)
	config.ocpus > always_free.arm_ocpus
	msg := sprintf(
		"OCI free-tier: A1.Flex instance '%s' requests %v OCPUs (limit %d).",
		[name_of(instance), config.ocpus, always_free.arm_ocpus],
	)
}

deny contains msg if {
	some instance in arm_instances
	config := shape_config_of(instance)
	config.memory_in_gbs > always_free.arm_memory_gb
	msg := sprintf(
		"OCI free-tier: A1.Flex instance '%s' requests %v GB RAM (limit %d).",
		[name_of(instance), config.memory_in_gbs, always_free.arm_memory_gb],
	)
}

arm_ocpus_total := sum([ocpus |
	some instance in arm_instances
	config := shape_config_of(instance)
	ocpus := config.ocpus
	is_number(ocpus)
])

arm_memory_total := sum([memory |
	some instance in arm_instances
	config := shape_config_of(instance)
	memory := config.memory_in_gbs
	is_number(memory)
])

deny contains msg if {
	arm_ocpus_total > always_free.arm_ocpus
	msg := sprintf(
		"OCI free-tier: A1.Flex total is %v OCPUs across the tenancy (limit %d).",
		[arm_ocpus_total, always_free.arm_ocpus],
	)
}

deny contains msg if {
	arm_memory_total > always_free.arm_memory_gb
	msg := sprintf(
		"OCI free-tier: A1.Flex total is %v GB RAM across the tenancy (limit %d).",
		[arm_memory_total, always_free.arm_memory_gb],
	)
}

# ---------------------------------------------------------------------------
# Block storage: 200 GB total across block and boot volumes.
# ---------------------------------------------------------------------------
block_volumes := array.concat(
	resources("oci_core_volume"),
	resources("oci_core_boot_volume"),
)

deny contains msg if {
	some volume in block_volumes
	not is_number(object.get(volume, "size_in_gbs", null))
	msg := sprintf(
		"OCI free-tier: block volume '%s' must declare a numeric size_in_gbs so the 200 GB Always Free budget can be verified.",
		[object.get(volume, "display_name", "unnamed")],
	)
}

block_storage_total := sum([size |
	some volume in block_volumes
	size := object.get(volume, "size_in_gbs", 0)
	is_number(size)
])

deny contains msg if {
	block_storage_total > always_free.block_storage_gb
	msg := sprintf(
		"OCI free-tier: declared block storage is %v GB (limit %d GB).",
		[block_storage_total, always_free.block_storage_gb],
	)
}

# ---------------------------------------------------------------------------
# Bastion: never expose the managed bastion to the whole internet.
# ---------------------------------------------------------------------------
bastions := resources("oci_bastion_bastion")

deny contains msg if {
	some bastion in bastions
	some cidr in object.get(bastion, "client_cidr_block_allow_list", [])
	cidr in {"0.0.0.0/0", "::/0"}
	msg := sprintf(
		"OCI Bastion '%s' allows the whole internet (%s); restrict client_cidr_block_allow_list to known operator CIDRs.",
		[name_of(bastion), cidr],
	)
}