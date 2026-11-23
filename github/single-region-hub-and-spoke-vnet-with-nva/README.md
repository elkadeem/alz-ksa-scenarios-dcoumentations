# Scenario 8: Saudi Arabia landing zone with Terraform and GitHub

Deploy a **single-region hub and spoke virtual network prepared for a Network Virtual Appliance (NVA)** with the Azure Landing Zones accelerator, private bootstrap networking, and self-hosted GitHub Actions runners on Azure Container Instances (ACI).

This runbook is self-contained: it includes the platform configuration, policy rationale, GitHub prerequisites, and deployment procedures. No other scenario needs to be read or deployed first.

This is a configuration and deployment runbook, not proof of a successful Azure deployment. It was **cross-checked against** [moselim200/saudi-alz-github-hub-spoke-nva](https://github.com/moselim200/saudi-alz-github-hub-spoke-nva), whose owner reports a verified GitHub deployment (section 10). No deployment was run from this repository.

> **Prefer a ready-made package with less manual editing?** See [section 11](#11-alternative-for-teams-that-prefer-less-manual-work): Mohamed Selim's repository ships a prewired package and a launcher script.

## 1. Select the configuration and understand the regional split

Paths are relative to this scenario folder unless stated otherwise.

| Component | Setting |
| --- | --- |
| Bootstrap resources, runners, registry, and Terraform backend | UAE North: `uaenorth` |
| Regional platform landing-zone resources | Saudi Arabia East: `saudiarabiaeast` |
| Policy-assignment managed identities | UAE North (identity-only exception; Saudi creation failed in the DevOps test and in the colleague's GitHub deployment) |
| Version control and pipelines | GitHub organization, GitHub Actions |
| Runners | Self-hosted, ACI |
| Bootstrap networking | Private endpoints and a dedicated VNet |
| Pinned starter / Terraform / ALZ module / bootstrap | `v17.7.0` / `1.14.9` / `7.1.5` / `v7.3.2` |

**Why two regions?** The runner bootstrap depends on Azure Container Registry, which was unavailable in Saudi Arabia East for this design. Recheck service/SKU availability, quota, and zone support before running; this guide does not certify regional availability.

**Data residency approval is required.** Terraform state, runner execution, container images, and bootstrap storage are outside Saudi Arabia, and GitHub hosts the repositories, workflow logs, and artifacts in its own data location. Private endpoints do not make these services Saudi-resident. If all deployment data must stay in Saudi Arabia, stop and approve another design.

The scenario does **not** deploy an NVA, vendor licenses, production spokes, an ExpressRoute circuit, or an on-premises VPN device.

### Configuration files

Use the files in this scenario folder:

| Path | Content |
| --- | --- |
| [config/platform-landing-zone.tfvars](config/platform-landing-zone.tfvars) | Regions, resource flags, policy defaults and modifications, hub/NVA addressing |
| [config/lib/](config/lib/) | Custom ALZ library and policy-removal lists |
| [config/modules/](config/modules/) and [config/main.connectivity.hub.and.spoke.virtual.network.tf](config/main.connectivity.hub.and.spoke.virtual.network.tf) | 48-file hub-and-spoke `v0.17.2` / private DNS `v0.23.2` overlay with the Saudi DNS fix |

The configuration rationale and required checks are included below. Only [config/inputs.yaml](config/inputs.yaml) and the delivery procedures depend on GitHub.

## 2. Prepare permissions, tools, and GitHub

### Azure prerequisites

Prepare four platform subscriptions (Management, Connectivity, Identity, Security) in one Microsoft Entra tenant, an existing parent management group (or the Tenant Root Group), and an account with `Owner` on that management group and every platform subscription, including bootstrap. Record tenant/subscription IDs and activate PIM roles first. Inherited allowed-location policies must permit UAE North and Saudi Arabia East, or have approved scope-specific exemptions.

### GitHub prerequisites

- A **GitHub organization**. Personal accounts are not supported and the bootstrap fails on apply.
- **Plan matters.** On a **GitHub Free** organization the bootstrap makes the repositories **public** (required for the features it uses). Public repositories with privileged self-hosted runners are not production-hardened: require approval for all outside-contributor workflow runs and never approve untrusted fork runs. For private repositories, use a paid plan (Team or Enterprise Cloud). Runner groups (`use_runner_group`) only apply to Enterprise-licensed organizations.
- For GitHub Enterprise Cloud with data residency, uncomment `github_organization_domain_name` in `inputs.yaml`.
- The bootstrap account must be an **organization owner** (it creates repositories, a team, environments, and branch protection).
- Confirm the default repository names are free: `<service_name>-<environment_name>` (`alz-mgmt`) and `<service_name>-<environment_name>-templates` (`alz-mgmt-templates`).

### Tools and scenario generation

Use PowerShell **7.4 or newer**, Azure CLI **2.55.0 or newer**, Git, and optionally VS Code. Allow access to Azure, GitHub, PowerShell Gallery, and Terraform provider/module download endpoints. Cloud Shell and corporate-proxy operation are not explicitly supported.

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
$scenarioNumber = 8
$targetFolderPath = ".\github\single-region-hub-and-spoke-vnet-with-nva"
```

**The scenario already exists in this workspace. Skip generation.** For a new, empty destination only:

```powershell
New-AcceleratorFolderStructure `
    -iacType $iacType `
    -versionControl $versionControl `
    -scenarioNumber $scenarioNumber `
    -targetFolderPath $targetFolderPath
```

### Two fine-grained personal access tokens

Create both under **GitHub > Settings > Developer settings > Personal access tokens > Fine-grained tokens**, with **Resource owner** set to your organization and **Repository access** set to **All repositories** (you can narrow the runner token after bootstrap).

| Token | Permissions | Lifetime |
| --- | --- | --- |
| **Token 1: bootstrap** | Repository: Actions, Administration, Contents, Environments, Secrets, Variables, Workflows (all Read and write). Organization: Members (Read and write); Self-hosted runners (Read and write, only for runner groups) | Short (for example tomorrow's date) |
| **Token 2: runner registration** | Repository: Administration (Read and write). Organization: Self-hosted runners (Read and write, only for runner groups) | Long-lived, but establish a renewal and runner-recreation process before expiry; when it expires the runners go offline |

In the PowerShell terminal that will run bootstrap:

```powershell
$env:TF_VAR_github_personal_access_token = Read-Host "Bootstrap PAT (token 1)" -MaskInput
$env:TF_VAR_github_runners_personal_access_token = Read-Host "Runner registration PAT (token 2)" -MaskInput
```

Never print or commit token values. Keep both YAML PAT entries commented out: explicit file values can take precedence over environment variables. In a new terminal, restore authentication, the variables, and the selected folder.

## 3. Edit `config/inputs.yaml` once

Open [inputs.yaml](config/inputs.yaml). Complete all entries, then save.

| Entry | Required update | Reason |
| --- | --- | --- |
| `bootstrap_location` | Keep `"uaenorth"` | Runner ACR dependency is separate from the Saudi platform region. |
| `root_parent_management_group_id` | Existing management-group ID, or `""` for Tenant Root Group | Choose the hierarchy parent; not a full resource ID. |
| `subscription_ids` | Fill Management, Connectivity, Identity, and Security IDs | Replacements and placement depend on them. |
| `bootstrap_subscription_id` | **Set** the management subscription ID (the file ships with `""`) | Avoid relying on the current Azure CLI subscription. |
| `service_name`, `environment_name`, `postfix_number` | Keep `"alz"`, `"mgmt"`, `1`, or approved values | These also form the default repository names (`alz-mgmt`, `alz-mgmt-templates`) and the environments (`...-plan`, `...-apply`). Keep them when rerunning. |
| `use_self_hosted_runners`, `use_private_networking` | Both `true` | Run workflows against private backend/registry endpoints. |
| `allow_storage_access_from_my_ip` | `false` | Do not add a workstation public-IP exception. |
| `virtual_network_address_space` and the two subnet prefixes | `10.250.0.0/24`, `10.250.0.0/26`, `10.250.0.64/26` after IPAM approval | Separate bootstrap addressing from the Saudi hub (`10.0.0.0/16`). `10.250.0.128/25` stays unallocated. |
| `github_organization_name` | Organization name only, not a URL | The part of the URL after `github.com/`. |
| `github_organization_domain_name` | Only for GHE.com data residency | Leave commented otherwise. |
| `apply_approvers` | **Required: at least one** GitHub username, or `org/team-name` | See the warning below. |
| Both PAT entries | Keep commented out | Use the environment variables from section 2. |
| `starter_module_version`, `terraform_version` | `"v17.7.0"`, `"1.14.9"` | Match the version-specific module overlay. |
| `iac_type`, `bootstrap_module_name`, `starter_module_name` | `"terraform"`, `"alz_github"`, `"platform_landing_zone"` | Retain the GitHub deployment mode. |

> [!WARNING]
> **Do not leave `apply_approvers` empty.** The generated CD workflow (`02 Azure Landing Zones Continuous Delivery`) triggers on **every push to `main`**, and the approval gate on the apply environment is the only human control before changes reach Azure. The colleague's lab package ships `apply_approvers: []`, which disables that control; do not copy it into a shared or production tenant. Approvers on **private** repositories require a plan that supports environment protection rules.

Private networking is not air-gapped: the bootstrap includes NAT Gateway/public-IP egress. Runners need outbound HTTPS to GitHub, Entra ID, ARM, and package sources, plus private DNS/routing to backend storage and ACR. Preserve ACI subnet delegation and DNS links. `allow_storage_access_from_my_ip: false` does not give a workstation private connectivity; use the self-hosted runners for platform Terraform runs.

## 4. Review `config/platform-landing-zone.tfvars` and the library

Open [platform-landing-zone.tfvars](config/platform-landing-zone.tfvars) and review all settings before saving. The tracked profile is already configured; make only deliberate changes, merge into existing blocks without duplicate top-level maps, and preserve `$${...}` replacement tokens.

| Area | Required state |
| --- | --- |
| `starter_locations`, `starter_locations_short` | `["saudiarabiaeast"]`, `sae` |
| `management_group_settings.location` | `"uaenorth"` (policy identities only) |
| `management_resources_enabled` | `false`; keep the matching removal lists in `lib` active |
| NVA subnet `route_table.assign_generated_route_table` | `false` |
| Bastion host and public IP `zones` | `[]` on both |
| Corp DNS map | `dnzZoneRegionShortNames.saudiarabiaeast = "sae"` |
| DDoS | Disabled in source; flag, plan-ID default, and both `Enable-DDoS-VNET` removals must agree |
| Security subscription placement | Supply the ID, or comment out the whole placement block for three subscriptions |
| MCAPS public-IP tags (`FirstPartyUsage`) | Opt-in only when applied policies require them |

Never edit `.terraform`, and preserve `$${...}` replacement tokens.

### Resource flags, addressing, and DNS

Keep `management_groups_enabled = true` and `management_group_settings.architecture_name = "alz_custom"`. Disabling `management_resources_enabled` removes the entire management bundle (resource group, workspace, AMA identity, DCRs, and solutions), not bootstrap storage.

Under `custom_replacements.names`, keep VPN, Bastion, private zones, and private DNS auto-registration enabled; ExpressRoute and Private DNS Resolver disabled. Keep `hub_virtual_networks.primary.enabled_resources.firewall = false`; this is an NVA foundation, not Azure Firewall.

| Address replacement | Default |
| --- | --- |
| Regional routing space | `10.0.0.0/16` |
| Hub VNet | `10.0.0.0/22` |
| NVA subnet / next hop | `10.0.0.0/26` / `10.0.0.4` |
| Bastion subnet | `10.0.0.64/26` |
| Gateway subnet | `10.0.0.128/27` |
| Retained resolver subnet, resolver disabled | `10.0.0.160/28` |

Approve overlap checks against bootstrap, on-premises, and future spokes; update related `primary_*` replacements together. Keep the NVA subnet's `route_table.assign_generated_route_table = false`: otherwise the generated user-subnet default/summary routes point the appliance's own traffic back to itself.

Keep `hub_virtual_networks.primary.bastion.zones = []` and `bastion.bastion_public_ip.zones = []`. Saudi Bastion zonal creation failed with `BastionRegionAzNotSupported`; both lists must be empty to avoid inherited defaults. This is not zone-redundant Bastion and does not change gateway zones/SKUs.

Keep private zones, intended VNet links, and auto-registration (`saudiarabiaeast.azure.local`) enabled. Disabling Resolver does not disable zones or bootstrap DNS, but supplies no replacement forwarder. Approve an NVA/on-premises DNS path separately. Consider a customer-owned suffix instead of `.local`, which can conflict with multicast DNS.

**MCAPS only:** if applied policies require `FirstPartyUsage = "/Unprivileged"`, uncomment `ip_tags` inside **both** `virtual_network_gateways.vpn.ip_configurations.active_active_1.public_ip` and `active_active_2.public_ip`, and `bastion.bastion_public_ip`, all under `hub_virtual_networks.primary`. Place the tag in each public-IP object, not ordinary resource tags; retain empty Bastion zones. Verify all three IPs in the plan. Do not apply this tag indiscriminately.

### Policy defaults and Defender guardrails

Policy identity creation in Saudi Arabia East failed in a manual test and an independent deployment. Keep `management_group_settings.location = "uaenorth"` as an approved identity-only exception; changing it may replace assignments, identities, and role assignments. Keep Saudi resource locations unchanged.

Inside `management_group_settings.policy_default_values`:

| Entries | Required state and reason |
| --- | --- |
| `ama_change_tracking_data_collection_rule_id`, `ama_mdfc_sql_data_collection_rule_id`, `ama_vm_insights_data_collection_rule_id`, `ama_user_assigned_managed_identity_id`, `ama_user_assigned_managed_identity_name`, `log_analytics_workspace_id` | Commented out because the dependent resources and assignments are disabled. |
| `ddos_protection_plan_id` | Commented out for source-disabled DDoS. |
| `resource_group_name_mdfc`, `email_security_contact` | Commented out because automatic Defender configuration is excluded. |
| `resource_group_location`, `resource_group_name_service_health_alerts` | Active for the independent service-health policy; location stays on the Saudi replacement. |
| `private_dns_zone_subscription_id` | `"$${subscription_id_connectivity}"`. |
| `private_dns_zone_region` | `"$${starter_location_01}"` (full region, not `sae`). |
| `private_dns_zone_resource_group_name` | `"$${dns_resource_group_name}"`. |

In the existing `policy_assignments_to_modify` map, keep `corp.policy_assignments.Deploy-Private-DNS-Zones.parameters.dnzZoneRegionShortNames = { saudiarabiaeast = "sae" }`. The initiative must construct the same Backup zone ID as Terraform: `privatelink.sae.backup.windowsazure.com`. This replaces the entire default region map; extend it before adding another DNS region. If the Corp management-group ID changes, update the modification key. Do not remove the Corp DNS assignment.

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

Preserve [corp_custom](config/lib/archetype_definitions/corp_custom.alz_archetype_override.yaml) with `base_archetype: corp` and no removal of `Deploy-Private-DNS-Zones`, the [custom architecture](config/lib/architecture_definitions/alz_custom.alz_architecture_definition.yaml), [metadata](config/lib/alz_library_metadata.json), and remaining archetypes. A three-subscription test can retain an empty Security management group; remove its whole placement block, not the architecture.

For an approved enabled-DDoS variant, set `custom_replacements.names.ddos_protection_plan_enabled = true`, activate the policy default `ddos_protection_plan_id = "$${ddos_protection_plan_id}"`, remove only `Enable-DDoS-VNET` from the landing-zones removal list, and set the connectivity removal list to `[]`. Keep all monitoring/Defender removals and verify Saudi DDoS availability first.

To re-enable monitoring, restore the management bundle, its policy defaults, and dependent library assignments together. Before Defender re-enablement, review the complete retained source block and replace `defender_email_security_contact`. If Log Analytics stays off, retain `parameters.logAnalytics = ""` and the disabled override selecting `["ascExport", "defenderforKubernetes"]`; an empty workspace is not an alternative logging destination.

### Existing-deployment implications

- Management removal can delete a workspace, DCRs, identity, and resource group. Review retention/export, shared resources, deletion protection, and dependencies. Policy removal does not clean up agents, diagnostics, DCR associations, SQL auditing, or export automations.
- Removing Defender policies does not set existing plans to `Free`, remove integrations, or stop billing. Inventory existing protection, inherited policy, and automation separately.
- Removing a DDoS plan removes enhanced Network Protection, not baseline infrastructure protection; review VNet associations. IP Protection is not enabled automatically.
- Resolver deletion can break forwarding; Bastion/public-IP or gateway changes can replace resources and interrupt access. Review the exact plan.
- This reduced profile lacks centralized Log Analytics, VM Insights, AMA change tracking, SQL audit destination, and automatic Defender enablement. Obtain security/monitoring/compliance approval and alternatives. Remaining audit policies can still report noncompliance.

### Network module overlay

The [root networking overlay](config/main.connectivity.hub.and.spoke.virtual.network.tf) selects `source = "./modules/hub-and-spoke-vnet"` without `version`. The [hub module](config/modules/hub-and-spoke-vnet/main.tf) selects `source = "../private-link-private-dns-zones"` without `version`. The [DNS lookup](config/modules/private-link-private-dns-zones/locals.tf) returns `"sae"` only for normalized `saudiarabiaeast`, preserving upstream lookups for other regions: the upstream Saudi `geo_code` is null, which makes `replace` fail.

Keep all 48 source files, licenses, moved blocks, outputs, variables, and nested modules from hub-and-spoke `v0.17.2` and private DNS `v0.23.2`. The starter short name, Corp policy map, and module patch fix three separate lookups; all are required. Pass `lib`, `modules`, and the networking file to bootstrap (section 7); adjacent folders are not copied automatically. Preserve the starter's `modules\config-templating`.

## 5. Provider-validation workaround for GitHub Actions

The starter constrains AzureRM to `~> 4.0`, whose enhanced validation can reject `saudiarabiaeast` as unknown before ARM sees a request. The location-only switch below fixes that without disabling resource-provider validation:

```yaml
env:
  ARM_PROVIDER_ENHANCED_VALIDATION_LOCATIONS: "false"
```

GitHub has no Azure DevOps-style variable group. The setting must be in the `env:` block of **each of the three Terraform jobs** in the generated **templates repository**: the CI plan job in `ci-template.yaml`, and the plan and apply jobs in `cd-template.yaml` (separate jobs do not share it). The two other places you might try do **not** work: an `env:` block in the caller workflows (`ci.yaml`/`cd.yaml` in the platform repository) is not passed to the reusable template jobs, and a repository or organization Actions *variable* is only readable through the `vars` context, not exported as an environment variable. Never set the legacy `ARM_PROVIDER_ENHANCED_VALIDATION=false` alongside it (the provider rejects the combination). It does not bypass Azure Policy, RBAC, quota, or ARM validation, and it does not fix DNS geo-code metadata.

Choose one delivery path:

### Option A: bake it in before bootstrap (recommended)

The bootstrap source can be overridden so the templates repository is created with the fix. Upstream's `v7.3.2` templates already contain an `env:` block beginning with `ARM_CLIENT_ID` in all three jobs; add one line above it.

```powershell
$bootstrapSourcePath = Join-Path $env:USERPROFILE "alz-bootstrap-v7.3.2"   # outside this Git repository
git clone --branch v7.3.2 --depth 1 https://github.com/Azure/accelerator-bootstrap-modules.git $bootstrapSourcePath
```

In `alz\github\actions\terraform\templates\workflows\ci-template.yaml` (1 job) and `cd-template.yaml` (2 jobs), insert as the first entry of each Terraform job's `env:` block:

```yaml
      ARM_PROVIDER_ENHANCED_VALIDATION_LOCATIONS: "false"
```

Confirm exactly three occurrences, then add `-bootstrapModuleOverrideFolderPath $bootstrapSourcePath` to the bootstrap command in section 7. Keep this folder outside the repository: it is a full copy of upstream with its licenses.

> [!NOTE]
> The colleague's package pins the bootstrap commit `7887040f`, which is **one commit ahead of the `v7.3.2` release**. Use the tag unless you have reviewed that extra commit.

### Option B: pull request after bootstrap

Skip the override. After bootstrap, open a pull request against `<organization>/<service>-<environment>-templates` (default `alz-mgmt-templates`) adding the same line to the three jobs in `.github/workflows/ci-template.yaml` and `cd-template.yaml`, and merge it **before** the first deliberate CI/CD run. Branch protection requires the pull request.

Expect the **automatic first CD run triggered by bootstrap's push to `main` to fail at the plan stage** with a location-validation error until the fix is merged. That failure is harmless, but the apply approval must still stay enabled (section 3); do not approve any apply from a run that did not use the reviewed plan.

## 6. Validate files and complete preflight

### Source checks

```powershell
$targetFolderPath = "D:\workarea\Source\alz\terraform\github\single-region-hub-and-spoke-vnet-with-nva"
# For a private, ignored copy, point at its folder instead:
# $targetFolderPath = "...\single-region-hub-and-spoke-vnet-with-nva\.local-tests"

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

Formatting parses Terraform files, not YAML, ALZ semantics, backend access, or Azure availability. This overlay is **not** a complete Terraform root; do not run `terraform validate` or plan here.

### Authentication and design gates

```powershell
az login --tenant "<tenant-id>" --use-device-code
az account set --subscription "<management-subscription-id>"
az account show --query "{tenantId:tenantId,subscriptionId:id,name:name}" --output table
az account list-locations `
    --query "[?name=='saudiarabiaeast' || name=='uaenorth'].{Name:name,DisplayName:displayName}" `
    --output table
```

Repeat service/SKU/quota checks in the relevant subscriptions; region visibility alone is insufficient. For enabled DDoS, check the connectivity subscription explicitly:

```powershell
az provider show `
    --subscription "<connectivity-subscription-id>" `
    --namespace Microsoft.Network `
    --query "resourceTypes[?resourceType=='ddosProtectionPlans'].{Type:resourceType,Locations:locations}" `
    --output json
az network ddos-protection list `
    --subscription "<connectivity-subscription-id>" `
    --query "[?location=='saudiarabiaeast'].{Name:name,Location:location,ResourceGroup:resourceGroup}" `
    --output table
```

Before bootstrap, confirm:

- [ ] Folder, subscription inputs, placements, bootstrap subscription, tenant, and parent management group agree.
- [ ] Azure permissions/PIM, provider registrations, GitHub organization-owner rights, repository-name availability, and both PAT variables are ready.
- [ ] The GitHub plan, repository visibility (public on Free), and outside-contributor workflow approval policy are approved.
- [ ] `apply_approvers` contains real approvers.
- [ ] Regional split, cross-border state/runners, policy exceptions, SKUs, capacity, and address ranges are approved.
- [ ] Provider-validation workaround delivery (Option A or B) is chosen.
- [ ] Bastion zones are `[]`; VPN and Bastion deployment are approved.
- [ ] DDoS flag, plan-ID default, and both removal lists agree; any required MCAPS tags are on all three public IPs.
- [ ] Monitoring, Defender, and resolver removals include dependent policy updates and approved alternatives.
- [ ] Corp DNS map, full DNS region, starter short name, library, and all overlay paths are present.
- [ ] No state, credentials, generated caches, or tenant-specific files are staged.

## 7. Bootstrap, then verify the exact workflow checkout

Run this **one** command after preflight, with the selected `$targetFolderPath` and both PAT variables still set. Omit the last override line for Option B.

```powershell
Deploy-Accelerator `
    -inputs "$targetFolderPath\config\inputs.yaml", "$targetFolderPath\config\platform-landing-zone.tfvars" `
    -starterAdditionalFiles "$targetFolderPath\config\lib", `
                            "$targetFolderPath\config\modules", `
                            "$targetFolderPath\config\main.connectivity.hub.and.spoke.virtual.network.tf" `
    -output "$targetFolderPath\output" `
    -bootstrapModuleOverrideFolderPath $bootstrapSourcePath
```

ALZ `7.1.5` copies additional folders by folder name and files by filename before bootstrap Terraform runs, overwriting matching starter content. Pass all three paths: only `lib` omits the Saudi workaround, and modules without the networking file leaves the registry hub active. Adjacent folders are not included automatically.

Review the plan before confirming apply: UAE North resources, the approved `10.250.0.*` layout, private endpoints, runners, the two repositories and their visibility, the approval team and environments, and no unexpected changes. Bootstrap creates the delivery foundation, not the platform. Protect and back up its output/state; if it fails, fix the specific cause and rerun with the **same configuration, output, and preserved state**. Do not delete state or repositories to force regeneration.

After bootstrap:

1. Confirm the two self-hosted runners are online (**Settings > Actions > Runners** in the platform repository, or the runner group on Enterprise).
2. Confirm the `<service>-<environment>-plan` and `-apply` environments exist, the apply environment lists the intended reviewers, and branch protection on `main` is active.
3. Inspect the exact `main` commit: both module sources are local without a `version` argument, the Saudi lookup is present, all 48 module files and licenses are committed, and `config-templating` and the custom library are intact.
4. Confirm the three `ARM_PROVIDER_ENHANCED_VALIDATION_LOCATIONS` entries are present in the templates repository (and that none of them also sets the legacy variable).
5. Run **01 Azure Landing Zones Continuous Integration** through a pull request or manual dispatch and review the authenticated plan. Then run **02 Azure Landing Zones Continuous Delivery** with `apply`, using the approval gate. Do not push to `main` merely to inspect a plan: the push starts CD.

From a generated platform checkout, local syntax validation can run these **individually**, stopping on failure:

```powershell
terraform fmt -check -recursive
terraform init -backend=false -input=false
terraform validate
```

Keep the lock file and avoid `-upgrade`. CI/CD must initialize the real backend and run the reviewed plan.

### Platform apply acceptance checks

- No null `replace` or SQL casing errors.
- Backup zone is `privatelink.sae.backup.windowsazure.com` and the Corp policy constructs the same ID; auto-registration is `saudiarabiaeast.azure.local`, with intended VNet links and bootstrap DNS intact.
- Platform resources are in Saudi Arabia East, bootstrap in UAE North, and policy identities in the approved identity region. Global resources have no regional location.
- No management workspace, DCRs, or AMA identity; removed monitoring/Defender assignments are absent, and both guardrail scopes retain disabled Defender settings.
- No Private DNS Resolver/endpoints or ExpressRoute gateway; VPN and Bastion remain enabled, with both Bastion zone lists empty.
- DDoS resource/assignments match the chosen variant; MCAPS tags are on all three public IPs when required.
- No unexpected deletions, replacements, resource-address changes, subscription moves, or permission changes.

Only an authorized approver approves the acceptable plan. Bootstrap success or local validation does not replace these checks.

### Existing generated repository: fallback delivery

If bootstrap already completed without the overlay, **do not rerun it just for DNS**. In the generated **platform repository** (`<service>-<environment>`), not the templates repository:

1. Create a change branch.
2. Compare starter/hub/DNS versions against the pins above.
3. Copy the two tracked module folders into the existing `modules` folder, preserving `config-templating`.
4. Change the hub module source in the root networking file to `"./modules/hub-and-spoke-vnet"` and remove that call's `version` argument.
5. Merge all applicable tfvars changes into `platform-landing-zone.auto.tfvars`, and deliver the library changes.
6. Open a pull request, let CI run, and merge only after reviewing the plan. Retain the provider lock file.

## 8. Operations and version control

After apply, verify hierarchy and subscription placement, regional resources, runner access to private backend/registry, federated credentials (OIDC), apply approvals, policy compliance, and a drift plan.

Deploy and license the NVA separately; align its IP with `10.0.0.4`, configure IP forwarding, routing, inspection, and the replacement DNS path, add and peer spokes, and test end-to-end traffic. A route to an undeployed appliance is not a functioning NVA path.

Clear the local tokens after bootstrap and revoke the short-lived bootstrap token:

```powershell
Remove-Item Env:\TF_VAR_github_personal_access_token
Remove-Item Env:\TF_VAR_github_runners_personal_access_token
```

Clearing variables does not revoke tokens already given to runners; keep the runner-token renewal process.

Use the [workspace root](../../) as the single Git repository and keep the root and [scenario ignore rules](.gitignore) excluding output, temp, local tests, state, plans, caches, and credentials:

```powershell
Set-Location "D:\workarea\Source\alz\terraform"
git add -- github\single-region-hub-and-spoke-vnet-with-nva
git diff --cached --check
git diff --cached --stat
# Inspect staged content for credentials and unintended changes before committing.
```

These steps do not publish anything to the generated GitHub repositories; ongoing platform changes go through pull requests there. Remove the temporary overlay only after a verified upstream release fixes the dependency actually consumed by the hub module, and drop the provider-validation workaround only after confirming the provider's region metadata.

## 9. Troubleshooting

| Symptom | Action |
| --- | --- |
| Null `replace` still fails | Check the exact workflow checkout's two local module sources and Saudi DNS lookup; reinitialize. Never patch `.terraform`. |
| `Module not installed` / source changed | Run `terraform init`; remove `version` only from calls switched to local sources. |
| `BastionRegionAzNotSupported` | Set both host and public-IP zones to `[]`; inspect provisioning/state before recovery, not blind deletion/import. |
| SQL override rejects `"Disabled"` | Overrides use lowercase `"disabled"`; initiative parameters use `"Disabled"`. |
| DNS policy cannot index region map | Keep full `saudiarabiaeast` in defaults, its `sae` map entry, and the actual Corp management-group key. |
| DNS zones/links unexpectedly replaced | Preserve block names and instance keys; investigate rather than approve. |
| ACR fails in Saudi / ACI zone error | Keep bootstrap in a supported region. If approved, set `agent_container_zone_support: false`; assess registry zone redundancy separately. |
| Invalid Security placement | Supply its subscription ID or comment out the entire placement block for a three-subscription test. |
| Region/SKU denied or unavailable | Check subscription access, policy, capacity, and zones with the workflow identity; approve design changes rather than silently relocating resources. |
| NVA next hop unreachable | Deploy/license the appliance, align its IP with the next hop, and test routing and DNS. |
| `saudiarabiaeast` rejected as an invalid location | Check the three template jobs have `ARM_PROVIDER_ENHANCED_VALIDATION_LOCATIONS: "false"` and not the legacy variable; verify access with the same OIDC identity. |
| Runners offline / jobs queued | Check runner token expiry and scope, ACI logs, image pull, DNS/egress, and runner group/repository assignment. For an expired token, use the accelerator's recovery steps. |
| Backend access denied/timed out | Check the plan/apply managed-identity roles, private endpoint approval, routing, and DNS; do not enable public access. |
| `Resource not accessible by integration` / 403 on bootstrap | Check token 1 permissions, resource owner, repository access, and organization-owner rights. |
| Bootstrap fails creating repositories as private | Free plan forces public; use an eligible paid plan for private repositories. |
| CD ran immediately after bootstrap | Expected: bootstrap pushes to `main`. Verify the apply environment has reviewers and cancel any unreviewed run. |
| Apply never prompts | `apply_approvers` was empty, or the environment protection is unavailable on the plan. Fix it before any apply. |
| OIDC `AADSTS70021` / no matching federated credential | Environment or repository names changed after bootstrap; keep `service_name`/`environment_name` stable. |
| `alz_custom` missing | Pass the complete library in `-starterAdditionalFiles`. |
| Source edit does not affect the workflow | Deliver it to the generated platform repository by pull request; rerunning bootstrap does not republish a different local folder. |
| ALZ prerequisite check fails on `Find-PSResource` (private Azure Artifacts feed) | Re-run with `-skipAlzModuleVersionRequirementsCheck` on `Deploy-Accelerator` after importing the exact ALZ version. This skips only the online latest-version lookup. |
| Long-path errors on Windows | Use a short folder path and process-only `git -c core.longpaths=true`; do not change global Git settings. |

## 10. Cross-check with Mohamed Selim's GitHub repository

Compared on 22 November 2026 with [moselim200/saudi-alz-github-hub-spoke-nva](https://github.com/moselim200/saudi-alz-github-hub-spoke-nva) (commit `7f39b81`): `alz_github`, starter `v17.7.0`, Terraform `1.14.9`, ALZ `7.1.5`, library `platform/alz@2026.11.0`. The owner's publication status is **customer-reported verified**; no independent run evidence, traffic test, security certification, or production-readiness claim accompanies it. This guide was compared file by file and was not deployed.

| Area | Result |
| --- | --- |
| Hub-and-spoke `v0.17.2` and private DNS `v0.23.2` modules | **Match.** The runtime `.tf` files are identical except the hub module's DNS source (`../private-dns-zones` there, `../private-link-private-dns-zones` here), the networking overlay's source path (`./modules/vendor/hub-and-spoke-vnet` there, `./modules/hub-and-spoke-vnet` here), trailing blank lines in three files, and the DNS `locals.tf` (`lookup()` versus a conditional; both give `sae` for Saudi Arabia East and the upstream value otherwise). Their extra files are documentation, a mocked test, and `.terraform-docs` metadata. |
| Saudi DNS | **Match.** `saudiarabiaeast` maps to `sae` (`privatelink.sae.backup.windowsazure.com`); Corp `dnzZoneRegionShortNames.saudiarabiaeast = "sae"`. |
| Bastion | **Match.** Host and public IP use `zones = []`. |
| Policy-identity location | **Match.** `management_group_settings.location = "uaenorth"`; Saudi policy-resource locations are unchanged. |
| NVA subnet | **Match.** `assign_generated_route_table = false`. Their explicit `route_table_*_enabled = true`, `nat_gateway = false`, and `default_outbound_access_enabled = false` equal this module's defaults, so there is no functional difference. |
| Bootstrap | **Match.** Everything in `uaenorth`, private networking, `10.250.0.0/24` layout, `allow_storage_access_from_my_ip: false`, explicit bootstrap subscription, four distinct subscriptions. |
| Provider validation | **Match.** `ARM_PROVIDER_ENHANCED_VALIDATION_LOCATIONS: "false"` in all three jobs (CI plan, CD plan, CD apply) via a patched bootstrap source; the launcher also clears the legacy variable. Option A here does the same from a pinned release tag. |
| Policy removals | **Differs, by design.** They remove only `Deploy-AzActivity-Log`, `Deploy-Diag-LogsCat`, and `Deploy-MDFC-Config-H224` at the root and keep the SQL and endpoint Defender assignments. This guide removes the broader Defender and workspace-dependent set; that is a security decision, not an error. They also omit the Defender guardrail parameter overrides (`policy_assignments_to_modify` for `platform` and `landingzones`) that this guide keeps. |
| VPN gateway | **Not validated.** They set `primary_virtual_network_gateway_vpn_enabled = false` and their tfvars has no `virtual_network_gateways` block, so their deployment gives no evidence for this guide's VPN gateway. |
| DDoS, Log Analytics, Private DNS Resolver | Same disabled profile; they report Azure rejected Resolver (and Log Analytics) in Saudi Arabia East. Recheck per subscription. |
| Hub addressing | **Differs.** Theirs: `10.0.4.0/22`, NVA `10.0.4.64/26`, next hop `10.0.4.68`. Here: `10.0.0.0/22`, NVA `10.0.0.0/26`, next hop `10.0.0.4`. Both are samples that need IPAM approval. |
| Auto-registration zone | **Differs.** `<region>.customer.internal` there; `saudiarabiaeast.azure.local` here. `.local` is reserved for multicast DNS and can conflict with on-premises name resolution; consider a customer-owned suffix before production (update the name consistently). |
| `apply_approvers` | **Differs, and this guide is safer.** They ship `[]` for the lab, which disables the apply gate. |
| Bootstrap source | **Differs.** They pin a commit one ahead of `v7.3.2`; this guide uses the release tag. |
| Public-IP tags (`FirstPartyUsage`) | They do not use them; here they remain opt-in for MCAPS. |

Follow-ups from the comparison: the `.local` suffix and the empty-approver default are the two items worth acting on. Their mocked-plan test (`terraform test`, 192 resources) and launcher are useful references and are not adopted here.

## 11. Alternative for teams that prefer less manual work

This guide is deliberately file-by-file. If your team does not want to edit and assemble these files manually, use Mohamed Selim's prewired package instead:

**[moselim200/saudi-alz-github-hub-spoke-nva](https://github.com/moselim200/saudi-alz-github-hub-spoke-nva)** (a combined catalogue with the other scenarios is at [moselim200/saudi-alz-scenario-packages](https://github.com/moselim200/saudi-alz-scenario-packages)).

What it does for you:

- Ships the topology, custom library, Saudi DNS overlay, and a patched bootstrap source already wired together (no overlay or topology swapping).
- Provides `Start-CustomerBootstrap.ps1`, which runs offline checks (`-CheckOnly`), rejects unresolved placeholders and invalid subscription IDs, pins ALZ `7.1.5`, sets only the location-validation variable, and calls `Deploy-Accelerator` with every additional path.
- You normally edit two files: `config\inputs.yaml` and `config\platform-landing-zone.tfvars`.
- Includes a Word customer guide, a checklist, and a mocked-plan test.

Typical use: download the repository ZIP into a short path such as `C:\ALZ\HSNVA`, fill `config\inputs.yaml`, install Terraform `1.14.9` and the ALZ module, set the two token variables, run `.\Start-CustomerBootstrap.ps1 -CheckOnly -TerraformPath $tf`, then the same command without `-CheckOnly`.

Know the limits before choosing it:

- Its status is **customer-reported verified**, not independently verified, and it makes no production-readiness claim. It disables VPN, DDoS, Firewall, Resolver, and central monitoring.
- It is one fixed profile. Changes such as enabling the VPN gateway, a different policy-removal set, or a different region split require editing its Terraform, at which point this guide's rationale applies.
- Before bootstrapping, set at least one `apply_approvers` entry and review the repository visibility (public on GitHub Free), outside-contributor policy, hub addressing, and the `.local` suffix noted in section 10. Its launcher requires the PAT placeholders to stay literal and the tokens to come from `TF_VAR_*` variables, and it requires four distinct subscriptions.
- It pins a bootstrap commit one ahead of `v7.3.2`; review that or accept it explicitly.

## References

Recheck all of these before deployment:

- [Scenario 8: hub and spoke with NVA](https://azure.github.io/Azure-Landing-Zones/accelerator/starter-terraform/scenarios/single-region-hub-and-spoke-vnet-with-nva/)
- [GitHub prerequisites and tokens](https://azure.github.io/Azure-Landing-Zones/accelerator/1_prerequisites/github/)
- [Planning](https://azure.github.io/Azure-Landing-Zones/accelerator/0_planning/)
- [Tooling prerequisites](https://azure.github.io/Azure-Landing-Zones/accelerator/1_prerequisites/)
- [Platform subscriptions and permissions](https://azure.github.io/Azure-Landing-Zones/accelerator/1_prerequisites/platform-subscriptions/)
- [Advanced bootstrap commands](https://azure.github.io/Azure-Landing-Zones/accelerator/2_bootstrap/advanced/)
- [Deployment pipeline](https://azure.github.io/Azure-Landing-Zones/accelerator/3_run/)
- [Accelerator troubleshooting](https://azure.github.io/Azure-Landing-Zones/accelerator/troubleshooting/)
- [GitHub bootstrap variables](https://github.com/Azure/accelerator-bootstrap-modules/blob/v7.3.2/alz/github/variables.tf)
- [GitHub workflow templates at v7.3.2](https://github.com/Azure/accelerator-bootstrap-modules/tree/v7.3.2/alz/github/actions/terraform/templates/workflows)
- [AzureRM 4.77 enhanced-validation controls](https://github.com/hashicorp/terraform-provider-azurerm/blob/v4.77.0/internal/features/enhanced_validation.go)
- [Hub-and-spoke source v0.17.2](https://github.com/Azure/terraform-azurerm-avm-ptn-alz-connectivity-hub-and-spoke-vnet/tree/v0.17.2)
- [Private DNS source v0.23.2](https://github.com/Azure/terraform-azurerm-avm-ptn-network-private-link-private-dns-zones/tree/v0.23.2)
- [Colleague's GitHub package](https://github.com/moselim200/saudi-alz-github-hub-spoke-nva)
