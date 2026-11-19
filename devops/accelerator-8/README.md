# Scenario 8: Saudi Arabia landing zone with Terraform and Azure DevOps

This guide deploys **scenario 8: Single-Region Hub and Spoke Virtual Network with a Network Virtual Appliance (NVA)** using the Azure Landing Zones accelerator, Azure DevOps, private networking, and self-hosted agents.

The guide describes configuration and deployment steps. Configuration edits described as already applied are saved locally; they are not proof of an Azure deployment. Examples below show where to merge changes, not permission to replace whole configuration files.

### Start here: files, scope, and current blockers

Line references below describe the current configuration snapshot and can shift after edits. Use the named block as the primary search anchor. Paths are relative to this scenario folder.

| What to edit | File / current line | Search anchor |
| --- | --- | --- |
| Bootstrap region, subscriptions, Azure DevOps, and version pins | [inputs.yaml](config/inputs.yaml#L11) | `bootstrap_location`, `subscription_ids`, `starter_module_version` |
| Saudi region and starter short-name override | [platform-landing-zone.tfvars](config/platform-landing-zone.tfvars#L21) | `starter_locations`, `starter_locations_short` |
| DDoS, VPN, and Private DNS Resolver flags | [platform-landing-zone.tfvars](config/platform-landing-zone.tfvars#L58) | `custom_replacements.names` |
| Disable the management-resources bundle | [platform-landing-zone.tfvars](config/platform-landing-zone.tfvars#L139) | `management_resources_enabled` |
| Policy-assignment identity location | [platform-landing-zone.tfvars](config/platform-landing-zone.tfvars#L170) | `management_group_settings.location` |
| Shared DNS, monitoring, and DDoS policy parameters | [platform-landing-zone.tfvars](config/platform-landing-zone.tfvars#L178) | `policy_default_values` |
| Saudi DNS policy map | [platform-landing-zone.tfvars](config/platform-landing-zone.tfvars#L221) | `policy_assignments_to_modify.corp` |
| Defender guardrail parameter overrides | [platform-landing-zone.tfvars](config/platform-landing-zone.tfvars#L267) and [landing-zones block](config/platform-landing-zone.tfvars#L308) | `platform`, `landingzones` |
| Gateway configuration and DNS zone wiring | [platform-landing-zone.tfvars](config/platform-landing-zone.tfvars#L430) and [DNS block](config/platform-landing-zone.tfvars#L462) | `virtual_network_gateways`, `private_dns_zones` |
| Root monitoring/Defender policy removals | [root_custom.alz_archetype_override.yaml](config/lib/archetype_definitions/root_custom.alz_archetype_override.yaml#L4) | `policy_assignments_to_remove` |
| Platform AMA policy removals | [platform_custom.alz_archetype_override.yaml](config/lib/archetype_definitions/platform_custom.alz_archetype_override.yaml#L4) | `policy_assignments_to_remove` |
| Landing-zone monitoring, Defender, and DDoS removals | [landing_zones_custom.alz_archetype_override.yaml](config/lib/archetype_definitions/landing_zones_custom.alz_archetype_override.yaml#L4) | `policy_assignments_to_remove` |
| Connectivity DDoS policy removal | [connectivity_custom.alz_archetype_override.yaml](config/lib/archetype_definitions/connectivity_custom.alz_archetype_override.yaml#L4) | `Enable-DDoS-VNET` |
| Preserve the Corp DNS assignment and its scope | [corp_custom.alz_archetype_override.yaml](config/lib/archetype_definitions/corp_custom.alz_archetype_override.yaml#L1) and [custom architecture](config/lib/architecture_definitions/alz_custom.alz_architecture_definition.yaml#L24) | `base_archetype: corp`, `id: corp` |

**Choose one configuration folder before editing or running bootstrap:**

| Setting | Source scenario described by this guide | Existing isolated local test copy |
| --- | --- | --- |
| Folder selected by `$targetFolderPath` | This scenario folder | Its `.local-tests\accelerator-8` subfolder |
| Platform subscriptions | Four placeholder IDs still need customer input | Three configured subscriptions; Security placement is commented out |
| Policy-assignment identity location | References the Saudi starter region | References the Saudi starter region |
| DDoS plan and auto-enablement policies | Disabled | Enabled |
| VPN gateway | Enabled | Enabled |
| Saudi starter short name and Corp DNS policy map | `sae`, already applied | `sae`, already applied |
| Log Analytics bundle, Private DNS Resolver, automatic Defender enablement | Disabled | Disabled |

The test copy is ignored by Git and is not included in a fresh clone. Where present, follow its own [README](.local-tests/accelerator-8/README.md); do not copy its tenant-specific configuration into the tracked source or regenerate it. Editing the source does not synchronize the test copy or an already-generated Azure DevOps repository.

> **Platform deployment gate:** The pinned private DNS module still fails when the Saudi `geo_code` is null. Bootstrap can prepare the delivery foundation, but before running or approving the platform deployment, follow [Post-bootstrap Saudi DNS module fix](#post-bootstrap-saudi-dns-module-fix) and review a successful generated Terraform plan. The starter `sae` override and policy region map do not fix that module dependency. Fill in the source subscription/organization placeholders before bootstrap.

## 1. Understand the deployment and region split

| Component | Region / setting |
| --- | --- |
| Infrastructure as code | Terraform |
| Version control and pipelines | Azure DevOps Services |
| Scenario | `8` |
| Bootstrap resources, including agent infrastructure and Terraform backend storage | UAE North: `uaenorth` |
| Regional platform landing-zone resources | Saudi Arabia East: `saudiarabiaeast` |
| Policy assignments with managed identities | Saudi Arabia East, following `starter_location_01` |
| Pipeline agents | Self-hosted Azure Container Instances (ACI) agents |
| Bootstrap networking | Private endpoints and a dedicated bootstrap virtual network |

**Why two regions?** For this deployment, Azure Container Registry (ACR) is not yet available in Saudi Arabia East. The standard self-hosted-agent bootstrap creates an ACR to build and store the agent image, so **do not set `bootstrap_location` to `saudiarabiaeast` while that dependency is unavailable**. Use `uaenorth` for the bootstrap and `saudiarabiaeast` for `starter_locations`.

Treat ACR unavailability as a deployment constraint to recheck before execution, not a permanent Azure limitation. Verify regional access, service/SKU availability, capacity, and availability-zone support for both regions in the target subscriptions. This guide does not certify their availability.

> **Data residency approval is required.** Bootstrap storage, agent execution, container images, and Terraform state are outside Saudi Arabia in this design. Terraform state and pipeline artifacts can contain infrastructure metadata and sensitive values. Azure DevOps also has its own organization data location. Private endpoints do not make those services Saudi-resident. If all deployment data must remain in Saudi Arabia, stop and approve a different supported bootstrap design rather than using this workaround.

Scenario 8 creates management groups, policies, management resources, and a single-region hub network ready for an NVA. It does **not** deploy the third-party NVA, vendor licenses, production spoke workloads, an ExpressRoute circuit, or an on-premises VPN device. Those require separate deployment and configuration.

## 2. Prepare subscriptions, permissions, and tools

### Azure prerequisites

Prepare four platform subscriptions in the same Microsoft Entra tenant:

| Subscription | Purpose |
| --- | --- |
| Management | Management resources and, in this guide, bootstrap resources |
| Connectivity | Saudi hub networking and connectivity services |
| Identity | Placement for identity workloads |
| Security | Placement for security workloads |

Record their subscription IDs and the tenant ID. Choose an existing parent management group; leaving its configuration value empty uses the Tenant Root Group.

The account running the bootstrap needs:

- `Owner` on the chosen parent management group.
- `Owner` on all four platform subscriptions, including the management subscription used for bootstrap.
- Active privileged roles if access is controlled through Privileged Identity Management.
- Azure DevOps permissions to create/manage the project, repositories, pipelines, service connections, environments, and organization-level agent pool. PAT scopes do not grant rights the user does not already have.

Review inherited policies before deploying. In particular, allowed-location policies must permit the UAE North bootstrap resources as well as the Saudi regional resources, or have approved, appropriately scoped exemptions. A Saudi-only policy applied indiscriminately to the management subscription will block this design. Do not remove governance controls simply to make deployment succeed.

### Local tools

Use a **PowerShell 7.4 or newer** terminal with:

- Azure CLI 2.55.0 or newer.
- Git.
- Visual Studio Code, recommended.
- Internet access to Azure, Azure DevOps, PowerShell Gallery, GitHub, and the Terraform/provider download endpoints required by the accelerator.

The ALZ module manages its accelerator dependencies. This deployment pins the starter module to `v17.7.0` and Terraform to `1.14.9` in the bootstrap inputs. Keep provider versions compatible with the pinned starter module.

The accelerator does not explicitly support Azure Cloud Shell or operation behind a corporate proxy. Use a suitable workstation or administrative VM instead.

Check the tools:

```powershell
$PSVersionTable.PSVersion
az version
git --version
```

## 3. Prepare Azure DevOps and two PATs

Use an Azure DevOps Services organization connected to the intended tenant. Confirm that at least one **self-hosted parallel job** is available; provisioning agents alone does not grant pipeline concurrency.

Under **User settings > Personal access tokens**, create two tokens scoped to that organization.

### Token 1: bootstrap administration

Use a short lifetime sufficient to finish bootstrap. The accelerator prerequisites specify:

| Scope | Permission |
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

### Token 2: self-hosted agent registration

Grant only **Agent Pools > Read & manage**. Choose an organization-approved lifetime and establish renewal before expiry; agents may need the token again when restarted or recreated.

Use environment variables rather than saving token values in configuration files. In the PowerShell terminal that will run bootstrap:

```powershell
$env:TF_VAR_azure_devops_personal_access_token = Read-Host "Bootstrap PAT (token 1)" -MaskInput
$env:TF_VAR_azure_devops_agents_personal_access_token = Read-Host "Agent registration PAT (token 2)" -MaskInput
```

Do not print these variables, commit PATs, or put them in command-line literals. Environment variables prevent embedding tokens in the source configuration, but generated Terraform state and other bootstrap artifacts must still be protected.

## 4. Install ALZ and generate scenario 8

Start from the Terraform workspace root. The following example uses this workspace's Windows path:

```powershell
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
$targetFolderPath = ".\devops\accelerator-$scenarioNumber"

New-AcceleratorFolderStructure `
    -iacType $iacType `
    -versionControl $versionControl `
    -scenarioNumber $scenarioNumber `
    -targetFolderPath $targetFolderPath
```

Set `$scenarioNumber = 8` explicitly; assigning `$scenarioNumber` to itself does not select a scenario in a fresh terminal.

**Existing folder:** This workspace already contains the scenario 8 configuration. Skip the generation command when using those files. Back up any customizations before deliberately regenerating configuration.

Review:

- [Bootstrap inputs](config/inputs.yaml).
- [Platform landing-zone settings](config/platform-landing-zone.tfvars).
- [Custom ALZ library](config/lib/).

Keep the terminal open for the later commands. In a new terminal, restore the working directory, variables, and PAT environment variables.

## 5. Configure the bootstrap inputs

Edit [config/inputs.yaml](config/inputs.yaml). The following is a complete example for this design. Replace every angle-bracket placeholder with your own value.

The current source still contains subscription/organization placeholders, leaves `bootstrap_subscription_id` empty, and does not yet include the custom bootstrap network inputs shown below. Set the management subscription explicitly and add those network keys when following this design. Do not assume the example has already been saved into the source inputs.

**Keep the existing two PAT entries commented out in the YAML when using the environment variables from step 3.** Do not leave active placeholder PAT values in the file, because explicit configuration values can take precedence over environment variables. The checked-in entries are commented out for this workflow.

```yaml
---
# Bootstrap resources stay in UAE North while Saudi ACR is unavailable.
bootstrap_location: "uaenorth"

# Existing management group ID, not its full resource ID.
# Leave empty to use the Tenant Root Group.
root_parent_management_group_id: "<parent-management-group-id>"

subscription_ids:
  management: "<management-subscription-id>"
  identity: "<identity-subscription-id>"
  connectivity: "<connectivity-subscription-id>"
  security: "<security-subscription-id>"

# Use the management subscription for bootstrap.
bootstrap_subscription_id: "<management-subscription-id>"

service_name: "alz"
environment_name: "mgmt"
postfix_number: 1

use_self_hosted_agents: true
use_private_networking: true

virtual_network_address_space: "10.250.0.0/24"
virtual_network_subnet_address_prefix_container_instances: "10.250.0.0/26"
virtual_network_subnet_address_prefix_private_endpoints: "10.250.0.64/26"
allow_storage_access_from_my_ip: false

# Organization name only, not the https://dev.azure.com/ URL.
azure_devops_organization_name: "<azure-devops-organization>"
azure_devops_project_name: "<azure-devops-project-name>"
apply_approvers: ["<approver-user-principal-name>"]

# Version pins
starter_module_version: "v17.7.0"
terraform_version: "1.14.9"

# Basic inputs: do not modify for this deployment.
iac_type: "terraform"
bootstrap_module_name: "alz_azuredevops"
starter_module_name: "platform_landing_zone"
```

Use an approver who exists in the Azure DevOps organization and can approve the generated apply environment. Retain the approval gate for production.

The bootstrap creates a project by default. To use an existing project, add:

```yaml
azure_devops_create_project: false
```

Confirm your account can administer the existing project and that generated resource names do not conflict with existing repositories, pipelines, or agent pools.

### Bootstrap network design

| Network | CIDR | Purpose |
| --- | --- | --- |
| Bootstrap VNet | `10.250.0.0/24` | Dedicated UAE North bootstrap network |
| ACI subnet | `10.250.0.0/26` | Self-hosted container agents |
| Private endpoint subnet | `10.250.0.64/26` | Bootstrap private endpoints |
| Unallocated space | `10.250.0.128/25` | Reserved; no additional subnet is requested here |

These settings customize the **bootstrap network**, not the Saudi hub VNet. They avoid the scenario's default hub range of `10.0.0.0/22`, but both networks must also be checked against corporate, VPN, ExpressRoute, and future spoke ranges.

Private networking does not mean an air-gapped deployment:

- The bootstrap provisions supporting networking, including NAT Gateway and a public IP for outbound access.
- Agents require outbound HTTPS to Azure DevOps, Microsoft Entra ID, Azure Resource Manager, and required module/provider/package sources.
- Agents must resolve and reach the private endpoints for state storage and the registry.
- Keep ACI subnet delegation and generated private DNS links intact.
- Do not add blanket inbound internet access to register agents; agents initiate their Azure DevOps connections outbound.

`allow_storage_access_from_my_ip: false` means the accelerator must not add your workstation's public IP as a storage firewall exception. It does not create workstation connectivity to private storage. For any administrative operation that directly accesses the private storage data plane, arrange approved private routing and DNS first. Use the self-hosted pipelines for platform Terraform runs rather than assuming local backend access will work.

## 6. Configure Saudi Arabia East and scenario-specific settings

In [config/platform-landing-zone.tfvars](config/platform-landing-zone.tfvars#L21), the following settings are already applied to the source and local test copy. When starting from a newly generated scenario, replace the region placeholder and add the short-name map at the top level, outside `custom_replacements`:

```hcl
starter_locations = ["saudiarabiaeast"]
starter_locations_short = {
  starter_location_01_short = "sae"
}
```

Inside the existing `custom_replacements.names` map, the Defender security-contact value is retained for a future re-enable. It is not consumed by an active Defender configuration assignment while Defender is disabled below. Before re-enabling Defender, replace it:

```hcl
defender_email_security_contact = "<security-contact-email-address>"
```

Do not replace the entire file with these short snippets. Preserve the remaining scenario configuration and the `$${...}` replacement tokens; the accelerator resolves them during generation.

### Policy assignment location

Following the successful regional identity test below, policy assignments with managed identities are configured to use the primary landing-zone region, Saudi Arabia East. Keep bootstrap resources in UAE North because the ACR constraint is separate.

The source and local test configuration both use `location = "$${starter_location_01}"` in `management_group_settings`. The steps below show how to apply the same change to a configuration that still uses `uaenorth`.

1. Open [config/platform-landing-zone.tfvars](config/platform-landing-zone.tfvars).
2. Find the top-level `management_group_settings` block. Do not change the separate `management_resource_settings.location` setting.
3. Inside `management_group_settings`, replace:

   ```hcl
   location = "uaenorth"
   ```

   with:

   ```hcl
   # location = "uaenorth"
   location = "$${starter_location_01}"
   ```

   The beginning of the existing block should now look like this; retain all its other settings:

   ```hcl
   management_group_settings = {
     architecture_name  = "alz_custom"
     # location = "uaenorth"
     location           = "$${starter_location_01}"
     parent_resource_id = "$${root_parent_management_group_id}"
     # Keep the existing policy defaults, subscription placements, and overrides.
   }
   ```

4. Set `starter_locations = ["saudiarabiaeast"]`, as described above, so `$${starter_location_01}` resolves to Saudi Arabia East. Keep `bootstrap_location: "uaenorth"` in the bootstrap inputs. Leave `policy_default_values.resource_group_location` and `private_dns_zone_region` referencing the primary landing-zone region; those control different aspects of the deployed resources.
5. Save the file. From the Terraform workspace root, check its syntax without rewriting it:

   ```powershell
   terraform fmt -write=false ".\devops\accelerator-8\config\platform-landing-zone.tfvars"
   ```

   Run this check after applying the configuration change. It is not a Terraform plan or proof that Azure will accept the full deployment.
6. Deliver the change through the appropriate path:
   - **Before bootstrap:** use the saved local configuration when running `Deploy-Accelerator` in step 8.
   - **After bootstrap:** make the equivalent change in the generated Azure DevOps repository's platform configuration, submit a pull request, and run its validation pipeline. Editing this local source alone does not update that repository.
7. Run the continuous-delivery pipeline described in step 9 and review the plan. Confirm policy assignments with managed identities and enabled regional platform resources target `saudiarabiaeast`, while bootstrap resources remain in `uaenorth`. For an existing deployment, inspect any assignment replacement and associated identity/role-assignment changes before approving.
8. After approval and successful apply, verify the affected assignment locations and managed identities in Azure, then check policy evaluation and remediation behavior.

**Scope:** This setting does not move the resources those policies configure or change their deployment-location parameters. Disabling Log Analytics is a separate configuration change, documented below. No landing-zone deployment was run as part of this documentation update.

#### Regional managed-identity test: 19 November 2026

A separate, isolated Azure CLI test **successfully created and read back a policy assignment with `location: saudiarabiaeast` and a `SystemAssigned` identity with a nonempty `principalId`** in the approved test subscription.

1. Created a temporary resource group in `uaenorth`; the assignment's location, not the resource group's location, was the regional setting under test.
2. Used the built-in Allowed locations policy with its effect `Disabled` and assignment enforcement `DoNotEnforce`. No identity role assignments were granted.
3. The Azure CLI 2.93.0 `az policy assignment create` attempt failed during built-in policy resolution, before testing regional identity creation. Retried successfully with Azure CLI `az rest`, issuing a policy-assignment PUT using API version `2024-04-01`.
4. Read the assignment back through ARM and verified the Saudi location and system-assigned principal.
5. Deleted both temporary test resource groups and verified they no longer existed.

This confirms regional policy-assignment identity creation at **resource-group scope in the tested subscription**. It supports trying Saudi Arabia East for the landing-zone assignments, but does not validate management-group scope, remediation, identity permissions, all landing-zone policies, or other services' regional availability. Follow the configuration-update steps above and review the full plan; the test itself did not change the landing-zone configuration.

### Disable Log Analytics and its dependent policies

The following changes are already applied to the local scenario configuration. Starter `v17.7.0` has no workspace-only deployment switch: disabling its management-resources module also prevents creation of that module's resource group, AMA managed identity, data collection rules, and workspace-related solutions/onboarding. Management groups, subscription placement, networking, and bootstrap state storage remain enabled.

1. In [config/platform-landing-zone.tfvars](config/platform-landing-zone.tfvars), set:

   ```hcl
   management_resources_enabled = false
   ```

   Keep `management_groups_enabled = true`. After applying the policy-location update above, use `management_group_settings.location = "$${starter_location_01}"` with `starter_locations = ["saudiarabiaeast"]`. The existing `management_resource_settings` and custom resource-name/ID replacements are retained as inactive configuration for a future re-enable; they do not deploy the disabled module.
2. In `management_group_settings.policy_default_values`, comment out these six defaults so active assignments no longer receive IDs for the disabled monitoring resources. Retain the original values as comments rather than deleting them:

   - `log_analytics_workspace_id`
   - `ama_change_tracking_data_collection_rule_id`
   - `ama_mdfc_sql_data_collection_rule_id`
   - `ama_vm_insights_data_collection_rule_id`
   - `ama_user_assigned_managed_identity_id`
   - `ama_user_assigned_managed_identity_name`

   The checked-in values are already commented out:

   ```hcl
   # ama_change_tracking_data_collection_rule_id = "$${ama_change_tracking_data_collection_rule_id}"
   # ama_mdfc_sql_data_collection_rule_id        = "$${ama_mdfc_sql_data_collection_rule_id}"
   # ama_vm_insights_data_collection_rule_id     = "$${ama_vm_insights_data_collection_rule_id}"
   # ama_user_assigned_managed_identity_id       = "$${ama_user_assigned_managed_identity_id}"
   # ama_user_assigned_managed_identity_name     = "$${ama_user_assigned_managed_identity_name}"
   # log_analytics_workspace_id                  = "$${log_analytics_workspace_id}"
   ```

   Keep the explicit `policy_assignments_to_remove` entries below active: commenting out those removal entries would re-enable the unwanted policies. Merge each YAML list with the other removals in that same file; do not overwrite Defender or DDoS entries when following this subsection alone.

3. In [root_custom.alz_archetype_override.yaml](config/lib/archetype_definitions/root_custom.alz_archetype_override.yaml), add the following to `policy_assignments_to_remove`:

   ```yaml
   policy_assignments_to_remove: [
     Deploy-AzActivity-Log,
     Deploy-Diag-LogsCat,
   ]
   ```

   This removes automatic Activity Log and resource diagnostic-log forwarding to the central workspace.
4. In [platform_custom.alz_archetype_override.yaml](config/lib/archetype_definitions/platform_custom.alz_archetype_override.yaml), enable the existing AMA removal entries:

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

5. In [landing_zones_custom.alz_archetype_override.yaml](config/lib/archetype_definitions/landing_zones_custom.alz_archetype_override.yaml), enable the same seven AMA deployment removals and additionally remove SQL auditing to the workspace:

   ```yaml
   policy_assignments_to_remove: [
     Deploy-AzSqlDb-Auditing,
     Deploy-MDFC-DefSQL-AMA,
     Deploy-VM-ChangeTrack,
     Deploy-VM-Monitoring,
     Deploy-vmArc-ChangeTrack,
     Deploy-vmHybr-Monitoring,
     Deploy-VMSS-ChangeTrack,
     Deploy-VMSS-Monitoring,
   ]
   ```

   The separate DDoS customization below also adds `Enable-DDoS-VNET` to this removal list.
6. With Defender disabled as described below, `Deploy-MDFC-Config-H224` is excluded and its previous configuration is retained as comments. There is no active Defender export to the disabled workspace. If later re-enabling that assignment while keeping Log Analytics off, its retained configuration uses `parameters.logAnalytics = ""` and the following targeted override:

   ```hcl
   overrides = [
     {
       kind  = "policyEffect"
       value = "disabled"
       selectors = [
         {
           kind = "policyDefinitionReferenceId"
           in   = ["ascExport", "defenderforKubernetes"]
         }
       ]
     }
   ]
   ```

   These reference IDs come from ALZ library `platform/alz/2026.11.0`. This retained, currently commented-out override disables Defender's continuous export to Log Analytics and the legacy Kubernetes Defender control that takes a workspace ID. Review it before any future re-enable; an empty workspace parameter is not an alternative logging destination.
7. Save the Terraform variables and all three library overrides. Check Terraform syntax with the command in the preceding section. Local Terraform expression checks and YAML parsing passed; removal names and monitoring dependencies were also checked against the pinned ALZ library. These checks do not replace a live Terraform plan. Include the complete updated library with `-starterAdditionalFiles` during bootstrap. For an already-bootstrapped environment, submit these equivalent changes together in the generated Azure DevOps repository.
8. Run the validation and delivery pipelines. Before approving, confirm the plan has no management-module workspace, DCR, or AMA identity creation and the listed assignments are absent, including the separately disabled Defender configuration assignment. Confirm networking and unrelated policy assignments remain configured.
9. After apply, verify the policy assignments/overrides in Azure and run another plan to check for unexpected drift.

> **Existing deployment warning:** Disabling the module can plan deletion of an existing workspace, its data collection rules, identity, and resource group. Review data retention/export needs, deletion protection, resources sharing that group, and existing monitoring dependencies before approving. Removing policies does not automatically remove diagnostic settings, agents, DCR associations, or Defender export automations that policies previously deployed. Inventory and explicitly retire or redirect those separately; do not assume policy removal cleans them up.

This design no longer supplies centralized Log Analytics collection, VM Insights, AMA change tracking, or the removed SQL audit destination. Retained security-benchmark audit policies can still report missing logging as noncompliance; they are not removed wholesale. Obtain the required monitoring/compliance approval and provide an alternative observability design before production use.

### Disable the DDoS Network Protection plan

The following changes are already applied locally. They disable the enhanced DDoS Network Protection plan, not Azure's baseline infrastructure-level DDoS protection.

1. In [config/platform-landing-zone.tfvars](config/platform-landing-zone.tfvars), under `custom_replacements.names`, set:

   ```hcl
   ddos_protection_plan_enabled = false
   ```

   The existing `connectivity_resource_groups.ddos.settings.enabled` and `hub_and_spoke_networks_settings.enabled_resources.ddos_protection_plan` reference this value, disabling both the dedicated DDoS resource group and plan. Keep the existing names and plan configuration for future re-enablement; the flag gates their deployment.
2. In `management_group_settings.policy_default_values`, comment out the plan ID rather than deleting it:

   ```hcl
   # ddos_protection_plan_id = "$${ddos_protection_plan_id}"
   ```

3. In both [landing_zones_custom.alz_archetype_override.yaml](config/lib/archetype_definitions/landing_zones_custom.alz_archetype_override.yaml) and [connectivity_custom.alz_archetype_override.yaml](config/lib/archetype_definitions/connectivity_custom.alz_archetype_override.yaml), uncomment `Enable-DDoS-VNET` in `policy_assignments_to_remove`. Preserve all existing monitoring-policy removals. Keep this removal directive active so policy does not try to attach VNets to a disabled plan.
4. Save the Terraform variables and both library overrides, then run the Terraform formatting/syntax check. Include the updated library during bootstrap, or submit the equivalent changes together through a pull request in the generated Azure DevOps repository if already bootstrapped.
5. Review the delivery pipeline plan before approving: no DDoS plan or dedicated DDoS resource group should be created, and `Enable-DDoS-VNET` should be absent at both management-group scopes. Review any existing VNet-plan associations and planned plan/resource-group deletion before applying.
6. After apply, verify the plan and its auto-enablement assignments are absent and run another plan to check for drift.

> Disabling the plan removes its enhanced protection benefits. Approve an alternative protection strategy for public-facing workloads, such as separately configured DDoS IP Protection where appropriate. This change does not enable that alternative automatically. Existing policy-created VNet associations are not necessarily removed by deleting a policy assignment; reconcile them before deleting a plan.

#### Alternative: enable DDoS and retain VPN Gateway, as in the local test

This alternative is already applied to the isolated local test, **not** to the source scenario. To select it in another copy, change these entries inside the existing `custom_replacements.names` map:

```hcl
ddos_protection_plan_enabled                 = true
primary_virtual_network_gateway_vpn_enabled = true
```

Uncomment the existing plan default inside `management_group_settings.policy_default_values`:

```hcl
ddos_protection_plan_id = "$${ddos_protection_plan_id}"
```

Remove `Enable-DDoS-VNET` from `policy_assignments_to_remove` in both the [connectivity override](config/lib/archetype_definitions/connectivity_custom.alz_archetype_override.yaml) and [landing-zones override](config/lib/archetype_definitions/landing_zones_custom.alz_archetype_override.yaml). Leave all monitoring and Defender removals intact. The connectivity removal list is then `policy_assignments_to_remove: []`. The existing DDoS resource-group/plan flags and VPN gateway configuration already reference these settings; do not add duplicate gateway blocks.

A read-only check on 19 November 2026 confirmed that the local test's connectivity subscription advertises Saudi Arabia East for `Microsoft.Network/ddosProtectionPlans`, with no existing Saudi plan found. A different subscription did not advertise it. Recheck the actual target rather than assuming tenant-wide availability:

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

Provider metadata is not proof of a successful deployment or VPN SKU capacity. Review the pipeline plan for the DDoS resource group, plan, auto-enablement assignments, and VPN gateway. After apply, verify actual VNet-plan associations and any required remediation. VPN connections, an on-premises device, and an ExpressRoute circuit remain separate work.

### Disable Defender deployment and enablement policies

The local configuration now prevents this scenario from automatically enabling Defender plans, SQL threat protection, and Defender for Endpoint deployment/integration. Existing Defender subscriptions and agents are not switched off by removing policy assignments.

1. In [root_custom.alz_archetype_override.yaml](config/lib/archetype_definitions/root_custom.alz_archetype_override.yaml), add the following to the existing `policy_assignments_to_remove` list, preserving the logging-policy removals:

   ```yaml
   Deploy-MDFC-Config-H224,
   Deploy-MDFC-OssDb,
   Deploy-MDFC-SqlAtp,
   Deploy-MDEndpoints,
   Deploy-MDEndpointsAMA,
   ```

   This excludes the main Defender configuration initiative, database-plan enablement, endpoint-agent deployment, and endpoint integration settings. The main initiative also contains the Defender security-contact and export configuration, so those are no longer deployed through it.
2. In [landing_zones_custom.alz_archetype_override.yaml](config/lib/archetype_definitions/landing_zones_custom.alz_archetype_override.yaml), add `Deploy-SQL-Threat` to the removal list. Keep the existing `Deploy-MDFC-DefSQL-AMA` removals at both the landing-zones and platform scopes.
3. In [config/platform-landing-zone.tfvars](config/platform-landing-zone.tfvars), comment out the entire `Deploy-MDFC-Config-H224` entry under `management_group_settings.policy_assignments_to_modify.alz.policy_assignments`. Retain its former plan parameters and Log Analytics overrides as comments rather than deleting them. An active modification must not target an excluded assignment.
4. Comment out `resource_group_name_mdfc` and `email_security_contact` in `management_group_settings.policy_default_values`. Keep `resource_group_location` active because the independent service-health policy still uses it.
5. In `management_group_settings.policy_assignments_to_modify`, configure the following parameters as `"Disabled"` under **both** `platform.policy_assignments` and `landingzones.policy_assignments`:

   | Assignment | Parameter |
   | --- | --- |
   | `Enforce-GR-MySQL0` | `mySqlAdvThreatProtection` |
   | `Enforce-GR-PostgreSQL0` | `postgreSqlAdvThreatProtection` |
   | `Enforce-GR-Storage0` | `storageThreatProtection` |
   | `Enforce-GR-Synapse0` | `synapseDefender` |
   | `Enforce-GR-SQL0` | `sqlManagedDefender` |

   For `Enforce-GR-SQL0` at both scopes, also add a `policyEffect` override of `"disabled"` selecting `policyDefinitionReferenceId` `"Dine-Sql-Adv-Data"`. The ALZ provider requires this override effect in lowercase; keep the policy parameters in the table as `"Disabled"` because their values are defined separately by the initiatives. That member enables SQL Advanced Data Security without an exposed effect parameter. These assignments are `DoNotEnforce` in the pinned library; the explicit Defender settings also protect against accidental enablement if their enforcement mode is changed later. Other guardrail parameters and enforcement modes are not changed.

   For a copyable example, merge these five entries into **each** existing `policy_assignments` map under `platform` and `landingzones`. The source already has both copies. Do not replace the outer `policy_assignments_to_modify` map or remove its `corp` DNS and `alz` entries:

   ```hcl
   Enforce-GR-MySQL0 = {
     parameters = {
       mySqlAdvThreatProtection = "Disabled"
     }
   }
   Enforce-GR-PostgreSQL0 = {
     parameters = {
       postgreSqlAdvThreatProtection = "Disabled"
     }
   }
   Enforce-GR-Storage0 = {
     parameters = {
       storageThreatProtection = "Disabled"
     }
   }
   Enforce-GR-Synapse0 = {
     parameters = {
       synapseDefender = "Disabled"
     }
   }
   Enforce-GR-SQL0 = {
     parameters = {
       sqlManagedDefender = "Disabled"
     }
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
   }
   ```

6. Save the variables and library overrides together. Run Terraform formatting/syntax and YAML checks, then deliver them through bootstrap or a pull request in the already-generated Azure DevOps repository as appropriate. Local Terraform evaluation, YAML parsing, and assignment/parameter/reference checks against the pinned library passed for this change; no live plan or deployment was run.
7. Review the pipeline plan: the excluded assignments must be absent, the five guardrail Defender parameters must be disabled at both scopes, and each SQL guardrail must have the targeted disabled override. Retain management groups, service-health alerting, unrelated security guardrails/benchmark auditing, and connectivity.
8. After apply, verify assignments and overrides in Azure and run another plan to check for drift.

> **Existing deployment and billing:** Policy removal or a policy effect of `Disabled` does not set an existing Defender pricing tier to `Free`, uninstall endpoint agents, remove existing integrations, or cancel charges. If Defender is already enabled, separately inventory its subscription/resource-level plans and protections, obtain approval, and explicitly turn those off through the supported Defender controls. Check inherited policies and external automation that could re-enable them. No such live changes are performed by this local configuration update.

Disabling Defender reduces threat detection and protection. Obtain the required security approval before production use. Microsoft Cloud Security Benchmark assignments and unrelated audit policies remain; they may report missing Defender coverage.

### Saudi DNS region short name and policy assignment

The source [platform configuration](config/platform-landing-zone.tfvars#L221) and local test copy both set the Saudi starter short name and modify the Corp DNS assignment. Inside the **existing** `management_group_settings.policy_assignments_to_modify` map, merge this complete `corp` entry alongside `alz`, `platform`, and `landingzones`; do not create a second top-level map:

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

Keep these existing values inside `management_group_settings.policy_default_values`. They select the central zone subscription/resource group and pass the **full** Azure region name to the policy:

```hcl
private_dns_zone_subscription_id     = "$${subscription_id_connectivity}"
private_dns_zone_region              = "$${starter_location_01}"
private_dns_zone_resource_group_name = "$${dns_resource_group_name}"
```

Do not set `private_dns_zone_region` to `sae`: the policy indexes the region map with `saudiarabiaeast`. Likewise, `starter_location_01_short` is a starter replacement override, not a way to modify a nested module's internal region metadata.

`dnzZoneRegionShortNames` is the exact object parameter name in ALZ library `platform/alz/2026.11.0`. This value replaces the entire default region map; extend it before selecting another private DNS region. The assignment is inherited through `corp_custom` from `corp` and is not removed by the local override. If the Corp management-group ID is renamed in the custom architecture, update the `corp` modification key too. Existing Defender assignment modifications are preserved.

The `sae` value is the confirmed Azure Backup DNS code for Saudi Arabia East (`privatelink.sae.backup.windowsazure.com`). The public region-code document does not list it, so it was confirmed against the service rather than that document.

**Separate deployment blocker:** These overrides do not populate the internal `geo_code` used by private DNS module `0.23.2`. Its regions dependency `0.12.0` has no Saudi entry, and its unconditional `replace` call rejects a null region code, even for zone names without `{regionCode}`. Apply the [post-bootstrap fix](#post-bootstrap-saudi-dns-module-fix) before deploying the private-link zones; changing only the policy map, starter short name, or Backup zone name does not resolve that Terraform error. The auto-registration zone remains `saudiarabiaeast.azure.local`.

The DNS overrides are now present in both copies, but future edits are not synchronized automatically. Run the generated repository's validation and Terraform plan before deployment.

### Post-bootstrap Saudi DNS module fix

**Chosen approach:** Keep bootstrap unchanged, then make the fix in the generated platform repository. For a single deployment, committing local copies of the two affected modules is simpler than maintaining two remote forks. The committed copies make the fix reproducible on clean pipeline agents; never patch files under `.terraform`.

This section is an implementation runbook, not confirmation that the generated repository has been patched or that a deployment plan has passed.

Apply this temporary workaround manually after bootstrap. The [end-of-guide checklist](#additional-steps-after-bootstrap) summarizes the required edits and validation. When the expected upstream fix becomes available, verify it before removing this customization.

1. Complete [bootstrap](#8-deploy-the-bootstrap). If it has already completed, do not rerun it just for this error. Keep platform apply blocked while preparing the fix. If a delivery pipeline starts automatically, do not approve its apply stage.
2. Open your own clone of the **generated platform repository** and create a normal change branch using your preferred Git client. Locate the Terraform root containing `main.connectivity.hub.and.spoke.virtual.network.tf` and `platform-landing-zone.auto.tfvars`. For the local checkout discussed here, that root is `D:\workarea\Source\alz\alz-mgmt`. All paths below are relative to that root, not this source scenario folder or the pipeline-template repository.
3. Confirm the generated module versions match this runbook: starter `v17.7.0`, hub-and-spoke `0.17.2`, private DNS `0.23.2`. If they differ, inspect the new dependency chain before applying this version-specific fix. Choose one of these manual preparation methods:

   **Recommended: use the prepared module ZIP**

   [saudi-dns-modules.zip](saudi-dns-modules.zip) contains the two customized module folders copied unchanged from `D:\workarea\Source\alz\alz-mgmt\modules` on 19 November 2026. All 48 archived files were checked byte-for-byte against that checkout. This verifies the package contents, not a successful Azure deployment.

   - In your clone of this documentation repository, open `devops\accelerator-8` in File Explorer and locate `saudi-dns-modules.zip`. If viewing this guide on GitHub, open the ZIP link and select **Download raw file**.
   - Right-click the ZIP, select **Extract All**, and choose a temporary location outside the generated platform repository.
   - Open the extracted folder. You should see `hub-and-spoke-vnet` and `private-link-private-dns-zones` directly inside it.
   - Copy those **two folders** into the generated platform repository's existing `modules` folder. For the checkout discussed here, that is `D:\workarea\Source\alz\alz-mgmt\modules`. Preserve its existing `config-templating` folder. If either destination module folder already exists, compare it first rather than blindly overwriting another customization.
   - The ZIP includes Terraform files, required nested module files, and both licenses. It excludes configuration variables, credentials, state, plans, Git metadata, and provider caches.
   - The nested DNS source change in step 5 and the Saudi lookup change in step 6 are **already included**. Verify those edits rather than applying them again. You must still perform the root source change in step 4, which is deliberately not included in this module-only archive.

   **Alternative: prepare the same files from upstream ZIPs**

   **Download the two ZIP files**

   - Open the [hub-and-spoke v0.17.2 page](https://github.com/Azure/terraform-azurerm-avm-ptn-alz-connectivity-hub-and-spoke-vnet/tree/v0.17.2). Confirm the selected tag is `v0.17.2`, click **Code > Download ZIP**, and save it outside your platform repository. Alternatively, use the [v0.17.2 ZIP download](https://github.com/Azure/terraform-azurerm-avm-ptn-alz-connectivity-hub-and-spoke-vnet/archive/refs/tags/v0.17.2.zip).
   - Repeat for the [private DNS v0.23.2 page](https://github.com/Azure/terraform-azurerm-avm-ptn-network-private-link-private-dns-zones/tree/v0.23.2), selecting tag `v0.23.2`, or use the [v0.23.2 ZIP download](https://github.com/Azure/terraform-azurerm-avm-ptn-network-private-link-private-dns-zones/archive/refs/tags/v0.23.2.zip).
   - In Windows File Explorer, right-click each ZIP and select **Extract All**. Open the extracted folder until you can see `main.tf`, `locals.tf`, and `LICENSE`. Do not copy the enclosing archive-name folder into the repository.

   **Copy only the required module files**

   In your generated repository's existing `modules` folder, create the two folders below. Do not replace the existing `modules` folder or remove its `config-templating` subfolder.

   | Extracted package | Destination relative to the generated Terraform root | Files to copy |
   | --- | --- | --- |
   | Hub-and-spoke `v0.17.2` | `modules\hub-and-spoke-vnet` | All root-level files ending in `.tf`, plus `LICENSE`. |
   | Same hub-and-spoke package, `modules\hub-virtual-network-mesh` | `modules\hub-and-spoke-vnet\modules\hub-virtual-network-mesh` | All `.tf` files from this subfolder, preserving their names. |
   | Same hub-and-spoke package, `modules\virtual-network-gateway` | `modules\hub-and-spoke-vnet\modules\virtual-network-gateway` | All `.tf` files from this subfolder, preserving their names. |
   | Private DNS `v0.23.2` | `modules\private-link-private-dns-zones` | All root-level `.tf` files, plus `LICENSE`. No nested module Terraform files are required for this version. |

   Copying only the three files that will be edited is **not enough**: the other Terraform files define the modules' variables, outputs, resources, and provider requirements. Include `main.telemetry.tf`, `terraform.tf`, moved blocks, and every other `.tf` file in the locations listed above. Files such as `avm.tflint.override.hcl` do not end in `.tf` and are not needed. Do not copy `.git`, `.github`, `.terraform`, examples, tests, or downloaded state/plan files.

   Check these example paths in File Explorer before continuing:

   - `D:\workarea\Source\alz\alz-mgmt\modules\hub-and-spoke-vnet\main.tf`
   - `D:\workarea\Source\alz\alz-mgmt\modules\hub-and-spoke-vnet\modules\hub-virtual-network-mesh\main.tf`
   - `D:\workarea\Source\alz\alz-mgmt\modules\hub-and-spoke-vnet\modules\virtual-network-gateway\main.tf`
   - `D:\workarea\Source\alz\alz-mgmt\modules\private-link-private-dns-zones\locals.tf`

   There must not be another archive-name folder between these directory names and their `.tf` files. Record the two source tags in the change description.

4. In the generated root's `main.connectivity.hub.and.spoke.virtual.network.tf`, change only the `source` of the existing `module "hub_and_spoke_vnet"` to:

   ```hcl
   source = "./modules/hub-and-spoke-vnet"
   ```

   Remove that module call's `version = "0.17.2"` argument: local module sources do not accept `version`. Preserve the module name, `count`, arguments, and provider mappings.

5. In `modules/hub-and-spoke-vnet/main.tf`, change only the `source` of the existing `module "private_dns_zones"` to the following, or verify it if using the prepared ZIP:

   ```hcl
   source = "../private-link-private-dns-zones"
   ```

   Remove that call's `version = "0.23.2"` argument. Preserve its name, `for_each`, and arguments. These HCL source addresses use Terraform's slash notation even on Windows.

6. `sae` is the confirmed Azure Backup DNS code for Saudi Arabia East (`privatelink.sae.backup.windowsazure.com`), so no further confirmation is needed. In `modules/private-link-private-dns-zones/locals.tf`, replace only the first region-lookup `locals` block with the following, or verify the equivalent lookup already included in the prepared ZIP:

   ```hcl
   locals {
     location_name = module.regions.regions_by_name_or_display_name[var.location].name
     location_geo_code = local.location_name == "saudiarabiaeast" ? (
       "sae"
     ) : module.regions.regions_by_name_or_display_name[var.location].geo_code
   }
   ```

   This explicitly supplies the Saudi code and leaves all other regions' lookups unchanged. Keep every subsequent locals block intact. Do not substitute UAE North, use an empty-string fallback, or disable private DNS to bypass the error.

7. Check the generated `platform-landing-zone.auto.tfvars`, not just the source inputs:
   - Retain `starter_locations = ["saudiarabiaeast"]` and `starter_locations_short.starter_location_01_short = "sae"`.
   - Retain the `corp` DNS policy modification with `dnzZoneRegionShortNames = { saudiarabiaeast = "sae" }`, alongside the existing modifications for other scopes. Keep the policy's full DNS region as `saudiarabiaeast`.
   - At both `platform` and `landingzones`, the SQL `policyEffect` override must use `value = "disabled"`. Keep initiative parameters such as `sqlManagedDefender = "Disabled"` unchanged.

8. Format the changed Terraform files and generated variables using `terraform fmt`, then commit the module copies, source-reference changes, and any corrected generated variables to the generated repository. Preserve module block names and instance keys so changing source locations alone does not change resource addresses. No state move or import is expected solely for this source change.
9. Run CI and the delivery plan from a clean checkout using the normal pipeline identity/backend. Module source changes require `terraform init` before `terraform validate` and plan; keep the existing provider lock file and do not add `-upgrade` for this fix. Do not use this source scenario directory as a Terraform root.
10. Before approving apply, confirm:
    - The null `replace` error and both SQL override validation errors are absent.
    - The Backup zone is `privatelink.sae.backup.windowsazure.com`, and the Corp policy constructs the same zone resource ID.
    - Auto-registration remains `saudiarabiaeast.azure.local`; private zones and intended VNet links remain enabled.
    - No unexpected resource deletion, replacement, or address change is planned.

Changing the two sources preserves addresses, but existing deployments still require plan review. Keep the generated-repository customization under version control: regeneration or a future bootstrap/template upgrade may overwrite its source references. Recheck it after upgrades. When a verified upstream release resolves Saudi metadata, switch back through a reviewed change and repeat the same plan checks before removing the local copies.

#### Verify the fix and troubleshoot

**Reference implementation:** the `alz-mgmt` repository, branch `add-arm-provider-enhanced-validation`, commit `18a2d16`, contains the finished change. A colleague can compare their generated repository against it or copy `modules/hub-and-spoke-vnet` and `modules/private-link-private-dns-zones` from it, then make only the root source edit in step 4 if it is not already present.

Quick checks from the Terraform root before pushing:

```powershell
# 1. The three edits are present
Select-String -Path main.connectivity.hub.and.spoke.virtual.network.tf -Pattern 'source\s*=\s*"\./modules/hub-and-spoke-vnet"'
Select-String -Path modules\hub-and-spoke-vnet\main.tf -Pattern 'source\s*=\s*"\.\./private-link-private-dns-zones"'
Select-String -Path modules\private-link-private-dns-zones\locals.tf -Pattern 'saudiarabiaeast'

# 2. No stale registry source or version remains for either module
Select-String -Path main.connectivity.hub.and.spoke.virtual.network.tf, modules\hub-and-spoke-vnet\main.tf -Pattern 'avm-ptn-alz-connectivity|avm-ptn-network-private-link|version\s*=\s*"0\.(17|23)'

# 3. Format, re-initialize modules, validate
terraform fmt -check -recursive modules main.connectivity.hub.and.spoke.virtual.network.tf
terraform init -backend=false -input=false
terraform validate
```

Check 1 must return all three lines and check 2 must return nothing for the changed module blocks. Local validation does not replace the delivery pipeline plan. In that plan, both the `replace` null error and the SQL override error must be gone; the Backup zone must be `privatelink.sae.backup.windowsazure.com`; and no DNS zone, VNet link, or auto-registration zone may be replaced or deleted.

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| `Invalid value for "replace" parameter: argument must not be null` still appears | The pipeline still downloads the registry modules, or the `locals.tf` edit is missing | Confirm checks 1 and 2 above, and that the changes are committed to the branch the pipeline runs |
| `Module not installed` or `module source has changed` | Source changed without re-initialization | Run `terraform init`; the pipeline does this automatically |
| `Unexpected attribute: "version"` on a module | A local module source still has `version` | Remove the `version` argument from that module call |
| Plan wants to destroy and recreate DNS zones or links | Module block names or `for_each` keys were changed | Restore the original names and keys; do not approve apply |
| `Invalid Attribute Value Match ... got: "Disabled"` | SQL `policyEffect` override uses a capital `D` | Use lowercase `disabled` for override values; keep `"Disabled"` for policy parameters |
| Backup zone name is wrong for another region | The conditional was widened | Keep the `saudiarabiaeast` test; other regions must keep the upstream lookup |

### Disable Azure Private DNS Resolver

The Saudi hub's Azure Private DNS Resolver is disabled locally. Private DNS zones, auto-registration, zone links, and bootstrap private-endpoint DNS remain enabled.

1. In [config/platform-landing-zone.tfvars](config/platform-landing-zone.tfvars), under `custom_replacements.names`, set:

   ```hcl
   primary_private_dns_resolver_enabled = false
   ```

2. Keep `hub_virtual_networks.primary.enabled_resources.private_dns_resolver` referencing `$${primary_private_dns_resolver_enabled}`. This flag gates resolver deployment. Retain the resolver name, subnet-prefix replacement, and existing `private_dns_resolver` settings for future re-enablement; do not delete them.
3. Keep `primary_private_dns_zones_enabled` and `primary_private_dns_auto_registration_zone_enabled` set to `true`. Do not exclude `Deploy-Private-DNS-Zones` or disable bootstrap private networking as part of this resolver-only change.

   Together, the relevant entries in `custom_replacements.names` should remain:

   ```hcl
   primary_private_dns_zones_enabled                  = true
   primary_private_dns_auto_registration_zone_enabled = true
   primary_private_dns_resolver_enabled               = false
   ```

4. Arrange an alternative DNS design for clients that require forwarded resolution. An NVA or an on-premises DNS server cannot forward queries to a resolver inbound endpoint that is no longer deployed. Use an approved DNS forwarder with access to the relevant linked zones, or another supported design. Azure-provided DNS can still resolve linked private zones for clients using it in the linked VNet; this is not automatically an on-premises forwarding solution.
5. Save and run the Terraform formatting/syntax check. For a new environment, use the updated source at bootstrap; for an already-bootstrapped environment, submit the equivalent change in the generated Azure DevOps repository and run validation/delivery.
6. Review the plan before applying: no Private DNS Resolver or its endpoints should be created. For an existing deployment, review resolver, endpoint, and dedicated subnet deletion/replacement and update dependent forwarding rules before approval. Confirm private DNS zones and bootstrap DNS resources are not removed.
7. After apply, verify private-endpoint name resolution from pipeline agents and representative workload/on-premises clients using the approved replacement DNS path, then run another plan to check for drift.

This local change does not deploy a replacement DNS server or alter existing clients' DNS settings automatically.

### Review the default Saudi hub addressing

The existing scenario contains:

| Setting | Default |
| --- | --- |
| Regional routing address space | `10.0.0.0/16` |
| Hub VNet | `10.0.0.0/22` |
| NVA subnet | `10.0.0.0/26` |
| NVA next-hop address | `10.0.0.4` |
| Bastion subnet | `10.0.0.64/26` |
| Gateway subnet | `10.0.0.128/27` |
| Private DNS Resolver subnet prefix (retained; resolver disabled) | `10.0.0.160/28` |

If these overlap your estate, update the related `primary_*` address replacements together. Keep the NVA next-hop address aligned with the actual appliance address.

### Review enabled services before planning

The checked-in configuration enables ExpressRoute and VPN gateways, Bastion, private DNS zones, and management groups with the remaining policies. Private DNS Resolver, DDoS Network Protection, the Log Analytics management-resources bundle, and automatic Defender enablement/deployment policies are disabled as described above. Azure Firewall is disabled because this is an NVA scenario.

Check Saudi Arabia East availability and subscription capacity for every enabled service and SKU. Region visibility alone does not prove that a service or SKU is deployable. If a service is unavailable, stop and agree an explicit design change; do not silently move it outside Saudi Arabia.

The NVA is a separate workstream:

1. Select a vendor and a Saudi-supported appliance image/SKU.
2. Deploy and license the appliance separately.
3. Configure IP forwarding, routing, security inspection, and DNS forwarding/proxy behavior using the approved alternative DNS path, not a disabled Private DNS Resolver endpoint.
4. Validate that the route-table next hop points to the working appliance.
5. Add and peer workload spokes as required.

Until that work is complete, routes targeting `10.0.0.4` do not provide a functioning NVA path.

### Preserve the custom library

The configuration references `architecture_name = "alz_custom"`. Keep [config/lib](config/lib/) and pass it to the accelerator in step 8 so its architecture and archetype overrides are included.

If customizing management group IDs or policies, keep the library definitions, subscription placements, and policy references consistent. Do not simply rename the architecture in the Terraform variables.

## 7. Sign in and complete preflight checks

```powershell
az login --tenant "<tenant-id>" --use-device-code
az account set --subscription "<management-subscription-id>"
az account show --query "{tenantId:tenantId,subscriptionId:id,name:name}" --output table

az account list-locations `
    --query "[?name=='saudiarabiaeast' || name=='uaenorth'].{Name:name,DisplayName:displayName}" `
    --output table
```

Repeat regional access checks in the other platform subscriptions as appropriate. Confirm service/SKU availability through the portal, the relevant service's regional/SKU documentation, and subscription-specific quota checks.

Before approving bootstrap, confirm:

- [ ] Four correct platform subscription IDs and the correct tenant.
- [ ] Parent management group exists and bootstrap permissions are active.
- [ ] UAE North bootstrap and cross-border state/agent processing are approved.
- [ ] Saudi Arabia East access and required regional services/SKUs are confirmed.
- [ ] Required resource providers are registered in each relevant subscription, including networking, storage, managed identities, container services, monitoring, and security providers as applicable.
- [ ] Bootstrap and hub IP ranges do not overlap existing or planned networks.
- [ ] Inherited policies allow the agreed regional split.
- [ ] Two PAT environment variables are set; YAML PAT entries remain commented out and no real PAT values are saved in the file.
- [ ] Azure DevOps permissions, self-hosted concurrency, and approver membership are ready.
- [ ] `starter_locations` is updated; the retained Defender contact must be reviewed before any future Defender re-enable.
- [ ] Policy-assignment identity location references the starter region in the configuration selected for deployment.
- [ ] The Saudi DNS policy map is present at `corp`, the full DNS region remains `saudiarabiaeast`, and the [post-bootstrap DNS fix](#post-bootstrap-saudi-dns-module-fix) is scheduled before platform deployment. A successful generated platform plan is an apply gate, not a prerequisite for creating the bootstrap foundation.
- [ ] Default gateways, Bastion, and agent infrastructure are approved for deployment and ongoing charges.
- [ ] Disabled Defender coverage is approved, with any existing plans/agents and ongoing billing assessed separately.
- [ ] An alternative DNS path is approved for clients that depended on Private DNS Resolver; private zones and bootstrap DNS remain enabled.
- [ ] The chosen DDoS configuration is explicit: source-disabled or test-style enabled. Availability, protection strategy, policy assignments, associations, and any planned deletions/replacements have been reviewed.
- [ ] Custom library files are preserved.
- [ ] Log Analytics resource/policy changes are included together, monitoring gaps are approved, and any planned deletion of existing monitoring resources has been reviewed.

## 8. Deploy the bootstrap

After completing the preflight checks, run the bootstrap from the same PowerShell terminal with the PAT environment variables set. Explicitly select the scenario folder:

```powershell
$targetFolderPath = "D:\workarea\Source\alz\terraform\devops\accelerator-8"

terraform fmt -check "$targetFolderPath\config\platform-landing-zone.tfvars"
if ($LASTEXITCODE -ne 0) {
    throw "Terraform formatting/syntax check failed. Correct the selected configuration before bootstrap."
}

Deploy-Accelerator `
    -inputs "$targetFolderPath\config\inputs.yaml", "$targetFolderPath\config\platform-landing-zone.tfvars" `
    -starterAdditionalFiles "$targetFolderPath\config\lib" `
    -output "$targetFolderPath\output"
```

The `-inputs` argument loads the bootstrap inputs and platform Terraform variables. `-starterAdditionalFiles` includes the customized ALZ library, and `-output` selects the bootstrap working/output directory. Keep these paths pointed at the same scenario folder.

For the existing isolated test copy, replace **only** the `$targetFolderPath` assignment above with the following before running the same check and bootstrap command. Do not run both configurations:

```powershell
$targetFolderPath = "D:\workarea\Source\alz\terraform\devops\accelerator-8\.local-tests\accelerator-8"
```

The formatting check parses the variables file; it does not validate ALZ policy parameters, initialize the generated modules, or resolve the DNS dependency blocker. In the generated platform Terraform working directory, the validation pipeline must run `terraform init` and `terraform validate`, followed by the normal delivery plan. Do not run those commands against this source folder as if it were the generated root module.

Review the generated bootstrap plan before accepting the deployment prompt. In particular, check:

- Bootstrap resources are in `uaenorth`.
- The bootstrap VNet/subnets use the requested `10.250.0.*` ranges.
- Private endpoints and self-hosted agents are enabled.
- Subscription placement, identity permissions, and Azure DevOps changes match the intended scopes.
- No unexpected deletion or replacement is planned.

Bootstrap creates the delivery foundation: state storage, identities and federated service connections, agent image/registry and container agents, networking, repositories, pipelines, and approval configuration. Depending on the accelerator version it also prepares management-group/subscription placement. It is **not** the complete regional platform deployment; run the delivery pipeline next.

Protect the generated [output folder](output/) and any local state, plans, logs, or temporary files. Do not commit the entire bootstrap working directory or publish state as an unrestricted artifact. Keep recoverable bootstrap state in an approved protected location.

If bootstrap fails, inspect the specific failed resource and error, correct the configuration or permissions, and rerun with the same configuration/output and preserved state. Do not delete state or regenerate a different bootstrap to bypass a partial failure.

## 9. Verify the agents and run the landing-zone pipeline

In Azure DevOps:

1. Open the configured project.
2. Under **Project settings > Agent pools**, verify the generated self-hosted pool is available and the agents are online.
3. Inspect the generated repositories, including the pipeline-template repository when created. Complete the [post-bootstrap Saudi DNS module fix](#post-bootstrap-saudi-dns-module-fix) in the platform repository and pass CI before running the delivery pipeline.
4. Verify the federated plan/apply service connections and apply-environment approvers.
5. Under **Pipelines**, open **02 Azure landing zone Continuous Delivery**.
6. Select **Run pipeline**, keep the intended default branch/settings, and run it.
7. If prompted, explicitly authorize the intended pipeline to use its generated service connections, agent pool, repositories, variable groups, and environments.
8. Review the Terraform plan and confirm regional platform resources target `saudiarabiaeast`. Non-regional resources such as management groups and global DNS zones will not have that regional location.
9. Have an authorized approver approve the apply stage.
10. Confirm apply completes successfully.

Do not approve a plan that unexpectedly deletes existing resources, changes subscription placement, or puts Saudi regional resources in UAE North. Investigate configuration and policy effects first.

## 10. Validate and operate

After the pipeline succeeds:

- Confirm the management-group hierarchy and all four subscription placements.
- Confirm Saudi regional management and connectivity resources are deployed in `saudiarabiaeast`.
- Confirm bootstrap resources remain in `uaenorth`.
- Confirm agents can read/write the private Terraform backend and pull their image without a workstation-IP storage exception.
- Verify registry/storage private endpoint approval, private DNS resolution, and network restrictions.
- Verify apply approvals remain enforced and service connections use the generated federated identities.
- Review policy compliance and any required remediation tasks; initial compliance evaluation can take time.
- Validate the separately deployed NVA, DNS forwarding, spoke peering, and end-to-end traffic flow before onboarding production workloads.
- Run a subsequent pipeline plan to check for unexpected drift.

For ongoing changes, edit the **generated Azure DevOps repository**, use pull requests and the generated validation pipeline, then deploy through the delivery pipeline. Do not assume editing the original local configuration automatically updates an already-bootstrapped repository.

After bootstrap, clear PATs from the administrative terminal:

```powershell
Remove-Item Env:\TF_VAR_azure_devops_personal_access_token
Remove-Item Env:\TF_VAR_azure_devops_agents_personal_access_token
```

Revoke the short-lived bootstrap PAT when no longer needed. Maintain an approved renewal and agent-recreation process for the registration PAT; clearing the local environment does not remove a token already supplied to deployed agent infrastructure.

### Troubleshooting

| Symptom | Checks / action |
| --- | --- |
| ACR deployment fails in Saudi Arabia East | Confirm bootstrap still uses `uaenorth`; `starter_locations` alone should use `saudiarabiaeast` in this design. |
| Region/service/SKU unavailable | Check subscription access, service rollout, quotas, and zone support. Resolve the specific blocker before applying. |
| ALZ `policyEffect` override rejects `"Disabled"` | Set the override's `value` to lowercase `"disabled"` at both `platform` and `landingzones`. Do not lowercase initiative parameters such as `sqlManagedDefender = "Disabled"` indiscriminately. |
| AzureRM says `saudiarabiaeast` is not a supported Azure Location | Follow the metadata-validation checks below. Do not silently relocate resources or assume an environment-variable workaround proves regional access. |
| ACI zone-related deployment error | Check UAE North support for the requested ACI configuration. If required and approved, set `agent_container_zone_support: false` in bootstrap inputs; assess the separate ACR `container_registry_zone_redundancy_enabled` setting against its support as well. |
| Agents offline or jobs remain queued | Check ACI provisioning/logs, image pull, PAT validity and pool permissions, DNS/egress, pipeline pool authorization, and self-hosted parallel-job capacity. |
| Backend access denied or timed out | Check identity data-plane roles, private endpoint approval, DNS, and routing from the actual execution host. Do not turn on public storage access as a shortcut. |
| Azure DevOps bootstrap returns 401/403 | Check PAT scopes, expiry, organization, underlying user permissions, and whether placeholder YAML PAT values were removed. |
| `alz_custom` architecture cannot be found | Confirm the complete library is present and `-starterAdditionalFiles` points to it. |
| `Invalid value for "replace" parameter: argument must not be null` in private DNS locals | Follow the [post-bootstrap Saudi DNS module fix](#post-bootstrap-saudi-dns-module-fix) in the generated platform repository. The starter short-name and policy-map overrides do not populate the nested module's `geo_code`. Do not edit the `.terraform` cache or rerun bootstrap just for this fix. |
| DNS policy fails to index `dnzZoneRegionShortNames` | Keep `private_dns_zone_region` as `saudiarabiaeast`, ensure the map contains that key, and extend the entire replacement map when using other DNS regions. Confirm the override targets the actual Corp management-group ID. |
| Editing the source does not affect a test run or existing pipeline | Check `$targetFolderPath`; local test configuration and generated Azure DevOps repositories are separate copies. Deliver related variables and library changes together to the copy actually being used. |
| Traffic follows an unreachable NVA next hop | Deploy/configure the appliance and reconcile its IP with `primary_nva_ip_address`; the scenario only prepares the NVA integration. |
| Allowed-location policy denies UAE resources | Obtain the approved bootstrap scope exception or permitted-location design; keep Saudi workload restrictions intact. |

#### AzureRM 4.x rejects the Saudi location before contacting the resource API

The starter constrains AzureRM to `~> 4.0`. In AzureRM 4.x, enhanced validation can reject a newly available region using its Azure metadata location list before a resource-group request reaches Azure. The reported error alone does not distinguish metadata lag from missing subscription access.

1. In the failing pipeline, check the selected AzureRM version in `.terraform.lock.hcl` or the `terraform init` output. Using the **same service-connection identity**, verify Saudi Arabia East is visible in each relevant subscription and that the required resource types/SKUs are available. A successful check using a workstation user's identity or another subscription is not sufficient.
2. If the region is authorized and this is a metadata-list limitation, add this **non-secret** variable to the existing Azure DevOps Library variable group imported by the generated CI and CD pipelines:

   | Variable | Value |
   | --- | --- |
   | `ARM_PROVIDER_ENHANCED_VALIDATION` | `false` |

   The generated templates import the group for validation, plan, and apply. Non-secret group variables are exposed to task environments. Alternatively, merge the following into the existing `env` map on each affected Terraform validation/plan/apply task in the generated templates repository:

   ```yaml
   env:
     ARM_PROVIDER_ENHANCED_VALIDATION: "false"
   ```

   Keep existing environment entries such as `TERRAFORM_ACTION`. Do not modify only the downloaded bootstrap cache: those edits do not update a running Azure DevOps pipeline.
3. This legacy setting is supported by AzureRM 4.x and disables its metadata-based enhanced checks, including resource-provider checks. It does **not** disable Azure Policy, authentication, RBAC, regional restrictions, quota checks, or Azure's validation of actual deployment requests. Use it as an explicit temporary exception, not evidence that deployment will succeed. With versions that support `ARM_PROVIDER_ENHANCED_VALIDATION_LOCATIONS`, prefer that location-only setting instead; do not combine it with the legacy variable. Reassess the setting when upgrading providers.
4. Deliver the corrected variables file to the generated platform repository too. For the existing local test, its generated `platform-landing-zone.auto.tfvars` was corrected locally alongside the source inputs, but the remote repository is a separate copy. Rerun CI and review a new delivery plan before any apply.

The lowercase override fix and this AzureRM metadata setting address different errors. Neither resolves the separate private-DNS-module null `geo_code` blocker documented above.

## 11. Track all scenarios in the root Git repository

1. Use the [Terraform workspace root](../../) as the single repository root for all scenarios. Do not initialize a nested repository in this scenario or its local test copy. The root repository is already initialized; for a fresh workspace only, run `git init` there:

   ```powershell
   Set-Location "D:\workarea\Source\alz\terraform"
   git rev-parse --show-toplevel
   ```

2. Keep the [root .gitignore](../../.gitignore) and [scenario .gitignore](.gitignore) in place. They exclude generated output, temporary files, local test copies, Terraform working directories/state/plans, and common credential-file formats. Review staged configuration for real credentials before every commit; ignore rules cannot detect secrets embedded in an otherwise valid configuration file. Scenario 8's former nested Git metadata/history was preserved outside the workspace during consolidation; its source files are now tracked directly by the root repository.
3. Validate the scenario configuration, then stage and review all source scenarios before committing:

   ```powershell
   terraform fmt -check ".\devops\accelerator-8\config\platform-landing-zone.tfvars"
   git add -- .gitignore scenarios.ps1 devops github
   git diff --cached --check
   git diff --cached --stat
   git commit -m "Track landing zone scenarios and Saudi configuration" `
       -m "Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
   git status --short
   ```

This is a local source repository only. No remote or push is configured by these steps, and it does not replace the repositories generated by the Azure DevOps bootstrap. Preserve disabled settings as comments, while keeping the explicit policy-removal configuration active.

## References

Official guidance consulted on 19 November 2026; recheck it and regional availability before execution:

- [Scenario 8: single-region hub and spoke with NVA](https://azure.github.io/Azure-Landing-Zones/accelerator/starter-terraform/scenarios/single-region-hub-and-spoke-vnet-with-nva/)
- [Planning and bootstrap decisions](https://azure.github.io/Azure-Landing-Zones/accelerator/0_planning/)
- [Tooling prerequisites](https://azure.github.io/Azure-Landing-Zones/accelerator/1_prerequisites/)
- [Platform subscriptions and permissions](https://azure.github.io/Azure-Landing-Zones/accelerator/1_prerequisites/platform-subscriptions/)
- [Azure DevOps prerequisites and PAT scopes](https://azure.github.io/Azure-Landing-Zones/accelerator/1_prerequisites/azuredevops/)
- [Advanced bootstrap commands](https://azure.github.io/Azure-Landing-Zones/accelerator/2_bootstrap/advanced/)
- [Running the deployment pipeline](https://azure.github.io/Azure-Landing-Zones/accelerator/3_run/)
- [Azure DevOps bootstrap input definitions](https://github.com/Azure/accelerator-bootstrap-modules/blob/main/alz/azuredevops/variables.tf)
- [Bootstrap region and resource wiring](https://github.com/Azure/accelerator-bootstrap-modules/blob/main/alz/azuredevops/main.tf)
- [Azure products by region](https://azure.microsoft.com/explore/global-infrastructure/products-by-region/)
- [Disabling AMA policy assignments](https://azure.github.io/Azure-Landing-Zones/accelerator/starter-terraform/options/ama/)
- [Disabling the DDoS Network Protection plan](https://azure.github.io/Azure-Landing-Zones/accelerator/starter-terraform/options/ddos/)
- [Defender plan policy options](https://azure.github.io/Azure-Landing-Zones/accelerator/starter-terraform/options/defender/)
- [Pinned SQL guardrail, including independent Defender deployment](https://github.com/Azure/Azure-Landing-Zones-Library/blob/platform/alz/2026.11.0/platform/alz/policy_set_definitions/Enforce-Guardrails-SQL.alz_policy_set_definition.json)
- [Pinned starter management-resource deployment](https://github.com/Azure/alz-terraform-accelerator/blob/v17.7.0/templates/platform_landing_zone/main.management.resources.tf)
- [Pinned ALZ policy defaults and dependent assignments](https://github.com/Azure/Azure-Landing-Zones-Library/blob/platform/alz/2026.11.0/platform/alz/alz_policy_default_values.json)
- [Pinned Defender configuration initiative](https://github.com/Azure/Azure-Landing-Zones-Library/blob/platform/alz/2026.11.0/platform/alz/policy_set_definitions/Deploy-MDFC-Config_20240319.alz_policy_set_definition.json)
- [Pinned DNS policy parameters and region map](https://github.com/Azure/Azure-Landing-Zones-Library/blob/platform/alz/2026.11.0/platform/alz/policy_set_definitions/Deploy-Private-DNS-Zones.alz_policy_set_definition.json)
- [Pinned starter short-name replacement precedence](https://github.com/Azure/alz-terraform-accelerator/blob/v17.7.0/templates/platform_landing_zone/modules/config-templating/locals.config.tf)
- [Pinned DNS module region-code substitution](https://github.com/Azure/terraform-azurerm-avm-ptn-network-private-link-private-dns-zones/blob/v0.23.2/locals.tf)
- [Pinned regions module geo-code map](https://github.com/Azure/terraform-azurerm-avm-utl-regions/blob/v0.12.0/locals.geo.codes.tf.json)
- [AzureRM 4.x enhanced-validation environment variable](https://github.com/hashicorp/terraform-provider-azurerm/blob/v4.0.0/internal/features/enhanced_validation.go)
- [AzureRM 4.77 enhanced-validation controls and conflicting-variable checks](https://github.com/hashicorp/terraform-provider-azurerm/blob/v4.77.0/internal/features/enhanced_validation.go)

## Additional steps after bootstrap

Apply this **temporary manual workaround** in the generated platform repository after bootstrap. No helper, script, or pipeline cache patch is required. An upstream fix is expected next month, but its release/version is not verified here; remove the workaround only after testing a release that fixes the Saudi lookup.

1. Complete bootstrap once. If it already completed, do not rerun it for the DNS error. Keep platform apply blocked.
2. In your own clone of the generated platform repository, open its Terraform root containing `main.connectivity.hub.and.spoke.virtual.network.tf` and create a change branch. For the checkout discussed here, use `D:\workarea\Source\alz\alz-mgmt`. Do not edit the bootstrap directory or downloaded starter cache.
3. `sae` is confirmed as the Saudi Arabia East Azure Backup DNS code (`privatelink.sae.backup.windowsazure.com`).
4. Use the prepared [saudi-dns-modules.zip](saudi-dns-modules.zip): right-click it in File Explorer, select **Extract All**, then copy the extracted `hub-and-spoke-vnet` and `private-link-private-dns-zones` folders into your generated repository's existing `modules` folder. Keep `config-templating` untouched and compare existing destination folders before overwriting. The archive is an unchanged copy of the test checkout's module files; no download/copy script is needed. For upstream downloads instead, follow step 3 of the [manual runbook](#post-bootstrap-saudi-dns-module-fix).
5. Make the root source edit below by hand. The other two edits are already included in the prepared ZIP; verify them. If using the upstream archives instead, apply all three. Preserve every other argument and module block name:
   - In the root's `main.connectivity.hub.and.spoke.virtual.network.tf`, set the existing `hub_and_spoke_vnet` module source to `"./modules/hub-and-spoke-vnet"` and remove its `version` argument.
   - In `modules/hub-and-spoke-vnet/main.tf`, set the existing `private_dns_zones` module source to `"../private-link-private-dns-zones"` and remove its `version` argument.
   - In `modules/private-link-private-dns-zones/locals.tf`, replace only the first region-lookup locals block with:

   ```hcl
   locals {
     location_name = module.regions.regions_by_name_or_display_name[var.location].name
     location_geo_code = local.location_name == "saudiarabiaeast" ? (
       "sae"
     ) : module.regions.regions_by_name_or_display_name[var.location].geo_code
   }
   ```

6. In the generated variables, retain the Saudi starter and Corp policy maps. Ensure both SQL policy-effect overrides use lowercase `"disabled"` while initiative parameters retain `"Disabled"`; the source [configuration](config/platform-landing-zone.tfvars) already contains that casing fix. Preserve environment-specific subscription settings.
7. From the generated Terraform root, run these commands individually, stopping if any fails:

   ```powershell
   terraform fmt main.connectivity.hub.and.spoke.virtual.network.tf
   terraform fmt modules\hub-and-spoke-vnet\main.tf
   terraform fmt modules\private-link-private-dns-zones\locals.tf
   terraform init -backend=false -input=false
   terraform validate
   ```

8. Review and commit the two module directories, root module source change, and any corrected generated variables through the generated repository's normal change process. Retain the provider lock file and avoid unrelated dependency upgrades. This source documentation does not make those remote changes automatically.
9. Run normal authenticated CI and the delivery plan, including initialization of the real backend. Local validation does not replace a plan. Before approving apply, verify that both reported errors are gone, Backup zone naming agrees with the policy, auto-registration and VNet links remain intact, and no unexpected replacements or deletions are planned.
10. Once an upstream fix is released, verify that the hub-and-spoke release actually consumes the corrected DNS/regions dependency. Restore the registry module source with that tested version, initialize and review a new plan, then remove the unused local copies in the same reviewed change. Do not assume upgrading the starter or DNS module alone fixes the nested dependency.

The expanded [manual runbook](#post-bootstrap-saudi-dns-module-fix) explains the module wiring and safeguards. Never edit `.terraform` as the permanent fix or commit bootstrap output, state, plans, credentials, or caches.
