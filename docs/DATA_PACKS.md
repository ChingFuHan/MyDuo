# 字典與音檔資料包

## 輸入

`tools/dictionary_pipeline.py` 接受 Kaikki／Wiktextract 一行一 JSON 的
English dump（`.jsonl` 或 `.jsonl.gz`）。每次建包必須明確提供：

- source name
- source URL
- dump date
- 實際 license
- attribution

不可假設不同日期 dump 使用相同授權。請依取得當日的 Wiktionary／Kaikki
notice 填寫。

## 建立完整 SQLite＋FTS5 詞庫

```powershell
python .\tools\dictionary_pipeline.py ingest `
  --input .\data\raw\kaikki-english.jsonl.gz `
  --output .\data\generated\dictionary-2026.07.sqlite `
  --version 2026.07 `
  --source-name 'Kaikki English Wiktionary extract' `
  --source-url 'https://kaikki.org/dictionary/English/' `
  --license '依該 dump notice 填寫' `
  --attribution 'Wiktionary contributors; extracted by Wiktextract/Kaikki' `
  --dump-date 2026-07-01 `
  --audio-plan .\data\generated\audio-plan.jsonl
```

Pipeline streaming 處理，不把整個 dump 載入記憶體。它匯入：

- headword、UK／US IPA
- part of speech、gloss、繁中 translation
- forms、examples、phrases
- synonym／antonym／hypernym／hyponym／derived／related
- 音檔 URL plan 與來源 metadata

完成後執行 SQLite `integrity_check` 與 FTS5 query。

## 增量 delta

```powershell
python .\tools\dictionary_pipeline.py delta `
  --base .\data\generated\dictionary-2026.06.sqlite `
  --target .\data\generated\dictionary-2026.07.sqlite `
  --output .\data\generated\dictionary-2026.06-to-2026.07.jsonl
```

Delta 每行是：

```json
{"op":"delete","headword":"old word"}
{"op":"upsert","entry":{"headword":"word","senses":[]}}
```

App 只在 `from_version` 等於 active version 時選 delta。它先複製 active DB 到
staging、transaction 套用、重建 FTS、驗 schema/integrity，再切換 pointer。
不相容時下載 full SQLite。

## 音檔包

先依 `audio-plan.jsonl` 下載已確認可再散布的音檔，放在 plan 的
`relative_path`。不得因 URL 可公開存取就推定可再散布。

```powershell
python .\tools\dictionary_pipeline.py audio-pack `
  --plan .\data\generated\audio-plan-approved.jsonl `
  --input-dir .\data\raw\audio `
  --output .\data\generated\audio-en-2026.07.zip `
  --version 2026.07 `
  --accent uk
```

ZIP 內 `audio_manifest.json` 記錄每檔 SHA-256、大小、headword、accent、source、
license、attribution。App 解壓時拒絕 absolute path 與 `..`，再用版本 pointer
原子啟用。

## Manifest

```powershell
python .\tools\dictionary_pipeline.py manifest `
  --version 2026.07 `
  --output .\data\generated\manifest.json `
  --artifact "dictionary-full|sqlite|$env:TEMP\myduo-packs\dictionary-2026.07.sqlite" `
  --artifact "dictionary-delta|jsonl|$env:TEMP\myduo-packs\delta.jsonl|2026.06" `
  --artifact "audio|zip|$env:TEMP\myduo-packs\audio-en-2026.07.zip||uk" `
  --source 'Kaikki|https://kaikki.org/|ACTUAL LICENSE|2026-07-01|Wiktionary contributors'
```

Artifact URL 預設為檔名；部署時讓 manifest 與 artifact 位於可相對解析的位置。
Manifest schema：

```json
{
  "schema": 1,
  "version": "2026.07",
  "created_at": "2026-07-29T00:00:00Z",
  "artifacts": [
    {
      "kind": "dictionary-full",
      "format": "sqlite",
      "url": "dictionary-2026.07.sqlite",
      "sha256": "...",
      "size": 123,
      "version": "2026.07",
      "from_version": "",
      "accent": ""
    }
  ],
  "sources": []
}
```

## Ed25519

測試 key：

```powershell
$testKeyRoot = Join-Path $env:TEMP 'myduo-test-keys'
New-Item -ItemType Directory -Path $testKeyRoot -Force | Out-Null
$testPrivateKey = Join-Path $testKeyRoot 'test-private-key.txt'
$testPublicKey = Join-Path $testKeyRoot 'test-public-key.txt'
python .\tools\dictionary_pipeline.py keygen `
  --private-key $testPrivateKey `
  --public-key $testPublicKey
```

正式私鑰必須由獨立 secret／HSM 流程產生，不可用 repository 內路徑。

```powershell
$keyRoot = $env:MYDUO_SIGNING_KEY_DIR
if ([string]::IsNullOrWhiteSpace($keyRoot)) {
  throw 'Set MYDUO_SIGNING_KEY_DIR outside repository.'
}
$privateKey = Join-Path $keyRoot 'production-private-key.txt'
$publicKey = Join-Path $keyRoot 'production-public-key.txt'
python .\tools\dictionary_pipeline.py sign `
  --manifest .\data\generated\manifest.json `
  --private-key $privateKey

python .\tools\dictionary_pipeline.py verify `
  --manifest .\data\generated\manifest.json `
  --signature .\data\generated\manifest.json.sig `
  --public-key $publicKey
```

先簽 canonical file bytes，再上傳；上傳後不可格式化 manifest。

## 下載、App 設定與 activation

PowerShell 預下載：

```powershell
.\scripts\Get-DataPack.ps1 `
  -ManifestUri 'https://packages.example/manifest.json' `
  -PublicKey 'BASE64_PUBLIC_KEY'
```

Artifact 使用 `.part` 與 HTTP Range 續傳，先驗 signed manifest，再驗每檔 size 與
SHA-256。

App build：

```powershell
flutter build windows --release `
  --dart-define=MYDUO_PACK_MANIFEST_URL=https://packages.example/manifest.json `
  --dart-define=MYDUO_PACK_PUBLIC_KEY=BASE64_PUBLIC_KEY
```

更新順序：

1. HTTPS 下載 manifest 與 `.sig`
2. Ed25519 驗 manifest 原始 bytes
3. 選 compatible delta 或 full
4. HTTP Range 續傳
5. 驗 size 與 SHA-256
6. staging 套用／解壓，拒絕 path traversal
7. 驗 SQLite schema 與 FTS5
8. 關閉舊 DB、atomic pointer swap
9. 任何錯誤重新啟用舊 pack

`favorites`／`history` 位於獨立 `user.sqlite`，不隨 pack 覆蓋。
