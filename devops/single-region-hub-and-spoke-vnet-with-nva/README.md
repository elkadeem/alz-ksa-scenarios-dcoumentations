# Scenario 8: Saudi Arabia landing zone with Terraform and Azure DevOps

Deploy a **single-region hub and spoke virtual network prepared for a Network Virtual Appliance (NVA)** with the Azure Landing Zones accelerator, private bootstrap networking, and self-hosted Azure DevOps agents.

This is a configuration and deployment runbook, not proof of a successful Azure deployment. **Finish every edit for one file before opening the next.** The file-by-file instructions below consolidate region, monitoring, Defender, DDoS, DNS, and Bastion changes; validation and deployment happen once afterward.

This runbook is self-contained. You do not need to read or deploy another scenario first.

## 1. Select the configuration and understand the regional split

Paths in this guide are relative to this scenario folder unless stated otherwise.

| Component | Setting |
| --- | --- |
| Bootstrap resources, agents, registry, and Terraform backend | UAE North: `uaenorth` |
| Regional platform landing-zone resources | Saudi Arabia East: `saudiarabiaeast` |
| Policy-assignment managed identities | UAE North: `uaenorth` (identity-only exception; Saudi creation failed in two independent tests) |
| Version control and pipelines | Azure DevOps Services |
| Agents | Self-hosted Azure Container Instances (ACI) |
| Bootstrap networking | Private endpoints and a dedicated VNet |
| Pinned starter / Terraform | `v17.7.0` / `1.14.9` |

**Why two regions?** The standard agent bootstrap depends on Azure Container Registry (ACR), which was unavailable in Saudi Arabia East for this design. Keep bootstrap in UAE North while that dependency is unavailable. Recheck service/SKU availability, subscription access, capacity, and zone support before execution; this guide does not certify regional availability.

**Data residency approval is required.** State, agent execution, container images, and bootstrap storage are outside Saudi Arabia. State and pipeline artifacts can contain sensitive infrastructure metadata. Azure DevOps has its own organization data location. Private endpoints do not make these services Saudi-resident. If all deployment data must remain in Saudi Arabia, stop and approve another supported bootstrap design.

The scenario does **not** deploy an NVA, vendor licenses, production spokes, an ExpressRoute circuit, or an on-premises VPN device. Those require separate work.

### Tracked source defaults

| Setting | Tracked [config](config/) |
| --- | --- |
| `$targetFolderPath` | This scenario folder |
| Platform subscriptions | Four placeholders requiring customer input; Security placement is active |
| Policy-assignment identity location | `uaenorth` |
| NVA subnet generated route table | Not associated (`assign_generated_route_table = false`) |
| DDoS plan and auto-enablement policies | Disabled; an enabled variant is described in section 5 |
| VPN / Bastion / private DNS zones | Enabled |
| Saudi starter short name / Corp DNS map | `sae` / Saudi map |
| Log Analytics bundle / Private DNS Resolver / automatic Defender enablement | Disabled |
| Bastion host and public-IP zones | `[]` on both |
| MCAPS public-IP tags | Commented out; enable only when applied policies require them |
| Saudi DNS module overlay | Included as source files |

There is no tracked local-test copy: tenant-specific copies belong in an ignored folder and must not be force-added. Editing the tracked source does not synchronize any private copy or an already-generated Azure DevOps repository.

**Deliberate design choices to keep consistent in every copy:**

- **Security subscription:** `subscription_placement.security` references `$${subscription_id_security}`. For a three-subscription copy, comment out the **entire** Security placement block; otherwise supply the real Security ID. An empty ID is not a valid placement.
- **Bootstrap subscription:** an empty `bootstrap_subscription_id` follows the Azure CLI selection. Set it explicitly to the intended management subscription.
- **Bootstrap network:** add the VNet/subnet inputs and `allow_storage_access_from_my_ip` in section 3; do not assume the `10.250.0.*` layout is configured.
- **Policy identities:** use UAE North. Saudi Arabia East creation failed in a manual test and in a colleague's deployment; the earlier resource-group-scope success does not cover management-group scope. Saudi platform resources are not moved.
- **NVA subnet:** keep `route_table.assign_generated_route_table = false`; otherwise the generated user-subnet route table (`0.0.0.0/0` and the regional summary to the NVA IP) is associated with the appliance's own subnet.
- **Defender re-enable:** the commented-out configuration retains its Log Analytics export overrides; use the complete tracked block as the reference.

## 2. Prepare permissions, tools, and Azure DevOps

### Azure prerequisites

Prepare Management, Connectivity, Identity, and Security platform subscriptions in one Microsoft Entra tenant. The isolated three-subscription test is an explicit exception; keep its subscription inputs and placement map consistent.

Record the tenant and subscription IDs. Select an existing parent management group; an empty parent value selects the Tenant Root Group. The bootstrap account needs:

- `Owner` on the chosen parent management group and all selected platform subscriptions, including the bootstrap subscription.
- Active privileged roles when access is controlled by Privileged Identity Management.
- Azure DevOps rights to manage the project, repositories, pipelines, service connections, environments, and organization-level agent pool. PAT scopes do not grant rights the account lacks.

Inherited allowed-location policies must permit UAE North bootstrap resources and Saudi platform resources, or have approved scope-specific exemptions. Do not remove governance controls to bypass deployment errors.

### Tools and scenario generation

Use PowerShell **7.4 or newer**, Azure CLI **2.55.0 or newer**, Git, and optionally VS Code. Allow access to Azure, Azure DevOps, PowerShell Gallery, GitHub, and required Terraform/provider/package download endpoints. Cloud Shell and corporate-proxy operation are not explicitly supported by the accelerator.

```powershell
$PSVersionTable.PSVersion
az version
git --version

Set-Location "D:\workarea\Source\alz\terraform"
$alzModule = Get-InstalledPSResource -Name ALZ -ErrorAction SilentlyContinue
if (-not $alzModule) {
    Install-PSResource -Name ALZ
} else {
    Update-PSResource -Name ALZ
}
Import-Module ALZ
Get-Module ALZ | Select-Object Name, Version

$iacType = "terraform"
$versionControl = "azure-devops"
$scenarioNumber = 8
$targetFolderPath = ".\devops\single-region-hub-and-spoke-vnet-with-nva"
```

**The scenario already exists in this workspace. Skip generation.** For a new, empty destination only:

```powershell
New-AcceleratorFolderStructure `
    -iacType $iacType `
    -versionControl $versionControl `
    -scenarioNumber $scenarioNumber `
    -targetFolderPath $targetFolderPath
```

Back up customizations before deliberate regeneration. Assign the scenario number explicitly; assigning it to itself does not select scenario 8 in a fresh terminal.

### Two PATs

Use an Azure DevOps Services organization connected to the intended tenant. Confirm at least one **self-hosted parallel job** is available; agents alone do not grant pipeline concurrency.

Create organization-scoped PATs under **User settings > Personal access tokens**.

| Bootstrap administration PAT scope | Permission |
| --- | --- |
| Agent Pools | Read & manage |
| Build | Read & execute |
| Code | Full |
| Environment | Read & manage |
| Graph | Read & manage |
| Pipeline Resources | Use & manage |
| Project and Team | Read, write & manage |
| Service Connections | Read, query & manage |
| Variable Groups | Read, create & manage |

Use a short bootstrap-PAT lifetime. The separate **agent registration PAT** needs only **Agent Pools > Read & manage**; establish renewal and agent-recreation procedures before it expires.

In the PowerShell terminal that will run bootstrap:

```powershell
$env:TF_VAR_azure_devops_personal_access_token = Read-Host "Bootstrap PAT (token 1)" -MaskInput
$env:TF_VAR_azure_devops_agents_personal_access_token = Read-Host "Agent registration PAT (token 2)" -MaskInput
```

Never print or commit token values. Keep both YAML PAT entries commented out: explicit file values can take precedence over environment variables. Environment variables avoid embedding tokens in source, but state and generated artifacts still require protection. In a new terminal, restore authentication, variables, and the selected configuration path.

## 3. Edit `config/inputs.yaml` once

Open [inputs.yaml](config/inputs.yaml). Complete all these entries, then save. The tracked source still has customer placeholders and implicit bootstrap subscription/network settings; the table is an edit checklist, not a claim that those values are already saved.

| Entry | Required update | Reason |
| --- | --- | --- |
| `bootstrap_location` | Keep `"uaenorth"` | Agent ACR dependency is separate from the Saudi platform region. |
| `root_parent_management_group_id` | Existing management-group ID, or `""` for Tenant Root Group | Select the intended hierarchy parent; do not use a full resource ID. |
| `subscription_ids` | Fill Management, Connectivity, Identity, and Security IDs | Replacements and subscription placement depend on them. |
| `bootstrap_subscription_id` | Explicit management subscription ID | Avoid relying on the current CLI subscription. |
| `service_name`, `environment_name`, `postfix_number` | Keep `"alz"`, `"mgmt"`, and `1`, or approved existing values | Preserve bootstrap names/state when rerunning. |
| `use_self_hosted_agents`, `use_private_networking` | Both `true` | Run pipelines against private backend/registry endpoints. |
| `virtual_network_address_space` | `"10.250.0.0/24"` after overlap approval | Separate bootstrap addressing from the Saudi hub. |
| `virtual_network_subnet_address_prefix_container_instances` | `"10.250.0.0/26"` | Dedicated agent subnet. |
| `virtual_network_subnet_address_prefix_private_endpoints` | `"10.250.0.64/26"` | Dedicated private endpoint subnet. |
| `allow_storage_access_from_my_ip` | `false` | Do not add a workstation public-IP firewall exception. |
| `azure_devops_organization_name` | Organization name only, not a URL | Match bootstrap input format. |
| `azure_devops_project_name` | Intended project name | Select the delivery project. |
| `apply_approvers` | Approved organization user principal names | Retain the apply approval gate. |
| Both PAT entries | Keep commented out | Use the environment variables from section 2. |
| `starter_module_version`, `terraform_version` | `"v17.7.0"`, `"1.14.9"` | Match the version-specific module overlay. |
| `iac_type`, `bootstrap_module_name`, `starter_module_name` | `"terraform"`, `"alz_azuredevops"`, `"platform_landing_zone"` | Retain the Azure DevOps deployment mode. |

The four network keys to add together are:

```yaml
virtual_network_address_space: "10.250.0.0/24"
virtual_network_subnet_address_prefix_container_instances: "10.250.0.0/26"
virtual_network_subnet_address_prefix_private_endpoints: "10.250.0.64/26"
allow_storage_access_from_my_ip: false
```

This leaves `10.250.0.128/25` unallocated. Check corporate, VPN, ExpressRoute, and future-spoke ranges too. For an **existing bootstrap**, inspect its actual network and plan before changing these values; a guide example is not approval to replace deployed networking.

For an existing project, add `azure_devops_create_project: false` after confirming administrative rights and absence of name conflicts.

Private networking is not air-gapped: the bootstrap includes NAT Gateway/public-IP egress. Agents need outbound HTTPS to Azure DevOps, Entra ID, ARM, and package sources, plus private DNS/routing to backend storage and ACR. Preserve ACI subnet delegation and DNS links. Do not open blanket inbound access for agent registration.

`allow_storage_access_from_my_ip: false` does not provide private workstation connectivity. Administrative storage data-plane access needs approved private routing and DNS; use self-hosted pipelines for platform Terraform runs.

## 4. Edit `config/platform-landing-zone.tfvars` once

Open [platform-landing-zone.tfvars](config/platform-landing-zone.tfvars). Merge changes into the existing blocks; do not replace the file with snippets or create duplicate top-level maps. Preserve `$${...}` tokens for accelerator replacement.

The tracked source already contains the following configuration. Optional variants (such as enabled DDoS) are called out where they apply.

### Regions, subscription placement, and resource flags

| Block / entry | Source value or update | Reason |
| --- | --- | --- |
| `starter_locations` | `["saudiarabiaeast"]` | Regional platform resources stay in Saudi Arabia East. |
| `starter_locations_short` | `{ starter_location_01_short = "sae" }` | Override the starter's missing Saudi geo-code metadata. |
| `management_resources_enabled` | `false` | Disable the whole management-resource bundle, not just its workspace. |
| `management_groups_enabled` | `true` | Preserve hierarchy, subscription placement, and remaining policies. |
| `management_group_settings.architecture_name` | `"alz_custom"` | Use the custom library edited in section 5. |
| `management_group_settings.location` | `"uaenorth"` | Policy-assignment identities are created here, not in Saudi Arabia East: creation failed in a manual test and in a colleague's independent GitHub-variant deployment. This does not move workload resources; keep `policy_default_values.resource_group_location` on the Saudi region. Approve this location exception. |
| `hub_virtual_networks.primary.hub_virtual_network.subnets.nva.route_table.assign_generated_route_table` | `false` | The hub module associates the generated user-subnet route table to every subnet by default. Its `0.0.0.0/0` and regional summary routes use the NVA next hop, so the appliance subnet would route its own traffic back to itself. |
| `management_group_settings.subscription_placement` | Match the subscriptions in YAML | For the three-subscription test, comment out the entire `security` block; alternatively supply its input ID. |
| `custom_replacements.names.ddos_protection_plan_enabled` | `false` in source; `true` in test | Explicitly select enhanced DDoS protection; keep policy changes consistent. |
| `primary_virtual_network_gateway_express_route_enabled` | `false` | No ExpressRoute gateway in this design. |
| `primary_virtual_network_gateway_vpn_enabled` | `true` | Retain VPN gateway and its shared gateway subnet/configuration. |
| `primary_private_dns_zones_enabled` | `true` | Preserve central private-link DNS zones. |
| `primary_private_dns_auto_registration_zone_enabled` | `true` | Preserve VNet auto-registration. |
| `primary_private_dns_resolver_enabled` | `false` | Disable only the hub resolver and its endpoints. |
| `primary_bastion_enabled` | `true` | Keep administrative access through Bastion. |
| `hub_virtual_networks.primary.enabled_resources.firewall` | `false` | This is an NVA scenario, not Azure Firewall. |

Keep existing names, inactive management-resource settings, resolver configuration, and resource ID replacements for later re-enablement. Disabling the management bundle also disables its resource group, AMA identity, DCRs, and workspace solutions/onboarding. It does not disable bootstrap state storage.

### Policy defaults

Inside `management_group_settings.policy_default_values`, finish all changes together:

| Entries | Action | Reason |
| --- | --- | --- |
| `ama_change_tracking_data_collection_rule_id`, `ama_mdfc_sql_data_collection_rule_id`, `ama_vm_insights_data_collection_rule_id`, `ama_user_assigned_managed_identity_id`, `ama_user_assigned_managed_identity_name`, `log_analytics_workspace_id` | Retain as comments | Removed assignments must not receive IDs for resources that are no longer deployed. |
| `ddos_protection_plan_id` | Comment out for source-disabled DDoS; keep active for enabled DDoS | Coordinate the plan ID with the resource flag and both library removal lists. |
| `resource_group_name_mdfc`, `email_security_contact` | Retain as comments | Automatic Defender configuration is excluded. |
| `resource_group_location`, `resource_group_name_service_health_alerts` | Keep active | The independent service-health policy still uses them. |
| `private_dns_zone_subscription_id` | `"$${subscription_id_connectivity}"` | Central private zones are in Connectivity. |
| `private_dns_zone_region` | `"$${starter_location_01}"` | Pass the full region, not `sae`, to the DNS policy. |
| `private_dns_zone_resource_group_name` | `"$${dns_resource_group_name}"` | Match the central DNS resource group. |

### Policy modifications: Corp DNS and Defender guardrails

Inside the **existing** `management_group_settings.policy_assignments_to_modify` map, retain `alz`, `platform`, and `landingzones`, and include:

```hcl
corp = {
  policy_assignments = {
    Deploy-Private-DNS-Zones = {
      parameters = {
        dnzZoneRegionShortNames = {
          saudiarabiaeast = "sae"
        }
      }
    }
  }
}
```

**Reason:** the inherited Corp DNS initiative needs the Saudi Backup DNS code to construct the same zone ID as Terraform: `privatelink.sae.backup.windowsazure.com`. Keep the full region name in the policy defaults. `dnzZoneRegionShortNames` replaces the entire default region map; extend it before using another DNS region. If the Corp management-group ID changes in the architecture, update this modification key too. Do not remove `Deploy-Private-DNS-Zones` in the Corp override.

Comment out the entire `alz.policy_assignments.Deploy-MDFC-Config-H224` modification: its assignment is excluded in the root library override. Keep prior configuration as comments, not active modifications of an absent assignment.

Under **both** `platform.policy_assignments` and `landingzones.policy_assignments`, retain:

| Assignment | Parameter | Value |
| --- | --- | --- |
| `Enforce-GR-MySQL0` | `mySqlAdvThreatProtection` | `"Disabled"` |
| `Enforce-GR-PostgreSQL0` | `postgreSqlAdvThreatProtection` | `"Disabled"` |
| `Enforce-GR-Storage0` | `storageThreatProtection` | `"Disabled"` |
| `Enforce-GR-Synapse0` | `synapseDefender` | `"Disabled"` |
| `Enforce-GR-SQL0` | `sqlManagedDefender` | `"Disabled"` |

For `Enforce-GR-SQL0` in **both scopes**, also keep:

```hcl
overrides = [
  {
    kind  = "policyEffect"
    value = "disabled"
    selectors = [
      {
        kind = "policyDefinitionReferenceId"
        in   = ["Dine-Sql-Adv-Data"]
      }
    ]
  }
]
```

**Reason:** that SQL initiative member independently enables Advanced Data Security without an exposed effect parameter. Override effects must be lowercase `"disabled"`; initiative parameters remain `"Disabled"`. These guardrails are `DoNotEnforce` in the pinned library, but explicit settings protect against accidental enablement if enforcement changes. Preserve other guardrails/enforcement settings.

Before future Defender re-enablement, review the complete retained source configuration, replace `defender_email_security_contact`, and reconcile its monitoring dependencies. If Log Analytics stays off, the retained main-initiative configuration uses `parameters.logAnalytics = ""` and a targeted disabled override selecting `["ascExport", "defenderforKubernetes"]`. An empty workspace parameter is not an alternative logging destination.

### MCAPS subscriptions with applied public-IP policies

> [!CAUTION]
> **MCAPS SUBSCRIPTIONS ONLY:** If your subscription has applied policies requiring the `FirstPartyUsage = "/Unprivileged"` public-IP tag, enable it on **both VPN gateway public IPs and the Bastion public IP**. Confirm the actual policy requirements first; do not apply this tag indiscriminately to other subscriptions. The tracked source leaves these settings commented out.

While the same [platform variables file](config/platform-landing-zone.tfvars) is open, uncomment the supplied `ip_tags` line inside each of these existing blocks under `hub_virtual_networks.primary`:

| Existing block | Update | Reason |
| --- | --- | --- |
| `virtual_network_gateways.vpn.ip_configurations.active_active_1.public_ip` | `ip_tags = { FirstPartyUsage = "/Unprivileged" }` | Meet the applied MCAPS public-IP policy for the first VPN IP. |
| `virtual_network_gateways.vpn.ip_configurations.active_active_2.public_ip` | Same tag | The active-active VPN gateway creates a second public IP that must also comply. |
| `bastion.bastion_public_ip` | Same tag; retain `zones = []` | Meet the applied MCAPS public-IP policy without undoing the Bastion zone fix. |

Place the tag in the **public-IP object**, not on the gateway/Bastion host or in the ordinary resource `tags` map. Preserve names and other settings. No module edits are needed because the tracked modules already pass `ip_tags` through.

For an existing generated repository, include the same conditional updates when editing its `platform-landing-zone.auto.tfvars`. Verify that the plan includes the required tag on all three public IPs, inspect policy compliance and any replacement/access impact, and approve the plan before apply. These tags do not remove or bypass the subscription's policies.

### Bastion, DNS, and addressing

Inside `hub_virtual_networks.primary.bastion`, keep:

```hcl
bastion = {
  subnet_address_prefix = "$${primary_bastion_subnet_address_prefix}"
  name                  = "$${primary_bastion_host_name}"
  zones                 = []
  bastion_public_ip = {
    name  = "$${primary_bastion_host_public_ip_name}"
    zones = []
    # MCAPS only, when required by applied policies:
    # ip_tags = { FirstPartyUsage = "/Unprivileged" }
  }
}
```

**Reason:** the reported Saudi deployment rejected Bastion with zones (`BastionRegionAzNotSupported`). Empty lists explicitly disable zones for **both** host and public IP rather than inheriting module defaults. Bastion remains enabled; this does not change gateway zones/SKUs or provide zone-redundant Bastion.

Keep private-zone/auto-registration settings, the auto-registration zone `saudiarabiaeast.azure.local`, and intended VNet links. Disabling Private DNS Resolver does not disable private zones or bootstrap private-endpoint DNS. It also does not deploy a replacement DNS forwarder: approve a DNS path for on-premises/NVA clients before production use.

| Address replacement | Default |
| --- | --- |
| Regional routing space | `10.0.0.0/16` |
| Hub VNet | `10.0.0.0/22` |
| NVA subnet / next hop | `10.0.0.0/26` / `10.0.0.4` |
| Bastion subnet | `10.0.0.64/26` |
| Gateway subnet | `10.0.0.128/27` |
| Retained resolver subnet prefix, resolver disabled | `10.0.0.160/28` |

Update related `primary_*` replacements together if overlap exists. Align the next hop with the separately deployed appliance.

### Existing deployment and protection implications

- Disabling management resources can delete an existing workspace, DCRs, identity, and resource group. Review retention/export, deletion protection, shared resources, and monitoring dependencies first. Policy removal does not clean up previously deployed agents, diagnostic settings, DCR associations, SQL audit settings, or export automations.
- Disabling Defender policies does not set existing plans to `Free`, uninstall agents, remove integrations, or stop billing. Separately inventory existing protection, inherited policies, and external automation before approved changes.
- Disabling a DDoS plan removes enhanced Network Protection, not baseline infrastructure-level protection. Reconcile existing VNet associations before deletion. Approve an alternative strategy where required; DDoS IP Protection is not enabled automatically.
- Resolver removal can delete endpoints/subnets and break forwarding. Bastion/public-IP or gateway changes can replace resources and interrupt access. Review the exact plan before approval.
- This design lacks centralized Log Analytics, VM Insights, AMA change tracking, the removed SQL audit destination, and automatic Defender enablement. Obtain monitoring/security/compliance approval and alternatives before production. Remaining benchmark/audit policies can still report noncompliance; do not remove them wholesale.

Save this file after completing all blocks.

## 5. Edit each custom-library file once

Open each file below, finish its entire removal list, preserve all other fields, then save. **Removal directives must remain active**; commenting out an assignment in `policy_assignments_to_remove` re-enables it through the base archetype.

### `root_custom.alz_archetype_override.yaml`

In the [root override](config/lib/archetype_definitions/root_custom.alz_archetype_override.yaml), the complete source removal list is:

```yaml
policy_assignments_to_remove: [
  Deploy-AzActivity-Log,
  Deploy-Diag-LogsCat,
  Deploy-MDFC-Config-H224,
  Deploy-MDFC-OssDb,
  Deploy-MDFC-SqlAtp,
  Deploy-MDEndpoints,
  Deploy-MDEndpointsAMA,
]
```

**Reason:** the first two policies forward logs to the disabled workspace; the remaining policies automatically configure Defender plans, database threat protection, endpoint deployment, or integration.

### `platform_custom.alz_archetype_override.yaml`

In the [platform override](config/lib/archetype_definitions/platform_custom.alz_archetype_override.yaml):

```yaml
policy_assignments_to_remove: [
  DenyAction-DeleteUAMIAMA,
  Deploy-MDFC-DefSQL-AMA,
  Deploy-VM-ChangeTrack,
  Deploy-VM-Monitoring,
  Deploy-vmArc-ChangeTrack,
  Deploy-vmHybr-Monitoring,
  Deploy-VMSS-ChangeTrack,
  Deploy-VMSS-Monitoring,
]
```

**Reason:** remove protection of the disabled AMA identity and all dependent AMA/monitoring deployments.

### `landing_zones_custom.alz_archetype_override.yaml`

In the [landing-zones override](config/lib/archetype_definitions/landing_zones_custom.alz_archetype_override.yaml):

```yaml
policy_assignments_to_remove: [
  Deploy-AzSqlDb-Auditing,
  Deploy-MDFC-DefSQL-AMA,
  Deploy-SQL-Threat,
  Deploy-VM-ChangeTrack,
  Deploy-VM-Monitoring,
  Deploy-vmArc-ChangeTrack,
  Deploy-vmHybr-Monitoring,
  Deploy-VMSS-ChangeTrack,
  Deploy-VMSS-Monitoring,
  Enable-DDoS-VNET,
]
```

**Reason:** remove workspace SQL auditing, AMA/monitoring dependencies, automatic SQL threat protection, and attachment to the disabled DDoS plan.

**Enabled-DDoS test alternative:** remove only `Enable-DDoS-VNET` from this list. Keep every monitoring/Defender removal, the active DDoS plan ID, and the enabled resource flag.

### `connectivity_custom.alz_archetype_override.yaml`

In the [connectivity override](config/lib/archetype_definitions/connectivity_custom.alz_archetype_override.yaml), source-disabled DDoS uses:

```yaml
policy_assignments_to_remove: [
  Enable-DDoS-VNET,
]
```

**Reason:** prevent policy attaching connectivity VNets to a disabled plan.

For enabled DDoS, use `policy_assignments_to_remove: []`. This is the second scope that must agree with the resource flag and plan default.

### Preserve the remaining library files

Keep the [Corp override](config/lib/archetype_definitions/corp_custom.alz_archetype_override.yaml) inheriting `base_archetype: corp` without removing `Deploy-Private-DNS-Zones`. Keep the [custom architecture](config/lib/architecture_definitions/alz_custom.alz_architecture_definition.yaml), [metadata](config/lib/alz_library_metadata.json), and remaining archetypes.

**Reason:** `architecture_name = "alz_custom"` and policy modification keys depend on these definitions. A three-subscription test may retain an empty Security management group; disabling subscription placement does not require deleting its architecture/archetype.

## 6. Use the tracked network file and module overlay

The former module ZIP is replaced by directly version-controlled files:

```text
config\
  main.connectivity.hub.and.spoke.virtual.network.tf
  modules\
    hub-and-spoke-vnet\
      ... root Terraform files and LICENSE ...
      modules\
        hub-virtual-network-mesh\
        virtual-network-gateway\
    private-link-private-dns-zones\
      ... root Terraform files and LICENSE ...
```

The module tree retains all **48 files**, including licenses, moved blocks, variables, outputs, telemetry files, and required nested modules. Do not copy only the edited files.

| File | Included change | Reason |
| --- | --- | --- |
| [Root networking overlay](config/main.connectivity.hub.and.spoke.virtual.network.tf) | `hub_and_spoke_vnet.source = "./modules/hub-and-spoke-vnet"`; no `version` argument | Make the generated starter use the patched local hub module. Preserve count, names, arguments, provider mappings, and addresses. |
| [Hub module `main.tf`](config/modules/hub-and-spoke-vnet/main.tf) | `private_dns_zones.source = "../private-link-private-dns-zones"`; no `version` argument | Use the sibling patched DNS module rather than registry DNS `0.23.2`. |
| [DNS module `locals.tf`](config/modules/private-link-private-dns-zones/locals.tf) | Return `"sae"` only for normalized `saudiarabiaeast`; preserve other region lookups | The dependency's Saudi `geo_code` is null and the unconditional `replace` rejects it. |

The DNS lookup is already included:

```hcl
locals {
  location_name = module.regions.regions_by_name_or_display_name[var.location].name
  location_geo_code = local.location_name == "saudiarabiaeast" ? (
    "sae"
  ) : module.regions.regions_by_name_or_display_name[var.location].geo_code
}
```

The module sources use Terraform's slash notation even on Windows. Neither `starter_locations_short` nor the Corp policy map changes this module's internal metadata; all three layers are required.

**Provenance:** these are the prepared hub-and-spoke `v0.17.2` and private DNS `v0.23.2` sources formerly distributed in the archive, originally copied from the generated test checkout on 19 November 2026. They retain their MIT licenses. Excess blank lines at the end of five vendored files were removed for Git whitespace checks; their Terraform content is unchanged. The networking overlay retains the starter module call with only its local source selection. This is a version-specific workaround, not a new general-purpose networking implementation.

### New bootstrap or another configuration folder

The source configuration already contains the overlay. To prepare another configuration, copy the two module folders into its `config\modules` and copy the complete networking overlay into its `config`. Do not copy tenant inputs, state, or generated repositories.

All three additional paths (`lib`, `modules`, networking file) must be passed to bootstrap in section 8. Adjacent folders are **not** included automatically. Preserve the starter's existing `modules\config-templating`; this repository's overlay does not replace it.

### Existing generated repository: fallback delivery

If bootstrap already completed without the overlay, **do not rerun bootstrap just for DNS**:

1. Create a change branch in the generated **platform repository**, not the pipeline-template repository or downloaded starter cache.
2. Compare its starter/hub/DNS versions with the pins above; inspect changed dependencies before using this version-specific overlay.
3. Copy the two tracked module folders into that root's existing `modules` folder, preserving `config-templating`. Compare pre-existing customizations before overwriting.
4. Open its root networking file once. Change the existing hub module source to `"./modules/hub-and-spoke-vnet"` and remove that call's `version` argument. Preserve its other arguments; use the full tracked overlay only if the original module call has no additional customizations.
5. Open its generated `platform-landing-zone.auto.tfvars` once and merge **all** applicable section 4 updates, preserving environment-specific configuration. Deliver the complete section 5 library changes too.
6. Commit the modules, networking change, variables, and library together through normal review. Retain the provider lock file; do not add unrelated dependency upgrades.

Do not edit `.terraform`. Source changes alone do not require state moves/imports when block names and instance keys stay unchanged, but the actual plan must confirm that.

## 7. Validate files and complete preflight

### Source checks

Select **one** configuration:

```powershell
$targetFolderPath = "D:\workarea\Source\alz\terraform\devops\single-region-hub-and-spoke-vnet-with-nva"
# For a private, ignored copy, point at its folder instead:
# $targetFolderPath = "D:\workarea\Source\alz\terraform\devops\single-region-hub-and-spoke-vnet-with-nva\.local-tests"

$requiredPaths = @(
    "$targetFolderPath\config\inputs.yaml"
    "$targetFolderPath\config\platform-landing-zone.tfvars"
    "$targetFolderPath\config\lib"
    "$targetFolderPath\config\modules"
    "$targetFolderPath\config\main.connectivity.hub.and.spoke.virtual.network.tf"
)
foreach ($path in $requiredPaths) {
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Required configuration path is missing: $path"
    }
}

terraform fmt -check -recursive "$targetFolderPath\config"
if ($LASTEXITCODE -ne 0) {
    throw "Terraform formatting/syntax check failed."
}
```

Formatting parses Terraform files, not YAML, ALZ assignment semantics, backend access, or Azure availability. Correct YAML syntax and cross-file consistency before bootstrap. This configuration overlay is **not** a complete Terraform root; do not run `terraform validate` or plan here.

### Authentication and design gates

```powershell
az login --tenant "<tenant-id>" --use-device-code
az account set --subscription "<management-subscription-id>"
az account show --query "{tenantId:tenantId,subscriptionId:id,name:name}" --output table
az account list-locations `
    --query "[?name=='saudiarabiaeast' || name=='uaenorth'].{Name:name,DisplayName:displayName}" `
    --output table
```

Repeat service/SKU/quota and regional-access checks in relevant subscriptions. Region visibility alone is insufficient. For enabled DDoS:

```powershell
$connectivitySubscriptionId = "<connectivity-subscription-id>"
az provider show `
    --subscription $connectivitySubscriptionId `
    --namespace Microsoft.Network `
    --query "resourceTypes[?resourceType=='ddosProtectionPlans'].{Type:resourceType,Locations:locations}" `
    --output json
az network ddos-protection list `
    --subscription $connectivitySubscriptionId `
    --query "[?location=='saudiarabiaeast'].{Name:name,Location:location,ResourceGroup:resourceGroup}" `
    --output table
```

Before bootstrap, confirm:

- [ ] Selected folder, subscription inputs/placements, bootstrap subscription, tenant, and parent management group agree.
- [ ] Permissions/PIM, provider registrations, Azure DevOps rights, self-hosted concurrency, approvers, and PAT environment variables are ready.
- [ ] Regional split, cross-border state/agents, inherited policy exceptions, service/SKU availability, capacity, and address ranges are approved.
- [ ] Identity location is deliberate; changing it may replace assignments/identities and role assignments.
- [ ] DDoS flag/default/both removal lists agree; VPN and Bastion deployment are approved.
- [ ] Bastion host and public IP use `zones = []`; related replacement/access risks are approved.
- [ ] For MCAPS subscriptions with the applicable policies, both VPN public IPs and the Bastion public IP include the required `FirstPartyUsage = "/Unprivileged"` tag.
- [ ] Monitoring, Defender, and resolver removals include dependent policy updates and approved alternatives.
- [ ] Corp DNS map, full DNS region, starter short name, custom library, and all overlay paths are present.
- [ ] No state, credentials, generated caches, or tenant-specific test files are staged.

## 8. Bootstrap, then verify the exact pipeline checkout

Run this **one** bootstrap command after preflight, with the selected `$targetFolderPath` and PAT variables still set:

```powershell
Deploy-Accelerator `
    -inputs "$targetFolderPath\config\inputs.yaml", "$targetFolderPath\config\platform-landing-zone.tfvars" `
    -starterAdditionalFiles "$targetFolderPath\config\lib", `
                            "$targetFolderPath\config\modules", `
                            "$targetFolderPath\config\main.connectivity.hub.and.spoke.virtual.network.tf" `
    -output "$targetFolderPath\output"
```

ALZ `7.1.5` copies additional folders by folder name and files by filename before bootstrap Terraform runs, overwriting matching starter content. Supplying only `lib` omits the workaround; supplying modules without the networking file leaves the registry hub active.

Review bootstrap's plan: UAE North resources, approved `10.250.0.*` layout (if selected), private endpoints/self-hosted agents, intended permissions/subscription placement, and no unexpected destruction or repository changes.

Bootstrap creates the delivery foundation, not the full platform deployment. Protect its output/state and retain a recoverable copy in approved storage. If it fails, correct the specific resource/permission/configuration error and rerun with the **same configuration/output and preserved state**. Do not delete state or repositories to force regeneration.

In Azure DevOps:

1. Confirm generated agents are online and the federated plan/apply service connections and approvers are correct.
2. Inspect the **exact platform branch/commit** used by CI/CD. Confirm both local module source calls have no `version`, the Saudi lookup is present, all 48 module files/licenses are committed, and `config-templating` plus the custom library remain intact.
3. Confirm generated variables retain the chosen regions/subscriptions, Corp DNS map, lowercase SQL overrides, and Bastion zone settings.
4. If an existing remote repository was not updated, deliver the changes through its normal pull-request process. Do not assume rerunning bootstrap republishes or selects your local files.
5. Run CI and **02 Azure landing zone Continuous Delivery** against the intended branch. Authorize only the intended pipeline's required service connections, pool, repositories, variable groups, and environments.

For an explicitly approved legacy provider-validation workaround on an older AzureRM provider without the location-specific switch, merge this into the top-level `variables` block of each generated CI/CD pipeline YAML:

```yaml
variables:
  ARM_PROVIDER_ENHANCED_VALIDATION: 'false'
```

This skips enhanced location and resource-provider validation, not `terraform validate` or Azure-side validation. Do not combine it with `ARM_PROVIDER_ENHANCED_VALIDATION_LOCATIONS` or `ARM_PROVIDER_ENHANCED_VALIDATION_RESOURCES`, including settings inherited from variable groups or task environments. For AzureRM 4.77+, prefer the location-only workaround described in [troubleshooting](#azurerm-metadata-rejects-the-saudi-location).

From a generated platform checkout, local syntax validation can run these commands **individually**, stopping on failure:

```powershell
terraform fmt -check -recursive
terraform init -backend=false -input=false
terraform validate
```

Retain the lock file and avoid `-upgrade` for this overlay. Local validation is not an authenticated backend plan. CI/CD must initialize the real backend and run the reviewed delivery plan.

### Platform apply acceptance checks

- No null `replace` error or SQL override casing errors.
- Backup DNS zone is `privatelink.sae.backup.windowsazure.com`; Corp policy constructs the same resource ID.
- Auto-registration is `saudiarabiaeast.azure.local`; intended private zones/VNet links and bootstrap DNS remain enabled.
- Regional platform resources target Saudi Arabia East; bootstrap resources target UAE North; policy identities match the selected design. Global resources have no regional location.
- No management-bundle workspace, DCRs, or AMA identity; listed monitoring/Defender assignments are absent and both guardrail scopes retain their disabled Defender settings.
- No Private DNS Resolver/endpoints or ExpressRoute gateway; VPN and Bastion remain enabled without Bastion zones.
- For MCAPS subscriptions with the applicable policies, all three VPN/Bastion public IPs carry the required IP tag.
- DDoS plan and assignments match the chosen enabled/disabled variant.
- No unexpected deletions, replacements, changed addresses, subscription moves, or permission changes.

Only an authorized approver should approve the acceptable plan. A successful bootstrap or local validation is not permission to skip these gates.

## 9. Validate operations and maintain version control

After apply, verify hierarchy and selected subscription placement, regional resources, private backend/image access from agents, private endpoint approval/DNS restrictions, federated identities, apply approvals, policy compliance/remediation, and a subsequent drift plan.

Deploy/license the NVA separately with an approved Saudi image/SKU. Configure IP forwarding, routing, inspection, and the replacement DNS path; align its IP with `10.0.0.4`, add/peer spokes, and test end-to-end traffic. A route pointing at an undeployed appliance is not a functioning NVA path.

Clear the local PAT environment after bootstrap:

```powershell
Remove-Item Env:\TF_VAR_azure_devops_personal_access_token
Remove-Item Env:\TF_VAR_azure_devops_agents_personal_access_token
```

Revoke the short-lived bootstrap PAT when no longer needed. Clearing local variables does not revoke tokens already supplied to agents; maintain their approved renewal/recreation process.

Use the [workspace root](../../) as the single Git repository; do not initialize nested repositories. Keep the [root ignore rules](../../.gitignore) and [scenario ignore rules](.gitignore) excluding output, temp, local tests, state, plans, provider caches, and credential files. Ignore rules cannot detect secrets inside valid source files.

Review and stage the scenario source, including the overlay and archive removal:

```powershell
Set-Location "D:\workarea\Source\alz\terraform"
git rev-parse --show-toplevel
git add -- devops\single-region-hub-and-spoke-vnet-with-nva
git diff --cached --check
git diff --cached --stat
# Inspect staged content for credentials and unintended changes before committing.
git commit -m "Track Saudi DNS modules and consolidate scenario 8 runbook" `
    -m "Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
git status --short
```

Do not force-add `.local-tests`. These source-repository steps do not publish changes to the generated Azure DevOps repositories. Ongoing platform changes belong in the generated platform repository, with reviewed variables/library/modules and normal CI/CD.

Remove the temporary overlay only after a verified upstream release fixes the dependency actually consumed by the hub module. Restore tested registry sources/versions, initialize, review a plan preserving addresses/DNS links, and remove unused local files/additional bootstrap paths in the same reviewed change. Do not assume a starter-only upgrade fixes nested metadata or promise an unverified release date.

## Troubleshooting

| Symptom | Action |
| --- | --- |
| Null `replace` still fails | Check the pipeline's committed module sources and Saudi lookup; reinitialize. Never patch `.terraform`. |
| `Module not installed` / source changed | Run `terraform init` after source changes. |
| Unexpected `version` argument | Remove it only from the two calls switched to local sources. |
| DNS policy cannot index region map | Use full `saudiarabiaeast`, its map key, and the actual Corp management-group ID. |
| SQL override rejects `"Disabled"` | Overrides use `"disabled"`; initiative parameters retain `"Disabled"`. |
| DNS links/zones unexpectedly replaced | Preserve block names and `for_each` keys; investigate the plan, do not approve. |
| `BastionRegionAzNotSupported` | Set both Bastion host and public-IP zones to `[]`; inspect state/provisioning before recovering a failed existing host. Do not blindly delete/import. |
| `randomization_factor` deprecation | Separate dependency warning, not the Bastion failure; review compatibility separately. |
| ACR fails in Saudi | Bootstrap must remain in a supported region; recheck the design constraint. |
| ACI zone error | Check support; if approved, set `agent_container_zone_support: false`. Assess `container_registry_zone_redundancy_enabled` separately. |
| Agents offline / jobs queued | Check ACI logs, image pull, PAT/pool permissions, DNS/egress, pipeline authorization, and parallel-job capacity. |
| Backend access denied/timed out | Check actual host identity roles, private endpoint approval, routing, and DNS; do not enable public access as a shortcut. |
| Azure DevOps 401/403 | Check PAT scopes/expiry/organization, account rights, and inactive YAML PAT placeholders. |
| `alz_custom` missing | Include the complete library in additional files. |
| Source edit does not affect pipeline | Verify selected folder and remote branch/commit; deliver changes to the actual checkout. |
| Invalid Security subscription placement | Supply its subscription ID or comment out its entire placement block for the three-subscription test. |
| Region/SKU denied or unavailable | Check subscription access, identity, policy, capacity, and zone support; approve a design change rather than silently relocating resources. |
| NVA next hop unreachable | Deploy/configure the appliance and reconcile routing/DNS. |

### AzureRM metadata rejects the Saudi location

The starter constrains AzureRM to `~> 4.0`. Enhanced validation can reject a new region before ARM receives a deployment request. First inspect the selected provider in the lock file/init output and verify regional/service access using the **same pipeline identity and subscriptions**, not a workstation identity alone.

For a confirmed metadata limitation, use an explicitly approved temporary setting in the variable group imported by generated CI/CD:

| Variable | Value |
| --- | --- |
| `ARM_PROVIDER_ENHANCED_VALIDATION_LOCATIONS` | `false` |

This non-secret variable is exposed to task environments. Alternatively merge it into the `env` of **every** affected Terraform validation, plan, and apply task (separate jobs do not share it), preserving other entries:

```yaml
env:
  ARM_PROVIDER_ENHANCED_VALIDATION_LOCATIONS: "false"
```

**Why the location-only variable:** AzureRM 4.77+ (the generated lock file selected 4.81.0) supports it. It disables only the stale location list. The legacy `ARM_PROVIDER_ENHANCED_VALIDATION=false` also disables resource-provider validation, and must **never** be set alongside either specific variable (the provider rejects the combination). Use the legacy variable only on an older provider that lacks the location-specific one. Neither setting bypasses Azure Policy, RBAC, quota, regional access, or actual ARM validation. Reassess on upgrades. This exception does not fix DNS geo-code metadata or SQL casing.

## Cross-check with a colleague's independent deployment

Compared on 22 November 2026 with [moselim200/saudi-alz-github-hub-spoke-nva](https://github.com/moselim200/saudi-alz-github-hub-spoke-nva), a **GitHub-variant** package (`alz_github`, same starter `v17.7.0`, Terraform `1.14.9`, ALZ `7.1.5`). Its owner reports a verified deployment; that is customer-reported, with no independent run evidence, and it is not an Azure DevOps result.

| Area | Result |
| --- | --- |
| Hub-and-spoke `v0.17.2` / private DNS `v0.23.2` module sources | **Match** this guide's 48 files, apart from documentation/test files only they ship. Their hub module points to their `../private-dns-zones` path; ours to `../private-link-private-dns-zones`. |
| Saudi DNS code | **Match**: `saudiarabiaeast` maps to `sae`, giving `privatelink.sae.backup.windowsazure.com`. They use `lookup()`; we use a conditional; behavior is equivalent. |
| Corp DNS policy map | **Match**: `dnzZoneRegionShortNames.saudiarabiaeast = "sae"` at `corp`. |
| Bastion and public-IP zones | **Match**: both `[]` (they also note Saudi zonal creation failed). |
| Bootstrap | **Match**: entire bootstrap in `uaenorth`, private networking, `10.250.0.0/24` layout, `allow_storage_access_from_my_ip: false`, explicit bootstrap subscription, and four distinct subscriptions. |
| Policy-assignment identity location | **Corrected here**: they use `uaenorth` because Saudi identity creation failed. This guide previously used Saudi. |
| NVA subnet route table | **Added here**: they disable `assign_generated_route_table` on the NVA subnet. This guide lacked it. |
| Provider validation variable | **Updated here**: they set `ARM_PROVIDER_ENHANCED_VALIDATION_LOCATIONS=false` in each plan/apply job (CI plan, CD plan, CD apply), not the broader legacy variable. |
| Log Analytics, Private DNS Resolver | Same disabled profile; they report Azure rejected both in Saudi Arabia East. Recheck for your subscriptions. |
| VPN gateway, DDoS | **Not validated.** They disable the gateways and DDoS as lab choices, so their deployment gives no evidence for this guide's VPN or the enabled-DDoS variant. Keep the earlier availability checks. |
| Defender policy removals | They remove only `Deploy-MDFC-Config-H224` at the root and keep `Deploy-SQL-Threat`. This guide's broader removals are a separate security decision, not an error. |
| Public-IP tags (`FirstPartyUsage`) | They do not use them; ours remain opt-in for MCAPS policy requirements only. |
| Pipeline | They edit the GitHub workflow templates directly. Azure DevOps uses the variable group or task `env` approach in the troubleshooting section. |

Their package also adds mocked-plan tests (`terraform test`) and a launcher script; those are useful references but are not adopted here.

## Historical test evidence and limits

- **19 November 2026, policy identity:** an isolated resource-group-scope ARM test created/read a Saudi policy assignment with a system-assigned identity and nonempty principal. Azure CLI 2.93.0 policy creation failed in built-in resolution; `az rest` with API `2024-04-01` succeeded. The policy was disabled/non-enforcing with no identity role assignments, and temporary resources were removed. This does **not** cover management-group scope, which is what the accelerator uses. A later full deployment reported by a colleague (and a manual test) failed to create Saudi policy identities, so this guide uses `uaenorth` for them.
- **19 November 2026, DDoS:** one tested Connectivity subscription advertised Saudi DDoS plans, another did not. No existing Saudi plan was found in that test. Availability is subscription-specific and must be rechecked.
- **19 November 2026, local overlay generation:** ALZ `7.1.5`, bootstrap `v7.3.2`, starter `v17.7.0`, and Terraform `1.14.9` generated files successfully using `alz_local` with `create_bootstrap_resources_in_azure: false`. The plan used 96 local files, one random string, and one time value, without managed Azure/Azure DevOps resources. All 48 module files and the networking overlay matched; five config-templating files and 14 library files remained. Platform initialization/validation passed. The architecture's normal root-existing transformation did not create an Azure group.

For a separate local-only generation experiment, use a **new** ignored test folder and the local input schema: `bootstrap_module_name: "alz_local"`, explicit `create_bootstrap_resources_in_azure: false`, the above pins, and your own `target_directory`. Do not repurpose the existing Azure DevOps test or execute the generated deployment script. Local mode otherwise defaults to creating Azure bootstrap resources and still required Azure CLI authentication in the historical trial.

The historical trial needed a narrowly skipped package-feed ALZ version lookup and process-only Git long-path support. These are not blanket instructions to bypass preflight or modify global Git settings. It did not test Azure DevOps publication, regional platform plan/apply, service availability, policy evaluation, or DNS resource creation.

## References

Official guidance originally consulted on 19 November 2026; recheck before deployment:

- [Scenario 8: hub and spoke with NVA](https://azure.github.io/Azure-Landing-Zones/accelerator/starter-terraform/scenarios/single-region-hub-and-spoke-vnet-with-nva/)
- [Planning](https://azure.github.io/Azure-Landing-Zones/accelerator/0_planning/)
- [Tooling prerequisites](https://azure.github.io/Azure-Landing-Zones/accelerator/1_prerequisites/)
- [Platform subscriptions and permissions](https://azure.github.io/Azure-Landing-Zones/accelerator/1_prerequisites/platform-subscriptions/)
- [Azure DevOps prerequisites/PATs](https://azure.github.io/Azure-Landing-Zones/accelerator/1_prerequisites/azuredevops/)
- [Advanced bootstrap commands](https://azure.github.io/Azure-Landing-Zones/accelerator/2_bootstrap/advanced/)
- [Deployment pipeline](https://azure.github.io/Azure-Landing-Zones/accelerator/3_run/)
- [Bootstrap inputs](https://github.com/Azure/accelerator-bootstrap-modules/blob/main/alz/azuredevops/variables.tf)
- [Bootstrap region/resource wiring](https://github.com/Azure/accelerator-bootstrap-modules/blob/main/alz/azuredevops/main.tf)
- [Products by region](https://azure.microsoft.com/explore/global-infrastructure/products-by-region/)
- [AMA options](https://azure.github.io/Azure-Landing-Zones/accelerator/starter-terraform/options/ama/)
- [DDoS options](https://azure.github.io/Azure-Landing-Zones/accelerator/starter-terraform/options/ddos/)
- [Defender options](https://azure.github.io/Azure-Landing-Zones/accelerator/starter-terraform/options/defender/)
- [Pinned SQL guardrail](https://github.com/Azure/Azure-Landing-Zones-Library/blob/platform/alz/2026.11.0/platform/alz/policy_set_definitions/Enforce-Guardrails-SQL.alz_policy_set_definition.json)
- [Pinned management-resource deployment](https://github.com/Azure/alz-terraform-accelerator/blob/v17.7.0/templates/platform_landing_zone/main.management.resources.tf)
- [Pinned policy defaults](https://github.com/Azure/Azure-Landing-Zones-Library/blob/platform/alz/2026.11.0/platform/alz/alz_policy_default_values.json)
- [Pinned Defender initiative](https://github.com/Azure/Azure-Landing-Zones-Library/blob/platform/alz/2026.11.0/platform/alz/policy_set_definitions/Deploy-MDFC-Config_20240319.alz_policy_set_definition.json)
- [Pinned DNS initiative](https://github.com/Azure/Azure-Landing-Zones-Library/blob/platform/alz/2026.11.0/platform/alz/policy_set_definitions/Deploy-Private-DNS-Zones.alz_policy_set_definition.json)
- [Starter short-name replacement](https://github.com/Azure/alz-terraform-accelerator/blob/v17.7.0/templates/platform_landing_zone/modules/config-templating/locals.config.tf)
- [Starter networking module call](https://github.com/Azure/alz-terraform-accelerator/blob/v17.7.0/templates/platform_landing_zone/main.connectivity.hub.and.spoke.virtual.network.tf)
- [Hub-and-spoke source v0.17.2](https://github.com/Azure/terraform-azurerm-avm-ptn-alz-connectivity-hub-and-spoke-vnet/tree/v0.17.2)
- [Private DNS source v0.23.2](https://github.com/Azure/terraform-azurerm-avm-ptn-network-private-link-private-dns-zones/tree/v0.23.2)
- [DNS substitution](https://github.com/Azure/terraform-azurerm-avm-ptn-network-private-link-private-dns-zones/blob/v0.23.2/locals.tf)
- [Regions geo-code map](https://github.com/Azure/terraform-azurerm-avm-utl-regions/blob/v0.12.0/locals.geo.codes.tf.json)
- [AzureRM 4.0 enhanced validation](https://github.com/hashicorp/terraform-provider-azurerm/blob/v4.0.0/internal/features/enhanced_validation.go)
- [AzureRM 4.77 enhanced-validation controls](https://github.com/hashicorp/terraform-provider-azurerm/blob/v4.77.0/internal/features/enhanced_validation.go)
