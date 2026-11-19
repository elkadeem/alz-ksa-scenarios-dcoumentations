
$alzModule = Get-InstalledPSResource -Name ALZ 2>$null
if (-not $alzModule) {
    Install-PSResource -Name ALZ
} else {
    Update-PSResource -Name ALZ
}

# add loop from 1 to 11 and create folder for each senario for landing zone
for ($scenarioNumber = 1; $scenarioNumber -le 11; $scenarioNumber++) {
$iacType = "terraform"  # Must be one of: "bicep" or "terraform"
$versionControl = "azure-devops"  # Must be one of: "azure-devops", "github", "local"
$scenarioNumber = $scenarioNumber  # Must be a number between 1 and 9 for Terraform only. Ignored for Bicep.
$targetFolderPath = "./devops/accelerator-$scenarioNumber" # Choose your target folder for the cached files
    New-AcceleratorFolderStructure `
        -iacType $iacType `
        -versionControl $versionControl `
        -scenarioNumber $scenarioNumber `
        -targetFolderPath $targetFolderPath
}