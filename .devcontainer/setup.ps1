# Installs Pester and writes a first synthetic review so the console has a
# report.json to open straight away.
$ErrorActionPreference = 'Stop'
Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
Install-Module Pester -RequiredVersion 5.7.1 -Scope CurrentUser -Force -SkipPublisherCheck
& (Join-Path $PSScriptRoot '../scripts/Invoke-CatalogReview.ps1') -Synthetic -OutputDirectory (Join-Path $PSScriptRoot '../review') | Format-List
