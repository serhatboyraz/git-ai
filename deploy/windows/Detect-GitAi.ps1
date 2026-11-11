# Intune / SCCM algilama (detection) scripti. Kullanici baglaminda calisir.
# Kurulu: STDOUT'a yazi + cikis 0. Kurulu degil: cikti yok + cikis 1.
# Build-ItPackage.ps1 asagidaki surumu otomatik doldurur.
$ExpectedVersion = '__GIT_AI_VERSION__'

$exe = Join-Path $HOME '.git-ai\bin\git-ai.exe'
if (-not (Test-Path -LiteralPath $exe)) { exit 1 }

try { $version = "$(& $exe --version 2>$null | Select-Object -First 1)".Trim() } catch { exit 1 }

if ($version -eq $ExpectedVersion) {
    Write-Output "Git AI $version kurulu"
    exit 0
}
exit 1
