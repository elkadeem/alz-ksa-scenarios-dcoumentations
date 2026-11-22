# Scenario 9: Saudi Arabia landing zone with Virtual WAN, Terraform and GitHub

Deploy a **single-region Virtual WAN with a sidecar virtual network prepared for a Network Virtual Appliance (NVA)** using the Azure Landing Zones accelerator, private bootstrap networking, and self-hosted GitHub Actions runners.

This is the GitHub counterpart of the [Azure DevOps scenario 9 runbook](../../devops/single-region-virtual-wan-with-nva/README.md). The platform design, tfvars, library, and module overlay are identical; this guide covers only what differs for GitHub. For GitHub procedures shared with scenario 8 (organization and plan prerequisites, token creation, runner and environment checks, workflow behavior), it points to the [scenario 8 GitHub runbook](../single-region-hub-and-spoke-vnet-with-nva/README.md).

This is a configuration and deployment runbook, not proof of a successful Azure deployment. The colleague's packages [moselim200/saudi-alz-github-vwan-nva](https://github.com/moselim200/saudi-alz-github-vwan-nva) and [moselim200/saudi-alz-azuredevops-vwan-nva](https://github.com/moselim200/saudi-alz-azuredevops-vwan-nva) are **test references, not the source of truth** (section 7), and are recommended for teams that prefer not to customize files (section 8).

## 1. Configuration and what is shared

| Component | Setting |
| --- | --- |
| Bootstrap resources, runners, registry, Terraform backend | UAE North: `uaenorth` |
| Regional platform resources | Saudi Arabia East: `saudiarabiaeast` |
| Policy-assignment managed identities | UAE North (identity-only exception) |
| Version control / pipelines / runners | GitHub organization, GitHub Actions, self-hosted ACI runners |
| Pinned starter / Terraform / ALZ module / bootstrap | `v17.7.0` / `1.14.9` / `7.1.5` / `v7.3.2` |
| Connectivity modules | Virtual WAN `0.18.0` and Private DNS `0.23.2`, both vendored; DNS is Saudi-patched |

The regional split, data-residency approval (state, runners, images, and GitHub-hosted repositories and logs are outside Saudi Arabia), design choices, vWAN topology, and the unvalidated VPN gateway are covered in the [DevOps scenario 9 README](../../devops/single-region-virtual-wan-with-nva/README.md), sections 1, 4 and 9. Read them first.

These files are byte-identical copies of the DevOps scenario 9 files, because they do not depend on the version-control system:

| Path | Content |
| --- | --- |
| [config/platform-landing-zone.tfvars](config/platform-landing-zone.tfvars) | Regions, flags, policy settings, hub/sidecar addressing |
| [config/lib/](config/lib/) | Custom library and policy removals |
| [config/modules/](config/modules/) and [config/main.connectivity.virtual.wan.tf](config/main.connectivity.virtual.wan.tf) | Vendored `virtual-wan` (89 files) and private DNS (7 files) overlay |
| [tests/](tests/) | Staged offline validation (same script and mocked test) |

Only [config/inputs.yaml](config/inputs.yaml) and this README are GitHub-specific. The inputs file is the same as scenario 8's GitHub inputs.

## 2. Prerequisites

Use the scenario 8 GitHub runbook, section 2 for: a GitHub **organization** (personal accounts are unsupported), the plan caveat (on GitHub Free the bootstrap makes repositories **public**), organization-owner rights, repository-name availability, and the two fine-grained tokens. Azure prerequisites (four subscriptions, `Owner` on the parent management group and subscriptions, allowed-location policies for UAE North and Saudi Arabia East) are the same as scenario 8.

```powershell
$iacType = "terraform"
$versionControl = "github"
$scenarioNumber = 9
$targetFolderPath = ".\github\single-region-virtual-wan-with-nva"
```

**The scenario already exists in this workspace. Skip generation.**

```powershell
$env:TF_VAR_github_personal_access_token = Read-Host "Bootstrap PAT (token 1)" -MaskInput
$env:TF_VAR_github_runners_personal_access_token = Read-Host "Runner registration PAT (token 2)" -MaskInput
```

Keep both YAML token entries commented out. Complete [inputs.yaml](config/inputs.yaml) using the scenario 8 GitHub runbook, section 3: subscriptions, explicit `bootstrap_subscription_id`, naming, the `10.250.0.*` network keys, `github_organization_name`, and **at least one `apply_approvers` entry**.

> [!WARNING]
> **Do not leave `apply_approvers` empty.** The generated CD workflow runs on every push to `main`, and the apply environment's approval is the only human gate before changes reach Azure. The colleague's lab packages ship `[]`.

## 3. Provider-validation workaround

AzureRM can reject `saudiarabiaeast` before ARM sees a request. The location-only switch must be in the job-level `env:` of **each of the three Terraform jobs** in the generated **templates repository** (CI plan in `ci-template.yaml`; plan and apply in `cd-template.yaml`):

```yaml
env:
  ARM_PROVIDER_ENHANCED_VALIDATION_LOCATIONS: "false"
```

It does not work from caller workflows or repository Actions variables, and must never be combined with the legacy `ARM_PROVIDER_ENHANCED_VALIDATION`. Either bake it in before bootstrap with a pinned `v7.3.2` bootstrap copy and `-bootstrapModuleOverrideFolderPath` (**Option A, recommended**), or merge a pull request into the templates repository after bootstrap (**Option B**). Both are described in the scenario 8 GitHub runbook, section 5. With Option B, the automatic CD run triggered by bootstrap's first push to `main` will fail at plan until the fix is merged, and approvals must stay enabled.

## 4. Validate and bootstrap

```powershell
$targetFolderPath = "D:\workarea\Source\alz\terraform\github\single-region-virtual-wan-with-nva"
terraform fmt -check -recursive "$targetFolderPath\config"

$tf = "<path-to-terraform-1.14.9>\terraform.exe"
& "$targetFolderPath\tests\Invoke-StagedValidation.ps1" -TerraformPath $tf
```

The staged validation clones the pinned starter into a temporary folder, overlays this configuration the way bootstrap does, and runs `fmt`, `init -backend=false`, `validate`, and mocked `terraform test`; it needs no Azure sign-in. On 22 November 2026 it passed with Terraform `1.14.9` and starter `v17.7.0` (`4 passed, 0 failed`), including the `privatelink.sae.backup.windowsazure.com` zone assertion, and failed as expected with the registry DNS module restored. The test ran against the DevOps copy of the same files. It is **not** an authenticated plan and does not prove regional availability, policy acceptance, quota, or RBAC.

Complete the preflight list in the DevOps scenario 9 README, section 7, plus the GitHub items: plan and repository visibility approved, outside-contributor workflow approval policy set, approvers real, and the provider-validation delivery chosen. Then run the **one** bootstrap command:

```powershell
Deploy-Accelerator `
    -inputs "$targetFolderPath\config\inputs.yaml", "$targetFolderPath\config\platform-landing-zone.tfvars" `
    -starterAdditionalFiles "$targetFolderPath\config\lib", `
                            "$targetFolderPath\config\modules", `
                            "$targetFolderPath\config\main.connectivity.virtual.wan.tf" `
    -output "$targetFolderPath\output" `
    -bootstrapModuleOverrideFolderPath $bootstrapSourcePath   # omit for Option B
```

All three additional paths are required: only `lib` omits the Saudi workaround, and modules without the networking file leaves the registry Virtual WAN module active. Protect and keep the output and state, and rerun failed bootstraps with the **same** configuration and output.

After bootstrap, verify as in the scenario 8 GitHub runbook, section 7 (runners online, `plan` and `apply` environments with reviewers, branch protection, the exact `main` commit, the three provider-validation entries), and these scenario 9 checks:

- The platform repository contains `modules\virtual-wan` (89 files), `modules\private-link-private-dns-zones` (7 files), `modules\config-templating`, and a root `main.connectivity.virtual.wan.tf` with no `version` argument.
- The plan creates a Virtual WAN, one hub, the sidecar VNet and connection, Bastion without zones, the DNS zones and links, and `privatelink.sae.backup.windowsazure.com`; and no resolver, firewall, ExpressRoute gateway, workspace, DCRs, or AMA identity.
- Policy identities are in UAE North, platform resources in Saudi Arabia East, with no unexpected deletions or replacements.

Run **01 Azure Landing Zones Continuous Integration** through a pull request or manual dispatch, review the plan, then run **02 Azure Landing Zones Continuous Delivery** with `apply` through the approval gate. Do not push to `main` merely to inspect a plan.

## 5. Operations

The NVA, its vWAN routing, and the DNS path are **not** created by this configuration; the sample `10.0.4.68` is referenced by nothing. With the Private DNS Resolver disabled, an NVA in the sidecar VNet can forward to the Azure-provided resolver (`168.63.129.16`) because the private zones are linked to that VNet; this is an untested suggestion that needs approval. See the DevOps scenario 9 README, sections 4 and 9.

Clear the tokens (`Remove-Item Env:\TF_VAR_github_personal_access_token`, `Env:\TF_VAR_github_runners_personal_access_token`) and revoke the short-lived bootstrap token. Commit this folder from the workspace root with `git diff --cached --check` and a content review. Updates to the generated repositories go through pull requests there. For an existing generated repository, use the scenario 8 GitHub runbook's fallback delivery, substituting the `virtual-wan` folder and the `main.connectivity.virtual.wan.tf` file.

## 6. Troubleshooting

Use the DevOps scenario 9 table for topology symptoms (module source changes, hub or VPN creation, address conflicts, no traffic to the NVA, DNS from on-premises) and the scenario 8 GitHub table for GitHub symptoms (runners offline, 403 on bootstrap, public repositories on Free, CD triggered immediately, empty approvers, OIDC credential mismatch, `Find-PSResource` feed errors, Windows long paths).

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
- The [DevOps scenario 9 runbook](../../devops/single-region-virtual-wan-with-nva/README.md) and the [scenario 8 GitHub runbook](../single-region-hub-and-spoke-vnet-with-nva/README.md).
