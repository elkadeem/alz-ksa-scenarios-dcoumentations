# Scenario 8: Saudi Arabia landing zone with Terraform and GitHub

Deploy a **single-region hub and spoke virtual network prepared for a Network Virtual Appliance (NVA)** with the Azure Landing Zones accelerator, private bootstrap networking, and self-hosted GitHub Actions runners on Azure Container Instances (ACI).

This is the GitHub counterpart of the [Azure DevOps runbook](../../devops/single-region-hub-and-spoke-vnet-with-nva/README.md). The platform design is identical; only the version-control system, tokens, bootstrap inputs, pipeline mechanics, and the provider-validation workaround differ.

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

### What is shared with the DevOps scenario

These files are byte-identical copies of the DevOps scenario because they do not depend on the version-control system:

| Path | Content |
| --- | --- |
| [config/platform-landing-zone.tfvars](config/platform-landing-zone.tfvars) | Regions, resource flags, policy defaults and modifications, hub/NVA addressing |
| [config/lib/](config/lib/) | Custom ALZ library and policy-removal lists |
| [config/modules/](config/modules/) and [config/main.connectivity.hub.and.spoke.virtual.network.tf](config/main.connectivity.hub.and.spoke.virtual.network.tf) | 48-file hub-and-spoke `v0.17.2` / private DNS `v0.23.2` overlay with the Saudi DNS fix |

The rationale for every setting in those files is in the DevOps README, sections 4 to 6. Do not restate or fork it here: when it changes, update both scenarios (see the drift check in section 6).

Only [config/inputs.yaml](config/inputs.yaml) and this README are GitHub-specific.

## 2. Prepare permissions, tools, and GitHub

### Azure prerequisites

Identical to the DevOps scenario: four platform subscriptions (Management, Connectivity, Identity, Security) in one Microsoft Entra tenant, an existing parent management group (or the Tenant Root Group), and an account with `Owner` on that management group and every platform subscription, including the bootstrap subscription (activate PIM roles first). Inherited allowed-location policies must permit UAE North and Saudi Arabia East, or have approved scope-specific exemptions.

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

These files are already complete and identical to the DevOps scenario. Edit them only for deliberate changes, using the DevOps README sections 4 and 5 for the reasoning. The settings to keep consistent:

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

Confirm the shared files still match the DevOps scenario, unless a difference is deliberate:

```powershell
$gh = "$targetFolderPath\config"
$ado = "D:\workarea\Source\alz\terraform\devops\single-region-hub-and-spoke-vnet-with-nva\config"
$names = "platform-landing-zone.tfvars", "main.connectivity.hub.and.spoke.virtual.network.tf"
foreach ($name in $names) {
    "{0}: {1}" -f $name, ((Get-FileHash "$gh\$name").Hash -eq (Get-FileHash "$ado\$name").Hash)
}
foreach ($folder in "lib", "modules") {
    $a = Get-ChildItem "$gh\$folder" -Recurse -File | Get-FileHash | ForEach-Object { "$($_.Path.Substring($gh.Length))=$($_.Hash)" }
    $b = Get-ChildItem "$ado\$folder" -Recurse -File | Get-FileHash | ForEach-Object { "$($_.Path.Substring($ado.Length))=$($_.Hash)" }
    "{0}: {1}" -f $folder, -not (Compare-Object $a $b)
}
```

### Authentication and design gates

```powershell
az login --tenant "<tenant-id>" --use-device-code
az account set --subscription "<management-subscription-id>"
az account show --query "{tenantId:tenantId,subscriptionId:id,name:name}" --output table
az account list-locations `
    --query "[?name=='saudiarabiaeast' || name=='uaenorth'].{Name:name,DisplayName:displayName}" `
    --output table
```

Repeat service/SKU/quota checks in the relevant subscriptions; region visibility alone is insufficient. For enabled DDoS, check `ddosProtectionPlans` availability in Saudi Arabia East as in the DevOps README, section 7.

Before bootstrap, confirm:

- [ ] Folder, subscription inputs, placements, bootstrap subscription, tenant, and parent management group agree.
- [ ] Azure permissions/PIM, provider registrations, GitHub organization-owner rights, repository-name availability, and both PAT variables are ready.
- [ ] The GitHub plan, repository visibility (public on Free), and outside-contributor workflow approval policy are approved.
- [ ] `apply_approvers` contains real approvers.
- [ ] Regional split, cross-border state/runners, policy exceptions, SKUs, capacity, and address ranges are approved.
- [ ] Provider-validation workaround delivery (Option A or B) is chosen.
- [ ] Bastion zones are `[]`; VPN and Bastion deployment are approved.
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

Use the DevOps README section 8 list, which applies unchanged: no null `replace` or SQL casing errors; Backup zone `privatelink.sae.backup.windowsazure.com`; auto-registration `saudiarabiaeast.azure.local`; platform resources in Saudi Arabia East, bootstrap in UAE North, policy identities per design; no management workspace/DCRs/AMA identity; no Private DNS Resolver or ExpressRoute gateway; VPN and Bastion enabled without Bastion zones; DDoS matching the chosen variant; no unexpected deletions, replacements, or permission changes. Only an authorized approver approves the plan.

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
| Null `replace`, Bastion zone, SQL casing, DNS map errors | Same causes and fixes as the DevOps README troubleshooting table. |
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
- The [Azure DevOps runbook](../../devops/single-region-hub-and-spoke-vnet-with-nva/README.md) for the full policy, DNS, Bastion, and addressing rationale.
