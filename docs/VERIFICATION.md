# MyDuo 本機實測紀錄

環境：Windows 11 x64、PowerShell 5.1.22621、2026-07-30。

## Toolchain

- Flutter 3.24.5／Dart 3.5.4
- Git 2.46.2.windows.1
- Temurin JDK 17.0.20+8
- Android SDK Platform 35／Build Tools 35.0.0／adb 37.0.0
- Visual Studio Build Tools 2022 17.14.35
- Windows SDK 10.0.26100.0
- Visual Studio CMake 與 Ninja

`scripts\Test-Toolchain.ps1` exit 0。Android Studio 未安裝；CLI toolchain 完整。

## Static checks

- `flutter create --platforms=android,windows --org io.github.chingfuhan --project-name myduo`：exit 0
- `flutter pub get`：exit 0
- `dart format --set-exit-if-changed lib test`：0 changed
- `flutter analyze`：No issues found
- `flutter test`：7 tests passed
- `python -m compileall -q tools`：exit 0
- Python pipeline unittest：2 tests passed
- PowerShell AST parse：全部 script 0 syntax errors

測試涵蓋 FTS5、英文 prefix、繁中反查、Levenshtein 模糊、詞形／片語／來源、
收藏／歷史持久化、delta staging／atomic rollback、Ed25519 tamper rejection、
signed streamed full-pack download／activation（MockClient）、audio provenance
pack、multilingual widget render。

## Pipeline

Kaikki fixture ingest 建成 SQLite／FTS5，`integrity_check` 與 query 通過。
臨時 Ed25519 keygen、manifest sign、verify 通過；key 位於 `%TEMP%` 並已刪除。

## Android

- `flutter build apk --release`：23.2 MB
- `flutter build appbundle --release`：23.3 MB
- 產物：`myduo-test.apk`、`myduo-test.aab`
- `apksigner`：v1 true、v2 true、1 signer、Android Debug certificate
- `aapt`：package `io.github.chingfuhan.myduo`、label `MyDuo`、
  launchable `io.github.chingfuhan.myduo.MainActivity`
- `jar`：manifest、Flutter ABI libraries、SQLite ABI libraries 存在
- AAB `jarsigner`：exit 0
- `SHA256SUMS.txt`：生成後重新驗證
- APK SHA-256：`9ee82781fbb50c3c94325ddf54dd7c42b10349d22ed1b7f1822b7c41d87b9a77`
- AAB SHA-256：`7ccc3589937fdf045c26c5cb9b72402526ca9649ee241d819057c4b2e55d5b80`
- API 35 x86_64 emulator：`emulator-5554`
- `adb install -r`：Success
- cold launch：Status ok，Activity 正確
- `pm path` 與 window state：正確；PID 存在，fatal log 0

## Windows

- `flutter build windows --release`：exit 0
- Release：`myduo.exe`、Flutter DLL、SQLite DLL、data、assets、AOT library 完整
- Version metadata：CompanyName `ChingFuHan`、ProductName／FileDescription `MyDuo`
- portable ZIP：產生、解壓、再次驗證
- 產物：`myduo-windows-portable.zip`
- 解壓版 exe：實際啟動
- offline query、favorite、history、FTS5、SAPI fallback：全部 true
- process exit 0
- Windows `SHA256SUMS.txt`：生成後重新驗證
- ZIP SHA-256：`0339c43bb04a80b6f18d461ad2c68ff9fd91a0e16031691cee6dc3d3f93111a4`

`dist` 是本機 ignored artifact；hash 以其中 `SHA256SUMS.txt` 為準。
