#
# Creates a ZIP archive containing only files tracked by Git
# This archive can be uploaded to LoxBerry for testing
#

# Get the plugin name from plugin.cfg
$pluginName = (Get-Content plugin.cfg | Select-String -Pattern "^FOLDER=" | ForEach-Object { $_ -replace "^FOLDER=", "" }).Trim()
if ([string]::IsNullOrEmpty($pluginName)) {
    $pluginName = "bmw-cardata"
}

# Get version from plugin.cfg
$version = (Get-Content plugin.cfg | Select-String -Pattern "^VERSION=" | ForEach-Object { $_ -replace "^VERSION=", "" }).Trim()
if ([string]::IsNullOrEmpty($version)) {
    $version = "dev"
}

# Output filename
$zipName = "$pluginName-$version.zip"

Write-Host "Creating plugin ZIP archive: $zipName"
Write-Host "Plugin: $pluginName"
Write-Host "Version: $version"
Write-Host ""

# Remove old ZIP if it exists
if (Test-Path $zipName) {
    Remove-Item $zipName -Force
}

Write-Host "Copying Git-tracked files..."

# Create temporary directory
$tempDir = Join-Path $env:TEMP "loxberry-plugin-$(Get-Random)"
$pluginDir = Join-Path $tempDir $pluginName
New-Item -ItemType Directory -Path $pluginDir -Force | Out-Null

# Use git archive to export all tracked files to the plugin directory
# git archive creates a tar by default, which we pipe directly to tar for extraction
git archive HEAD | tar -x -C $pluginDir

# Create ZIP archive using tar (more compatible with Unix systems than Compress-Archive)
# tar on Windows 10+ supports creating ZIP files
$originalDir = $PSScriptRoot
$zipPath = Join-Path $originalDir $zipName

Push-Location $tempDir
tar -c -f $zipPath --format=zip $pluginName
Pop-Location

# Cleanup
Remove-Item $tempDir -Recurse -Force

Write-Host ""
Write-Host "Successfully created: $zipName" -ForegroundColor Green
Write-Host ""

$zipFile = Get-Item (Join-Path $originalDir $zipName)
Write-Host "File size: $([math]::Round($zipFile.Length / 1KB, 2)) KB"
Write-Host ""
Write-Host "You can now upload this file to LoxBerry for testing."