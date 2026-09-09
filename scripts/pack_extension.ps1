# Pack Nexus Browser WebExtension for Chrome/Firefox/Edge
$ErrorActionPreference = "Stop"

$ExtDir = "$PSScriptRoot\..\extensions\nexus_browser_ext"
$DistDir = "$PSScriptRoot\..\dist\extensions"
New-Item -ItemType Directory -Force -Path $DistDir | Out-Null

$ZipFile = "$DistDir\nexus_browser_ext_v1.0.0.zip"
if (Test-Path $ZipFile) { Remove-Item -Force $ZipFile }

Compress-Archive -Path "$ExtDir\*" -DestinationPath $ZipFile -Force
Write-Host "Browser WebExtension packaged to: $ZipFile" -ForegroundColor Green
