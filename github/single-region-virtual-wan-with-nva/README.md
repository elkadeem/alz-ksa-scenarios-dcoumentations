# Scenario 9: Saudi Arabia landing zone with Virtual WAN, Terraform and GitHub

Deploy a **single-region Virtual WAN with a sidecar virtual network prepared for a Network Virtual Appliance (NVA)** using the Azure Landing Zones accelerator, private bootstrap networking, and self-hosted GitHub Actions runners.

This runbook is self-contained: it includes the topology, platform configuration, policy rationale, GitHub prerequisites, and deployment procedures. No other scenario needs to be read or deployed first.

This is a configuration and deployment runbook, not proof of a successful Azure deployment. The colleague's packages [moselim200/saudi-alz-github-vwan-nva](https://github.com/moselim200/saudi-alz-github-vwan-nva) and [moselim200/saudi-alz-azuredevops-vwan-nva](https://github.com/moselim200/saudi-alz-azuredevops-vwan-nva) are **test references, not the source of truth** (section 7), and are recommended for teams that prefer not to customize files (section 8).

## 1. Configuration and regional split

Paths are relative to this scenario folder unless stated otherwise.

| Component | Setting |
| --- | --- |
| Bootstrap resources, runners, registry, Terraform backend | UAE North: `uaenorth` |
| Regional platform resources | Saudi Arabia East: `saudiarabiaeast` |
| Policy-assignment managed identities | UAE North (identity-only exception) |
| Version control / pipelines / runners | GitHub organization, GitHub Actions, self-hosted ACI runners |
| Pinned starter / Terraform / ALZ module / bootstrap | `v17.7.0` / `1.14.9` / `7.1.5` / `v7.3.2` |
| Connectivity modules | Virtual WAN `0.18.0` and Private DNS `0.23.2`, both vendored; DNS is Saudi-patched |

**Why two regions?** The runner bootstrap depends on Azure Container Registry (ACR), which was unavailable in Saudi Arabia East for this design. Keep bootstrap in UAE North while that dependency is unavailable. Recheck service/SKU availability, subscription access, quota, and zone support before execution.

**Data residency approval is required.** State, runner execution, container images, and bootstrap storage are outside Saudi Arabia; GitHub hosts repositories, workflow logs, and artifacts in its own data location. State and artifacts can contain sensitive infrastructure metadata. Private endpoints do not make them Saudi-resident. If all deployment data must stay in Saudi Arabia, stop and approve another supported design.

The scenario does **not** deploy an NVA, vendor licenses, production spokes, an ExpressRoute circuit, an on-premises VPN device, or routing through an NVA.

### Topology

| Resource | Notes |
| --- | --- |
| Virtual WAN and one virtual hub | Standard Virtual WAN, hub prefix `10.0.0.0/22`, in Connectivity. |
| Sidecar VNet | `10.0.4.0/22`, connected to the hub; contains Bastion, NVA, and retained disabled-resolver subnets. |
| Bastion subnet | `10.0.4.0/26`; Standard Bastion, host and public-IP zones both `[]`. |
| NVA subnet / sample IP | `10.0.4.64/26` / `10.0.4.68`. The sample IP is referenced by no resource. |
| Retained resolver subnet prefix | `10.0.4.128/28`; Resolver is disabled. |
| Private DNS zones / auto-registration | Enabled, linked to the sidecar VNet. |
| Virtual hub VPN gateway | Enabled in source, **not validated** in Saudi Arabia East by any known deployment. |

The regional address-space example is `10.0.0.0/16`. Check overlap with bootstrap, corporate, VPN, ExpressRoute, and future-spoke ranges; update related `primary_*` replacements together. The Virtual WAN hub has no appliance subnet, so the hub-and-spoke module's `assign_generated_route_table` setting does not apply.

### Configuration files

Use the files in this scenario folder:

| Path | Content |
| --- | --- |
| [config/platform-landing-zone.tfvars](config/platform-landing-zone.tfvars) | Regions, flags, policy settings, hub/sidecar addressing |
| [config/lib/](config/lib/) | Custom library and policy removals |
| [config/modules/](config/modules/) and [config/main.connectivity.virtual.wan.tf](config/main.connectivity.virtual.wan.tf) | Vendored `virtual-wan` (89 files) and private DNS (7 files) overlay |
| [tests/](tests/) | Staged offline validation (same script and mocked test) |

Complete the input checklist in section 2, then review each configuration file below before validation. Only [config/inputs.yaml](config/inputs.yaml) and delivery procedures depend on GitHub.

### Platform variables, resource flags, and DNS

Open [platform-landing-zone.tfvars](config/platform-landing-zone.tfvars). Merge deliberate changes into existing blocks without duplicate top-level maps; preserve `$${...}` replacement tokens. The tracked source includes:

| Setting | Required state and reason |
| --- | --- |
| `connectivity_type` | `"virtual_wan"`. |
| `starter_locations`, `starter_locations_short` | `["saudiarabiaeast"]`, `{ starter_location_01_short = "sae" }`; the starter lacks the Saudi short code. |
| `management_groups_enabled`, `management_group_settings.architecture_name` | `true`, `"alz_custom"`; preserve hierarchy and custom policies. |
| `management_group_settings.location` | `"uaenorth"` for policy-assignment identities only. Saudi creation failed in a manual test and an independent deployment; approve this exception without moving Saudi resources. |
| `management_resources_enabled` | `false`; disables the whole management bundle (resource group, workspace, AMA identity, DCRs, and solutions), not bootstrap storage. |
| `custom_replacements.names.ddos_protection_plan_enabled` | `false`, consistent with the plan-ID default and both library removals below. |
| `primary_virtual_network_gateway_vpn_enabled` | `true`; recheck Virtual WAN VPN support and scale units in Saudi, or explicitly approve disabling it. The colleague's lab disabled it and provides no validation. |
| `primary_virtual_network_gateway_express_route_enabled` | `false`. |
| `primary_sidecar_virtual_network_enabled`, `primary_bastion_enabled` | `true`. |
| `primary_private_dns_zones_enabled`, `primary_private_dns_auto_registration_zone_enabled` | `true`; retain central zones, intended links, and auto-registration. |
| `primary_private_dns_resolver_enabled` | `false`; Saudi deployment tests rejected Resolver. No replacement forwarder is created. |
| `virtual_hubs.primary.enabled_resources.firewall` | `false`; this is an NVA foundation, not Azure Firewall. |
| `virtual_hubs.primary.bastion.zones`, `bastion.bastion_public_ip.zones` | `[]` on both; avoid inherited defaults after Saudi `BastionRegionAzNotSupported` failures. This is not zone-redundant Bastion. |

Match `management_group_settings.subscription_placement` to the input IDs. For a three-subscription test, comment out the **entire** Security placement block; an empty ID is invalid. The architecture may retain an empty Security management group.

Keep auto-registration as `saudiarabiaeast.azure.local` unless deliberately changing it consistently. `.local` can conflict with multicast DNS; consider a customer-owned suffix before production. Disabling Resolver does not disable private zones or bootstrap private-endpoint DNS; approve the replacement path in section 5.

**MCAPS only:** if applied policies require `FirstPartyUsage = "/Unprivileged"`, uncomment `ip_tags` inside `virtual_hubs.primary.bastion.bastion_public_ip`. Put it in the public-IP object, not ordinary tags; retain `zones = []`. This configuration defines no public-IP resource for the hub VPN gateway, so there is nothing else to tag. Do not apply this tag indiscriminately.

### No NVA routing is created

The configuration creates the hub, sidecar connection, and NVA subnet, but no static routes, route maps, routing intent, or hub route table that sends traffic through an appliance. Design supported vWAN NVA routing separately before attaching spokes. The pinned module `0.18.0` exposes hub `route_tables` and `route_maps`; later releases add connection static-route options, but this overlay does not upgrade it. `primary_nva_ip_address` documents the sample `10.0.4.68` only; no resource uses it.

### Policy defaults and Defender guardrails

Inside `management_group_settings.policy_default_values`, retain:

| Entries | Required state and reason |
| --- | --- |
| `ama_change_tracking_data_collection_rule_id`, `ama_mdfc_sql_data_collection_rule_id`, `ama_vm_insights_data_collection_rule_id`, `ama_user_assigned_managed_identity_id`, `ama_user_assigned_managed_identity_name`, `log_analytics_workspace_id` | Commented out because dependent resources and assignments are disabled. |
| `ddos_protection_plan_id` | Commented out for source-disabled DDoS. |
| `resource_group_name_mdfc`, `email_security_contact` | Commented out because automatic Defender configuration is excluded. |
| `resource_group_location`, `resource_group_name_service_health_alerts` | Active for the independent service-health policy; location stays on the Saudi replacement. |
| `private_dns_zone_subscription_id` | `"$${subscription_id_connectivity}"`. |
| `private_dns_zone_region` | `"$${starter_location_01}"` (full region, not `sae`). |
| `private_dns_zone_resource_group_name` | `"$${dns_resource_group_name}"`. |

In the existing `policy_assignments_to_modify` map, keep `corp.policy_assignments.Deploy-Private-DNS-Zones.parameters.dnzZoneRegionShortNames = { saudiarabiaeast = "sae" }`. It must construct the same Backup zone ID as Terraform: `privatelink.sae.backup.windowsazure.com`. This replaces the entire default region map; extend it before adding another DNS region. If the Corp management-group ID changes, update the modification key. Do not remove the Corp DNS assignment.

Keep the entire `alz.policy_assignments.Deploy-MDFC-Config-H224` modification commented out because its assignment is excluded. Under **both** `platform.policy_assignments` and `landingzones.policy_assignments`, retain:

| Assignment | Parameter | Value |
| --- | --- | --- |
| `Enforce-GR-MySQL0` | `mySqlAdvThreatProtection` | `"Disabled"` |
| `Enforce-GR-PostgreSQL0` | `postgreSqlAdvThreatProtection` | `"Disabled"` |
| `Enforce-GR-Storage0` | `storageThreatProtection` | `"Disabled"` |
| `Enforce-GR-Synapse0` | `synapseDefender` | `"Disabled"` |
| `Enforce-GR-SQL0` | `sqlManagedDefender` | `"Disabled"` |

For `Enforce-GR-SQL0` in **both scopes**, also keep the `policyEffect` override with lowercase `value = "disabled"` and selector `kind = "policyDefinitionReferenceId"`, `in = ["Dine-Sql-Adv-Data"]`. That initiative member independently enables Advanced Data Security without an exposed effect parameter. Parameters use `"Disabled"`; overrides use `"disabled"`. Preserve other enforcement settings.

### Custom library and coordinated re-enablement

In [config/lib/archetype_definitions/](config/lib/archetype_definitions/), preserve other fields and keep these complete `policy_assignments_to_remove` lists active. Commenting out a removal **re-enables** an inherited assignment.

| Override file | Complete removal list | Reason |
| --- | --- | --- |
| [root_custom](config/lib/archetype_definitions/root_custom.alz_archetype_override.yaml) | `Deploy-AzActivity-Log`, `Deploy-Diag-LogsCat`, `Deploy-MDFC-Config-H224`, `Deploy-MDFC-OssDb`, `Deploy-MDFC-SqlAtp`, `Deploy-MDEndpoints`, `Deploy-MDEndpointsAMA` | Remove workspace log forwarding and automatic Defender/endpoint configuration. |
| [platform_custom](config/lib/archetype_definitions/platform_custom.alz_archetype_override.yaml) | `DenyAction-DeleteUAMIAMA`, `Deploy-MDFC-DefSQL-AMA`, `Deploy-VM-ChangeTrack`, `Deploy-VM-Monitoring`, `Deploy-vmArc-ChangeTrack`, `Deploy-vmHybr-Monitoring`, `Deploy-VMSS-ChangeTrack`, `Deploy-VMSS-Monitoring` | Remove disabled AMA identity protection and dependent deployments. |
| [landing_zones_custom](config/lib/archetype_definitions/landing_zones_custom.alz_archetype_override.yaml) | `Deploy-AzSqlDb-Auditing`, `Deploy-MDFC-DefSQL-AMA`, `Deploy-SQL-Threat`, `Deploy-VM-ChangeTrack`, `Deploy-VM-Monitoring`, `Deploy-vmArc-ChangeTrack`, `Deploy-vmHybr-Monitoring`, `Deploy-VMSS-ChangeTrack`, `Deploy-VMSS-Monitoring`, `Enable-DDoS-VNET` | Remove workspace auditing, monitoring, SQL threat protection, and attachment to a disabled DDoS plan. |
| [connectivity_custom](config/lib/archetype_definitions/connectivity_custom.alz_archetype_override.yaml) | `Enable-DDoS-VNET` | Do not attach connectivity VNets to a disabled plan. |

Preserve [corp_custom](config/lib/archetype_definitions/corp_custom.alz_archetype_override.yaml) with `base_archetype: corp` and no removal of `Deploy-Private-DNS-Zones`, the [custom architecture](config/lib/architecture_definitions/alz_custom.alz_architecture_definition.yaml), [metadata](config/lib/alz_library_metadata.json), and all other archetypes.

For an approved enabled-DDoS variant, set `custom_replacements.names.ddos_protection_plan_enabled = true`, activate the policy default `ddos_protection_plan_id = "$${ddos_protection_plan_id}"`, remove only `Enable-DDoS-VNET` from the landing-zones removal list, and set the connectivity removal list to `[]`. Keep all monitoring/Defender removals and verify Saudi DDoS availability first.

To re-enable monitoring, restore the management bundle, its policy defaults, and dependent library assignments together. Before Defender re-enablement, review the complete retained source block and replace `defender_email_security_contact`. If Log Analytics stays off, retain `parameters.logAnalytics = ""` and the disabled override selecting `["ascExport", "defenderforKubernetes"]`; an empty workspace is not an alternative logging destination.

### Existing-deployment implications

- Management removal can delete a workspace, DCRs, identity, and resource group. Review retention/export, shared resources, deletion protection, and dependencies. Policy removal does not clean up agents, diagnostics, DCR associations, SQL auditing, or export automations.
- Removing Defender policies does not set existing plans to `Free`, remove integrations, or stop billing. Inventory existing protection, inherited policy, and automation separately.
- Removing DDoS Network Protection does not remove baseline infrastructure protection or automatically enable IP Protection. Review VNet associations and approve alternatives.
- Resolver deletion can break forwarding; Bastion/public-IP or gateway changes can replace resources and interrupt access. Identity-region changes can replace assignments, identities, and role assignments. Review the exact plan.
- This reduced profile lacks centralized Log Analytics, VM Insights, AMA change tracking, SQL audit destination, and automatic Defender enablement. Obtain security/monitoring/compliance approval and alternatives. Remaining audit policies can still report noncompliance.

### Network module overlay

The [root networking overlay](config/main.connectivity.virtual.wan.tf) selects `source = "./modules/virtual-wan"` without `version`. The [vWAN module](config/modules/virtual-wan/main.tf) selects `source = "../private-link-private-dns-zones"` without `version`. The [DNS lookup](config/modules/private-link-private-dns-zones/locals.tf) returns `"sae"` only for normalized `saudiarabiaeast`, preserving upstream lookups for other regions: the upstream Saudi `geo_code` is null, which makes `replace` fail.

Keep all 89 vWAN files (including 11 child modules) and all seven private DNS files, with their MIT licenses. These are vWAN `v0.18.0` (commit `116594239389f448c8db52b225566ef9e7ca68b5`) and DNS `v0.23.2`, pinned to the starter. Children are vendored locally, avoiding runtime Git fetches for those modules. Never patch `.terraform`.

The starter short name, Corp policy map, and module patch fix three separate lookups; all are required. Pass `lib`, `modules`, and the networking file to bootstrap (section 4); adjacent folders are not copied automatically. Preserve the starter's `modules\config-templating`. Existing generated repositories use the fallback in section 5.

## 2. Prerequisites

### Azure prerequisites

Prepare Management, Connectivity, Identity, and Security subscriptions in one Microsoft Entra tenant. Record tenant/subscription IDs. Select an existing parent management group, or an empty parent value for Tenant Root Group. The bootstrap account needs `Owner` on that group and all selected subscriptions, including bootstrap; activate PIM roles first. Inherited allowed-location policies must permit UAE North and Saudi Arabia East, or have approved scope-specific exemptions.

### GitHub prerequisites

- Use a **GitHub organization**; personal accounts are unsupported and bootstrap fails on apply.
- The bootstrap account must be an **organization owner**: it creates repositories, a team, environments, and branch protection.
- On **GitHub Free**, bootstrap makes repositories **public** for the features it uses. Privileged self-hosted runners on public repositories are not production-hardened: require approval for all outside-contributor workflow runs and never approve untrusted fork runs. Use an eligible paid plan for private repositories and environment protection rules.
- Runner groups (`use_runner_group`) require an Enterprise license. For GHE.com data residency, uncomment `github_organization_domain_name`.
- Confirm default repository names are free: `<service_name>-<environment_name>` (`alz-mgmt`) and `<service_name>-<environment_name>-templates` (`alz-mgmt-templates`).

### Tools and scenario selection

Use PowerShell **7.4+**, Azure CLI **2.55.0+**, Git, and Terraform **1.14.9** for local checks. Allow outbound access to Azure, GitHub, Entra ID, PowerShell Gallery, and Terraform/package download endpoints. Cloud Shell and corporate-proxy operation are not explicitly supported.

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
$versionControl = "github"
$scenarioNumber = 9
$targetFolderPath = ".\github\single-region-virtual-wan-with-nva"
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

### Two fine-grained personal access tokens

Create both under **GitHub > Settings > Developer settings > Personal access tokens > Fine-grained tokens**, with **Resource owner** set to the organization and **Repository access** set to **All repositories** (you can narrow the runner token after bootstrap).

| Token | Permissions | Lifetime |
| --- | --- | --- |
| Bootstrap | Repository: Actions, Administration, Contents, Environments, Secrets, Variables, Workflows (all Read and write). Organization: Members (Read and write); Self-hosted runners (Read and write, only for runner groups). | Short-lived. |
| Runner registration | Repository: Administration (Read and write). Organization: Self-hosted runners (Read and write, only for runner groups). | Establish renewal and runner-recreation procedures before expiry; expired tokens leave runners offline. |

Set both in the terminal that will run bootstrap:

```powershell
$env:TF_VAR_github_personal_access_token = Read-Host "Bootstrap PAT (token 1)" -MaskInput
$env:TF_VAR_github_runners_personal_access_token = Read-Host "Runner registration PAT (token 2)" -MaskInput
```

Never print or commit tokens. Explicit YAML values can take precedence over environment variables, so keep both PAT entries commented out. Protect state and generated artifacts too. In a new terminal restore authentication, variables, and the selected folder.

### Edit inputs once

Open [inputs.yaml](config/inputs.yaml), complete all entries, then save.

| Entry | Required update |
| --- | --- |
| `bootstrap_location` | Keep `"uaenorth"` for bootstrap ACR/runners, separate from the Saudi platform. |
| `root_parent_management_group_id` | Existing management-group ID (not full resource ID), or `""` for Tenant Root Group. |
| `subscription_ids` | Fill Management, Connectivity, Identity, and Security IDs. |
| `bootstrap_subscription_id` | Set the management subscription ID explicitly; the file ships with `""` and otherwise follows Azure CLI selection. |
| `service_name`, `environment_name`, `postfix_number` | Keep `"alz"`, `"mgmt"`, `1`, or approved values; names form repositories/environments and must stay stable on reruns. |
| `use_self_hosted_runners`, `use_private_networking` | Both `true`. |
| `allow_storage_access_from_my_ip` | `false`; no workstation public-IP firewall exception. |
| `virtual_network_address_space` | `"10.250.0.0/24"` after overlap approval. |
| `virtual_network_subnet_address_prefix_container_instances` | `"10.250.0.0/26"`; dedicated runner subnet. |
| `virtual_network_subnet_address_prefix_private_endpoints` | `"10.250.0.64/26"`; dedicated private endpoint subnet. |
| `github_organization_name` | Organization name only, not URL. |
| `github_organization_domain_name` | Uncomment only for GHE.com data residency. |
| `apply_approvers` | At least one real GitHub username or `org/team-name`. |
| Both PAT entries | Keep commented out; use environment variables. |
| `starter_module_version`, `terraform_version` | `"v17.7.0"`, `"1.14.9"`. |
| `iac_type`, `bootstrap_module_name`, `starter_module_name` | `"terraform"`, `"alz_github"`, `"platform_landing_zone"`. |

The bootstrap example leaves `10.250.0.128/25` unallocated. Check overlap with on-premises, hub, sidecar, and future spokes. For an existing bootstrap, inspect its actual network and plan before changing ranges.

> [!WARNING]
> **Do not leave `apply_approvers` empty.** The generated CD workflow runs on every push to `main`, and the apply environment's approval is the only human gate before changes reach Azure. The colleague's lab packages ship `[]`.

Private networking is not air-gapped: bootstrap includes NAT Gateway/public-IP egress. Runners need outbound HTTPS to GitHub, Entra ID, ARM, and package sources, plus private routing/DNS to backend storage and ACR. Preserve ACI subnet delegation and DNS links; do not open blanket inbound access. `allow_storage_access_from_my_ip: false` does not provide private workstation access; use self-hosted runners for platform Terraform runs.

## 3. Provider-validation workaround

The starter constrains AzureRM to `~> 4.0`. Enhanced validation can reject `saudiarabiaeast` before ARM sees a request. Check the selected provider in the lock file/init output and verify service/regional access using the **same OIDC identity and subscriptions**. For a confirmed metadata limitation on AzureRM **4.77+**, the location-only switch must be in the job-level `env:` of **each of the three Terraform jobs** in the generated **templates repository** (CI plan in `ci-template.yaml`; plan and apply in `cd-template.yaml`):

```yaml
env:
  ARM_PROVIDER_ENHANCED_VALIDATION_LOCATIONS: "false"
```

Caller workflow `env` is not passed to reusable template jobs; repository/organization Actions variables are only readable through `vars`, not automatically exported. Separate jobs do not share environments. Never combine this switch with legacy `ARM_PROVIDER_ENHANCED_VALIDATION`; the provider rejects the combination. It disables only stale location validation, not resource-provider validation, and bypasses neither Policy, RBAC, quota, regional access, nor ARM validation. It does not fix DNS metadata or SQL casing. Reassess on upgrades.

### Option A: bake it in before bootstrap (recommended)

Clone the pinned bootstrap release outside this repository:

```powershell
$bootstrapSourcePath = Join-Path $env:USERPROFILE "alz-bootstrap-v7.3.2"
git clone --branch v7.3.2 --depth 1 https://github.com/Azure/accelerator-bootstrap-modules.git $bootstrapSourcePath
```

In `alz\github\actions\terraform\templates\workflows\ci-template.yaml` (one job) and `cd-template.yaml` (two jobs), add `ARM_PROVIDER_ENHANCED_VALIDATION_LOCATIONS: "false"` as the first entry in each existing Terraform job's `env:` block, above `ARM_CLIENT_ID`. Preserve all other entries and indentation. Confirm exactly three occurrences, then use `-bootstrapModuleOverrideFolderPath $bootstrapSourcePath` in section 4. Retain the clone's licenses.

Use tag `v7.3.2` unless explicitly reviewing another revision; the colleague's package pins commit `7887040f`, one commit ahead of that release.

### Option B: pull request after bootstrap

Omit the bootstrap override. In `<organization>/<service>-<environment>-templates` (default `alz-mgmt-templates`), submit and merge a pull request adding the same line to all three jobs in `.github/workflows/ci-template.yaml` and `cd-template.yaml`, before the first deliberate CI/CD run.

The automatic first CD run triggered by bootstrap's push to `main` can fail at plan with the location-validation error until the fix is merged. Keep apply approvals enabled, cancel unreviewed runs, and never approve apply without its reviewed plan.

## 4. Validate and bootstrap

```powershell
$targetFolderPath = "D:\workarea\Source\alz\terraform\github\single-region-virtual-wan-with-nva"
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

$tf = "<path-to-terraform-1.14.9>\terraform.exe"
& "$targetFolderPath\tests\Invoke-StagedValidation.ps1" -TerraformPath $tf
```

The staged validation clones the pinned starter into a temporary folder, overlays this configuration the way bootstrap does, and runs `fmt`, `init -backend=false`, `validate`, and mocked `terraform test`; it needs no Azure sign-in. On 22 November 2026 it passed with Terraform `1.14.9` and starter `v17.7.0` (`4 passed, 0 failed`), including the `privatelink.sae.backup.windowsazure.com` zone assertion, and failed as expected with the registry DNS module restored. The test ran against the DevOps copy of the same files. It is **not** an authenticated plan and does not prove regional availability, policy acceptance, quota, or RBAC.

Formatting does not validate YAML, ALZ semantics, backend access, or availability. This overlay is **not** a complete Terraform root; do not run `terraform validate` or plan here. The staged script supplies the complete starter for offline checks.

### Authentication and preflight

```powershell
az login --tenant "<tenant-id>" --use-device-code
az account set --subscription "<management-subscription-id>"
az account show --query "{tenantId:tenantId,subscriptionId:id,name:name}" --output table
az account list-locations `
    --query "[?name=='saudiarabiaeast' || name=='uaenorth'].{Name:name,DisplayName:displayName}" `
    --output table
```

Region visibility alone is insufficient. Recheck service/SKU/quota and regional access in the relevant subscriptions, including Standard Virtual WAN, virtual hub, Bastion, and the VPN gateway/scale units in Connectivity. For an enabled-DDoS variant, inspect `Microsoft.Network` provider resource type `ddosProtectionPlans` for Saudi availability in Connectivity and check existing plans before approving.

Before bootstrap:

- [ ] Folder, subscription inputs/placements, bootstrap subscription, tenant, and parent management group agree.
- [ ] Azure permissions/PIM, provider registrations, organization-owner rights, repository-name availability, and both PAT variables are ready.
- [ ] GitHub plan, repository visibility (public on Free), and outside-contributor workflow approval policy are approved.
- [ ] `apply_approvers` contains real reviewers and the plan supports the required environment protection.
- [ ] Regional split, cross-border state/runners, identity exception, inherited policies, capacity, and zones are approved.
- [ ] Hub, sidecar, bootstrap, on-premises, and future-spoke ranges do not overlap.
- [ ] The NVA routing and DNS designs have owners; the configuration supplies neither.
- [ ] Monitoring, Defender, and resolver removals include dependent policies and approved alternatives.
- [ ] Bastion host/public-IP zones are `[]`; any required MCAPS tag is on the Bastion public IP.
- [ ] DDoS flag, plan-ID default, and both removal lists agree.
- [ ] Corp DNS map, full DNS region, starter short name, complete custom library, and all overlay paths are present.
- [ ] Provider-validation delivery (Option A or B) is chosen.
- [ ] No credentials, state, caches, or tenant-specific test files are staged.

### Bootstrap

Run this **one** command with the selected folder and both PAT variables still set. Omit the last override line for Option B:

```powershell
Deploy-Accelerator `
    -inputs "$targetFolderPath\config\inputs.yaml", "$targetFolderPath\config\platform-landing-zone.tfvars" `
    -starterAdditionalFiles "$targetFolderPath\config\lib", `
                            "$targetFolderPath\config\modules", `
                            "$targetFolderPath\config\main.connectivity.virtual.wan.tf" `
    -output "$targetFolderPath\output" `
    -bootstrapModuleOverrideFolderPath $bootstrapSourcePath
```

ALZ `7.1.5` copies additional folders by folder name and files by filename before bootstrap Terraform runs. All three paths are required: only `lib` omits the Saudi workaround, and modules without the networking file leaves the registry Virtual WAN module active.

Review bootstrap's plan: UAE North resources, approved bootstrap network, private endpoints/runners, intended repositories and visibility, approver team/environments, permissions, and no unexpected changes. Bootstrap creates the delivery foundation, **not** the platform. Protect output/state and keep a recoverable copy in approved storage. On failure, fix the specific cause and rerun with the **same configuration/output and preserved state**; do not delete state or repositories.

### Verify the exact workflow checkout

After bootstrap:

1. Confirm both self-hosted runners are online in the platform repository's **Settings > Actions > Runners**, or the Enterprise runner group.
2. Verify `<service>-<environment>-plan` and `-apply` environments, intended apply reviewers, branch protection on `main`, and matching OIDC federated credentials.
3. Inspect the **exact `main` commit** used by workflows, including both local module sources without `version`, the Saudi DNS lookup, all module files/licenses, and the custom library. Deliver unpublished local changes through a pull request; rerunning bootstrap does not guarantee publication.
4. Confirm the three location-only validation entries are in the templates repository and no job also sets the legacy switch.

From a generated platform checkout, run these individually, stopping on failure:

```powershell
terraform fmt -check -recursive
terraform init -backend=false -input=false
terraform validate
```

Retain the provider lock file; avoid `-upgrade`. CI/CD must initialize the real backend and produce the authenticated, reviewed plan. Acceptance checks:

- The platform repository contains `modules\virtual-wan` (89 files), `modules\private-link-private-dns-zones` (7 files), `modules\config-templating`, and a root `main.connectivity.virtual.wan.tf` with no `version` argument.
- The plan creates a Virtual WAN, one hub, the sidecar VNet and connection, Bastion without zones, the DNS zones and links, and `privatelink.sae.backup.windowsazure.com`; and no resolver, firewall, ExpressRoute gateway, workspace, DCRs, or AMA identity.
- Policy identities are in UAE North, platform resources in Saudi Arabia East, with no unexpected deletions or replacements.
- Auto-registration is `saudiarabiaeast.azure.local`; intended VNet links and bootstrap DNS remain enabled. No null `replace` or SQL override casing errors remain.
- Removed monitoring/Defender assignments are absent, both guardrail scopes retain disabled Defender settings, DDoS matches the chosen variant, and any required MCAPS Bastion IP tag is present.
- VPN matches the approved choice; no unexpected resource-address changes, subscription moves, or permission changes occur.

Run **01 Azure Landing Zones Continuous Integration** through a pull request or manual dispatch, review the plan, then run **02 Azure Landing Zones Continuous Delivery** with `apply` through the approval gate. Do not push to `main` merely to inspect a plan.

## 5. Operations

After apply, verify hierarchy/subscription placement, regional resources, runner access to private backend/registry, private endpoint approval/DNS restrictions, federated credentials, apply approvals, policy compliance/remediation, and a drift plan.

Deploy/license the NVA separately in its subnet with an approved Saudi image/SKU, enable IP forwarding, and design supported vWAN routing/inspection before attaching spokes. The sample `10.0.4.68` is referenced by nothing. With Private DNS Resolver disabled, an NVA in the sidecar VNet can forward to the Azure-provided resolver (`168.63.129.16`) because private zones are linked to that VNet; this is an untested suggestion, not a configured forwarding path. Approve and test it, any on-premises conditional forwarding, and end-to-end traffic before production.

Clear local tokens after bootstrap, then revoke the short-lived bootstrap token:

```powershell
Remove-Item Env:\TF_VAR_github_personal_access_token
Remove-Item Env:\TF_VAR_github_runners_personal_access_token
```

Clearing variables does not revoke tokens supplied to runners; maintain their renewal/recreation process.

Use the [workspace root](../../) as the single Git repository, not a nested repository. Keep the [root ignore rules](../../.gitignore) and [scenario ignore rules](.gitignore) excluding output, temp, local tests, state, plans, caches, and credentials; ignore rules cannot detect secrets in valid source files. Review staged content for secrets and unintended changes:

```powershell
Set-Location "D:\workarea\Source\alz\terraform"
git add -- github\single-region-virtual-wan-with-nva
git diff --cached --check
git diff --cached --stat
```

These source-repository steps do not publish to the generated GitHub repositories; ongoing changes go through pull requests there. Remove the overlay only after a verified upstream release fixes the dependency actually consumed by vWAN and a reviewed plan preserves addresses/DNS links. Restore tested registry sources/versions and remove unused local files/bootstrap paths in one reviewed change. Remove the provider-validation workaround only after confirming the provider metadata is fixed.

### Existing generated repository: fallback delivery

If bootstrap completed without the overlay, **do not rerun it just for DNS**:

1. Create a change branch in the generated **platform repository** (`<service>-<environment>`), not the templates repository or starter cache.
2. Compare its starter/vWAN/DNS versions with the pins in section 1 before using this version-specific overlay.
3. Copy the complete tracked `virtual-wan` and `private-link-private-dns-zones` module folders into its existing `modules` folder, preserving `config-templating` and comparing customizations before overwriting.
4. In the root networking file, change the existing vWAN module source to `"./modules/virtual-wan"` and remove only that call's `version`. Preserve all other arguments, providers, names, and instance keys.
5. Merge all applicable section 1 changes into its generated `platform-landing-zone.auto.tfvars`, and deliver the complete custom library.
6. Submit the modules, networking, variables, and library together through a pull request. Retain the provider lock file; do not introduce unrelated upgrades. Review CI and the exact plan before merging.

Never edit `.terraform`. Unchanged block names and instance keys should not need state moves/imports, but the actual plan must confirm that.

## 6. Troubleshooting

| Symptom | Action |
| --- | --- |
| Null `replace` still fails | Check the exact workflow checkout's two local module sources and Saudi DNS lookup; reinitialize. Never patch `.terraform`. |
| vWAN module not installed / source changed | Run `terraform init`; remove `version` only from calls switched to local sources. |
| Registry vWAN module still downloaded | Pass the networking file to bootstrap and confirm it is committed in the workflow checkout. |
| SQL override rejects `"Disabled"` | Overrides use lowercase `"disabled"`; initiative parameters use `"Disabled"`. |
| DNS policy cannot index region map | Keep full `saudiarabiaeast` in defaults, its `sae` map entry, and the actual Corp management-group key. |
| DNS zones/links unexpectedly replaced | Preserve block names and instance keys; investigate rather than approve. |
| `BastionRegionAzNotSupported` | Set host and public-IP zones to `[]`; inspect provisioning/state before recovery, not blind deletion/import. |
| Saudi region rejected by AzureRM | Apply the location-only setting to all three template jobs after verifying access with the same OIDC identity. |
| Hub or VPN creation fails in Saudi | Recheck subscription service/scale-unit availability; approve disabling VPN if necessary rather than relocating the region silently. |
| Hub/sidecar address conflict | Update paired `primary_*` replacements together and recheck all connected ranges. |
| Traffic never reaches NVA | No appliance or NVA routing is created; deploy/license the appliance and configure the approved vWAN routing design. |
| Private zones do not resolve from on-premises | Resolver is disabled; configure and test the approved NVA/DNS forwarding path. |
| ACR fails in Saudi / ACI zone error | Keep bootstrap in a supported region. If approved, set `agent_container_zone_support: false`; assess registry zone redundancy separately. |
| Runners offline / jobs queued | Check token expiry/scope, ACI logs, image pull, DNS/egress, and runner group/repository assignment. Use approved token renewal/recreation recovery. |
| Backend denied/timed out | Check plan/apply identity roles, private endpoint approval, routing, and DNS; do not enable public access as a shortcut. |
| Bootstrap 403 / `Resource not accessible by integration` | Check token 1 permissions, resource owner, repository access, and organization-owner rights. |
| Bootstrap fails creating private repositories | Free forces public; use an eligible paid plan for private repositories. |
| CD ran immediately after bootstrap | Expected from the push to `main`; verify apply reviewers and cancel unreviewed runs. |
| Apply never prompts | Fix empty `apply_approvers` or unsupported environment protection before any apply. |
| OIDC `AADSTS70021` / credential mismatch | Check environment/repository names; keep `service_name`/`environment_name` stable. |
| `alz_custom` missing | Pass the complete library in additional files. |
| Source edit does not affect workflow | Deliver it to the generated platform repository by pull request and verify the actual branch/commit. |
| Invalid Security placement | Supply its subscription ID or comment out the entire placement block for a three-subscription test. |
| `Find-PSResource` fails on a private feed | After importing the exact ALZ version, use `-skipAlzModuleVersionRequirementsCheck` only to skip the online latest-version lookup. |
| Windows long-path errors | Use a short path and process-only `git -c core.longpaths=true`, not global changes. |

## 7. Cross-check with the colleague's repositories

Compared on 22 November 2026 with [saudi-alz-github-vwan-nva](https://github.com/moselim200/saudi-alz-github-vwan-nva) (commit `10958e1`; status **customer-reported verified**, no independent evidence) and [saudi-alz-azuredevops-vwan-nva](https://github.com/moselim200/saudi-alz-azuredevops-vwan-nva) (commit `5677322`; customer Azure DevOps bootstrap and CI/CD **not performed**). Their tfvars files are identical to each other. **They are treated as test references only.**

| Area | Result |
| --- | --- |
| Starter, Terraform, ALZ, library, vWAN `0.18.0`, DNS `0.23.2` | **Match.** |
| Vendored vWAN root | **Match** on content. They vendor root files only and pull the children and `route-map` from pinned Git sources; this guide vendors the 11 child modules locally. |
| Saudi DNS code | **Match.** `sae`, `privatelink.sae.backup.windowsazure.com`, Corp map `dnzZoneRegionShortNames.saudiarabiaeast = "sae"`. |
| Bastion, policy identity, bootstrap | **Match.** Zones `[]`, `uaenorth` identities, entire bootstrap in `uaenorth`, `10.250.0.0/24`, `allow_storage_access_from_my_ip: false`. |
| Provider validation | **Match.** Location-only setting in the three GitHub jobs; the launcher clears the legacy variable. |
| Gateways, DDoS, Resolver, Firewall, monitoring | Same disabled profile except the **VPN gateway: disabled there, enabled here** (not validated by them). |
| Policy removals / Defender guardrails | **Differs by design.** Broader removals and kept guardrail overrides here. |
| Auto-registration zone | **Differs.** `customer.internal` there; `azure.local` here (`.local` is reserved for multicast DNS). |
| `apply_approvers` | **Differs.** `[]` there; required here. |
| Bootstrap source | They pin a commit one ahead of `v7.3.2`; this guide uses the tag. |

## 8. Alternative for teams that prefer less manual work

If your team is not familiar with customizing ALZ, use the prewired packages instead of assembling files: [GitHub](https://github.com/moselim200/saudi-alz-github-vwan-nva) or [Azure DevOps](https://github.com/moselim200/saudi-alz-azuredevops-vwan-nva). Each ships the topology, library, Saudi overlay, a patched bootstrap source, and `Start-CustomerBootstrap.ps1` (offline `-CheckOnly`, placeholder checks, ALZ `7.1.5` pin, full `Deploy-Accelerator` call). You edit `config\inputs.yaml` and `config\platform-landing-zone.tfvars`.

Limits: one fixed reduced profile (VPN, ExpressRoute, DDoS, Firewall, Resolver, monitoring off); the GitHub package is customer-reported verified only; set real `apply_approvers`, review the hub and sidecar ranges and the `.local` suffix, and review public repositories on GitHub Free before use. Changes beyond that profile need the Terraform edits in this guide.

## References

Recheck before deployment:

- [Scenario 9: Virtual WAN with NVA](https://azure.github.io/Azure-Landing-Zones/accelerator/starter-terraform/scenarios/single-region-virtual-wan-with-nva/)
- [GitHub prerequisites and tokens](https://azure.github.io/Azure-Landing-Zones/accelerator/1_prerequisites/github/)
- [Advanced bootstrap commands](https://azure.github.io/Azure-Landing-Zones/accelerator/2_bootstrap/advanced/)
- [GitHub bootstrap variables](https://github.com/Azure/accelerator-bootstrap-modules/blob/v7.3.2/alz/github/variables.tf)
- [Virtual WAN source v0.18.0](https://github.com/Azure/terraform-azurerm-avm-ptn-alz-connectivity-virtual-wan/tree/v0.18.0)
- [Private DNS source v0.23.2](https://github.com/Azure/terraform-azurerm-avm-ptn-network-private-link-private-dns-zones/tree/v0.23.2)
