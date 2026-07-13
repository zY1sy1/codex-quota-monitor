[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$requirements = Import-PowerShellDataFile -LiteralPath (Join-Path $PSScriptRoot 'TestRequirements.psd1')
$moduleRoot = Join-Path $repoRoot $requirements.ModuleRoot
$pesterManifest = Join-Path $moduleRoot "Pester\$($requirements.PesterVersion)\Pester.psd1"

if (-not (Test-Path -LiteralPath $pesterManifest -PathType Leaf)) {
    New-Item -ItemType Directory -Path $moduleRoot -Force | Out-Null
    Save-Module -Name Pester -RequiredVersion $requirements.PesterVersion -Path $moduleRoot -Repository PSGallery
}

$pesterModule = Import-Module -Name $pesterManifest -Force -PassThru
if ($pesterModule.Version -ne [version]$requirements.PesterVersion) {
    throw "Expected Pester $($requirements.PesterVersion), but imported $($pesterModule.Version)."
}
