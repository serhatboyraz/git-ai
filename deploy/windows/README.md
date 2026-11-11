# Git AI __GIT_AI_VERSION__: Windows Dağıtım Paketi

Bu paket, Git AI'ı kullanıcı bilgisayarlarına **internet erişimi gerektirmeden** kurar. Git AI, AI kodlama araçlarının (Copilot, Claude Code, Cursor vb.) yazdığı kodu git commit'lerinde işaretleyen bir komut satırı aracıdır.

## Gereksinimler

| | |
|---|---|
| İşletim sistemi | Windows 10 / 11, x64 |
| Ön koşul | Git for Windows kurulu olmalı (`git.exe` PATH'te) |
| Kurulum bağlamı | **Kullanıcı** (SYSTEM değil) |
| Yönetici yetkisi | Gerekmez (yönetici olarak çalıştırılması da engellenmez) |
| Disk | ~20 MB, `%USERPROFILE%\.git-ai\` altında |

> **Önemli:** Git AI kullanıcı bazında kurulur. Script SYSTEM hesabıyla başlatılırsa bilerek hata verir. "Yönetici olarak çalıştır" ile kurulum mümkündür. Ancak Git AI'ın kendi dokümantasyonu bunu önermez: admin sahipli dosyalar, arka plan servisinin normal kullanıcı oturumunda kilitlenmesine yol açabilir. Mümkünse yükseltilmemiş kullanıcı olarak çalıştırın.

## Paket içeriği

| Dosya | Açıklama |
|---|---|
| `git-ai.exe` | Uygulama |
| `install.cmd` | Kurulum komutu (Intune/SCCM için) |
| `uninstall.cmd` | Kaldırma komutu |
| `Install-GitAi.ps1` | Kurulum scripti |
| `Uninstall-GitAi.ps1` | Kaldırma scripti |
| `Detect-GitAi.ps1` | Intune/SCCM algılama scripti |
| `scripts\` | Git AI'ın resmi kurulum yardımcıları (Install-GitAi.ps1 tarafından çağrılır) |
| `SHA256SUMS.txt` | Dosya bütünlük özetleri |

## Kurulum ne yapar?

1. `git-ai.exe`'yi `%USERPROFILE%\.git-ai\bin\` klasörüne kopyalar ve bu klasörü kullanıcı PATH'ine ekler.
2. Bilgisayarda bulunan IDE ve AI ajanlarına (VS Code, Cursor, Claude Code vb.) Git AI hook'larını kurar.
3. Kullanıcının global git ayarına `trace2.eventTarget` / `trace2.eventNesting` değerlerini yazar.
4. Otomatik güncellemeyi kapatır. Sürüm IT tarafından yönetilir.
5. Görev Zamanlayıcı'ya `\GitAI\Start bg at logon` görevini ekler. Bu görev, oturum açılışında Git AI arka plan servisini kullanıcı yetkisiyle başlatır.

Mevcut bir kurulum varsa script onu durdurup üzerine yazar; yükseltme için de aynı paket kullanılır.

## Parametreler

```
install.cmd [-ApiBase <url>] [-ApiKey <anahtar>] [-EnableAutoUpdates] [-SkipLoginTask]
uninstall.cmd [-Purge]
```

| Parametre | Açıklama |
|---|---|
| `-ApiBase` | Kurumsal Git AI sunucu adresi (varsa) |
| `-ApiKey` | Kurumsal Git AI API anahtarı (varsa). Komut satırı argümanları yerel olarak görülebilir. |
| `-EnableAutoUpdates` | Otomatik güncellemeyi açık bırakır (önerilmez) |
| `-SkipLoginTask` | Oturum açılış görevini kaydetmez |
| `-Purge` | Kaldırırken ayar ve log dahil `%USERPROFILE%\.git-ai` klasörünü tamamen siler |

**Çıkış kodları:** `0` başarılı, `1` hata.

**Loglar:** `%TEMP%\git-ai-deploy\install-*.log` ve `uninstall-*.log`

## Microsoft Intune (Win32 uygulaması)

1. Paket klasörünü `.intunewin` formatına çevirin:
   ```
   IntuneWinAppUtil.exe -c <paket klasörü> -s install.cmd -o <çıktı klasörü>
   ```
2. **Apps > Windows > Add > Windows app (Win32)** ile yükleyin.
3. Program ayarları:

   | Alan | Değer |
   |---|---|
   | Install command | `install.cmd` (gerekirse `install.cmd -ApiBase https://... -ApiKey ...`) |
   | Uninstall command | `uninstall.cmd` |
   | Install behavior | **User** |
   | Device restart behavior | No specific action |
   | Return codes | `0` = Success, `1` = Failed |

4. Requirements: Windows 10 1809+ ve x64.
5. Detection rules: **Use a custom detection script** ile `Detect-GitAi.ps1` dosyasını seçin.
   - Run script as 32-bit process on 64-bit clients: **No**
   - Enforce script signature check: **No** (scriptleri imzalamadıysanız)
6. Dependencies: Git for Windows uygulamanız Intune'daysa bağımlılık olarak ekleyin.
7. Kullanıcı gruplarına **Required** olarak atayın.

## Configuration Manager (SCCM / MECM)

- Deployment Type: **Script Installer**
- Installation program: `install.cmd`
- Uninstallation program: `uninstall.cmd`
- Detection method: **Use a custom script**, PowerShell, içerik `Detect-GitAi.ps1`
- User Experience: Installation behavior **Install for user**; logon requirement **Only when a user is logged on**
- Dağıtımı **kullanıcı koleksiyonuna** yapın.

## Grup İlkesi (GPO) ile

**User Configuration > Policies > Windows Settings > Scripts > Logon** altına, paylaşımdaki `install.cmd`'yi ekleyin. Paylaşım yolu kullanıcılar tarafından okunabilir olmalıdır. Script tekrar çalıştırıldığında güvenle aynı kurulumu yeniler. Sadece ilk sefer çalışsın istiyorsanız önce `Detect-GitAi.ps1` ile kontrol edin.

## Elle kurulum ve test

Normal (yükseltilmemiş) bir komut isteminde:

```
install.cmd
```

Doğrulama (yeni bir terminalde):

```
git-ai --version
git-ai bg status
schtasks /query /tn "\GitAI\Start bg at logon"
```

`git-ai --version` komutu `__GIT_AI_VERSION__` döndürmelidir.

## Güvenlik notları

- `git-ai.exe` **dijital olarak imzalı değildir**. Uygulama kontrolü kullanılıyorsa (AppLocker, WDAC, Defender ASR, SmartScreen) dosyayı kurum sertifikasıyla imzalayın ya da `SHA256SUMS.txt` içindeki özetle beyaz listeye ekleyin. Konum: `%USERPROFILE%\.git-ai\bin\git-ai.exe`.
- PowerShell scriptleri `-ExecutionPolicy Bypass` ile çağrılır. Yalnızca imzalı scriptlere izin veren bir ortamda scriptleri imzalayın.
- Kurulum, kullanıcının global git yapılandırmasındaki `[trace2]` bölümünü Git AI için yeniden yazar. Bu bölümü başka bir amaçla kullanan bir araç varsa çakışır.
- Arka plan servisi sadece oturum açan kullanıcının yetkisiyle çalışır; servis, sürücü veya sistem geneli değişiklik yoktur.

## Kaldırma

`uninstall.cmd` şunları geri alır: IDE/ajan hook'ları, oturum açılış görevi, arka plan servisi, git `trace2` ayarı, PATH girdisi ve `.git-ai\bin` klasörü. Git Bash profilinde (`.bashrc`) kalan PATH satırı zararsızdır; klasör artık olmadığı için etkisizdir.
