# Nexus Universal Continuity - Windows One-Click Build Script
$ErrorActionPreference = "Stop"

Write-Host "=====================================================" -ForegroundColor Cyan
Write-Host "   Nexus Universal Continuity - Windows Build Script " -ForegroundColor Cyan
Write-Host "=====================================================" -ForegroundColor Cyan

# 1. Setup Rust PATH & Stop running processes
Stop-Process -Name "nexus_ui", "nexus-daemon" -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 500
$env:Path = "$env:USERPROFILE\.cargo\bin;" + $env:Path

# 2. Build Rust Core & FFI in Release Mode
Write-Host "`n[1/4] Compiling Rust Workspace in Release Mode..." -ForegroundColor Yellow
cargo build --workspace --release

# 3. Create Distribution Directory
$DistDir = "$PSScriptRoot\..\dist\windows"
if (Test-Path $DistDir) { Remove-Item -Recurse -Force $DistDir }
New-Item -ItemType Directory -Force -Path $DistDir | Out-Null

# Copy Daemon and FFI DLL
Copy-Item "$PSScriptRoot\..\target\release\nexus-daemon.exe" "$DistDir\"
Copy-Item "$PSScriptRoot\..\target\release\nexus_ffi.dll" "$DistDir\"

Write-Host " -> Copied nexus-daemon.exe and nexus_ffi.dll to $DistDir" -ForegroundColor Green

# 4. Build Flutter Desktop Application
Write-Host "`n[2/4] Building Flutter Windows Desktop App..." -ForegroundColor Yellow
Set-Location "$PSScriptRoot\..\apps\nexus_ui"
flutter build windows --release

# Copy Flutter build outputs
$FlutterReleaseDir = "$PSScriptRoot\..\apps\nexus_ui\build\windows\x64\runner\Release"
if (Test-Path $FlutterReleaseDir) {
    Copy-Item "$FlutterReleaseDir\*" "$DistDir\" -Recurse -Force
    Copy-Item "$PSScriptRoot\..\target\release\nexus_ffi.dll" "$DistDir\" -Force
}

# 5. Pack Browser Extension
Write-Host "`n[3/4] Packaging Browser WebExtension..." -ForegroundColor Yellow
$ExtDistDir = "$PSScriptRoot\..\dist\extensions"
$ExtUnpackedDir = "$ExtDistDir\nexus_browser_ext_v1.0.0"
if (Test-Path $ExtUnpackedDir) { Remove-Item -Recurse -Force $ExtUnpackedDir }
New-Item -ItemType Directory -Force -Path $ExtUnpackedDir | Out-Null
Copy-Item "$PSScriptRoot\..\extensions\nexus_browser_ext\*" "$ExtUnpackedDir\" -Recurse -Force

if (Test-Path "$ExtDistDir\nexus_browser_ext_v1.0.0.zip") { Remove-Item -Force "$ExtDistDir\nexus_browser_ext_v1.0.0.zip" }
Compress-Archive -Path "$PSScriptRoot\..\extensions\nexus_browser_ext\*" -DestinationPath "$ExtDistDir\nexus_browser_ext_v1.0.0.zip" -Force

# 6. Summary
Write-Host "`n[4/4] Build Completed Successfully!" -ForegroundColor Green
Write-Host "-----------------------------------------------------" -ForegroundColor Cyan
Write-Host "Outputs located in: $DistDir" -ForegroundColor Cyan
Write-Host " - nexus-daemon.exe (Background service)"
Write-Host " - nexus_ui.exe     (Flutter GUI Application)"
Write-Host " - nexus_ffi.dll    (Real-time FFI Core)"
Write-Host " - dist/extensions/nexus_browser_ext_v1.0.0.zip"
Write-Host "-----------------------------------------------------" -ForegroundColor Cyan
