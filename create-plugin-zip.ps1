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

# Add snapshot suffix to version
$version = "$version-snapshot"

# Output filename
$zipName = "$pluginName-$version.zip"

Write-Host "Creating plugin ZIP archive: $zipName"
Write-Host "Plugin: $pluginName"
Write-Host "Version: $version"
Write-Host ""
Write-Host "NOTE: This creates a snapshot of the current working directory," -ForegroundColor Yellow
Write-Host "including uncommitted changes." -ForegroundColor Yellow
Write-Host ""

# Remove old ZIP if it exists
if (Test-Path $zipName) {
    Remove-Item $zipName -Force
}

Write-Host "Copying current working directory files..."

# Create temporary directory
$tempDir = Join-Path $env:TEMP "loxberry-plugin-$(Get-Random)"
$pluginDir = Join-Path $tempDir $pluginName
New-Item -ItemType Directory -Path $pluginDir -Force | Out-Null

# Define exclusion patterns
$excludeDirs = @('.git', '.github', '.idea', '.claude', 'node_modules', 'dev')
$excludeFiles = @('*.zip', '*.tar.gz', 'package.json', 'package-lock.json',
                  'create-plugin-zip.cmd', 'create-plugin-zip.sh', 'create-plugin-zip.ps1',
                  'create-plugin-zip.exclude', 'CLAUDE.md', '.gitignore')

# Copy all files except excluded ones
Get-ChildItem -Path . -Recurse | ForEach-Object {
    $relativePath = $_.FullName.Substring((Get-Location).Path.Length + 1)
    $shouldExclude = $false

    # Check if in excluded directory
    foreach ($excludeDir in $excludeDirs) {
        if ($relativePath -like "$excludeDir*") {
            $shouldExclude = $true
            break
        }
    }

    # Check if matches excluded file pattern
    if (-not $shouldExclude -and -not $_.PSIsContainer) {
        foreach ($excludeFile in $excludeFiles) {
            if ($_.Name -like $excludeFile) {
                $shouldExclude = $true
                break
            }
        }
    }

    if (-not $shouldExclude) {
        $destPath = Join-Path $pluginDir $relativePath
        if ($_.PSIsContainer) {
            if (-not (Test-Path $destPath)) {
                New-Item -ItemType Directory -Path $destPath -Force | Out-Null
            }
        } else {
            $destDir = Split-Path -Parent $destPath
            if (-not (Test-Path $destDir)) {
                New-Item -ItemType Directory -Path $destDir -Force | Out-Null
            }
            Copy-Item $_.FullName -Destination $destPath -Force
        }
    }
}

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