# Scenario 9: Saudi Arabia landing zone with Terraform and Azure DevOps (Virtual WAN + NVA)

This guide deploys **scenario 9: Single-Region Virtual WAN with a Network Virtual Appliance (NVA)** using the Azure Landing Zones accelerator, Azure DevOps, private networking, and self-hosted agents, in the Saudi Arabia data center.

It follows the same method as [scenario 8](../accelerator-8/README.md) (hub and spoke with NVA). Only the networking differs: scenario 9 uses an Azure **Virtual WAN hub** plus a **sidecar virtual network** that hosts the NVA and Bastion.

> Configuration edits described as "already applied" are saved in this folder only. They are not proof of an Azure deployment. Always review the pipeline plan before approving apply.

## 0. What is already prepared in this folder

| Item | File | State |
| --- | --- | --- |
| Bootstrap inputs | [config/inputs.yaml](config/inputs.yaml) | `uaenorth` bootstrap, private networking, self-hosted agents, version pins. Placeholders still need your values. |
| Platform settings | [config/platform-landing-zone.tfvars](config/platform-landing-zone.tfvars) | Saudi region `saudiarabiaeast` (short name `sae`), Virtual WAN topology, unavailable/unwanted services disabled. |
| Custom policy library | [config/lib](config/lib/) | Monitoring, Defender and DDoS policy removals (same as scenario 8). |
| Saudi DNS fix | [config/modules](config/modules/) and [config/main.connectivity.virtual.wan.tf](config/main.connectivity.virtual.wan.tf) | Patched copies of the Virtual WAN and private DNS modules, wired in for bootstrap. |

### Constraints carried over from scenario 8

| Topic | Decision |
| --- | --- |
| Bootstrap region | `uaenorth` (Azure Container Registry is not yet available in Saudi Arabia East). |
| Platform region | `saudiarabiaeast` (`starter_locations`). |
| Log Analytics / AMA | Disabled (`management_resources_enabled = false`) plus the policy removals. |
| DDoS Network Protection plan | Disabled (`ddos_protection_plan_enabled = false`) plus `Enable-DDoS-VNET` removal. |
| Microsoft Defender auto-enablement | Disabled via archetype removals and guardrail overrides. |
| Private DNS Resolver | Disabled (`primary_private_dns_resolver_enabled = false`). |
| ExpressRoute gateway | Disabled (`primary_virtual_network_gateway_express_route_enabled = false`). |
| VPN gateway | Enabled (hub site-to-site gateway). |
| Azure Firewall | Disabled: this is an NVA scenario. |
| Bastion | Enabled, in the sidecar VNet, `zones = []` on host and public IP (avoids `BastionRegionAzNotSupported`). |
| Saudi private DNS | Corp `dnzZoneRegionShortNames = { saudiarabiaeast = "sae" }`, plus the module fix below. |

> **Data residency approval is required.** Bootstrap storage, agent execution, container images and Terraform state live outside Saudi Arabia in this design, and Azure DevOps has its own data location. If all deployment data must stay in Saudi Arabia, stop and approve a different bootstrap design.

### Scenario 9 network layout

| Component | Address / value |
| --- | --- |
| Virtual WAN hub (`primary_hub_address_space`) | `10.0.0.0/22` |
| Sidecar VNet | `10.0.4.0/22` |
| Bastion subnet (sidecar) | `10.0.4.0/26` |
| NVA subnet (sidecar) | `10.0.4.64/26` |
| NVA next-hop IP | `10.0.4.68` |
| Private DNS Resolver subnet (retained, resolver disabled) | `10.0.4.128/28` |
| Bootstrap VNet (UAE North) | `10.250.0.0/24` (agents `10.250.0.0/26`, private endpoints `10.250.0.64/26`) |

Check these ranges against corporate, VPN and future spoke ranges. Change related `primary_*` values together.

The scenario creates management groups, policies, the Virtual WAN, one hub, hub VPN gateway, a sidecar VNet and Bastion. It does **not** deploy the NVA, vendor licenses, routing intent/route maps to the NVA, spokes, an ExpressRoute circuit, or an on-premises VPN device.

## 1. Prepare Azure and tools

1. Prepare four subscriptions (Management, Connectivity, Identity, Security) in one Microsoft Entra tenant. Record the tenant and subscription IDs.
2. The bootstrap account needs `Owner` on the parent management group (or Tenant Root Group) and on all four subscriptions, with PIM roles activated. It also needs Azure DevOps rights to create projects, repos, pipelines, service connections, environments and agent pools.
3. Make sure allowed-location policies permit both `uaenorth` (bootstrap) and `saudiarabiaeast`. Do not remove governance controls just to deploy.
4. Install **PowerShell 7.4+**, **Azure CLI 2.55+**, **Git** and VS Code. Cloud Shell and corporate proxies are not supported by the accelerator.

```powershell
$PSVersionTable.PSVersion
az version
git --version
```

## 2. Create two Azure DevOps PATs

In **User settings > Personal access tokens** (for your organization):

| Token | Scopes | Lifetime |
| --- | --- | --- |
| Token 1 - bootstrap | Agent Pools R&M, Build R&E, Code Full, Environment R&M, Graph R&M, Pipeline Resources U&M, Project and Team R/W/M, Service Connections R/Q/M, Variable Groups R/C/M | Short |
| Token 2 - agents | Agent Pools Read & manage only | Organization-approved, with renewal planned |

Confirm at least one **self-hosted parallel job** is available. Then set the tokens as environment variables (never in files):

```powershell
$env:TF_VAR_azure_devops_personal_access_token = Read-Host "Bootstrap PAT (token 1)" -MaskInput
$env:TF_VAR_azure_devops_agents_personal_access_token = Read-Host "Agent registration PAT (token 2)" -MaskInput
```

## 3. Install the ALZ module

Skip generation: this folder already contains the scenario 9 configuration. Do not regenerate it over your edits.

```powershell
Set-Location "<path-to-this-repository>"

if (-not (Get-InstalledPSResource -Name ALZ -ErrorAction SilentlyContinue)) { Install-PSResource -Name ALZ } else { Update-PSResource -Name ALZ }
Import-Module ALZ
Get-Module ALZ | Select-Object Name, Version
```

(For a brand-new folder only: `New-AcceleratorFolderStructure -iacType terraform -versionControl azure-devops -scenarioNumber 9 -targetFolderPath .\devops\accelerator-9`.)

## 4. Fill in the bootstrap inputs

Edit [config/inputs.yaml](config/inputs.yaml) and replace every `<...>` placeholder:

```yaml
bootstrap_location: "uaenorth"                       # keep
root_parent_management_group_id: "<parent-management-group-id>"   # empty = Tenant Root Group
subscription_ids:
  management: "<management-subscription-id>"
  identity: "<identity-subscription-id>"
  connectivity: "<connectivity-subscription-id>"
  security: "<security-subscription-id>"
bootstrap_subscription_id: "<management-subscription-id>"   # set explicitly
azure_devops_organization_name: "<azure-devops-organization>"   # name only, not the URL
azure_devops_project_name: "<azure-devops-project-name>"
apply_approvers: ["<approver-user-principal-name>"]
```

Rules:

- Keep the two `azure_devops_*_personal_access_token` lines **commented out** so the environment variables are used.
- The bootstrap network keys are already in the file; keep them (or adjust the CIDRs):

  ```yaml
  virtual_network_address_space: "10.250.0.0/24"
  virtual_network_subnet_address_prefix_container_instances: "10.250.0.0/26"
  virtual_network_subnet_address_prefix_private_endpoints: "10.250.0.64/26"
  allow_storage_access_from_my_ip: false
  ```

- Keep `starter_module_version: "v17.7.0"` and `terraform_version: "1.14.9"`.
- Optional: set `defender_email_security_contact` in the tfvars only before you ever re-enable Defender.

Save and check the syntax of the platform variables:

```powershell
terraform fmt -check ".\devops\accelerator-9\config\platform-landing-zone.tfvars"
```

## 5. Sign in and complete preflight checks

```powershell
az login --tenant "<tenant-id>" --use-device-code
az account set --subscription "<management-subscription-id>"
az account show --query "{tenantId:tenantId,subscriptionId:id,name:name}" --output table
az account list-locations --query "[?name=='saudiarabiaeast' || name=='uaenorth'].{Name:name,DisplayName:displayName}" --output table
```

Repeat the location check for the connectivity subscription. Also confirm the connectivity subscription can create a **Virtual WAN (Standard)**, **virtual hub** and **VPN gateway** in Saudi Arabia East:

```powershell
az provider show --subscription "<connectivity-subscription-id>" --namespace Microsoft.Network `
  --query "resourceTypes[?resourceType=='virtualWans' || resourceType=='virtualHubs' || resourceType=='vpnGateways'].{Type:resourceType,Locations:locations}" --output json
```

Provider metadata does not prove deployability. If any service is unavailable, stop and agree a design change; do not silently move it out of Saudi Arabia.

Checklist before bootstrap:

- [ ] Correct tenant and four subscription IDs; Owner roles active.
- [ ] UAE North bootstrap and cross-border state/agent processing approved.
- [ ] Saudi Arabia East, Virtual WAN, hub and VPN gateway availability confirmed.
- [ ] Resource providers registered (Network, Storage, ManagedIdentity, ContainerInstance, ContainerRegistry, Authorization, PolicyInsights, Insights, Security).
- [ ] IP ranges above do not overlap existing networks.
- [ ] Two PAT environment variables set; YAML PAT lines remain commented out.
- [ ] Azure DevOps permissions, self-hosted parallel job and approver ready.
- [ ] Disabled DDoS, Defender, Log Analytics, Private DNS Resolver and ExpressRoute approved by security/monitoring owners.
- [ ] An alternative DNS forwarding design exists for clients that would have used the Private DNS Resolver.

## 6. Run the bootstrap (with the Saudi DNS fix)

The pinned private DNS module (`0.23.2`, used directly by Virtual WAN module `0.18.0`) fails for Saudi Arabia East because its region metadata has no `geo_code`. This folder ships a bootstrap-time workaround so you do not have to patch the generated repository by hand.

What is included (do not delete):

| Path | Purpose |
| --- | --- |
| `config/modules/virtual-wan` | Copy of `Azure/avm-ptn-alz-connectivity-virtual-wan` `0.18.0` with `private_dns_zones` source changed to `../private-link-private-dns-zones`. |
| `config/modules/private-link-private-dns-zones` | Copy of private DNS module `0.23.2` that returns `sae` for `saudiarabiaeast`. |
| `config/main.connectivity.virtual.wan.tf` | Starter `v17.7.0` file with `source = "./modules/virtual-wan"` and no `version`. |

Run from the repository root in the PowerShell session that has the PATs:

```powershell
$targetFolderPath = ".\devops\accelerator-9"

terraform fmt -check "$targetFolderPath\config\platform-landing-zone.tfvars"
if ($LASTEXITCODE -ne 0) { throw "Fix the tfvars formatting first." }

Deploy-Accelerator `
    -inputs "$targetFolderPath\config\inputs.yaml", "$targetFolderPath\config\platform-landing-zone.tfvars" `
    -starterAdditionalFiles "$targetFolderPath\config\lib", `
                            "$targetFolderPath\config\modules", `
                            "$targetFolderPath\config\main.connectivity.virtual.wan.tf" `
    -output "$targetFolderPath\output"
```

All three additional-file inputs are required: `lib` (custom policies), `modules` (patched modules) and the root file (makes the starter use them).

Review the bootstrap plan before typing `yes`:

- Bootstrap resources are in `uaenorth`; VNet/subnets use `10.250.0.*`.
- Private endpoints and self-hosted agents are enabled.
- No unexpected deletion or replacement.

Bootstrap creates state storage, identities, service connections, agents, networking, repositories, pipelines and approvals. It does **not** deploy the landing zone itself. If it fails, fix the specific error and rerun with the same configuration and output folder; do not delete state.

Protect the `output` folder (it is git-ignored). Never commit state, plans or tokens.

## 7. Verify the generated platform repository

In Azure DevOps, open the new platform repository on the branch the pipeline uses and confirm:

- [ ] `main.connectivity.virtual.wan.tf` has `source = "./modules/virtual-wan"` and no `version`.
- [ ] `modules/virtual-wan` (with nested `modules/`) and `modules/private-link-private-dns-zones` exist; `modules/config-templating` is still present.
- [ ] `modules/virtual-wan/main.tf` `module "private_dns_zones"` has `source = "../private-link-private-dns-zones"` and no `version`.
- [ ] `modules/private-link-private-dns-zones/locals.tf` returns `"sae"` for `saudiarabiaeast`.
- [ ] `platform-landing-zone.auto.tfvars` keeps `saudiarabiaeast`, the `sae` short name, the Corp DNS map, lowercase `"disabled"` SQL overrides and `zones = []` for Bastion.

If the files are missing, deliver them through a normal pull request into that repository; do not delete and regenerate it.

## 8. Run the landing-zone pipeline

1. **Project settings > Agent pools:** confirm the self-hosted pool and agents are online.
2. Run **01 Azure landing zone Continuous Integration** (validation) via a pull request or manually and make sure it passes.
3. Open **02 Azure landing zone Continuous Delivery** and select **Run pipeline**. Authorize the service connections, agent pool and environments if prompted.
4. Review the Terraform plan. Confirm:
   - Regional resources are in `saudiarabiaeast`; bootstrap resources stay in `uaenorth`.
   - A Virtual WAN, one hub (`10.0.0.0/22`), VPN gateway, sidecar VNet (`10.0.4.0/22`), Bastion, private DNS zones and the auto-registration zone `saudiarabiaeast.azure.local` are planned.
   - **No** Firewall, ExpressRoute gateway, DDoS plan, Private DNS Resolver, Log Analytics workspace/DCR/AMA identity.
   - Backup DNS zone is `privatelink.sae.backup.windowsazure.com`; no `replace ... must not be null` error.
   - Policy assignments listed in `config/lib` are absent; `Enable-DDoS-VNET` is absent.
   - No unexpected deletions or replacements.
5. An authorized approver approves the apply stage.
6. After apply, run another plan and check there is no drift.

## 9. Prepare the NVA (separate work)

1. Choose a vendor and a Saudi-supported appliance image/SKU, and license it.
2. Deploy it into the `subnet-nva-sae` subnet of the sidecar VNet and set its IP to `10.0.4.68` (or update `primary_nva_ip_address` to match).
3. Enable IP forwarding and configure routing, inspection and DNS forwarding using your approved DNS design (the Private DNS Resolver is disabled).
4. Configure hub routing/routing intent or route tables so spoke and branch traffic uses the NVA next hop. Until then, traffic does not flow through the NVA.
5. Connect spokes to the hub and test end-to-end traffic.

## 10. Operate

- Make later changes in the **generated Azure DevOps repository** through pull requests; editing this folder does not update it.
- Clear the PATs when done and revoke the bootstrap PAT:

  ```powershell
  Remove-Item Env:\TF_VAR_azure_devops_personal_access_token
  Remove-Item Env:\TF_VAR_azure_devops_agents_personal_access_token
  ```

- When a verified upstream fix for Saudi region metadata ships, switch back to registry module sources through a reviewed change, re-plan, then remove `config/modules`.

## Troubleshooting

| Symptom | Action |
| --- | --- |
| ACR deployment fails in Saudi Arabia East | Keep `bootstrap_location: "uaenorth"`. |
| `argument must not be null` in private DNS `locals` | The patched modules are not used. Re-check section 7. |
| `Unexpected attribute: "version"` on a module | Remove `version` from any module with a local `source`. |
| `Module not installed` / `source has changed` | Run `terraform init` (the pipeline does this). |
| `Invalid Attribute Value Match ... got: "Disabled"` | Policy `overrides` values must be lowercase `"disabled"`; policy parameters keep `"Disabled"`. |
| `BastionRegionAzNotSupported` | Keep `zones = []` on both the Bastion host and its public IP. |
| AzureRM rejects `saudiarabiaeast` as an unsupported location | Verify with the pipeline identity; if it is only provider metadata lag, add non-secret variable `ARM_PROVIDER_ENHANCED_VALIDATION=false` to the Azure DevOps variable group as a temporary, approved exception. |
| Agents offline or jobs queued | Check ACI logs, image pull, PAT validity, DNS/egress, pool authorization, parallel-job capacity. |
| Backend access denied | Check data-plane RBAC, private endpoint approval, DNS and routing from the agent. Do not enable public storage access. |
| 401/403 from Azure DevOps | Check PAT scopes/expiry/organization and that YAML PAT lines are commented out. |
| Plan replaces DNS zones or links | Module names or `for_each` keys changed. Restore them and do not apply. |

## References

- [Scenario 9: single-region Virtual WAN with NVA](https://azure.github.io/Azure-Landing-Zones/accelerator/starter-terraform/scenarios/single-region-virtual-wan-with-nva/)
- [Scenario 8 guide in this repository](../accelerator-8/README.md)
- [Planning and bootstrap decisions](https://azure.github.io/Azure-Landing-Zones/accelerator/0_planning/)
- [Prerequisites and PAT scopes](https://azure.github.io/Azure-Landing-Zones/accelerator/1_prerequisites/azuredevops/)
- [Running the deployment pipeline](https://azure.github.io/Azure-Landing-Zones/accelerator/3_run/)
- [Virtual WAN module v0.18.0](https://github.com/Azure/terraform-azurerm-avm-ptn-alz-connectivity-virtual-wan/tree/v0.18.0)
- [Private DNS module v0.23.2](https://github.com/Azure/terraform-azurerm-avm-ptn-network-private-link-private-dns-zones/tree/v0.23.2)
- [Starter v17.7.0 Virtual WAN file](https://github.com/Azure/alz-terraform-accelerator/blob/v17.7.0/templates/platform_landing_zone/main.connectivity.virtual.wan.tf)
