# MyDuo

MyDuo 是 Flutter 3.24.5 單一程式碼庫的 Android／Windows x64
離線英英與中英字典。核心查詢不需要網路。介面借鏡現代學習型字典的資訊層級，
但不含 Cambridge Dictionary 的文字、品牌、音檔或版面。

## 功能

- 英英定義、繁體中文翻譯與繁中反查
- UK／US IPA、詞性、詞形、片語、雙語例句、相關詞
- SQLite＋FTS5 全文索引、英文前綴與 Levenshtein 模糊搜尋
- 本機收藏與查詢歷史；更換字典資料包後仍保留
- 優先播放有授權的離線音檔；缺檔時使用 Android TextToSpeech 或 Windows SAPI
- Kaikki／Wiktextract JSONL streaming 匯入、完整包、delta JSONL、音檔包
- HTTP Range 續傳、SHA-256、Ed25519 detached signature、原子啟用與失敗回滾
- 每個詞條與音檔保留來源 URL、授權和 attribution

內建 starter 詞庫只用於首次啟動與 smoke test。正式大詞庫應用
[`tools/dictionary_pipeline.py`](tools/dictionary_pipeline.py) 從合法取得的
Kaikki／Wiktextract dump 建立，不把大型衍生資料提交到 Git。

## 快速開始

在 Windows 11 PowerShell 5.1 或 7：

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\scripts\Test-Toolchain.ps1
```

若缺 Flutter 3.24.5、JDK 17 或 Android CLI：

```powershell
.\scripts\Install-LocalToolchain.ps1 -InstallAndroidSystemImage
```

完整檢查與雙平台建置：

```powershell
.\scripts\Build-All.ps1
```

輸出：

```text
dist\android\myduo-test.apk
dist\android\myduo-test.aab
dist\android\SHA256SUMS.txt
dist\windows\myduo-windows-portable.zip
dist\windows\SHA256SUMS.txt
```

Android 產物刻意使用 Flutter debug certificate 作「test-signed release」。
不得發布到商店。正式簽章必須由外部、受控的 keystore 流程完成。

安裝並啟動 Android：

```powershell
.\scripts\Install-Android.ps1 -StartEmulator
```

## 文件

- [PowerShell 使用說明](docs/POWERSHELL.md)
- [建置與產物驗證](docs/BUILD.md)
- [資料包與 Kaikki pipeline](docs/DATA_PACKS.md)
- [安全說明](docs/SECURITY.md)
- [疑難排解](docs/TROUBLESHOOTING.md)
- [本機實測紀錄](docs/VERIFICATION.md)

## 資料與授權

`assets/data/seed_entries.json` 是本專案原創 CC0 starter 資料。Wiktionary
衍生包不隨 repository 提供；建立者與散布者必須依來源 dump 的實際授權保存
attribution、版本日期與 notices。詳見
[`assets/licenses/STARTER_DATA.md`](assets/licenses/STARTER_DATA.md)。

## 安全界線

Repository 不含 token、密碼、keystore、私鑰或正式 signature。資料包公鑰可由
`--dart-define=MYDUO_PACK_PUBLIC_KEY=...` 注入；私鑰只能存在隔離簽章環境。
`.gitignore` 排除常見秘密與本機產物。
