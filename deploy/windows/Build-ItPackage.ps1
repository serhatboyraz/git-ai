<#
.SYNOPSIS
    IT'ye verilecek Windows dagitim paketini (klasor + zip) olusturur.

.EXAMPLE
    # Repo kokunden, release build sonrasi:
    powershell -ExecutionPolicy Bypass -File deploy\windows\Build-ItPackage.ps1
#>
[CmdletBinding()]
param(
    [string]$BinaryPath,
    [string]$OutputDir
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
if (-not $BinaryPath) { $BinaryPath = Join-Path $RepoRoot 'dist\git-ai.exe' }
if (-not $OutputDir) { $OutputDir = Join-Path $RepoRoot 'dist' }
if (-not (Test-Path -LiteralPath $BinaryPath)) { throw "Binary bulunamadi: $BinaryPath (once cargo build --release)" }

$version = "$(& $BinaryPath --version)".Trim()
if ($version -notmatch '^\d+\.\d+\.\d+') { throw "Surum okunamadi: '$version'" }

$name = "git-ai-$version-windows-x64"
$pkgDir = Join-Path $OutputDir $name
$zipPath = "$pkgDir.zip"

if (Test-Path -LiteralPath $pkgDir) { Remove-Item -LiteralPath $pkgDir -Recurse -Force }
if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
New-Item -ItemType Directory -Force -Path (Join-Path $pkgDir 'scripts') | Out-Null

function Write-Text([string]$Path, [string]$Content, [switch]$Crlf, [switch]$Bom) {
    $text = $Content -replace "`r?`n", $(if ($Crlf) { "`r`n" } else { "`n" })
    [IO.File]::WriteAllText($Path, $text, (New-Object Text.UTF8Encoding($Bom.IsPresent)))
}

Copy-Item -LiteralPath $BinaryPath -Destination (Join-Path $pkgDir 'git-ai.exe')

# Paket scriptleri (PowerShell 5.1 icin CRLF + UTF-8 BOM)
foreach ($f in 'Install-GitAi.ps1', 'Uninstall-GitAi.ps1') {
    Write-Text (Join-Path $pkgDir $f) (Get-Content -Raw (Join-Path $PSScriptRoot $f)) -Crlf -Bom
}
$detect = (Get-Content -Raw (Join-Path $PSScriptRoot 'Detect-GitAi.ps1')).Replace('__GIT_AI_VERSION__', $version)
Write-Text (Join-Path $pkgDir 'Detect-GitAi.ps1') $detect -Crlf -Bom
foreach ($f in 'install.cmd', 'uninstall.cmd') {
    Write-Text (Join-Path $pkgDir $f) (Get-Content -Raw (Join-Path $PSScriptRoot $f)) -Crlf
}
$readme = (Get-Content -Raw -Encoding UTF8 (Join-Path $PSScriptRoot 'README.md')).Replace('__GIT_AI_VERSION__', $version)
Write-Text (Join-Path $pkgDir 'README.md') $readme -Crlf

# Repo'daki mevcut kurulum scriptleri (degistirilmeden)
Write-Text (Join-Path $pkgDir 'scripts\install.ps1') (Get-Content -Raw (Join-Path $RepoRoot 'install.ps1')) -Crlf -Bom
Write-Text (Join-Path $pkgDir 'scripts\install-login-start.ps1') `
    (Get-Content -Raw (Join-Path $RepoRoot 'mdm\windows\install-login-start.ps1')) -Crlf -Bom

# SHA256 ozetleri
$sums = Get-ChildItem -LiteralPath $pkgDir -Recurse -File | Sort-Object FullName | ForEach-Object {
    $rel = $_.FullName.Substring($pkgDir.Length + 1).Replace('\', '/')
    '{0}  {1}' -f (Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash.ToLower(), $rel
}
Write-Text (Join-Path $pkgDir 'SHA256SUMS.txt') (($sums -join "`n") + "`n") -Crlf

Compress-Archive -Path (Join-Path $pkgDir '*') -DestinationPath $zipPath
$zipHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $zipPath).Hash.ToLower()

Write-Host "Paket klasoru: $pkgDir"
Write-Host "Zip:           $zipPath"
Write-Host "Zip SHA256:    $zipHash"
