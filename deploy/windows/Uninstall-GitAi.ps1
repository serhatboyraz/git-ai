<#
.SYNOPSIS
    Git AI kurumsal kaldirma scripti - Windows.

.DESCRIPTION
    Kurulum scriptinin yaptiklarini geri alir: IDE/agent hook'lari, oturum
    acilis gorevi, arka plan servisi, git trace2 ayari, kullanici PATH girdisi
    ve %USERPROFILE%\.git-ai\bin klasoru.
    Kullanici baglaminda, yukseltilmemis calistirilmalidir.

.PARAMETER Purge
    Ayarlar, loglar ve calisma verisi dahil %USERPROFILE%\.git-ai klasorunun
    tamamini siler.

.NOTES
    Cikis kodlari: 0 = basarili, 1 = hata. Log: %TEMP%\git-ai-deploy\uninstall-*.log
#>
[CmdletBinding()]
param(
    [switch]$Purge
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$PackageDir = $PSScriptRoot
$BundledLoginStart = Join-Path $PackageDir 'scripts\install-login-start.ps1'
$GitAiHome = Join-Path $HOME '.git-ai'
$InstallDir = Join-Path $GitAiHome 'bin'
$InstalledExe = Join-Path $InstallDir 'git-ai.exe'

$LogDir = Join-Path $env:TEMP 'git-ai-deploy'
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$LogPath = Join-Path $LogDir ("uninstall-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))
Start-Transcript -Path $LogPath -Force | Out-Null

function Fail([string]$Message) {
    Write-Host "HATA: $Message" -ForegroundColor Red
    Stop-Transcript | Out-Null
    exit 1
}

function Normalize([string]$Path) {
    try { return ([IO.Path]::GetFullPath($Path.Trim())).TrimEnd('\').ToLowerInvariant() }
    catch { return $Path.Trim().TrimEnd('\').ToLowerInvariant() }
}

try {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    if ($identity.IsSystem) {
        Fail 'Script SYSTEM hesabiyla calisiyor; kullanici baglaminda calistirin.'
    }

    # 1) Oturum acilis gorevi
    if (Test-Path -LiteralPath $BundledLoginStart) {
        & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $BundledLoginStart --uninstall | Out-Host
    } else {
        Unregister-ScheduledTask -TaskPath '\GitAI\' -TaskName 'Start bg at logon' -Confirm:$false -ErrorAction SilentlyContinue
    }

    if (Test-Path -LiteralPath $InstalledExe) {
        # 2) IDE/agent hook'lari
        & $InstalledExe uninstall-hooks | Out-Host
        if ($LASTEXITCODE -ne 0) { Write-Warning "uninstall-hooks cikis kodu $LASTEXITCODE; devam ediliyor." }

        # 3) Arka plan servisi
        & $InstalledExe bg shutdown --hard *> $null
    }

    # Kalan git-ai sureclerini sonlandir (exe silinebilsin diye)
    $target = Normalize $InstalledExe
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.ExecutablePath -and (Normalize $_.ExecutablePath) -eq $target } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

    # 4) git trace2 ayari (install-hooks bu bolumu tamamen git-ai icin yazar)
    if (Get-Command git.exe -ErrorAction SilentlyContinue) {
        $eventTarget = & git.exe config --global --get trace2.eventTarget 2>$null
        if ($eventTarget -and $eventTarget -match 'git-ai') {
            & git.exe config --global --remove-section trace2 2>$null
        }
    }

    # 5) Kullanici PATH girdisi
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ($userPath) {
        $installNorm = Normalize $InstallDir
        $kept = @($userPath -split ';' | Where-Object { $_ -and (Normalize $_) -ne $installNorm })
        $newPath = $kept -join ';'
        if ($newPath -ne $userPath) {
            [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
        }
    }

    # 6) Dosyalar
    $removeTarget = if ($Purge) { $GitAiHome } else { $InstallDir }
    if (Test-Path -LiteralPath $removeTarget) {
        Remove-Item -LiteralPath $removeTarget -Recurse -Force
    }
    $loginDir = Join-Path $GitAiHome 'login'
    if (Test-Path -LiteralPath $loginDir) { Remove-Item -LiteralPath $loginDir -Recurse -Force }

    Write-Host 'Git AI kaldirildi.' -ForegroundColor Green
    Stop-Transcript | Out-Null
    exit 0
} catch {
    Fail $_.Exception.Message
}
