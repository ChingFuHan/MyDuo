# PowerShell 使用說明

## Clone portability

All scripts resolve repository root from `$PSScriptRoot`; they do not depend on this
computer's checkout path. `android/local.properties`, build output, downloaded
toolchains, and data packs are local generated files and are intentionally ignored.
Run commands from any clone with the same relative script paths.

所有 script 支援 Windows PowerShell 5.1 與 PowerShell 7，採
`Set-StrictMode -Version Latest`、`$ErrorActionPreference = 'Stop'`，
並使用 `-LiteralPath`／argument array 處理含空格路徑。Script 不依賴 bash、
grep、sed 或其他 Unix 指令。

## Script 一覽

```powershell
# 只檢查，不安裝
.\scripts\Test-Toolchain.ps1

# 安裝 project-local Flutter/JDK/Android CLI
.\scripts\Install-LocalToolchain.ps1 -InstallAndroidSystemImage

# create/pub/format/analyze/test/Python checks，接著建雙平台
.\scripts\Build-All.ps1

# 分開建置
.\scripts\Build-Android.ps1
.\scripts\Build-Windows.ps1

# 實機或 emulator 安裝
.\scripts\Install-Android.ps1 -StartEmulator

# 驗 Ed25519 後續傳下載資料包
.\scripts\Get-DataPack.ps1 `
  -ManifestUri 'https://packages.example/myduo/manifest.json' `
  -PublicKey 'BASE64_ED25519_PUBLIC_KEY'
```

`Build-All.ps1` 可用 `-SkipAndroid` 或 `-SkipWindows` 做單平台工作。

## 工具版本與安裝提示

`Test-Toolchain.ps1` 檢查：

- Flutter 必須精確為 3.24.5
- Git
- JDK 17
- Android SDK Platform 35、Build Tools 35.0.0、adb
- Visual Studio 2022 Desktop C++ workload
- Windows SDK、CMake、Ninja

常用安裝指令：

```powershell
winget install --id Git.Git -e
winget install --id EclipseAdoptium.Temurin.17.JDK -e
winget install --id Microsoft.VisualStudio.2022.BuildTools -e `
  --override '--wait --passive --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended'
```

專案內安裝 script 使用固定 URL 與 SHA-256：

- Flutter 3.24.5 stable
- Temurin JDK 17.0.20+8
- Android command-line tools 15859902
- API 35、Build Tools 35.0.0、platform-tools、emulator

下載寫入 `.toolcache`，工具解壓至 `.tools`；兩者均被 Git 忽略。重新執行時，
已通過 SHA-256 的檔案直接重用。

## PowerShell 5.1 `Get-FileHash`

某些電腦的 `PSModulePath` 會讓 PowerShell 7 module 遮蔽 Windows PowerShell
5.1 module。`Common.ps1` 在 cmdlet 缺失時顯式載入
`$PSHOME\Modules\Microsoft.PowerShell.Utility`，之後所有 checksum 仍由
`Get-FileHash -Algorithm SHA256` 完成。

## Developer Mode

本專案沒有 Flutter plugin dependency，因此 `flutter pub get` 不需建立
Windows plugin symlink，也不要求開啟 Developer Mode。Android SQLite 由 Gradle
AAR bundling；Windows SQLite 由 CMake 建成 `sqlite3.dll`。Android TTS 與
Windows SAPI 使用 runner 內 MethodChannel。

## Execution policy

不需永久改政策：

```powershell
Set-ExecutionPolicy -Scope Process Bypass
```

企業政策禁止 script 時，請由管理員依組織規範簽署 script；不要停用全機安全
政策。
