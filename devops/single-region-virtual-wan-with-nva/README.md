# Scenario 9: Saudi Arabia landing zone with Virtual WAN, Terraform and Azure DevOps

Deploy a **single-region Virtual WAN with a sidecar virtual network prepared for a Network Virtual Appliance (NVA)** using the Azure Landing Zones accelerator, private bootstrap networking, and self-hosted Azure DevOps agents.

This is a self-contained configuration and deployment runbook, not proof of a successful Azure deployment. No other scenario needs to be read or deployed first. Complete each file's edits before proceeding to validation and bootstrap.

> **Colleague packages are test references, not the source of truth.** [moselim200/saudi-alz-azuredevops-vwan-nva](https://github.com/moselim200/saudi-alz-azuredevops-vwan-nva) and [moselim200/saudi-alz-github-vwan-nva](https://github.com/moselim200/saudi-alz-github-vwan-nva) were used to cross-check this guide (section 10) and are recommended for teams that prefer not to customize files themselves (section 11).

## 1. Select the configuration and understand the regional split

Paths are relative to this scenario folder unless stated otherwise.

| Component | Setting |
| --- | --- |
| Bootstrap resources, agents, registry, Terraform backend | UAE North: `uaenorth` |
| Regional platform resources (Virtual WAN, hub, sidecar VNet, Bastion, DNS) | Saudi Arabia East: `saudiarabiaeast` |
| Policy-assignment managed identities | UAE North (identity-only exception) |
| Version control / pipelines / agents | Azure DevOps Services, self-hosted ACI agents |
| Bootstrap networking | Private endpoints and a dedicated VNet |
| Pinned starter / Terraform / ALZ module / bootstrap | `v17.7.0` / `1.14.9` / `7.1.5` / `v7.3.2` |
| Connectivity modules | Virtual WAN `0.18.0` (vendored), Private DNS `0.23.2` (vendored, Saudi-patched) |

**Why two regions?** The agent bootstrap depends on Azure Container Registry (ACR), which was unavailable in Saudi Arabia East for this design. Keep bootstrap in UAE North while that dependency is unavailable. Recheck service/SKU availability, subscription access, quota, and zone support before execution.

**Data residency approval is required.** Bootstrap state, agent execution, images, and storage are outside Saudi Arabia; Azure DevOps has its own organization data location. State and pipeline artifacts can contain sensitive infrastructure metadata. Private endpoints do not make them Saudi-resident. If all deployment data must remain in Saudi Arabia, stop and approve another supported bootstrap design.

The scenario does **not** deploy an NVA, vendor licenses, production spokes, an ExpressRoute circuit, or an on-premises VPN device. It also creates **no routing** that sends traffic to an NVA (section 4).

### What this topology is

| Resource | Notes |
| --- | --- |
| Virtual WAN and one virtual hub (`10.0.0.0/22`) | Microsoft-managed hub in the connectivity subscription. |
| Sidecar virtual network (`10.0.4.0/22`) | Connected to the hub. Holds the NVA subnet, the Bastion subnet, and the (disabled) DNS resolver subnet. |
| NVA subnet (`10.0.4.64/26`) | Where you deploy the appliance. `10.0.4.68` is a sample address. |
| Azure Bastion (Standard) | In the sidecar VNet. |
| Private DNS zones, VNet links, auto-registration zone | Linked to the sidecar VNet. |
| VPN gateway in the virtual hub | Enabled in source; not validated in Saudi (see below). |

The Virtual WAN hub has no appliance subnet to protect from a self-route, so the hub-and-spoke module's `assign_generated_route_table` setting does not exist here.

### Tracked source defaults

| Setting | Tracked [config](config/) |
| --- | --- |
| Platform subscriptions | Four placeholders requiring customer input; Security placement is active |
| Policy-assignment identity location | `uaenorth` |
| Starter short name / Corp DNS map | `sae` / Saudi map |
| DDoS plan and auto-enablement policies | Disabled |
| VPN gateway / ExpressRoute gateway | VPN **enabled**, ExpressRoute disabled |
| Private DNS zones / auto-registration | Enabled |
| Private DNS Resolver / Azure Firewall | Disabled |
| Log Analytics bundle / automatic Defender enablement | Disabled |
| Bastion host and public-IP zones | `[]` on both |
| MCAPS public-IP tag | Commented out (Bastion public IP only) |
| Saudi DNS and Virtual WAN overlay | Included as source files |

**Deliberate design choices to keep consistent:**

- **VPN gateway is unvalidated.** The source keeps the hub VPN gateway enabled. The colleague's lab disabled it, so no verified Saudi deployment covers it. Check Virtual WAN VPN gateway availability and scale units in Saudi Arabia East before bootstrap, or set `primary_virtual_network_gateway_vpn_enabled = false`.
- **Private DNS Resolver is disabled.** Azure rejected it in Saudi Arabia East in the tests behind this guide. The standard design has the NVA forward DNS to the resolver; see section 9 for the replacement path you must approve.
- **Policy identities in UAE North:** Saudi creation failed in a manual test and an independent deployment. This identity-only exception does not move Saudi resources; keep `resource_group_location` and `private_dns_zone_region` on the Saudi region. Changing identity location can replace assignments, identities, and role assignments.
- **Security subscription:** supply its ID or comment out the **entire** placement block for three subscriptions.
- **Bootstrap subscription and network:** set the bootstrap subscription explicitly; the `10.250.0.0/24` layout needs IPAM approval.

## 2. Prepare permissions, tools, and Azure DevOps

### Azure and Azure DevOps prerequisites

Prepare Management, Connectivity, Identity, and Security subscriptions in one Microsoft Entra tenant. Record their IDs and the tenant ID. Select an existing parent management group, or use an empty parent value for Tenant Root Group. The bootstrap account needs `Owner` on the parent management group and all selected subscriptions, including bootstrap; activate PIM roles first. Inherited allowed-location policies must allow UAE North bootstrap resources and Saudi platform resources, or have approved scope-specific exemptions.

Use an Azure DevOps Services organization connected to the intended tenant. The account needs rights to manage projects, repositories, pipelines, service connections, environments, and the organization-level agent pool. Confirm at least one **self-hosted parallel job** is available; agents alone do not provide concurrency.

### Tools and scenario selection

Use PowerShell **7.4+**, Azure CLI **2.55.0+**, Git, and Terraform **1.14.9** for local checks. Allow outbound access to Azure, Azure DevOps, Entra ID, PowerShell Gallery, GitHub, and Terraform/package download endpoints. Cloud Shell and corporate-proxy operation are not explicitly supported.

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
$scenarioNumber = 9
$targetFolderPath = ".\devops\single-region-virtual-wan-with-nva"
```

**The scenario already exists in this workspace. Skip generation.** For a new, empty destination only:

```powershell
New-AcceleratorFolderStructure `
    -iacType $iacType `
    -versionControl $versionControl `
    -scenarioNumber $scenarioNumber `
    -targetFolderPath $targetFolderPath
```

Back up customizations before deliberate regeneration.

### Two personal access tokens

Create organization-scoped PATs under **User settings > Personal access tokens**. PAT scopes do not grant rights the account lacks.

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

Use a short bootstrap-PAT lifetime. The separate **agent registration PAT** needs only **Agent Pools > Read & manage**; establish renewal and agent-recreation procedures before expiry.

Set both PATs as environment variables and keep the YAML entries commented out:

```powershell
$env:TF_VAR_azure_devops_personal_access_token = Read-Host "Bootstrap PAT (token 1)" -MaskInput
$env:TF_VAR_azure_devops_agents_personal_access_token = Read-Host "Agent registration PAT (token 2)" -MaskInput
```

Never print or commit tokens. Explicit YAML values can take precedence over environment variables, so keep both PAT entries commented out. State and generated artifacts still require protection. In a new terminal restore authentication, variables, and the selected folder.

## 3. Edit `config/inputs.yaml` once

Open [inputs.yaml](config/inputs.yaml), complete all entries below, then save. Customer values and the four network keys are not already configured in the tracked source.

| Entry | Required update |
| --- | --- |
| `bootstrap_location` | Keep `"uaenorth"` for bootstrap ACR/agents, separate from the Saudi platform. |
| `root_parent_management_group_id` | Existing management-group ID (not a full resource ID), or `""` for Tenant Root Group. |
| `subscription_ids` | Fill Management, Connectivity, Identity, and Security IDs. |
| `bootstrap_subscription_id` | Set the management subscription ID explicitly; do not rely on the current CLI selection. |
| `service_name`, `environment_name`, `postfix_number` | Keep `"alz"`, `"mgmt"`, `1`, or approved values; preserve names/state on reruns. |
| `use_self_hosted_agents`, `use_private_networking` | Both `true`. |
| `azure_devops_organization_name`, `azure_devops_project_name` | Organization name only (not URL), and the intended project name. |
| `apply_approvers` | Approved organization user principal names; retain the apply approval gate. |
| Both PAT entries | Keep commented out; use section 2 environment variables. |
| `starter_module_version`, `terraform_version` | `"v17.7.0"`, `"1.14.9"`. |
| `iac_type`, `bootstrap_module_name`, `starter_module_name` | `"terraform"`, `"alz_azuredevops"`, `"platform_landing_zone"`. |

Add these four keys together, after IPAM approval:

```yaml
virtual_network_address_space: "10.250.0.0/24"
virtual_network_subnet_address_prefix_container_instances: "10.250.0.0/26"
virtual_network_subnet_address_prefix_private_endpoints: "10.250.0.64/26"
allow_storage_access_from_my_ip: false
```

This leaves `10.250.0.128/25` unallocated. Check corporate, VPN, ExpressRoute, hub, sidecar, and future-spoke ranges. For existing bootstrap networking, inspect the actual network and plan before changing it. For an existing project, add `azure_devops_create_project: false` only after confirming administrative rights and no conflicts.

Private networking is not air-gapped: bootstrap includes NAT Gateway/public-IP egress. Agents need outbound HTTPS to Azure DevOps, Entra ID, ARM, and package sources, plus private routing/DNS to backend storage and ACR. Preserve ACI subnet delegation and DNS links; do not open blanket inbound access. `allow_storage_access_from_my_ip: false` does not provide private workstation access; use self-hosted pipelines for platform Terraform runs.

## 4. Review `config/platform-landing-zone.tfvars`

Open [platform-landing-zone.tfvars](config/platform-landing-zone.tfvars). Merge changes into existing blocks without duplicate top-level maps, and preserve `$${...}` tokens. The tracked configuration includes:

| Block / entry | Source value | Reason |
| --- | --- | --- |
| `connectivity_type` | `"virtual_wan"` | Selects the Virtual WAN connectivity module. |
| `starter_locations`, `starter_locations_short` | `["saudiarabiaeast"]`, `sae` | Regional resources stay in Saudi Arabia East; the starter lacks the short code. |
| `management_group_settings.location` | `"uaenorth"` | Policy identities only. |
| `ddos_protection_plan_enabled` | `false` | With the DDoS plan ID commented out and `Enable-DDoS-VNET` removed in two library files. |
| `primary_virtual_network_gateway_vpn_enabled` | `true` | Unvalidated (section 1). |
| `primary_virtual_network_gateway_express_route_enabled` | `false` | No ExpressRoute in this design. |
| `primary_private_dns_resolver_enabled` | `false` | Resolver rejected in Saudi Arabia East. Zones, links, and auto-registration stay on. |
| `virtual_hubs.primary.enabled_resources.firewall` | `false` | NVA scenario, not Azure Firewall. |
| `virtual_hubs.primary.bastion.zones` and `bastion_public_ip.zones` | `[]` | Saudi zonal Bastion creation failed (`BastionRegionAzNotSupported`). |
| `management_resources_enabled` | `false` | Disables the whole management bundle; matching removals in the library. |

Address replacements (sample values that need IPAM approval; update the related `primary_*` values together):

| Replacement | Default |
| --- | --- |
| Regional routing space (documentation) | `10.0.0.0/16` |
| Virtual hub address prefix | `10.0.0.0/22` |
| Sidecar VNet | `10.0.4.0/22` |
| Bastion subnet | `10.0.4.0/26` |
| NVA subnet / sample address | `10.0.4.64/26` / `10.0.4.68` |
| Resolver subnet prefix (resolver disabled) | `10.0.4.128/28` |

The `primary_nva_ip_address` replacement is **not referenced by any resource**; it only documents the intended appliance address. Nothing routes to it.

### No NVA routing is created

The generated configuration creates the hub, the sidecar VNet connection, and the NVA subnet. It does **not** create static routes, route maps, routing intent, or a hub route table that sends traffic through an appliance. Design that separately, using the supported vWAN NVA patterns, before you attach spokes. The pinned module version (`0.18.0`) exposes hub `route_tables` and `route_maps` inputs; later `0.18.x` releases add more (static routes on connections), but this overlay does not upgrade the module.

For the MCAPS-only public-IP tag, uncomment the `ip_tags` line in `virtual_hubs.primary.bastion.bastion_public_ip` after confirming that the applied policy requires `FirstPartyUsage = "/Unprivileged"`. Put it in the public-IP object, not ordinary resource tags; keep `zones = []`. This configuration defines no public-IP resource for the hub VPN gateway, so there is nothing else to tag.

### Policy defaults and modifications

Keep `management_groups_enabled = true` and `management_group_settings.architecture_name = "alz_custom"`. Match `subscription_placement` to the YAML IDs; for a three-subscription test, comment out the **entire** Security placement block, not just its ID.

In `management_group_settings.policy_default_values`:

| Entries | Required state and reason |
| --- | --- |
| `ama_change_tracking_data_collection_rule_id`, `ama_mdfc_sql_data_collection_rule_id`, `ama_vm_insights_data_collection_rule_id`, `ama_user_assigned_managed_identity_id`, `ama_user_assigned_managed_identity_name`, `log_analytics_workspace_id` | Commented out: dependent resources and assignments are disabled. |
| `ddos_protection_plan_id` | Commented out for disabled DDoS. |
| `resource_group_name_mdfc`, `email_security_contact` | Commented out: automatic Defender configuration is excluded. |
| `resource_group_location`, `resource_group_name_service_health_alerts` | Active: service-health policy still uses them; keep location on the Saudi replacement. |
| `private_dns_zone_subscription_id` | `"$${subscription_id_connectivity}"`. |
| `private_dns_zone_region` | `"$${starter_location_01}"` (full region, not `sae`). |
| `private_dns_zone_resource_group_name` | `"$${dns_resource_group_name}"`. |

In the existing `policy_assignments_to_modify` map, keep the `corp` assignment `Deploy-Private-DNS-Zones` with `parameters.dnzZoneRegionShortNames = { saudiarabiaeast = "sae" }`. It constructs the same Backup zone ID as Terraform: `privatelink.sae.backup.windowsazure.com`. This replaces the entire default region map; extend it before adding another DNS region. If the Corp management-group ID changes, update the modification key. Do not remove the Corp DNS assignment.

Keep the entire `alz.policy_assignments.Deploy-MDFC-Config-H224` modification commented out because its assignment is excluded. Under **both** `platform.policy_assignments` and `landingzones.policy_assignments`, retain:

| Assignment | Parameter | Value |
| --- | --- | --- |
| `Enforce-GR-MySQL0` | `mySqlAdvThreatProtection` | `"Disabled"` |
| `Enforce-GR-PostgreSQL0` | `postgreSqlAdvThreatProtection` | `"Disabled"` |
| `Enforce-GR-Storage0` | `storageThreatProtection` | `"Disabled"` |
| `Enforce-GR-Synapse0` | `synapseDefender` | `"Disabled"` |
| `Enforce-GR-SQL0` | `sqlManagedDefender` | `"Disabled"` |

For `Enforce-GR-SQL0` in **both scopes**, also retain the `policyEffect` override with lowercase `value = "disabled"` and selector `kind = "policyDefinitionReferenceId"`, `in = ["Dine-Sql-Adv-Data"]`. That initiative member independently enables Advanced Data Security without an exposed effect parameter. Parameters use `"Disabled"`; overrides use `"disabled"`. Preserve other enforcement settings.

Keep private zones, VNet links, and auto-registration (`saudiarabiaeast.azure.local`) enabled. `.local` can conflict with multicast DNS; consider a customer-owned suffix before production and update it consistently.

### Existing deployments and future re-enablement

- Disabling management resources can delete the workspace, DCRs, AMA identity, and resource group. Review retention/export, shared resources, deletion protection, and dependencies first. Policy removal does not clean up agents, diagnostic settings, DCR associations, SQL auditing, or export automations.
- Removing Defender policies does not set existing plans to `Free`, remove integrations, or stop billing. Inventory existing protection, inherited policy, and automation separately.
- Removing DDoS Network Protection does not remove baseline infrastructure protection or automatically enable IP Protection. Review VNet associations and approve alternatives.
- Resolver removal can delete endpoints/subnets and break forwarding. Bastion/public-IP or gateway changes can replace resources and interrupt access. Review the exact plan.
- This reduced profile lacks centralized Log Analytics, VM Insights, AMA change tracking, SQL audit destination, and automatic Defender enablement. Obtain security/monitoring/compliance approval and alternatives. Remaining audit policies can still report noncompliance.

To re-enable monitoring, restore the management bundle, its policy defaults, and dependent library assignments together. Before Defender re-enablement, review the complete retained source block and replace `defender_email_security_contact`. If Log Analytics stays off, retain `parameters.logAnalytics = ""` and the disabled override selecting `["ascExport", "defenderforKubernetes"]`; an empty workspace is not an alternative logging destination.

## 5. Custom library

In [config/lib/archetype_definitions/](config/lib/archetype_definitions/), preserve other fields and keep these complete `policy_assignments_to_remove` lists active. Commenting out a removal **re-enables** the inherited assignment.

| Override file | Complete removal list | Reason |
| --- | --- | --- |
| [root_custom](config/lib/archetype_definitions/root_custom.alz_archetype_override.yaml) | `Deploy-AzActivity-Log`, `Deploy-Diag-LogsCat`, `Deploy-MDFC-Config-H224`, `Deploy-MDFC-OssDb`, `Deploy-MDFC-SqlAtp`, `Deploy-MDEndpoints`, `Deploy-MDEndpointsAMA` | Remove workspace log forwarding and automatic Defender/endpoint configuration. |
| [platform_custom](config/lib/archetype_definitions/platform_custom.alz_archetype_override.yaml) | `DenyAction-DeleteUAMIAMA`, `Deploy-MDFC-DefSQL-AMA`, `Deploy-VM-ChangeTrack`, `Deploy-VM-Monitoring`, `Deploy-vmArc-ChangeTrack`, `Deploy-vmHybr-Monitoring`, `Deploy-VMSS-ChangeTrack`, `Deploy-VMSS-Monitoring` | Remove disabled AMA identity protection and dependent deployments. |
| [landing_zones_custom](config/lib/archetype_definitions/landing_zones_custom.alz_archetype_override.yaml) | `Deploy-AzSqlDb-Auditing`, `Deploy-MDFC-DefSQL-AMA`, `Deploy-SQL-Threat`, `Deploy-VM-ChangeTrack`, `Deploy-VM-Monitoring`, `Deploy-vmArc-ChangeTrack`, `Deploy-vmHybr-Monitoring`, `Deploy-VMSS-ChangeTrack`, `Deploy-VMSS-Monitoring`, `Enable-DDoS-VNET` | Remove workspace auditing, monitoring, SQL threat protection, and attachment to a disabled DDoS plan. |
| [connectivity_custom](config/lib/archetype_definitions/connectivity_custom.alz_archetype_override.yaml) | `Enable-DDoS-VNET` | Do not attach connectivity VNets to a disabled plan. |

For an approved enabled-DDoS variant, set `custom_replacements.names.ddos_protection_plan_enabled = true`, activate the policy default `ddos_protection_plan_id = "$${ddos_protection_plan_id}"`, remove only `Enable-DDoS-VNET` from the landing-zones removal list, and set the connectivity removal list to `[]`. Keep all monitoring/Defender removals and check Saudi DDoS availability first.

Preserve [corp_custom](config/lib/archetype_definitions/corp_custom.alz_archetype_override.yaml) with `base_archetype: corp` and no removal of `Deploy-Private-DNS-Zones`, the [custom architecture](config/lib/architecture_definitions/alz_custom.alz_architecture_definition.yaml), [metadata](config/lib/alz_library_metadata.json), and all other archetypes. Architecture and policy modification keys depend on them. A three-subscription test can retain an empty Security management group.

## 6. Module and networking overlay

The tracked files are:

```text
config\
  main.connectivity.virtual.wan.tf
  modules\
    virtual-wan\                 89 files: root .tf files, LICENSE, 11 child modules under modules\
    private-link-private-dns-zones\   7 files, including the Saudi DNS patch
```

| File | Change | Reason |
| --- | --- | --- |
| [Root networking overlay](config/main.connectivity.virtual.wan.tf) | `source = "./modules/virtual-wan"`, no `version` | The starter's registry call to `0.18.0` is replaced by the local copy. |
| [virtual-wan `main.tf`](config/modules/virtual-wan/main.tf) | `private_dns_zones.source = "../private-link-private-dns-zones"`, no `version` | Use the patched DNS module instead of registry `0.23.2`. |
| [DNS `locals.tf`](config/modules/private-link-private-dns-zones/locals.tf) | Return `"sae"` for `saudiarabiaeast` | The upstream Saudi `geo_code` is null and `replace` rejects it. |

Everything else is unchanged upstream content: virtual-wan `v0.18.0` (commit `116594239389f448c8db52b225566ef9e7ca68b5`) and private DNS `v0.23.2`, both MIT-licensed. Only runtime `.tf` files and the license are kept (no docs, tests, or tooling). The child modules are vendored locally, so the pipeline does not need Git access to GitHub at `terraform init`. As of 22 November 2026 upstream has newer releases (vWAN `0.18.2`, DNS `0.23.3`); neither fixes the Saudi geo code, and this overlay deliberately stays on the starter's pins. Do not edit `.terraform`.

All three overlay paths must be passed to bootstrap (section 8); adjacent folders are not copied automatically. Preserve the starter's existing `modules\config-templating`. The overlay merges by folder name and does not replace it. The starter short name, Corp DNS map, and module patch fix three separate lookups; all are required.

### Existing generated repository: fallback delivery

If bootstrap completed without the overlay, **do not rerun bootstrap just for DNS**:

1. Create a change branch in the generated **platform repository**, not the pipeline-template repository or starter cache.
2. Compare its starter/vWAN/DNS versions with the pins above; inspect dependencies before applying this version-specific overlay.
3. Copy the complete tracked `virtual-wan` and `private-link-private-dns-zones` module folders into its existing `modules` folder, preserving `config-templating` and comparing customizations before overwriting.
4. In its root networking file, change the existing vWAN module source to `"./modules/virtual-wan"` and remove only that call's `version`. Preserve all other arguments, providers, names, and instance keys.
5. Merge all applicable section 4 changes into its generated `platform-landing-zone.auto.tfvars`, and deliver the complete section 5 library.
6. Submit the modules, networking, variables, and library together through normal review. Retain the provider lock file; do not introduce unrelated upgrades.

Never edit `.terraform`. Unchanged block names and instance keys should not need state moves/imports, but the actual plan must confirm that.

## 7. Validate files and complete preflight

### Source and staged checks

```powershell
$targetFolderPath = "D:\workarea\Source\alz\terraform\devops\single-region-virtual-wan-with-nva"
$requiredPaths = @(
    "$targetFolderPath\config\inputs.yaml"
    "$targetFolderPath\config\platform-landing-zone.tfvars"
    "$targetFolderPath\config\lib"
    "$targetFolderPath\config\modules"
    "$targetFolderPath\config\main.connectivity.virtual.wan.tf"
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

Formatting does not validate YAML, ALZ semantics, backend access, or availability. This overlay is **not** a complete Terraform root; do not run `terraform validate` or plan here.

For a stronger offline check that needs **no Azure sign-in**, run the staged validation. It clones the pinned starter into a temporary folder, overlays this configuration the way bootstrap does, then runs `fmt`, `init -backend=false`, `validate`, and mocked `terraform test`. It does not change the repository.

```powershell
$tf = "<path-to-terraform-1.14.9>\terraform.exe"
& "$targetFolderPath\tests\Invoke-StagedValidation.ps1" -TerraformPath $tf
```

The mocked test ([saudi_profile.tftest.hcl](tests/saudi_profile.tftest.hcl)) mocks region metadata with a null Saudi geo code and asserts the active-module choice, UAE policy identities with Saudi resources, the Corp DNS map, the enabled/disabled resource profile, empty Bastion zones, disabled management resources, and the final Backup zone name `privatelink.sae.backup.windowsazure.com`.

**Result recorded on 22 November 2026** (Terraform `1.14.9`, starter `v17.7.0`): `fmt`, `init`, `validate` passed and `4 passed, 0 failed` (the starter's three tests plus this one). A negative control with the registry DNS module restored failed with the expected `replace ... argument must not be null` error, so the test does detect a missing patch. The mocks replace the VPN-gateway module outputs and Azure region lookups; this is **not** an authenticated plan and proves nothing about Azure availability, policy, quota, or RBAC.

### Authentication and design gates

```powershell
az login --tenant "<tenant-id>" --use-device-code
az account set --subscription "<management-subscription-id>"
az account list-locations `
    --query "[?name=='saudiarabiaeast' || name=='uaenorth'].{Name:name,DisplayName:displayName}" `
    --output table
```

Repeat service/SKU/quota checks in the relevant subscriptions. Additionally for this scenario, confirm Virtual WAN (Standard) and hub support, and the VPN gateway, in Saudi Arabia East for the connectivity subscription.

Before bootstrap, confirm:

- [ ] Selected folder, subscription inputs/placements, bootstrap subscription, tenant, and parent management group agree.
- [ ] Azure permissions/PIM, provider registrations, Azure DevOps administrative rights, self-hosted concurrency, approvers, and both PAT variables are ready.
- [ ] Regional split, cross-border state/agents, identity exception, inherited policies, capacity, and address ranges are approved.
- [ ] Monitoring, Defender, and resolver removals include dependent policies and approved alternatives.
- [ ] Corp DNS map, full DNS region, starter short name, complete custom library, and all overlay paths are present.
- [ ] MCAPS Bastion public-IP tag is enabled only if required by applied policy.
- [ ] No state, credentials, generated caches, or tenant-specific test files are staged.
- [ ] Virtual WAN, hub, sidecar VNet, Bastion, and (if kept) the VPN gateway are available for the connectivity subscription in Saudi Arabia East.
- [ ] Hub (`10.0.0.0/22`) and sidecar (`10.0.4.0/22`) ranges do not overlap on-premises, bootstrap, or future spokes.
- [ ] The NVA routing and DNS designs (sections 4 and 9) have owners; nothing in this configuration provides them.
- [ ] Bastion host and public IP use `zones = []`; DDoS flag, plan ID, and both library removals agree.

## 8. Bootstrap, then verify the exact pipeline checkout

Run this **one** command after preflight, with the PAT variables set:

```powershell
Deploy-Accelerator `
    -inputs "$targetFolderPath\config\inputs.yaml", "$targetFolderPath\config\platform-landing-zone.tfvars" `
    -starterAdditionalFiles "$targetFolderPath\config\lib", `
                            "$targetFolderPath\config\modules", `
                            "$targetFolderPath\config\main.connectivity.virtual.wan.tf" `
    -output "$targetFolderPath\output"
```

ALZ `7.1.5` copies additional folders by folder name and files by filename before bootstrap Terraform runs. Passing only `lib` omits the workaround; modules without the networking file leaves the registry Virtual WAN module active.

### AzureRM provider-validation workaround

The starter constrains AzureRM to `~> 4.0`. Enhanced validation can reject `saudiarabiaeast` before ARM sees a request. Check the selected provider in the lock file/init output, and verify service/regional access using the **same pipeline identity and subscriptions**.

For a confirmed metadata limitation on AzureRM **4.77+**, add the non-secret variable `ARM_PROVIDER_ENHANCED_VALIDATION_LOCATIONS` with value `false` to the variable group imported by generated CI/CD, or merge this into **every** Terraform validation, plan, and apply task's environment:

```yaml
env:
  ARM_PROVIDER_ENHANCED_VALIDATION_LOCATIONS: "false"
```

Separate jobs do not share task environments. This disables only stale location validation, not resource-provider validation. Never combine it with legacy `ARM_PROVIDER_ENHANCED_VALIDATION`; the provider rejects the combination. Use the broader legacy switch only on an older provider without the location-specific switch and with explicit approval. Neither bypasses Policy, RBAC, quota, regional access, or ARM validation, and neither fixes DNS metadata or SQL casing. Reassess on upgrades.

Alternatively, bake the location-only setting into bootstrap: clone `https://github.com/Azure/accelerator-bootstrap-modules.git` at `v7.3.2` outside this repository, add the line to the AzureCLI task's `env:` in both `alz\azuredevops\pipelines\terraform\templates\helpers\terraform-plan.yaml` and `terraform-apply.yaml`, and add `-bootstrapModuleOverrideFolderPath <clone>` to the bootstrap command.

### Bootstrap review and platform deployment

Review bootstrap's plan: UAE North resources, approved bootstrap network, private endpoints/self-hosted agents, intended repositories, permissions, and subscription placement, with no unexpected destruction. Bootstrap creates the delivery foundation, **not** the platform. Protect output/state and keep a recoverable copy in approved storage. On failure, fix the specific cause and rerun with the **same configuration/output and preserved state**; do not delete state or repositories.

In Azure DevOps:

1. Confirm agents are online, federated plan/apply service connections are correct, and the intended approvers are configured.
2. Inspect the **exact platform branch/commit** CI/CD uses. If local source was not published, deliver it through the generated repository's normal pull-request process; rerunning bootstrap does not guarantee publication.
3. Run CI and **02 Azure landing zone Continuous Delivery** against that branch. Authorize only the intended pipeline's service connections, pool, repositories, variable groups, and environments.

From a generated platform checkout, run these individually, stopping on failure:

```powershell
terraform fmt -check -recursive
terraform init -backend=false -input=false
terraform validate
```

Retain the lock file and avoid `-upgrade`. CI/CD must initialize the real backend and produce the authenticated, reviewed plan. Acceptance checks:

- The pipeline checkout contains `modules\virtual-wan` (89 files), `modules\private-link-private-dns-zones` (7 files), `modules\config-templating`, and the root `main.connectivity.virtual.wan.tf` with no `version` argument.
- The plan creates a Virtual WAN, one hub, the sidecar VNet and connection, Bastion without zones, the DNS zones and links, and `privatelink.sae.backup.windowsazure.com`; and no resolver, firewall, ExpressRoute gateway, workspace, DCRs, or AMA identity.
- Policy identities are in UAE North, platform resources in Saudi Arabia East, with no unexpected deletions or replacements. Only an authorized approver approves the plan.
- Auto-registration is `saudiarabiaeast.azure.local`; intended private links and bootstrap DNS remain enabled. No null `replace` or SQL override casing errors remain.
- Removed monitoring/Defender assignments are absent, both guardrail scopes retain disabled Defender settings, DDoS matches the chosen variant, and any required MCAPS Bastion IP tag is present.
- VPN matches the approved choice; no unexpected subscription moves, permission changes, or resource-address changes occur.

## 9. Operations and the NVA

After apply, verify hierarchy and placement, regional resources, agent access to the private backend and registry, approvals, policy compliance, and a drift plan.

- **NVA:** deploy and license the appliance separately in the NVA subnet. Configure IP forwarding, then design vWAN routing for it (static routes, route maps, or routing intent). The `10.0.4.68` address is only a sample; nothing in this configuration points at it.
- **DNS:** the standard design makes the NVA a DNS proxy that forwards to the Private DNS Resolver. This guide disables the resolver, so no forwarding target exists by default. Private link zones are linked to the sidecar VNet, so an NVA in that VNet can forward to the Azure-provided resolver (`168.63.129.16`). That path is a design suggestion, not tested here; approve and test it, and approve any on-premises conditional forwarding, before production.

Clear local PATs after bootstrap, then revoke the short-lived bootstrap token:

```powershell
Remove-Item Env:\TF_VAR_azure_devops_personal_access_token
Remove-Item Env:\TF_VAR_azure_devops_agents_personal_access_token
```

Clearing variables does not revoke tokens supplied to agents. Maintain their renewal/recreation process.

Version control: use the [workspace root](../../) as the single Git repository, keep the root and [scenario ignore rules](.gitignore) excluding output, temp, local tests, state, plans, caches, and credentials, and run `git diff --cached --check` and a content review before committing. These steps do not publish to the generated Azure DevOps repositories. Remove the overlay only after a verified upstream release fixes the dependency actually used and a reviewed plan preserves addresses and DNS links.

## Troubleshooting

| Symptom | Action |
| --- | --- |
| Null `replace` still fails | Check the exact pipeline checkout's two local module sources and Saudi DNS lookup; reinitialize. Never patch `.terraform`. |
| SQL override rejects `"Disabled"` | Overrides use lowercase `"disabled"`; initiative parameters use `"Disabled"`. |
| DNS policy cannot index region map | Keep full `saudiarabiaeast` in defaults, its `sae` map entry, and the actual Corp management-group key. |
| DNS links/zones unexpectedly replaced | Preserve block names and instance keys; investigate rather than approve. |
| `BastionRegionAzNotSupported` | Set host and public-IP zones to `[]`; inspect provisioning/state before recovery, not blind deletion/import. |
| ACR fails in Saudi / ACI zone error | Keep bootstrap in a supported region. If approved, set `agent_container_zone_support: false`; assess registry zone redundancy separately. |
| Agents offline / jobs queued | Check ACI logs, image pull, PAT/pool rights, DNS/egress, pipeline authorization, and self-hosted parallel-job capacity. |
| Backend denied/timed out | Check executing identity roles, private endpoint approval, routing, and DNS; do not enable public access as a shortcut. |
| Azure DevOps 401/403 | Check PAT scopes, expiry, organization, account rights, and commented YAML placeholders. |
| `alz_custom` missing | Pass the complete library in additional files. |
| Source edit does not affect pipeline | Verify selected folder and remote branch/commit; deliver changes to that checkout. |
| Invalid Security placement | Supply its subscription ID or comment out the entire placement block for a three-subscription test. |
| Saudi region rejected by AzureRM | Apply the location-only setting in section 8 after verifying access with the pipeline identity. |
| Region/SKU denied or unavailable | Check subscription access, policy, capacity, and zones; approve design changes rather than silently relocating resources. |
| `virtual_wan` module not installed / source changed | Run `terraform init` after source changes; confirm the root file has no `version` argument. |
| Registry `virtual-wan` still downloaded | The networking file was not passed to bootstrap, or the pipeline checkout lacks it. |
| Hub or VPN gateway creation fails in Saudi Arabia East | Recheck service and scale-unit availability for the subscription; disable the VPN gateway rather than relocating the region. |
| Hub/sidecar address conflict | Change the paired `primary_*` replacements together and recheck peering and on-premises ranges. |
| Traffic does not reach the NVA | Expected: no routing is created. Design vWAN routing for the appliance. |
| Private zones do not resolve from on-premises | Resolver is disabled; configure the approved NVA/DNS forwarding path. |

## 10. Cross-check with the colleague's repositories

Compared on 22 November 2026 with [saudi-alz-azuredevops-vwan-nva](https://github.com/moselim200/saudi-alz-azuredevops-vwan-nva) (this variant) and [saudi-alz-github-vwan-nva](https://github.com/moselim200/saudi-alz-github-vwan-nva). Both use starter `v17.7.0`, Terraform `1.14.9`, ALZ `7.1.5`, library `platform/alz@2026.11.0`, vWAN `0.18.0`, and DNS `0.23.2`. Their `platform-landing-zone.tfvars` files are identical to each other. Statuses: the GitHub package is **customer-reported verified**; the Azure DevOps package states that customer Azure DevOps bootstrap and CI/CD were **not performed**, with only local launcher and template checks. Neither is independent evidence or a production-readiness claim. **This guide treats them as test references only.**

| Area | Result |
| --- | --- |
| vWAN `0.18.0` module | **Match** on content. Their vendored root differs from upstream only in three source lines; they vendor root files only and use pinned Git sources for children and for `route-map`. This guide vendors the children locally to avoid runtime Git access. |
| Saudi DNS patch | **Match**: `saudiarabiaeast` maps to `sae` (`privatelink.sae.backup.windowsazure.com`); Corp `dnzZoneRegionShortNames.saudiarabiaeast = "sae"`. They confirmed the code from a Saudi Recovery Services vault's `privateLinkResources`; this guide reproduces it in a mocked plan. |
| Bastion, policy identity, bootstrap | **Match**: both Bastion zones `[]`, policy identities in `uaenorth`, whole bootstrap in `uaenorth`, `10.250.0.0/24` layout. |
| Provider validation | **Match** in effect: `ARM_PROVIDER_ENHANCED_VALIDATION_LOCATIONS: "false"` in the plan and apply helpers (DevOps), or the three jobs (GitHub). |
| Resolver, Firewall, DDoS, monitoring | Same disabled profile; they report Azure rejected the Resolver and Log Analytics here. |
| VPN and ExpressRoute gateways | **Differs.** Both disabled there; VPN enabled here, which no verified deployment covers. |
| Policy removals and Defender guardrails | **Differs, by design.** They remove three root assignments; this guide removes the broader set and keeps the Defender guardrail overrides. A security decision, not an error. |
| Auto-registration zone | **Differs.** `<region>.customer.internal` there; `saudiarabiaeast.azure.local` here. `.local` is reserved for multicast DNS; consider a customer-owned suffix. |
| `apply_approvers` | **Differs.** They ship `[]` for the lab, which leaves the apply gate unpopulated; this guide requires approvers. |
| Bootstrap source | They pin a commit one ahead of `v7.3.2`; this guide uses the release tag. |
| Extra tests and launcher | Their mocked-plan tests inspired the staged validation here; their launcher is described in section 11. |

Follow-ups: decide the VPN gateway and `.local` suffix before production, and keep approvers set.

## 11. Alternative for teams that prefer less manual work

If your team is not familiar with customizing ALZ files, use the colleague's prewired packages instead of assembling these files:

- **Azure DevOps:** [moselim200/saudi-alz-azuredevops-vwan-nva](https://github.com/moselim200/saudi-alz-azuredevops-vwan-nva)
- **GitHub:** [moselim200/saudi-alz-github-vwan-nva](https://github.com/moselim200/saudi-alz-github-vwan-nva)

Each ships the topology, library, Saudi overlay, a patched bootstrap source, and `Start-CustomerBootstrap.ps1`, which runs offline checks (`-CheckOnly`), rejects unresolved placeholders, pins ALZ `7.1.5`, and calls `Deploy-Accelerator` with every additional path. You edit `config\inputs.yaml` and `config\platform-landing-zone.tfvars`.

Know the limits first: it is one fixed reduced profile (VPN, ExpressRoute, DDoS, Firewall, Resolver, and monitoring off); the GitHub package is customer-reported verified only, and the Azure DevOps package is not verified end to end; and before use you should set real `apply_approvers`, review hub/sidecar ranges, the `.local` suffix, and, for GitHub Free, repository visibility. Changes beyond that profile need the Terraform edits described in this guide.

## References

Recheck all of these before deployment:

- [Scenario 9: Virtual WAN with NVA](https://azure.github.io/Azure-Landing-Zones/accelerator/starter-terraform/scenarios/single-region-virtual-wan-with-nva/)
- [Example configuration](https://raw.githubusercontent.com/Azure/alz-terraform-accelerator/refs/heads/main/templates/platform_landing_zone/examples/full-single-region-nva/virtual-wan.tfvars)
- [Azure DevOps prerequisites/PATs](https://azure.github.io/Azure-Landing-Zones/accelerator/1_prerequisites/azuredevops/)
- [Advanced bootstrap commands](https://azure.github.io/Azure-Landing-Zones/accelerator/2_bootstrap/advanced/)
- [Starter v17.7.0 Virtual WAN call](https://github.com/Azure/alz-terraform-accelerator/blob/v17.7.0/templates/platform_landing_zone/main.connectivity.virtual.wan.tf)
- [Virtual WAN source v0.18.0](https://github.com/Azure/terraform-azurerm-avm-ptn-alz-connectivity-virtual-wan/tree/v0.18.0)
- [Private DNS source v0.23.2](https://github.com/Azure/terraform-azurerm-avm-ptn-network-private-link-private-dns-zones/tree/v0.23.2)
- [Azure Virtual WAN NVA in the hub](https://learn.microsoft.com/azure/virtual-wan/about-nva-hub)
- [AzureRM 4.77 enhanced-validation controls](https://github.com/hashicorp/terraform-provider-azurerm/blob/v4.77.0/internal/features/enhanced_validation.go)
