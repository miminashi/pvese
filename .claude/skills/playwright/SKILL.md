---
name: playwright
description: "Playwright セットアップ・利用ガイド。headless Chromium によるブラウザ自動化の共通パターン。"
argument-hint: "<subcommand: setup|verify|stealth-template|download-template>"
---

# Playwright スキル

headless Chromium によるブラウザ自動化の共通基盤。

## 概要

| 項目 | 値 |
|------|-----|
| Python venv | `.venv/` (プロジェクトルート) |
| ブラウザ | Chromium (Playwright 管理) |
| 用途 | Dell FW ダウンロード、BMC KVM スクリーンショット |

## セットアップ手順

### 1. venv 作成と playwright インストール

```sh
uv venv .venv
uv pip install --python .venv/bin/python playwright
.venv/bin/playwright install chromium
```

### 2. 追加パッケージ (用途に応じて)

```sh
uv pip install --python .venv/bin/python Pillow   # BMC KVM スクリーンショット (画像処理)
```

## 確認方法

```sh
.venv/bin/playwright --version
.venv/bin/python -c "from playwright.sync_api import sync_playwright; print('OK')"
```

## ステルスモードパターン

CDN のボット検知 (Akamai 等) を回避するパターン。Dell ダウンロードサイト等で必要。

```python
browser = p.chromium.launch(
    headless=True,
    args=["--no-sandbox", "--disable-gpu"],
)
context = browser.new_context(
    user_agent="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
               "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
)
# webdriver プロパティを隠蔽
page = context.new_page()
page.add_init_script("""
    Object.defineProperty(navigator, 'webdriver', {get: () => undefined});
""")
```

- `user_agent`: 実在の Chrome バージョンに合わせる
- `webdriver=false`: ボット検知の最も基本的な回避策

## ダウンロードハンドリング

ファイルダウンロードを自動処理するパターン:

```python
context = browser.new_context(accept_downloads=True)
page = context.new_page()

with page.expect_download(timeout=300000) as download_info:
    page.goto(download_url)
download = download_info.value
download.save_as(save_path)
```

- `accept_downloads=True`: ダウンロードダイアログを自動承認
- `expect_download`: ダウンロード開始を待機。timeout はファイルサイズに応じて調整
- ダウンロード先ページに遷移する前に `expect_download` を開始する

## HTTPS 証明書エラー回避

BMC 等の自己署名証明書サイトにアクセスするパターン:

```python
browser = p.chromium.launch(
    headless=True,
    args=["--ignore-certificate-errors", "--no-sandbox", "--disable-gpu"],
)
context = browser.new_context(ignore_https_errors=True)
```

## 既存使用箇所

| スクリプト | 用途 |
|-----------|------|
| `scripts/bmc-kvm-screenshot.py` | BMC HTML5 KVM の canvas キャプチャ |
| dell-fw-download スキル | Dell CDN からの FW ダウンロード |

## 注意事項

- **venv パス**: スクリプトは `.venv/bin/python` を auto-detect する (`bmc-kvm-screenshot.py` 参照)
- **Chromium 依存**: `playwright install chromium` でインストールされた Chromium を使用。OS の Chrome とは独立
- **ヘッドレスのみ**: サーバ環境のため GUI なし。`headless=True` 必須
