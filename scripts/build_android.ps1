# Nexus Universal Continuity - Android Build Script
$ErrorActionPreference = "Stop"

Write-Host "=====================================================" -ForegroundColor Cyan
Write-Host "   Nexus Universal Continuity - Android Build Script " -ForegroundColor Cyan
Write-Host "=====================================================" -ForegroundColor Cyan

# 1. Setup Rust PATH
$env:Path = "$env:USERPROFILE\.cargo\bin;" + $env:Path

# 2. Build Flutter Android Release APK
Write-Host "`n[1/2] Building Android Release APK..." -ForegroundColor Yellow
Set-Location "$PSScriptRoot\..\apps\nexus_ui"
flutter build apk --release

# 3. Copy APK to Dist
$DistDir = "$PSScriptRoot\..\dist\android"
New-Item -ItemType Directory -Force -Path $DistDir | Out-Null
Copy-Item "$PSScriptRoot\..\apps\nexus_ui\build\app\outputs\flutter-apk\app-release.apk" "$DistDir\nexus-continuity-release.apk" -Force

Write-Host "`n[2/2] Android APK Build Completed Successfully!" -ForegroundColor Green
Write-Host "Output: $DistDir\nexus-continuity-release.apk" -ForegroundColor Cyan
