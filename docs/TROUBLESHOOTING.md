# 疑難排解

## `flutter`／`java`／`adb` 不在 PATH

Script 優先使用 `.tools`，不要求全域 PATH：

```powershell
.\scripts\Install-LocalToolchain.ps1 -InstallAndroidSystemImage
.\scripts\Test-Toolchain.ps1
```

## `Get-FileHash` 找不到

PowerShell 7 module 可能遮蔽 5.1 module。請用專案 script；`Common.ps1` 會顯式
載入相容 module。不要用不明第三方 hashing executable。

## Android Studio not installed

CLI build 不需要 Android Studio。若 `flutter doctor -v` 只有 Android Studio
warning，但 Android toolchain 顯示 `[✓]`，可繼續。

## SDK XML version warning

舊 Android Gradle Plugin 讀取較新 command-line tools metadata 時可能顯示：

```text
This version only understands SDK XML versions up to 3 ...
```

若 Gradle exit 0、APK/AAB 已由 `apksigner`／`aapt`／`jar` 驗證，這是相容性
warning。不要為消除 warning 任意升級 Flutter 3.24.5 內建 Gradle stack。

## Emulator `devices.xml` warning

`avdmanager` 可能在 API 35 system image 顯示找不到 `devices.xml`，仍會
auto-select x86_64 ABI。以 `adb devices`、`sys.boot_completed`、實際 install
和 Activity launch 結果判定，不以 warning 單獨判定失敗。

## 無 Android 裝置

```powershell
.\scripts\Install-Android.ps1 -StartEmulator
```

若 emulator 無法開機：

1. 在 BIOS／UEFI 開啟 CPU virtualization。
2. Windows Features 開啟 Windows Hypervisor Platform。
3. 重新開機。
4. 再跑 script。

實機需開 Developer options、USB debugging，並在裝置上接受 RSA prompt。

## SQLite／FTS5

Windows portable 必須同時有 `sqlite3.dll`。Android APK 必須每個 ABI 含
`libsqlite3.so`。`Build-Windows.ps1` 和 `Build-Android.ps1` 已強制檢查。

若 App data schema 壞掉，先備份：

```text
%LOCALAPPDATA%\MyDuo
```

不要直接修改 active SQLite。讓 signed updater 切換 pack；收藏與歷史在
`user.sqlite`。

## TTS 無聲

Windows：Settings → Time & language → Speech，安裝 English (United States)
與 English (United Kingdom) voice。

Android：Settings → Text-to-speech output，下載 English offline voice data。

有授權音檔時 App 優先播放；無音檔且系統無離線 voice 時會顯示
`tts_unavailable`，不會偷偷呼叫雲端 API。

## Windows build 下載 SQLite 失敗

CMake 下載 `sqlite-autoconf-3520000.tar.gz` 並驗固定 SHA-256。檢查企業 proxy
是否允許 `https://sqlite.org/`。不要移除 `URL_HASH`。下載完成後 CMake cache
可重用。

## `dart format --set-exit-if-changed` exit 1

代表 formatter 修改了檔案。檢查 diff，再重跑；第二次應 exit 0。Build script
故意在第一次停止，避免悄悄交付未檢視改動。
