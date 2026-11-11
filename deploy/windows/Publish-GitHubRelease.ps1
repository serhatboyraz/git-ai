<#
.SYNOPSIS
    dist altindaki Windows dagitim zip'ini GitHub Releases'e yukler.

.DESCRIPTION
    dist\git-ai-<surum>-windows-x64.zip dosyasini v<surum> etiketli release'e ekler.
    Release yoksa olusturur, varsa zip'i uzerine yazar. GitHub CLI (gh) ile calisir;
    once "gh auth login" yapilmis olmali.

.EXAMPLE
    # Cargo.toml'daki surumu yayinlar:
    powershell -ExecutionPolicy Bypass -File deploy\windows\Publish-GitHubRelease.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File deploy\windows\Publish-GitHubRelease.ps1 -Version 1.8.0 -Draft
#>
[CmdletBinding()]
param(
    [string]$Version,
    [string]$Repo,
    [string]$DistDir,
    [string]$Target,
    [switch]$Draft,
    [switch]$Prerelease
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
if (-not $DistDir) { $DistDir = Join-Path $RepoRoot 'dist' }

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw 'GitHub CLI (gh) bulunamadi: https://cli.github.com' }

function Invoke-Git {
    $out = & git -c "safe.directory=$($RepoRoot.Replace('\', '/'))" -C $RepoRoot @args
    if ($LASTEXITCODE -ne 0) { throw "git $($args -join ' ') basarisiz (cikis kodu $LASTEXITCODE)" }
    "$out".Trim()
}

if (-not $Version) {
    $cargo = Get-Content -Raw (Join-Path $RepoRoot 'Cargo.toml')
    if ($cargo -notmatch '(?m)^version\s*=\s*"([^"]+)"') { throw 'Cargo.toml icinde surum bulunamadi' }
    $Version = $Matches[1]
}
$Version = $Version.TrimStart('v')
if ($Version -notmatch '^\d+\.\d+\.\d+') { throw "Gecersiz surum: '$Version'" }

if (-not $Repo) {
    $url = Invoke-Git remote get-url origin
    if ($url -notmatch 'github\.com[:/](.+?)(\.git)?$') { throw "origin bir GitHub adresi degil: $url (-Repo owner/name verin)" }
    $Repo = $Matches[1]
}
if (-not $Target) { $Target = Invoke-Git rev-parse HEAD }

$tag = "v$Version"
$zipPath = Join-Path $DistDir "git-ai-$Version-windows-x64.zip"
if (-not (Test-Path -LiteralPath $zipPath)) {
    throw "Paket bulunamadi: $zipPath (once deploy\windows\Build-ItPackage.ps1 calistirin)"
}
$zipHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $zipPath).Hash.ToLower()

$tags = & gh release list --repo $Repo --limit 1000 --json tagName --jq '.[].tagName'
if ($LASTEXITCODE -ne 0) { throw "Release listesi alinamadi: $Repo (gh auth status ile kontrol edin)" }

if (@($tags) -contains $tag) {
    Write-Host "Release $tag mevcut, zip guncelleniyor..."
    & gh release upload $tag $zipPath --repo $Repo --clobber
    if ($LASTEXITCODE -ne 0) { throw "Zip yuklenemedi (cikis kodu $LASTEXITCODE)" }
}
else {
    $notes = @(
        "Git AI $Version - Windows x64 dagitim paketi.",
        '',
        'Kurulum: zip''i acip `install.cmd` calistirin. Ayrintilar paketteki `README.md` dosyasinda.',
        '',
        "SHA256 (``$(Split-Path -Leaf $zipPath)``): ``$zipHash``"
    ) -join "`n"

    $ghArgs = @('release', 'create', $tag, $zipPath, '--repo', $Repo, '--target', $Target,
        '--title', "Git AI $Version", '--notes', $notes)
    if ($Draft) { $ghArgs += '--draft' }
    if ($Prerelease) { $ghArgs += '--prerelease' }

    Write-Host "Release $tag olusturuluyor ($Repo @ $Target)..."
    & gh @ghArgs
    if ($LASTEXITCODE -ne 0) { throw "Release olusturulamadi (cikis kodu $LASTEXITCODE). Commit push edildi mi?" }
}

Write-Host "Zip:        $zipPath"
Write-Host "Zip SHA256: $zipHash"
Write-Host "Release:    https://github.com/$Repo/releases/tag/$tag"
