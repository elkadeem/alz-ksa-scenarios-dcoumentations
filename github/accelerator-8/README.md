# Scenario 8 (GitHub): Saudi Arabia landing zone with Terraform, GitHub Actions and self-hosted runners

Deploys **scenario 8: Single-Region Hub and Spoke Virtual Network with a Network Virtual Appliance (NVA)** using the Azure Landing Zones accelerator with **GitHub** as version control and CI/CD (GitHub Actions + private, self-hosted runners on Azure Container Instances).

This is the GitHub twin of [devops/accelerator-8](../../devops/accelerator-8/README.md). The Terraform variables (`platform-landing-zone.tfvars`) and custom ALZ library (`config/lib`) are **identical** in both; only the bootstrap inputs and the pipeline steps differ. The Saudi-specific design, rationale and troubleshooting live in the DevOps guide and are linked below rather than duplicated.

> Configuration edits are saved locally only; they are not proof of an Azure deployment. Review every plan before approving.

## What is already configured in this folder

| File | State |
| --- | --- |
| [config/inputs.yaml](config/inputs.yaml) | GitHub bootstrap inputs: `bootstrap_location: uaenorth`, private networking, self-hosted runners, pinned `v17.7.0` / Terraform `1.14.9`. **Placeholders remain** (subscriptions, org, approver). PAT lines are commented out on purpose. |
| [config/platform-landing-zone.tfvars](config/platform-landing-zone.tfvars) | Saudi Arabia East (`sae` short name), DDoS plan off, Log Analytics bundle off, Defender auto-enable off, Private DNS Resolver off, Bastion `zones = []`, VPN gateway on, Corp DNS policy map. |
| [config/lib](config/lib/) | Custom `alz_custom` library with the matching policy removals. |
| [saudi-dns-modules.zip](saudi-dns-modules.zip) | Patched hub/DNS modules (workaround for the null Saudi `geo_code` DNS error). |

Details of each change: [DevOps guide, section 6](../../devops/accelerator-8/README.md#6-configure-saudi-arabia-east-and-scenario-specific-settings).

## 1. Region split and constraints (read first)

| Component | Region |
| --- | --- |
| Bootstrap (runners, ACR, Terraform state storage, bootstrap VNet) | UAE North `uaenorth` |
| Platform landing-zone resources | Saudi Arabia East `saudiarabiaeast` |

ACR is not available in Saudi Arabia East, so **do not set `bootstrap_location` to `saudiarabiaeast`**. Terraform state, runner execution and container images are therefore outside Saudi Arabia, and GitHub has its own data location. **Obtain data-residency approval** before proceeding. This guide does not deploy the NVA appliance, ExpressRoute, an on-premises VPN device, or workloads.

## 2. Prerequisites

**Azure** (same Entra tenant): four subscriptions (Management, Connectivity, Identity, Security) and a parent management group (empty = Tenant Root). The deploying account needs `Owner` on the parent management group and on all four subscriptions (activate PIM roles first). Inherited allowed-location policies must permit both `uaenorth` and `saudiarabiaeast`.

**GitHub**
1. A GitHub **organization** (create one at *github.com > + > New organization*). GitHub Actions must be enabled and private repos allowed.
2. Personal GitHub accounts are not supported. On a *free* organization the bootstrap makes repositories **public** (not recommended for production); use a paid plan for private repos and required-reviewer environments. Do not remove the apply approval gate.
3. Your user must be an organization **owner**.

**Tools** (PowerShell 7.4+): Azure CLI 2.55+, Git, VS Code. Not supported: Azure Cloud Shell or corporate proxies.

```powershell
$PSVersionTable.PSVersion
az version
git --version
```

## 3. Create the two GitHub PATs

Create **fine-grained** tokens (*Settings > Developer settings > Personal access tokens > Fine-grained tokens > Generate new token*). For both: set **Resource owner** to your organization and **Repository access** to *All repositories*.

| Token | Repository permissions (Read and write) | Organization permissions (Read and write) | Expiry |
| --- | --- | --- | --- |
| 1: bootstrap | Actions, Administration, Contents, Environments, Secrets, Variables, Workflows | Members, Self-hosted runners | Short (tomorrow is enough) |
| 2: runner registration | Administration | Self-hosted runners | Approved lifetime; renew before expiry (runners go offline otherwise) |

After bootstrap you can narrow token 2 to the single platform repository. Source: <https://azure.github.io/Azure-Landing-Zones/accelerator/1_prerequisites/github/>.

Set them as environment variables (never in files):

```powershell
$env:TF_VAR_github_personal_access_token         = Read-Host "Bootstrap PAT (token 1)" -MaskInput
$env:TF_VAR_github_runners_personal_access_token = Read-Host "Runner PAT (token 2)" -MaskInput
```

## 4. Clone this repo and install ALZ

```powershell
git clone https://github.com/elkadeem/alz-ksa-scenarios-dcoumentations.git
Set-Location .\alz-ksa-scenarios-dcoumentations

$alzModule = Get-InstalledPSResource -Name ALZ -ErrorAction SilentlyContinue
if (-not $alzModule) { Install-PSResource -Name ALZ } else { Update-PSResource -Name ALZ }
Import-Module ALZ
Get-Module ALZ | Select-Object Name, Version
```

Do **not** run `New-AcceleratorFolderStructure`; the scenario 8 configuration already exists in `github\accelerator-8`.

## 5. Fill in the placeholders

Edit [config/inputs.yaml](config/inputs.yaml):

| Key | Value |
| --- | --- |
| `root_parent_management_group_id` | Existing management group **ID** (not resource ID), or empty for Tenant Root |
| `subscription_ids.*` | The four subscription IDs |
| `bootstrap_subscription_id` | Same as the management subscription ID |
| `github_organization_name` | Organization name only (the part after `github.com/`) |
| `apply_approvers` | GitHub usernames or `org/team-name` who approve apply |

Keep the two PAT lines **commented out** (explicit values override the environment variables). Bootstrap network `10.250.0.0/24` must not overlap the hub (`10.0.0.0/22`) or any corporate/VPN range.

Optional, before the first run: replace `defender_email_security_contact` in the tfvars only when you re-enable Defender; Defender is disabled by default here.

## 6. Sign in and run preflight checks

```powershell
az login --tenant "<tenant-id>" --use-device-code
az account set --subscription "<management-subscription-id>"
az account show --query "{tenantId:tenantId,subscriptionId:id,name:name}" --output table
az account list-locations --query "[?name=='saudiarabiaeast' || name=='uaenorth'].{Name:name,DisplayName:displayName}" --output table
```

Repeat the region check in the other subscriptions. Register required resource providers (`Microsoft.Network`, `Microsoft.Storage`, `Microsoft.ManagedIdentity`, `Microsoft.ContainerInstance`, `Microsoft.ContainerRegistry`, `Microsoft.App`, `Microsoft.OperationalInsights`, `Microsoft.Insights`, `Microsoft.Security`, `Microsoft.PolicyInsights`) in each subscription, for example:

```powershell
az provider register --subscription "<id>" --namespace Microsoft.ContainerInstance
```

Checklist:
- [ ] Correct tenant, four subscription IDs, parent management group, active `Owner` roles
- [ ] UAE North bootstrap and cross-border state/runner processing approved
- [ ] Saudi Arabia East services/SKUs (VPN gateway, Bastion, etc.) confirmed available
- [ ] Both PAT environment variables set; YAML PAT lines still commented
- [ ] Hub and bootstrap IP ranges do not overlap
- [ ] Inherited location policies allow the region split
- [ ] Disabled DDoS plan, Defender, Log Analytics and Private DNS Resolver are approved

## 7. Prepare the Saudi DNS module workaround (required before platform apply)

The pinned private-DNS module fails for Saudi Arabia East (null `geo_code`). Supply the fix **at bootstrap** so it lands in the generated platform repo:

1. Create `github\accelerator-8\config\modules`.
2. Extract [saudi-dns-modules.zip](saudi-dns-modules.zip) elsewhere, then copy the two folders `hub-and-spoke-vnet` and `private-link-private-dns-zones` into `config\modules` (no extra enclosing folder, do not copy the zip).
3. Download the raw file <https://github.com/Azure/alz-terraform-accelerator/blob/v17.7.0/templates/platform_landing_zone/main.connectivity.hub.and.spoke.virtual.network.tf> into `config\`, keeping the exact name (ensure it ends in `.tf`).
4. In that file, in `module "hub_and_spoke_vnet"`, set `source = "./modules/hub-and-spoke-vnet"` and delete the `version = "0.17.2"` line. Change nothing else.

Resulting layout:

```text
config\
  inputs.yaml
  platform-landing-zone.tfvars
  main.connectivity.hub.and.spoke.virtual.network.tf
  lib\...
  modules\hub-and-spoke-vnet\...
  modules\private-link-private-dns-zones\...
```

Skipping this means doing the [post-bootstrap fix](../../devops/accelerator-8/README.md#post-bootstrap-saudi-dns-module-fix) manually. The module copies and networking file are source files and may be committed here if you want them tracked.

## 8. Run the bootstrap

```powershell
$targetFolderPath = (Resolve-Path ".\github\accelerator-8").Path

terraform fmt -check "$targetFolderPath\config\platform-landing-zone.tfvars"
if ($LASTEXITCODE -ne 0) { throw "Fix the tfvars formatting first." }

Deploy-Accelerator `
    -inputs "$targetFolderPath\config\inputs.yaml", "$targetFolderPath\config\platform-landing-zone.tfvars" `
    -starterAdditionalFiles "$targetFolderPath\config\lib", `
                            "$targetFolderPath\config\modules", `
                            "$targetFolderPath\config\main.connectivity.hub.and.spoke.virtual.network.tf" `
    -output "$targetFolderPath\output"
```

Review the plan before typing `yes`:
- Bootstrap resources are in `uaenorth`; VNet ranges are `10.250.0.0/26` and `10.250.0.64/26`.
- Private endpoints and self-hosted runners are enabled.
- No unexpected deletions or replacements.

Bootstrap creates: state storage, federated identities (OIDC) for plan/apply, ACR and ACI runners, networking, the GitHub repositories (platform repo and a templates repo), workflows, environments, approvals and runner group.

If it fails, fix the cause and rerun with the same config and **preserved** output/state. Never delete the state. `output\` is git-ignored; keep it in a protected location and never commit it.

## 9. Verify GitHub and run the landing-zone workflow

In your GitHub organization:

1. Open the generated platform repository (named from `service_name`/`environment_name`, e.g. `alz-mgmt`) and the templates repository.
2. *Organization Settings > Actions > Runner groups*: the generated group shows your runners **online** (ACI start-up can take a few minutes).
3. Platform repo *Settings > Environments*: `plan` and `apply` exist; `apply` has your required reviewers.
4. Confirm the platform repo contains `modules/hub-and-spoke-vnet`, `modules/private-link-private-dns-zones`, the networking `source = "./modules/hub-and-spoke-vnet"` and the Saudi `locals.tf` (`saudiarabiaeast` returns `"sae"`).
5. Make changes by branch and pull request. Merging to `main` triggers the **CI** (validate) and **CD** workflows (names like *01 Azure Landing Zones Continuous Integration* and *02 Azure Landing Zones Continuous Delivery*) via *Actions*.
6. Open *Actions > 02 ... Continuous Delivery > Run workflow* on `main`.
7. Read the **plan** job. Check that regional resources target `saudiarabiaeast`, the Backup DNS zone is `privatelink.sae.backup.windowsazure.com`, no DDoS/Log Analytics/Defender/Private DNS Resolver resources appear, and nothing is unexpectedly destroyed.
8. An approver reviews and approves the `apply` environment deployment. Confirm success.

If CI/plan reports Saudi Arabia East as an unsupported location (AzureRM enhanced validation), add the repository/organization **variable** `ARM_PROVIDER_ENHANCED_VALIDATION=false`, or set it under `env:` in the templates repo workflow steps, as a documented temporary exception; see [the DevOps guide](../../devops/accelerator-8/README.md#azurerm-4x-rejects-the-saudi-location-before-contacting-the-resource-api).

## 10. Validate and operate

- Management group hierarchy and all four subscription placements are correct.
- Saudi platform resources are in `saudiarabiaeast`; bootstrap resources stay in `uaenorth`.
- Runners can reach the private state storage and registry; no public-storage or workstation-IP exception was added.
- Review policy compliance/remediation, then run another plan to confirm no drift.
- Separately deploy and configure the NVA (next hop `10.0.0.4`), DNS forwarding (the Private DNS Resolver is disabled), spoke peering and traffic tests before onboarding workloads.

For ongoing changes edit the **generated GitHub platform repo** via pull requests (not this documentation repo); changes here do not update an already bootstrapped environment.

Clean up and revoke PATs when done:

```powershell
Remove-Item Env:\TF_VAR_github_personal_access_token
Remove-Item Env:\TF_VAR_github_runners_personal_access_token
```

Revoke token 1 after bootstrap; keep a renewal process for token 2.

## Troubleshooting (GitHub-specific)

| Symptom | Checks |
| --- | --- |
| 401/403 or `Resource not accessible` during bootstrap | PAT permissions/expiry, org SSO authorization of the PAT, you are an org owner, YAML PAT lines still commented |
| Environment/approval creation fails | Org plan (free) does not support required reviewers on private repos |
| Runners offline / jobs queued | ACI logs, image pull from ACR via private endpoint, runner PAT validity, runner group repository access |
| ACI zone error in UAE North | Set `runner_container_zone_support: false` (and review the ACR zone-redundancy setting) if approved |
| Backend access denied | Private endpoint approval, DNS and routing from the runner; do not enable public storage access |
| `alz_custom` architecture not found | `-starterAdditionalFiles` must include `config\lib` |
| Null `replace` DNS error | Module workaround (step 7) missing from the platform repo commit that the workflow runs |
| ACR fails in Saudi Arabia East | `bootstrap_location` must remain `uaenorth` |

All other regional, DDoS, Defender, Log Analytics, DNS and Bastion troubleshooting is identical to the [DevOps guide](../../devops/accelerator-8/README.md#troubleshooting).

## References

- [Scenario 8](https://azure.github.io/Azure-Landing-Zones/accelerator/starter-terraform/scenarios/single-region-hub-and-spoke-vnet-with-nva/)
- [Accelerator planning](https://azure.github.io/Azure-Landing-Zones/accelerator/0_planning/) and [prerequisites](https://azure.github.io/Azure-Landing-Zones/accelerator/1_prerequisites/)
- [GitHub prerequisites and PAT scopes](https://azure.github.io/Azure-Landing-Zones/accelerator/1_prerequisites/github/)
- [GitHub bootstrap variables](https://github.com/Azure/accelerator-bootstrap-modules/blob/main/alz/github/variables.tf)
- [Running the pipeline](https://azure.github.io/Azure-Landing-Zones/accelerator/3_run/)
