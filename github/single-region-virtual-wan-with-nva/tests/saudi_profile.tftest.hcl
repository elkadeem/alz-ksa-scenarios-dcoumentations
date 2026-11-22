mock_provider "alz" {}
mock_provider "azurerm" {
  mock_data "azurerm_client_config" {
    defaults = {
      tenant_id       = "00000000-0000-0000-0000-000000000001"
      subscription_id = "00000000-0000-0000-0000-000000000002"
    }
  }
}
mock_provider "azurerm" {
  alias = "connectivity"
}
mock_provider "azurerm" {
  alias = "management"
}
mock_provider "azapi" {
  mock_data "azapi_client_config" {
    defaults = {
      tenant_id       = "00000000-0000-0000-0000-000000000001"
      subscription_id = "00000000-0000-0000-0000-000000000002"
    }
  }
  mock_data "azapi_resource_action" {
    defaults = {
      output = {
        value = [{
          name        = "saudiarabiaeast"
          displayName = "Saudi Arabia East"
          metadata = {
            geography      = "Saudi Arabia"
            regionType     = "Physical"
            regionCategory = "Recommended"
            pairedRegion   = []
          }
          availabilityZoneMappings = [{ logicalZone = "1" }, { logicalZone = "2" }, { logicalZone = "3" }]
        }]
      }
    }
  }
}
mock_provider "azapi" {
  alias = "connectivity"
  mock_data "azapi_resource_action" {
    defaults = {
      output = {
        value = [{
          name        = "saudiarabiaeast"
          displayName = "Saudi Arabia East"
          metadata = {
            geography      = "Saudi Arabia"
            regionType     = "Physical"
            regionCategory = "Recommended"
            pairedRegion   = []
          }
          availabilityZoneMappings = [{ logicalZone = "1" }, { logicalZone = "2" }, { logicalZone = "3" }]
        }]
      }
    }
  }
}
mock_provider "local" {}
mock_provider "random" {}
mock_provider "time" {}

# The upstream region metadata has no Backup DNS geo code for Saudi Arabia East.
override_module {
  target = module.config.module.regions
  outputs = {
    regions_by_name = {
      saudiarabiaeast = {
        geo_code   = null
        short_name = "sae"
      }
    }
  }
}

# Mocked providers return an empty computed bgp_settings list; real plans leave it unknown.
override_module {
  target = module.virtual_wan[0].module.virtual_wan[0].module.vpn_gateway
  outputs = {
    id                   = ["mock-vpn-gateway"]
    resource_id          = ["mock-vpn-gateway"]
    vpn_gateway_id       = ["mock-vpn-gateway"]
    vpn_gateway_name     = ["mock-vpn-gateway"]
    bgp_settings         = []
    resource             = []
    ip_configuration_ids = { primary = ["config0", "config1"] }
    resource_object = {
      primary = { id = "mock-vpn-gateway", name = "mock-vpn-gateway", bgp_settings = [] }
    }
  }
}
run "saudi_vwan_profile" {
  command = plan

  variables {
    subscription_ids = {
      management   = "00000000-0000-0000-0000-000000000002"
      connectivity = "00000000-0000-0000-0000-000000000003"
      identity     = "00000000-0000-0000-0000-000000000004"
      security     = "00000000-0000-0000-0000-000000000005"
    }
    root_parent_management_group_id = "00000000-0000-0000-0000-000000000001"
    management_groups_enabled       = false
    enable_telemetry                = false
  }

  assert {
    condition     = length(module.virtual_wan) == 1 && length(module.hub_and_spoke_vnet) == 0
    error_message = "Only the Virtual WAN connectivity module must be active."
  }

  assert {
    condition = (
      module.config.outputs.management_group_settings.location == "uaenorth" &&
      module.config.outputs.virtual_hubs.primary.location == "saudiarabiaeast" &&
      jsondecode(local.policy_default_values.resource_group_location).value == "saudiarabiaeast"
    )
    error_message = "Policy identities must use UAE North while networking and policy-created resource groups stay in Saudi Arabia East."
  }

  assert {
    condition = (
      jsondecode(local.policy_assignments_to_modify.corp.policy_assignments["Deploy-Private-DNS-Zones"].parameters.dnzZoneRegionShortNames).value.saudiarabiaeast == "sae" &&
      jsondecode(local.policy_default_values.private_dns_zone_region).value == "saudiarabiaeast"
    )
    error_message = "The Corp DNS policy must receive the Saudi Backup DNS code and the full region name."
  }

  assert {
    condition = (
      module.config.outputs.virtual_hubs.primary.enabled_resources.private_dns_zones &&
      !module.config.outputs.virtual_hubs.primary.enabled_resources.private_dns_resolver &&
      !module.config.outputs.virtual_hubs.primary.enabled_resources.firewall &&
      !module.config.outputs.virtual_hubs.primary.enabled_resources.virtual_network_gateway_express_route &&
      module.config.outputs.virtual_hubs.primary.enabled_resources.virtual_network_gateway_vpn
    )
    error_message = "Expected: private DNS zones and VPN on; resolver, firewall and ExpressRoute off."
  }

  assert {
    condition = (
      module.config.outputs.virtual_hubs.primary.enabled_resources.bastion &&
      length(module.config.outputs.virtual_hubs.primary.bastion.zones) == 0 &&
      length(module.config.outputs.virtual_hubs.primary.bastion.bastion_public_ip.zones) == 0
    )
    error_message = "Bastion host and public IP must both use empty zone sets."
  }

  assert {
    condition     = !var.management_resources_enabled && length(module.management_resources) == 0
    error_message = "The workspace-backed management resources must be disabled."
  }

  assert {
    condition     = module.virtual_wan[0].private_link_private_dns_zones_maps["primary"]["azure_backup"].zone_name == "privatelink.sae.backup.windowsazure.com"
    error_message = "The Backup private DNS zone must use the Saudi code: privatelink.sae.backup.windowsazure.com."
  }
}