<#
.SYNOPSIS
    Git AI kurumsal (offline) kurulum scripti - Windows.

.DESCRIPTION
    Paketle birlikte gelen git-ai.exe'yi internete cikmadan kullanicinin
    %USERPROFILE%\.git-ai\bin klasorune kurar, IDE/agent hook'larini ve git
    trace2 ayarini yapar, oturum acilisinda arka plan servisini baslatan
    zamanlanmis gorevi kaydeder.

    KULLANICI BAGLAMINDA calistirilmalidir (yonetici olarak da calisabilir).
    Intune: "Install behavior = User". SCCM: "Install for user".
    SYSTEM hesabiyla calistirilirsa hata verip cikar.

.PARAMETER ApiBase
    Opsiyonel. Kurumsal Git AI API adresi (api_base_url).

.PARAMETER ApiKey
    Opsiyonel. Kurumsal Git AI API anahtari (api_key).

.PARAMETER EnableAutoUpdates
    Verilmezse otomatik guncelleme kapatilir; surum IT tarafindan yonetilir.

.PARAMETER SkipLoginTask
    Oturum acilisinda servisi baslatan zamanlanmis gorevi kaydetme.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File Install-GitAi.ps1

.NOTES
    Cikis kodlari: 0 = basarili, 1 = hata. Log: %TEMP%\git-ai-deploy\install-*.log
#>
[CmdletBinding()]
param(
    [string]$ApiBase,
    [string]$ApiKey,
    [switch]$EnableAutoUpdates,
    [switch]$SkipLoginTask
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$PackageDir = $PSScriptRoot
$BundledExe = Join-Path $PackageDir 'git-ai.exe'
$BundledInstaller = Join-Path $PackageDir 'scripts\install.ps1'
$BundledLoginStart = Join-Path $PackageDir 'scripts\install-login-start.ps1'
$InstallDir = Join-Path $HOME '.git-ai\bin'
$InstalledExe = Join-Path $InstallDir 'git-ai.exe'

$LogDir = Join-Path $env:TEMP 'git-ai-deploy'
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$LogPath = Join-Path $LogDir ("install-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))
Start-Transcript -Path $LogPath -Force | Out-Null

function Fail([string]$Message) {
    Write-Host "HATA: $Message" -ForegroundColor Red
    Stop-Transcript | Out-Null
    exit 1
}

function Invoke-ChildPowerShell([string]$Script, [string[]]$Arguments = @()) {
    & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Script @Arguments | Out-Host
    return $LASTEXITCODE
}

function Invoke-GitAi([string[]]$Arguments) {
    & $InstalledExe @Arguments | Out-Host
    if ($LASTEXITCODE -ne 0) {
        Fail "git-ai $($Arguments[0..2] -join ' ') basarisiz (cikis kodu $LASTEXITCODE)"
    }
}

try {
    # --- On kontroller -----------------------------------------------------
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    $isElevated = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

    # Kim olarak calistigimizi her zaman goster (hata durumunda da loga girsin)
    Write-Host '--- whoami ----------------------------------------------'
    Write-Host ("Kullanici   : {0}" -f (& whoami.exe))
    Write-Host ("SID         : {0}" -f $identity.User.Value)
    Write-Host ("Bilgisayar  : {0}" -f $env:COMPUTERNAME)
    Write-Host ("Profil      : {0}" -f $HOME)
    Write-Host ("SYSTEM      : {0}" -f $(if ($identity.IsSystem) { 'Evet' } else { 'Hayir' }))
    Write-Host ("Yonetici    : {0}" -f $(if ($isElevated) { 'Evet (elevated)' } else { 'Hayir' }))
    Write-Host ("Log         : {0}" -f $LogPath)
    Write-Host '---------------------------------------------------------'

    if ($identity.IsSystem) {
        Fail 'Script SYSTEM hesabiyla calisiyor. Git AI kullanici bazinda kurulur; dagitimi kullanici baglaminda (Intune: Install behavior = User) yapin.'
    }
    if ($isElevated) {
        # Yonetici olarak calismaya izin verilir; install.ps1'in uyarisini bastir.
        $env:GIT_AI_ALLOW_SUPERUSER = '1'
    }
    foreach ($f in @($BundledExe, $BundledInstaller, $BundledLoginStart)) {
        if (-not (Test-Path -LiteralPath $f)) { Fail "Paket dosyasi eksik: $f" }
    }
    if (-not (Get-Command git.exe -ErrorAction SilentlyContinue)) {
        Write-Warning 'git.exe PATH uzerinde bulunamadi. Git for Windows kurulu degilse Git AI calismaz; once Git kurulmalidir.'
    }

    $packageVersion = "$(& $BundledExe --version)".Trim()
    Write-Host "Git AI $packageVersion kuruluyor -> $InstallDir"

    # --- 1) Binary kopyalama + hook kurulumu (repo'daki install.ps1 ile) ----
    # GIT_AI_LOCAL_BINARY: indirme yapmadan paketteki exe'yi kullanir. Calisan
    # bir daemon varsa install.ps1 onu durdurup dosyanin serbest kalmasini bekler.
    # Not: GIT_AI_SKIP_PATH_UPDATE AYARLANMAMALI; install-hooks --env de bu
    # degiskene bakar ve kalici kullanici PATH'ini atlar.
    $env:GIT_AI_LOCAL_BINARY = $BundledExe
    Remove-Item Env:\GIT_AI_SKIP_PATH_UPDATE -ErrorAction SilentlyContinue
    $code = Invoke-ChildPowerShell $BundledInstaller
    Remove-Item Env:\GIT_AI_LOCAL_BINARY -ErrorAction SilentlyContinue
    if ($code -ne 0) { Fail "install.ps1 basarisiz (cikis kodu $code)" }
    if (-not (Test-Path -LiteralPath $InstalledExe)) { Fail "$InstalledExe olusmadi" }

    # --- 2) Kurumsal ayarlar ----------------------------------------------
    $autoUpdatesDisabled = if ($EnableAutoUpdates) { 'false' } else { 'true' }
    Invoke-GitAi @('config', 'set', 'disable_auto_updates', $autoUpdatesDisabled)
    Invoke-GitAi @('config', 'set', 'disable_version_checks', $autoUpdatesDisabled)
    if ($ApiBase) { Invoke-GitAi @('config', 'set', 'api_base_url', $ApiBase) }
    if ($ApiKey) { Invoke-GitAi @('config', 'set', 'api_key', $ApiKey) }

    # --- 3) Oturum acilisinda arka plan servisini baslat --------------------
    if (-not $SkipLoginTask) {
        $code = Invoke-ChildPowerShell $BundledLoginStart @('install', '--bin', $InstalledExe)
        if ($code -ne 0) { Fail "Oturum acilis gorevi kaydedilemedi (cikis kodu $code)" }
    }

    # --- 4) Dogrulama --------------------------------------------------------
    $installedVersion = "$(& $InstalledExe --version)".Trim()
    if ($installedVersion -ne $packageVersion) {
        Fail "Kurulu surum ($installedVersion) paket surumuyle ($packageVersion) eslesmiyor"
    }

    Write-Host "Git AI $installedVersion basariyla kuruldu. Terminal ve IDE'lerin yeniden acilmasi gerekir." -ForegroundColor Green
    Stop-Transcript | Out-Null
    exit 0
} catch {
    Fail $_.Exception.Message
}
