---
name: dell-fw-download
description: "Dell ファームウェアダウンロード。Playwright で dl.dell.com から BIN を取得し firmimg.d7 を抽出する。"
argument-hint: "<driver-id> <save-dir>"
---

# Dell FW Download スキル

Playwright で Dell サポートサイトから FW BIN ファイルをダウンロードし、iDRAC 用の firmimg.d7 を抽出する。

## 概要

| 項目 | 値 |
|------|-----|
| ダウンロード元 | `dl.dell.com` (Akamai CDN) |
| ツール | Playwright (headless Chromium) |
| 出力形式 | `firmimg.d7` (iDRAC FW イメージ) |
| 前提スキル | [playwright](../playwright/SKILL.md) |

## 前提

- Playwright がセットアップ済みであること (playwright スキル参照)
- `.venv/bin/python` が利用可能であること

## Dell ドライバページ URL パターン

```
https://www.dell.com/support/home/en-us/drivers/driversdetails?driverid=<DRIVER-ID>
```

### iDRAC7 FW の Driver ID

| バージョン | Driver ID | ファイル名 |
|-----------|-----------|-----------|
| 1.66.65 | 992WY | iDRAC-with-Lifecycle-Controller_Firmware_VV01T_LN_1.66.65_A00.BIN |
| 2.20.20.20 | 4P5PF | iDRAC-with-Lifecycle-Controller_Firmware_XTPX4_LN_2.20.20.20_A00.BIN |
| 2.65.65.65 | Y9YPN | iDRAC-with-Lifecycle-Controller_Firmware_0JKKT_LN_2.65.65.65_A00.BIN |

## ダウンロードスクリプトテンプレート

`tmp/<session-id>/dell-download.py` として保存:

```python
import os, sys, time
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', '.venv', 'lib'))

from playwright.sync_api import sync_playwright

DRIVER_ID = sys.argv[1]         # e.g. "Y9YPN"
SAVE_DIR = sys.argv[2]          # e.g. "tmp/<session-id>"
DRIVER_URL = f"https://www.dell.com/support/home/en-us/drivers/driversdetails?driverid={DRIVER_ID}"

with sync_playwright() as p:
    browser = p.chromium.launch(
        headless=True,
        args=["--no-sandbox", "--disable-gpu"],
    )
    context = browser.new_context(
        accept_downloads=True,
        user_agent="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
                   "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
    )
    page = context.new_page()
    page.add_init_script(
        "Object.defineProperty(navigator, 'webdriver', {get: () => undefined});"
    )

    # Dell ドライバページを訪問してセッション確立
    print(f"Visiting driver page: {DRIVER_URL}", file=sys.stderr)
    page.goto(DRIVER_URL, wait_until="domcontentloaded", timeout=60000)
    time.sleep(3)

    # ダウンロードボタンをクリック
    dl_btn = page.locator('a:has-text("Download")')
    if dl_btn.count() > 0:
        with page.expect_download(timeout=300000) as download_info:
            dl_btn.first.click()
        download = download_info.value
        save_path = os.path.join(SAVE_DIR, download.suggested_filename)
        download.save_as(save_path)
        print(f"Downloaded: {save_path}")
    else:
        # 直接 DL URL パターン
        dl_url = f"https://dl.dell.com/FOLDER00000000/{DRIVER_ID}.BIN"
        with page.expect_download(timeout=300000) as download_info:
            page.goto(dl_url)
        download = download_info.value
        save_path = os.path.join(SAVE_DIR, download.suggested_filename)
        download.save_as(save_path)
        print(f"Downloaded: {save_path}")

    browser.close()
```

実行:
```sh
.venv/bin/python tmp/<session-id>/dell-download.py <DRIVER-ID> tmp/<session-id>
```

> **注意**: Dell CDN は curl 直接ダウンロードを Akamai ボット検知でブロック (403 Access Denied) する。必ず Playwright 経由でダウンロードすること。

## BIN 展開手順

Dell の Linux BIN ファイルは自己展開型シェルスクリプト。内部に `#####Startofarchive#####` マーカーがあり、その後に gzip tar アーカイブが続く。

### 展開スクリプトテンプレート

`tmp/<session-id>/extract-bin.py` として保存:

```python
import gzip
import io
import os
import sys
import tarfile

bin_path = sys.argv[1]          # e.g. "tmp/<session-id>/firmware.BIN"
output_dir = sys.argv[2]        # e.g. "tmp/<session-id>/fw-extracted"

MARKER = b"#####Startofarchive#####"

with open(bin_path, "rb") as f:
    data = f.read()

idx = data.find(MARKER)
if idx == -1:
    print("ERROR: Archive marker not found", file=sys.stderr)
    sys.exit(1)

# マーカー行の次の改行以降がアーカイブ
archive_start = data.index(b"\n", idx) + 1
archive_data = data[archive_start:]

print(f"Archive found at offset {archive_start} ({len(archive_data)} bytes)")

os.makedirs(output_dir, exist_ok=True)

gz = gzip.GzipFile(fileobj=io.BytesIO(archive_data))
tar = tarfile.open(fileobj=gz, mode="r:")
tar.extractall(path=output_dir)
tar.close()

# firmimg.d7 の場所を表示
for root, dirs, files in os.walk(output_dir):
    for name in files:
        if name == "firmimg.d7":
            fpath = os.path.join(root, name)
            fsize = os.path.getsize(fpath)
            print(f"Found: {fpath} ({fsize} bytes)")
```

実行:
```sh
python3 tmp/<session-id>/extract-bin.py tmp/<session-id>/firmware.BIN tmp/<session-id>/fw-extracted
```

### 展開後のディレクトリ構造

```
fw-extracted/
  payload/
    firmimg.d7          ← iDRAC FW アップデートで使用するファイル
    package.xml
    ...
```

## 全体フロー

1. ダウンロード: `.venv/bin/python tmp/<session-id>/dell-download.py <DRIVER-ID> tmp/<session-id>`
2. 展開: `python3 tmp/<session-id>/extract-bin.py tmp/<session-id>/<BIN-file> tmp/<session-id>/fw-extracted`
3. パーミッション修正: `chmod 644 tmp/<session-id>/fw-extracted/payload/firmimg.d7`
4. TFTP サーバに配置 (tftp-server スキル参照)

## 注意事項

- **curl は使用不可**: Akamai CDN がボット検知で 403 を返す。Playwright 必須
- **BIN ファイルサイズ**: 数十 MB 〜 100 MB 程度。ダウンロードに数分かかる場合がある
- **マーカーの位置**: `#####Startofarchive#####` はファイルによって位置が異なる。バイナリ検索で動的に検出する
- **firmimg.d7 の配置**: TFTP サーバで配信する際は `chmod 644` を忘れないこと (tftp-server スキル参照)

## 参照

- [playwright スキル](../playwright/SKILL.md)
- [tftp-server スキル](../tftp-server/SKILL.md)
- [iDRAC7 FW アップグレードレポート](../../../report/2026-03-02_143000_idrac7_firmware_upgrade.md)
