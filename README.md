# Azure Landing Zones for Saudi Arabia East: Terraform scenarios

This repository documents and tracks Terraform [Azure Landing Zones (ALZ) accelerator](https://azure.github.io/Azure-Landing-Zones/accelerator/) scenarios adapted for **Saudi Arabia East**, for both **GitHub** and **Azure DevOps**. It holds the accelerator configuration files, the Saudi-specific customizations, and file-by-file runbooks explaining what was changed and why.

## Recommended starting point

> **If your team does not want to edit and assemble configuration files manually, start with Mohamed Selim's prewired packages.** They already contain the Saudi-specific customizations, a launcher script, and Word instructions explaining what changed and in which files. Download the one you need with **Code → Download ZIP**, fill in the customer inputs, and run the included launcher.
>
> | Platform | Hub-spoke NVA-ready | vWAN NVA-ready |
> | --- | --- | --- |
> | **GitHub** | [saudi-alz-github-hub-spoke-nva](https://github.com/moselim200/saudi-alz-github-hub-spoke-nva) | [saudi-alz-github-vwan-nva](https://github.com/moselim200/saudi-alz-github-vwan-nva) |
> | **Azure DevOps** | [saudi-alz-azuredevops-hub-spoke-nva](https://github.com/moselim200/saudi-alz-azuredevops-hub-spoke-nva) | [saudi-alz-azuredevops-vwan-nva](https://github.com/moselim200/saudi-alz-azuredevops-vwan-nva) |
>
> **Reported status (from the package owner, not independently verified):** both GitHub scenarios worked in the owner's testing; Azure DevOps vWAN testing is underway; Azure DevOps hub-spoke still needs end-to-end verification.

Customer-specific inputs and validation are still required with these packages. Read the [GitHub prerequisites](https://azure.github.io/Azure-Landing-Zones/accelerator/1_prerequisites/github/) or [Azure DevOps prerequisites](https://azure.github.io/Azure-Landing-Zones/accelerator/1_prerequisites/azuredevops/) before starting.

**Please test in a fresh, isolated environment and share your results and any issues**, including sanitized errors and pipeline links, without credentials, state files, or customer-sensitive information.

## What this repository adds

The packages above are fixed, ready-to-run profiles. This repository is the **reference and customization route**, for teams that need to understand, review, or change the configuration:

- **Runbooks** that explain every Saudi-specific change, its reason, and its limits.
- **Tracked source** for the configuration and module overlays, so changes can be reviewed and versioned.
- **Cross-checks** of each runbook against the packages above. Those packages are treated as **test references, not the source of truth**.
- For scenario 9, an **offline staged validation** (`tests\Invoke-StagedValidation.ps1`) that overlays the configuration on the pinned starter and runs `fmt`, `init`, `validate`, and mocked tests without Azure credentials.

## Scenarios

| Scenario | Azure DevOps | GitHub |
| --- | --- | --- |
| **8**: single-region hub and spoke VNet with NVA | [Runbook](devops/single-region-hub-and-spoke-vnet-with-nva/README.md) | [Runbook](github/single-region-hub-and-spoke-vnet-with-nva/README.md) |
| **9**: single-region Virtual WAN with NVA | [Runbook](devops/single-region-virtual-wan-with-nva/README.md) | [Runbook](github/single-region-virtual-wan-with-nva/README.md) |

Each runbook is independent: choose one topology and delivery platform, then follow that README from prerequisites through operations. No other scenario README is required.

```text
devops\<scenario>\    Azure DevOps: README, config (inputs, tfvars, lib, modules), tests
github\<scenario>\    GitHub: README, config (inputs, tfvars, lib, modules), tests
```

Each scenario's `config` folder is passed to the accelerator's `Deploy-Accelerator` command. The tfvars, library, and module overlay are shared between the two platforms; only `inputs.yaml` and the pipeline-specific steps differ.

## Design summary

- **Region split:** bootstrap resources (state, registry, agents or runners) and policy-assignment identities use **UAE North**, which may be changed to another region based on customer preference. Platform resources target **Saudi Arabia East**. Bootstrap data therefore leaves Saudi Arabia, which needs data-residency approval.
- **Saudi compatibility fixes:** a patched Private DNS module (the upstream region metadata has no Backup DNS code for Saudi Arabia East, so `sae` is supplied), a matching Corp DNS policy parameter, Bastion zones disabled, and a location-only AzureRM validation setting in the pipelines.
- **Reduced baseline:** central monitoring, automatic Defender enablement, DDoS, Azure Firewall, and the Private DNS Resolver are off in the tracked source; each runbook states how to re-enable them and the dependent policy changes.
- **Pinned versions:** ALZ module `7.1.5`, starter `v17.7.0`, Terraform `1.14.9`, bootstrap `v7.3.2`.

## Important limits

- These are **reduced NVA-ready foundations**, not deployed appliances, and **not production-ready baselines**. No NVA, license, spoke workload, or traffic routing to an appliance is created.
- The runbooks in this repository have **not been verified by an Azure deployment**. The scenario 9 offline validation uses mocked providers and does not prove regional availability, policy acceptance, quota, or RBAC.
- Service availability in Saudi Arabia East is subscription-specific. Recheck it before every deployment. The VPN gateway setting in both scenarios is not validated by any known deployment.
- Do not commit tokens, state files, plans, or generated output. The `.gitignore` files exclude them, but they cannot detect secrets inside valid source files.
