#Requires -Version 7.0
<#
.SYNOPSIS
Offline validation of this scenario's configuration against the pinned starter. No Azure sign-in needed.

.DESCRIPTION
Clones the pinned starter into a temporary folder, overlays config\lib, config\modules, the networking file and
the tfvars (as the accelerator bootstrap does), then runs fmt, init -backend=false, validate and the mocked
terraform tests (the starter's own plus tests\saudi_profile.tftest.hcl). Nothing in this repository is changed.
#>
[CmdletBinding()]
param(
  [string]$TerraformPath = "terraform",
  [string]$StarterVersion = "v17.7.0",
  [string]$TerraformVersion = "1.14.9",
  [string]$StarterRepositoryPath,
  [switch]$KeepStage
)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $false
$scenario = Split-Path -Parent $PSScriptRoot
$config = Join-Path $scenario "config"
$terraform = (Get-Command $TerraformPath -ErrorAction Stop).Source

$installed = (& $terraform version -json | ConvertFrom-Json).terraform_version
if ($installed -ne $TerraformVersion) {
  throw "Terraform $TerraformVersion is required to match the pipeline (found $installed). Pass -TerraformPath."
}

function Invoke-Step([string]$Name, [scriptblock]$Action) {
  Write-Host "== $Name"
  & $Action
  if ($LASTEXITCODE -ne 0) { throw "$Name failed (exit $LASTEXITCODE)." }
}

$work = Join-Path ([IO.Path]::GetTempPath()) ("alz-stage-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
try {
  New-Item -ItemType Directory $work -Force | Out-Null
  if ($StarterRepositoryPath) {
    # An existing clone of Azure/alz-terraform-accelerator checked out at $StarterVersion.
    $source = (Resolve-Path $StarterRepositoryPath).Path
  } else {
    $source = Join-Path $work "src"
    Invoke-Step "Clone starter $StarterVersion" {
      git clone --quiet --depth 1 --branch $StarterVersion https://github.com/Azure/alz-terraform-accelerator.git $source
    }
  }
  $stage = Join-Path $work "platform_landing_zone"
  Copy-Item (Join-Path $source "templates\platform_landing_zone") $stage -Recurse

  # Match the bootstrap's additional-file handling: folders merge by name, files overwrite by filename.
  Copy-Item (Join-Path $config "lib\*") (Join-Path $stage "lib") -Recurse -Force
  Copy-Item (Join-Path $config "modules\*") (Join-Path $stage "modules") -Recurse -Force
  Get-ChildItem $config -Filter "main.*.tf" -File | Copy-Item -Destination $stage -Force
  Copy-Item (Join-Path $config "platform-landing-zone.tfvars") (Join-Path $stage "platform-landing-zone.auto.tfvars") -Force
  Copy-Item (Join-Path $PSScriptRoot "*.tftest.hcl") (Join-Path $stage "tests") -Force

  Invoke-Step "terraform fmt -check" { & $terraform "-chdir=$stage" fmt -check -recursive -no-color }
  Invoke-Step "terraform init -backend=false" { & $terraform "-chdir=$stage" init -backend=false -input=false -no-color }
  Invoke-Step "terraform validate" { & $terraform "-chdir=$stage" validate -no-color }
  Invoke-Step "terraform test (mocked providers)" { & $terraform "-chdir=$stage" test -no-color }
  Write-Host "PASS: staged root validated. This is not an authenticated plan and does not check Azure availability."
}
finally {
  if ($KeepStage) { Write-Host "Stage kept at $work" }
  elseif (Test-Path $work) { Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue }
}
