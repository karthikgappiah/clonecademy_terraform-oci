# ------------------------------------------------------------------------------
# PATH: ~/infrastructure/main.tf
# ------------------------------------------------------------------------------

# --- Versions ---

terraform {
  required_version = "~> 1.14.0" # Allows 1.14.X versions only.

  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 8.5.0" # Allows 8.5.X versions only.
    }
  }

  backend "oci" {
    config_file_profile = "clonecademy"
    bucket              = "tfstate_bucket"
    namespace           = "ax99ng5pq6oc"           # Must be hardcoded.
    key                 = "free/terraform.tfstate" # Located at tfstate_bucket/free/terraform.tfstate
  }
}

# --- Providers ---

variable "region" { type = string }
variable "tenancy_ocid" { type = string }
variable "user_ocid" { type = string }
variable "private_key_path" { type = string }
variable "fingerprint" { type = string }

provider "oci" {
  auth             = "APIKey"
  region           = var.region
  tenancy_ocid     = var.tenancy_ocid
  user_ocid        = var.user_ocid
  private_key_path = var.private_key_path
  fingerprint      = var.fingerprint
}

# --- Compartment ---

resource "oci_identity_compartment" "free_compartment" {
  compartment_id = var.tenancy_ocid
  name           = "free_compartment"
  description    = "A compartment for resources in the Always Free Tier."

  enable_delete = true
}

# --- Terraform State Bucket ---

data "oci_objectstorage_namespace" "ns" {
  compartment_id = var.tenancy_ocid
}

resource "oci_objectstorage_bucket" "tfstate_bucket" {
  namespace      = data.oci_objectstorage_namespace.ns.namespace
  compartment_id = oci_identity_compartment.free_compartment.id
  name           = "tfstate_bucket"

  object_events_enabled = true
  versioning            = "Enabled"
}

# --- Virtual Network ---

resource "oci_core_virtual_network" "free_network" {
  display_name   = "free_network"
  compartment_id = oci_identity_compartment.free_compartment.id

  dns_label      = "freevcn"
  is_ipv6enabled = false
  cidr_blocks    = ["10.0.0.0/16"]
}

# --- Gateways

resource "oci_core_internet_gateway" "free_internet_gateway" {
  display_name   = "free_internet_gateway"
  compartment_id = oci_identity_compartment.free_compartment.id
  vcn_id         = oci_core_virtual_network.free_network.id
  enabled        = true
}

resource "oci_core_nat_gateway" "free_nat_gateway" {
  display_name   = "free_nat_gateway"
  compartment_id = oci_identity_compartment.free_compartment.id
  vcn_id         = oci_core_virtual_network.free_network.id

}

data "oci_core_services" "all_oci_services" {}

locals {
  all_services_id   = [for s in data.oci_core_services.all_oci_services.services : s.id if length(regexall("All .* Services", s.name)) > 0][0]
  all_services_cidr = [for s in data.oci_core_services.all_oci_services.services : s.cidr_block if length(regexall("All .* Services", s.name)) > 0][0]
}

resource "oci_core_service_gateway" "free_service_gateway" {
  display_name   = "free_service_gateway"
  compartment_id = oci_identity_compartment.free_compartment.id
  vcn_id         = oci_core_virtual_network.free_network.id

  services {
    service_id = local.all_services_id
  }
}

# --- Route Tables

resource "oci_core_default_route_table" "free_default_route_table" {
  manage_default_resource_id = oci_core_virtual_network.free_network.default_route_table_id
  display_name               = "free_default_route_table"
  # NOTE: Leave the default route table empty and 
  #       use a custom public route table instead for security.
}

resource "oci_core_route_table" "public_route_table" {
  display_name   = "public_route_table"
  compartment_id = oci_identity_compartment.free_compartment.id
  vcn_id         = oci_core_virtual_network.free_network.id

  route_rules {
    description       = "Traffic to internet"
    network_entity_id = oci_core_internet_gateway.free_internet_gateway.id
    destination_type  = "CIDR_BLOCK"
    destination       = "0.0.0.0/0"
  }
}

resource "oci_core_route_table" "private_route_table" {
  display_name   = "private_route_table"
  compartment_id = oci_identity_compartment.free_compartment.id
  vcn_id         = oci_core_virtual_network.free_network.id

  route_rules {
    description       = "Traffic to NAT"
    network_entity_id = oci_core_nat_gateway.free_nat_gateway.id
    destination_type  = "CIDR_BLOCK"
    destination       = "0.0.0.0/0"
  }

  route_rules {
    description       = "Traffic to OCI services."
    network_entity_id = oci_core_service_gateway.free_service_gateway.id
    destination_type  = "SERVICE_CIDR_BLOCK"
    destination       = local.all_services_cidr
  }
}

# --- Security Lists

locals {
  vcn_cidr            = oci_core_virtual_network.free_network.cidr_blocks[0] # Returns: 10.0.0.0/16
  public_subnet_cidr  = cidrsubnet(local.vcn_cidr, 8, 0)                     # Returns: 10.0.0.0/24
  private_subnet_cidr = cidrsubnet(local.vcn_cidr, 8, 1)                     # Returns: 10.1.0.0/24
}

# Default Security List
resource "oci_core_default_security_list" "free_default_security_list" {
  manage_default_resource_id = oci_core_virtual_network.free_network.default_security_list_id
  display_name               = "free_default_security_list"
  # NOTE: Leave all default ingress/egress rules empty for security.
}

# Public Security List
resource "oci_core_security_list" "public_security_list" {
  display_name   = "public_security_list"
  compartment_id = oci_identity_compartment.free_compartment.id
  vcn_id         = oci_core_virtual_network.free_network.id

  egress_security_rules {
    description      = "Allows all traffic to all ports"
    protocol         = "all"
    destination_type = "CIDR_BLOCK"
    destination      = "0.0.0.0/0" # TODO: Restrict IP addresses for security.
    stateless        = false
  }

  ingress_security_rules {
    description = "Allows ICMP traffic from anywhere for Path MTU Discovery (PMTUD)"
    protocol    = "1" # 1 is an alias for ICMP.
    source_type = "CIDR_BLOCK"
    source      = "0.0.0.0/0"
    stateless   = false

    icmp_options {
      type = 3 # 3 is an alias for "Destination Unreachable".
      code = 4 # 4 is an alias for "Fragmentation Needed and Don't Fragment was Set".
    }
  }

  ingress_security_rules {
    description = "Allows ICMP traffic from this network for all codes"
    protocol    = "1" # 1 is an alias for ICMP.
    source_type = "CIDR_BLOCK"
    source      = local.vcn_cidr
    stateless   = false

    icmp_options {
      type = 3 # 3 is an alias for "Destination Unreachable".
      # no code implies all codes
    }
  }
}

# Private Security List
resource "oci_core_security_list" "private_security_list" {
  display_name   = "private_security_list"
  compartment_id = oci_identity_compartment.free_compartment.id
  vcn_id         = oci_core_virtual_network.free_network.id

  egress_security_rules {
    description      = "Allows all traffic to all ports."
    protocol         = "all"
    destination_type = "CIDR_BLOCK"
    destination      = "0.0.0.0/0" # TODO: Restrict IP addresses for security.
    stateless        = false
  }

  ingress_security_rules {
    description = "Allows ICMP traffic from anywhere to this network for Path MTU Discovery (PMTUD)"
    protocol    = "1" # 1 is an alias for ICMP.
    source_type = "CIDR_BLOCK"
    source      = "0.0.0.0/0"
    stateless   = false

    icmp_options {
      type = 3 # 3 is an alias for "Destination Unreachable".
      code = 4 # 4 is an alias for "Fragmentation Needed and Don't Fragment was Set".
    }
  }

  ingress_security_rules {
    description = "Allows ICMP traffic within this network for all codes"
    protocol    = "1" # 1 is an alias for ICMP.
    source_type = "CIDR_BLOCK"
    source      = local.vcn_cidr
    stateless   = false

    icmp_options {
      type = 3 # 3 is an alias for "Destination Unreachable".
      # no code implies all codes
    }
  }
}

# --- Subnets

resource "oci_core_subnet" "public_subnet" {
  display_name               = "public_subnet"
  dns_label                  = "freepubsub"
  cidr_block                 = local.public_subnet_cidr
  prohibit_public_ip_on_vnic = false
  compartment_id             = oci_identity_compartment.free_compartment.id
  vcn_id                     = oci_core_virtual_network.free_network.id
  dhcp_options_id            = oci_core_virtual_network.free_network.default_dhcp_options_id
  route_table_id             = oci_core_route_table.public_route_table.id
  security_list_ids          = [oci_core_security_list.public_security_list.id]
}

resource "oci_core_subnet" "private_subnet" {
  display_name               = "private_subnet"
  dns_label                  = "freeprisub"
  cidr_block                 = local.private_subnet_cidr
  prohibit_public_ip_on_vnic = true
  compartment_id             = oci_identity_compartment.free_compartment.id
  vcn_id                     = oci_core_virtual_network.free_network.id
  dhcp_options_id            = oci_core_virtual_network.free_network.default_dhcp_options_id
  route_table_id             = oci_core_route_table.private_route_table.id
  security_list_ids          = [oci_core_security_list.private_security_list.id]
}

# --- Network Security Groups (NSGs)

# SSH
resource "oci_core_network_security_group" "ssh_nsg" {
  display_name   = "ssh_nsg"
  compartment_id = oci_identity_compartment.free_compartment.id
  vcn_id         = oci_core_virtual_network.free_network.id
}

resource "oci_core_network_security_group_security_rule" "ssh_nsg_bastion" {
  network_security_group_id = oci_core_network_security_group.ssh_nsg.id
  direction                 = "INGRESS"
  protocol                  = "6" # TCP
  source_type               = "CIDR_BLOCK"
  # Only allows SSH connections from a Bastion within the network.
  source    = local.vcn_cidr
  stateless = false

  tcp_options {
    destination_port_range {
      min = 22
      max = 22
    }
  }
}

# Web (Dokploy)
resource "oci_core_network_security_group" "web_nsg" {
  display_name   = "web_nsg"
  compartment_id = oci_identity_compartment.free_compartment.id
  vcn_id         = oci_core_virtual_network.free_network.id
}

resource "oci_core_network_security_group_security_rule" "web_nsg_public" {
  network_security_group_id = oci_core_network_security_group.web_nsg.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source_type               = "CIDR_BLOCK"
  source                    = "0.0.0.0/0"

  for_each = toset(["80", "443"])
  tcp_options {
    destination_port_range {
      min = each.value
      max = each.value
    }
  }
}

locals {
  admin_ips = [
    "0.0.0.0/0", # TODO: Restrict IP addresses for security.
  ]
}

resource "oci_core_network_security_group_security_rule" "web_nsg_admin" {
  network_security_group_id = oci_core_network_security_group.web_nsg.id
  direction                 = "INGRESS"
  protocol                  = "6" # TCP
  source_type               = "CIDR_BLOCK"
  for_each                  = toset(local.admin_ips)
  source                    = each.value # Only administrators can access the Dokploy dashboard.

  tcp_options {
    destination_port_range {
      min = 3000
      max = 3000
    }
  }

  description = "Allow ${each.value} administrator access to the Dokploy dashboard"
}

# Minecraft
resource "oci_core_network_security_group" "minecraft_nsg" {
  display_name   = "minecraft_nsg"
  compartment_id = oci_identity_compartment.free_compartment.id
  vcn_id         = oci_core_virtual_network.free_network.id
}

resource "oci_core_network_security_group_security_rule" "minecraft_nsg_tcp" {
  network_security_group_id = oci_core_network_security_group.minecraft_nsg.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source_type               = "CIDR_BLOCK"
  source                    = "0.0.0.0/0"

  tcp_options {
    destination_port_range {
      min = 25565
      max = 25565
    }
  }
}

resource "oci_core_network_security_group_security_rule" "minecraft_nsg_udp" {
  network_security_group_id = oci_core_network_security_group.minecraft_nsg.id
  direction                 = "INGRESS"
  protocol                  = "17" # UDP
  source                    = "0.0.0.0/0"
  source_type               = "CIDR_BLOCK"

  udp_options {
    destination_port_range {
      min = 25565
      max = 25565
    }
  }
}
