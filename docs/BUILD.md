# 建置與產物驗證

## 一次完成

```powershell
.\scripts\Build-All.ps1
```

執行順序：

1. `Test-Toolchain.ps1`
2. `flutter create --platforms=android,windows`
3. `flutter pub get`
4. `dart format --set-exit-if-changed lib test`
5. `flutter analyze`
6. `flutter test`
7. `python -m compileall -q tools`
8. Python pipeline unittest
9. Android APK／AAB build 與驗證
10. Windows release／portable ZIP／smoke test

任何 native command 非零 exit code 都會中止。

## Android

App ID：

```text
io.github.chingfuhan.myduo
```

設定：

- compileSdk 35
- targetSdk 35
- Build Tools 35.0.0
- JDK／Kotlin JVM target 17
- universal APK：armeabi-v7a、arm64-v8a、x86_64
- release build 使用 debug certificate，僅供 test-signed artifact

建置：

```powershell
.\scripts\Build-Android.ps1
```

Script 驗證：

- `apksigner verify --verbose --print-certs`：APK signature
- `aapt dump badging`：package 與 launchable Activity
- `aapt dump xmltree`：MAIN intent manifest
- `jar tf`：APK／AAB manifest、Flutter ABI library、SQLite ABI library
- `jarsigner -verify -verbose -certs`：AAB JAR signature
- `Get-FileHash`：生成並重新驗證 `SHA256SUMS.txt`

實際安裝：

```powershell
# 已連線且授權裝置
.\scripts\Install-Android.ps1

# 無裝置時建立／啟動 API 35 x86_64 AVD
.\scripts\Install-Android.ps1 -StartEmulator
```

Script 執行 `adb install -r`、force-stop、`am start -W`、`pm path` 與 window
state 檢查。未偵測到 authorized device 時會失敗，不會宣稱已驗證。

### 正式 Android 簽章

現有 AAB 不可上架。正式流程應在 repository 外建立 `key.properties` 與
keystore，透過受控 secret store 注入。不得提交：

```text
android\key.properties
*.jks
*.keystore
密碼或 token
```

更換 Gradle signingConfig 後，重新跑同一套 `apksigner`／`jarsigner` 驗證。

## Windows

```powershell
.\scripts\Build-Windows.ps1
```

Script 驗證 Release 目錄：

- `myduo.exe`
- `flutter_windows.dll`
- `sqlite3.dll`（SQLite 3.52，FTS5）
- `data\app.so`
- `data\flutter_assets`
- starter dictionary 與 license assets

平台橋接編譯在 runner；沒有額外 Flutter plugin DLL。Script 將 Release 內容壓成
`dist\windows\myduo-windows-portable.zip`，解壓至 `%TEMP%` 後重做結構
驗證。

接著實際啟動解壓版：

```text
myduo.exe --smoke-test --smoke-output=<temp-json>
```

60 秒內必須完成：

- SQLite／FTS5 離線查詢
- 收藏寫入與讀回
- 歷史寫入與讀回
- Windows SAPI offline TTS fallback

JSON 每項為 `true` 才視為成功。最後用 `Get-FileHash` 產生 Windows
`SHA256SUMS.txt`。

## 清理

`build`、`dist`、`.tools`、`.toolcache` 均是 ignored local artifact。若要清理，
只刪除上述明確目錄；不要對 repository root 使用遞迴刪除。
