# Scenario 9: Saudi Arabia landing zone with Virtual WAN, Terraform and Azure DevOps

Deploy a **single-region Virtual WAN with a sidecar virtual network prepared for a Network Virtual Appliance (NVA)** using the Azure Landing Zones accelerator, private bootstrap networking, and self-hosted Azure DevOps agents.

This is a configuration and deployment runbook, not proof of a successful Azure deployment. It builds on the [scenario 8 hub-and-spoke runbook](../single-region-hub-and-spoke-vnet-with-nva/README.md): the bootstrap, regional split, policy exceptions, and library are the same, so this guide covers what is different and points to scenario 8 for the shared procedures. The [GitHub variant](../../github/single-region-virtual-wan-with-nva/README.md) shares the platform files.

> **Colleague packages are test references, not the source of truth.** [moselim200/saudi-alz-azuredevops-vwan-nva](https://github.com/moselim200/saudi-alz-azuredevops-vwan-nva) and [moselim200/saudi-alz-github-vwan-nva](https://github.com/moselim200/saudi-alz-github-vwan-nva) were used to cross-check this guide (section 10) and are recommended for teams that prefer not to customize files themselves (section 11).

## 1. Select the configuration and understand the regional split

Paths are relative to this scenario folder unless stated otherwise.

| Component | Setting |
| --- | --- |
| Bootstrap resources, agents, registry, Terraform backend | UAE North: `uaenorth` |
| Regional platform resources (Virtual WAN, hub, sidecar VNet, Bastion, DNS) | Saudi Arabia East: `saudiarabiaeast` |
| Policy-assignment managed identities | UAE North (identity-only exception, as in scenario 8) |
| Version control / pipelines / agents | Azure DevOps Services, self-hosted ACI agents |
| Bootstrap networking | Private endpoints and a dedicated VNet |
| Pinned starter / Terraform / ALZ module / bootstrap | `v17.7.0` / `1.14.9` / `7.1.5` / `v7.3.2` |
| Connectivity modules | Virtual WAN `0.18.0` (vendored), Private DNS `0.23.2` (vendored, Saudi-patched) |

The reasons for the two-region split and the data-residency approval are identical to scenario 8, section 1; read them before proceeding. Bootstrap state, agents, images, and Azure DevOps data are outside Saudi Arabia. Private endpoints do not make them Saudi-resident.

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

There is no hub VNet route table like scenario 8's: the Virtual WAN hub has no appliance subnet to protect from a self-route, so the `assign_generated_route_table` setting does not exist here.

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

- **VPN gateway is unvalidated.** The source keeps the hub VPN gateway enabled, as scenario 8 does for its VNet gateway. The colleague's lab disabled it, so no verified Saudi deployment covers it. Check Virtual WAN VPN gateway availability and scale units in Saudi Arabia East before bootstrap, or set `primary_virtual_network_gateway_vpn_enabled = false`.
- **Private DNS Resolver is disabled.** Azure rejected it in Saudi Arabia East in the tests behind this guide. The standard design has the NVA forward DNS to the resolver; see section 9 for the replacement path you must approve.
- **Policy identities in UAE North**, with `resource_group_location` and `private_dns_zone_region` on the Saudi region. Same rationale as scenario 8.
- **Security subscription:** supply its ID or comment out the **entire** placement block for three subscriptions.
- **Bootstrap subscription and network:** set the bootstrap subscription explicitly; the `10.250.0.0/24` layout needs IPAM approval.

## 2. Prepare permissions, tools, and Azure DevOps

Identical to scenario 8, section 2 (Azure prerequisites, tools, the two Azure DevOps PATs, token handling). Use scenario number **9**:

```powershell
$iacType = "terraform"
$versionControl = "azure-devops"
$scenarioNumber = 9
$targetFolderPath = ".\devops\single-region-virtual-wan-with-nva"
```

**The scenario already exists in this workspace. Skip generation.** For a new, empty destination only, run `New-AcceleratorFolderStructure` with those values.

Set both PATs as environment variables and keep the YAML entries commented out:

```powershell
$env:TF_VAR_azure_devops_personal_access_token = Read-Host "Bootstrap PAT (token 1)" -MaskInput
$env:TF_VAR_azure_devops_agents_personal_access_token = Read-Host "Agent registration PAT (token 2)" -MaskInput
```

## 3. Edit `config/inputs.yaml` once

[inputs.yaml](config/inputs.yaml) is the same file as scenario 8's, because bootstrap inputs do not depend on topology. Complete the entries in scenario 8, section 3 (subscriptions, explicit `bootstrap_subscription_id`, naming, the four `10.250.0.*` network keys, organization and project names, `apply_approvers`).

## 4. Review `config/platform-landing-zone.tfvars`

Open [platform-landing-zone.tfvars](config/platform-landing-zone.tfvars). Merge changes into the existing blocks and preserve `$${...}` tokens. The policy, DNS, Defender, and region settings are the same as scenario 8, section 4 (rationale there). The vWAN-specific parts:

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

For the MCAPS-only public-IP tag, uncomment the `ip_tags` line in `virtual_hubs.primary.bastion.bastion_public_ip` after confirming that the applied policy requires `FirstPartyUsage = "/Unprivileged"`. This configuration defines no public-IP resource for the hub VPN gateway, so there is nothing else to tag. Existing-deployment implications (resource deletion, Defender plans, DDoS, resolver, Bastion replacement) are the same as scenario 8.

## 5. Custom library

The [library](config/lib/) is byte-identical to scenario 8's: the removal lists do not depend on topology. Follow scenario 8, section 5. Removal directives must remain active, and the DDoS flag, plan-ID default, and both `Enable-DDoS-VNET` removals (connectivity and landing zones) must agree.

## 6. Module and networking overlay

The tracked files are:

```text
config\
  main.connectivity.virtual.wan.tf
  modules\
    virtual-wan\                 89 files: root .tf files, LICENSE, 11 child modules under modules\
    private-link-private-dns-zones\   7 files (same patched module as scenario 8)
```

| File | Change | Reason |
| --- | --- | --- |
| [Root networking overlay](config/main.connectivity.virtual.wan.tf) | `source = "./modules/virtual-wan"`, no `version` | The starter's registry call to `0.18.0` is replaced by the local copy. |
| [virtual-wan `main.tf`](config/modules/virtual-wan/main.tf) | `private_dns_zones.source = "../private-link-private-dns-zones"`, no `version` | Use the patched DNS module instead of registry `0.23.2`. |
| [DNS `locals.tf`](config/modules/private-link-private-dns-zones/locals.tf) | Return `"sae"` for `saudiarabiaeast` | The upstream Saudi `geo_code` is null and `replace` rejects it. |

Everything else is unchanged upstream content: virtual-wan `v0.18.0` (commit `116594239389f448c8db52b225566ef9e7ca68b5`) and private DNS `v0.23.2`, both MIT-licensed. Only runtime `.tf` files and the license are kept (no docs, tests, or tooling). The child modules are vendored locally, so the pipeline does not need Git access to GitHub at `terraform init`. As of 22 November 2026 upstream has newer releases (vWAN `0.18.2`, DNS `0.23.3`); neither fixes the Saudi geo code, and this overlay deliberately stays on the starter's pins. Do not edit `.terraform`.

All three overlay paths must be passed to bootstrap (section 8); adjacent folders are not copied automatically. Preserve the starter's existing `modules\config-templating`. The overlay merges by folder name and does not replace it. For an existing generated repository, follow the scenario 8, section 6 fallback, substituting the `virtual-wan` folder and the `main.connectivity.virtual.wan.tf` file.

## 7. Validate files and complete preflight

### Source and staged checks

```powershell
$targetFolderPath = "D:\workarea\Source\alz\terraform\devops\single-region-virtual-wan-with-nva"
terraform fmt -check -recursive "$targetFolderPath\config"
```

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

Before bootstrap, confirm the scenario 8, section 7 list, plus:

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

Provider validation: AzureRM can reject `saudiarabiaeast` before ARM sees a request. Apply the location-only setting `ARM_PROVIDER_ENHANCED_VALIDATION_LOCATIONS = "false"` as described in scenario 8 (variable group or task `env`). Alternatively, bake it into the bootstrap source: clone `Azure/accelerator-bootstrap-modules` at `v7.3.2`, add the line to the `env:` block of the AzureCLI task in `alz/azuredevops/pipelines/terraform/templates/helpers/terraform-plan.yaml` and `terraform-apply.yaml` (the same two files the colleague's DevOps package patches), keep the clone outside this repository, and add `-bootstrapModuleOverrideFolderPath <clone>` to the command. Never combine it with the legacy `ARM_PROVIDER_ENHANCED_VALIDATION`.

Then follow scenario 8, section 8 (review the plan, protect output/state, verify agents, service connections, approvers, the exact platform commit, and run CI and **02 Azure landing zone Continuous Delivery**). Checks specific to this scenario:

- The pipeline checkout contains `modules\virtual-wan` (89 files), `modules\private-link-private-dns-zones` (7 files), `modules\config-templating`, and the root `main.connectivity.virtual.wan.tf` with no `version` argument.
- The plan creates a Virtual WAN, one hub, the sidecar VNet and connection, Bastion without zones, the DNS zones and links, and `privatelink.sae.backup.windowsazure.com`; and no resolver, firewall, ExpressRoute gateway, workspace, DCRs, or AMA identity.
- Policy identities are in UAE North, platform resources in Saudi Arabia East, with no unexpected deletions or replacements. Only an authorized approver approves the plan.

## 9. Operations and the NVA

After apply, verify hierarchy and placement, regional resources, agent access to the private backend and registry, approvals, policy compliance, and a drift plan.

- **NVA:** deploy and license the appliance separately in the NVA subnet. Configure IP forwarding, then design vWAN routing for it (static routes, route maps, or routing intent). The `10.0.4.68` address is only a sample; nothing in this configuration points at it.
- **DNS:** the standard design makes the NVA a DNS proxy that forwards to the Private DNS Resolver. This guide disables the resolver, so no forwarding target exists by default. Private link zones are linked to the sidecar VNet, so an NVA in that VNet can forward to the Azure-provided resolver (`168.63.129.16`). That path is a design suggestion, not tested here; approve and test it, and approve any on-premises conditional forwarding, before production.
- Clear the local PATs and revoke the short-lived bootstrap token after bootstrap, as in scenario 8.

Version control: use the [workspace root](../../) as the single Git repository, keep the root and [scenario ignore rules](.gitignore) excluding output, temp, local tests, state, plans, caches, and credentials, and run `git diff --cached --check` and a content review before committing. These steps do not publish to the generated Azure DevOps repositories. Remove the overlay only after a verified upstream release fixes the dependency actually used and a reviewed plan preserves addresses and DNS links.

## Troubleshooting

Use scenario 8's table for shared symptoms (null `replace`, SQL override casing, Bastion zones, ACR/ACI, agents offline, backend access, PAT 401/403, missing `alz_custom`, region rejected by AzureRM). Additional symptoms for this scenario:

| Symptom | Action |
| --- | --- |
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
- The [scenario 8 runbook](../single-region-hub-and-spoke-vnet-with-nva/README.md) for the shared prerequisites, policy rationale, bootstrap verification, and troubleshooting.
