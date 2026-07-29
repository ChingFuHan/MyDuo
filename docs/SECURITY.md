# 安全說明

## 信任模型

- HTTPS 提供傳輸保護；Ed25519 public key 提供發布者身分。
- Manifest detached signature 覆蓋 artifact URL、version、size、SHA-256 與來源。
- SHA-256 只驗內容一致性，不能取代 Ed25519 身分驗證。
- Dictionary schema、FTS5 table 與 SQLite integrity 在 activation 前驗證。
- ZIP extraction 拒絕 absolute path 與 `..`。
- Pointer 以 `.new`／`.bak` 切換；失敗時恢復舊 pack。

## 不得提交

`.gitignore` 排除：

```text
android\local.properties
android\key.properties
*.jks
*.keystore
*.p12
*.pfx
*.pem
*.key
*.sig
*token*
*secret*
*private-key*
.env*
```

此外不得把密碼寫在 PowerShell history、command line、README、issue、log 或
`--dart-define`。Public key 不是秘密；private key 與 keystore password 是秘密。

## Production key

- 離線產生 Ed25519 signing key。
- 私鑰放 HSM／secret manager；build host 只拿 public key。
- 分離 data-pack signing key 與 Android app-signing key。
- 以雙人審核批准 manifest。
- 保存簽章事件、artifact hash 與來源 dump hash。
- Key rotation 時發布已由舊 key 簽署的過渡 manifest，讓 App 信任新 public key；
  不可只替換遠端 key。

## Test signing

`Build-Android.ps1` 生成的 APK／AAB 使用 Android debug certificate。此設計只供
本機 release-mode 測試，certificate DN 會顯示 `CN=Android Debug`。不得散布為
正式版或上傳商店。

`dictionary_pipeline.py keygen` 只供測試。CLI 拒絕覆寫既有 key；本專案測試在
`%TEMP%` 建 key 並立即刪除。

## Data supply chain

- 固定 Flutter、JDK、Android CLI 與 SQLite 下載 hash。
- Kaikki dump 自身也應另存 SHA-256 和取得日期。
- 每個 entry／audio 保存 source URL、license、attribution。
- 不接受未簽 manifest、未知 schema、HTTP 非 localhost、hash/size 不符 artifact。
- 不把遠端 HTML、definition 或 audio 當成可信程式碼執行。

## 回報

發現安全問題時，不在公開 issue 貼 token、private key、keystore 或未公開 pack
URL。先撤銷受影響 credential，再以最小重現資訊通報維護者。
