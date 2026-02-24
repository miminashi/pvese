# BMC KVM スクリーンショット機能の実装レポート

- **実施日時**: 2026年2月24日 12:27〜12:46

## 前提・目的

OS インストール (Phase 4-5) 中、SOL や POST コードだけでは画面状態を確認できない場合がある（POST 92 スタック、インストーラの VGA 出力など）。BMC の KVM 画面をプログラムからキャプチャし、Claude Code の Read ツールで PNG を閲覧して状態確認できるようにする。

- **背景**: `CapturePreview.cgi` は 404 を返すため使用不可。BMC iKVM Server Port = 5900 が開いていることは確認済み
- **目的**: BMC KVM のスクリーンショットを PNG で保存するスクリプトを実装する
- **前提条件**: BMC (10.10.10.24) に Web アクセスおよび iKVM アクセスが可能であること

## 環境情報

- BMC: Supermicro X11DPU (ASPEED AST2500 ベース)
- BMC IP: 10.10.10.24
- BMC KVM: ATEN iKVM Server (HTML5 noVNC + AST2100 コーデック)
- ローカル: Ubuntu 24.04, Python 3.12.3

## プロトコル調査結果

VNC 直接接続と WebSocket VNC の2方式を調査した。

### 1. VNC 直接接続 (port 5900) — 不可

TCP 接続は成功するが、サーバからデータが送信されない。RFB バージョン文字列を送信すると接続がリセットされる。SSL ラップも失敗。BMC Web セッションを介さない直接接続は不可。

### 2. WebSocket VNC (wss://BMC:443/) — 接続・認証成功、デコード断念

BMC の HTML5 KVM ビューアの JavaScript を解析し、WebSocket VNC プロトコルの全容を把握した。

**接続フロー**:
1. BMC Web ログイン → SID cookie 取得
2. HTML5 KVM ページ (`/cgi/url_redirect.cgi?url_name=man_ikvm_html5_bootstrap`) から `entry_value` (hidden input のセッショントークン) を取得
3. `wss://BMC:443/` に SID cookie 付きで WebSocket 接続
4. RFB 055.008 (Insyde カスタムバージョン) でハンドシェイク
5. Security type 16 (Insyde auth): 24 バイト challenge 受信 → entry_value を 48 バイト null パディングで送信
6. InsydeVNC 拡張 ServerInit: 標準 24 バイト + 拡張 12 バイト (SessionID, VideoEnable 等)
7. InsydeVNC メッセージ: type 57 (ユーザ通知 264 バイト)、type 55 (マウスモード 3 バイト) を消費
8. FramebufferUpdate: rect header 20 バイト (標準 12 + mode 4 + datalen 4)

**問題**: サーバは SetEncodings を無視し、常に AST2100 エンコーディング (encoding 87) を使用する。AST2100 は ASPEED 独自の DCT ベースコーデック (53K の JavaScript デコーダ) であり、Python へのポーティングは現実的でない。

#### InsydeVNC プロトコル詳細

**RFB バージョン**: サーバは `RFB 055.008` (Insyde カスタム) を送信。クライアントは同じバージョンをエコーバックする必要あり（RFB 003.008 を送ると切断）。

**認証 (Security Type 16)**:
- サーバは security type `[16]` のみを提示
- 24 バイト challenge 受信 → entry_value を先頭 24 バイトに配置 + 24 バイトゼロパディング = 48 バイト送信
- entry_value は KVM HTML ページの hidden input から取得。SID cookie や BMC 資格情報では認証不可

**ServerInit**:
- 標準 24 バイト + InsydeVNC 拡張 12 バイト (skip(4) + SessionID(4) + VideoEnable(1) + KbMsEnable(1) + KickUserEnable(1) + VMEnable(1))
- 初期報告サイズ: 480x640 (実際の解像度は FBU rect ヘッダで判明。例: 1024x768)
- BPP=32, depth=24, Name=`"ATEN iKVM Server"`

**InsydeVNC Server→Client メッセージ**:

| Type | 名前 | サイズ | 備考 |
|------|------|--------|------|
| 0 | FramebufferUpdate | 可変 | rect ヘッダが 20 バイト (後述) |
| 22 | Unknown | 1 バイト | 用途不明 |
| 55 | MouseMode | 3 バイト | crypto(1) + mode(1) + status(1) |
| 57 | UserNotification | 264 バイト | count(4) + tmp(4) + message(256)。例: `"869 root 10.1.4.2"` |

**InsydeVNC Rect ヘッダ (20 バイト)**:
```
x(2) + y(2) + width(2) + height(2) + encoding(4) + mode(4) + datalen(4)
```
- datalen=0 は "no signal" (映像なし) を意味する

**AST2100 エンコーディング (87)**: サーバは SetEncodings を完全に無視。RAW (0) のみリクエストしても AST2100 が返る。データ先頭は Y_Sel(1) + UV_Sel(1) バイト。

**BMC 上の JavaScript**: rfb.js (~56K), ast2100.js (~54K), nav_ui.js (~29K) — すべて minified。`screenshot.js` は html2canvas ライブラリで BMC スクリーンショット API ではない。

### 3. Playwright (HTML5 ビューア自動化) — 採用

BMC の既存 HTML5 KVM ビューア (noVNC + AST2100 JS デコーダ) を headless Chromium で開き、canvas の `toDataURL()` でスクリーンショットを取得する方式を採用。

## 実装

### `scripts/bmc-kvm-screenshot.py`

```
./scripts/bmc-kvm-screenshot.py \
    --bmc-ip 10.10.10.24 --bmc-user claude --bmc-pass Claude123 \
    --output tmp/<session-id>/screenshot.png [--timeout 30]
```

**処理フロー**:
1. `urllib` で BMC にログイン → SID cookie 取得
2. Playwright (headless Chromium) を起動し、SID cookie をセット
3. HTML5 KVM ビューアページを開く
4. canvas が 100x100 以上のサイズになるまで待機 (KVM 接続完了を確認)
5. canvas の `toDataURL('image/png')` で画像データを取得
6. PNG ファイルに保存

**Exit codes**: 0=成功, 1=接続/認証失敗, 2=タイムアウト, 3=依存エラー

**自動 venv 切替**: スクリプトは `.venv/bin/python` が存在する場合、自動的に `os.execv` で venv の Python に re-exec する。

### 依存関係

```sh
uv venv .venv
uv pip install --python .venv/bin/python playwright Pillow
.venv/bin/playwright install chromium
```

- `.venv/`: Python 仮想環境 (playwright 1.58.0, Pillow 12.1.1)
- `~/.cache/ms-playwright/chromium-1208`: Chromium ブラウザ (~167MB)
- `.venv/` は `.gitignore` に追加済み

## 動作確認

サーバ稼働中に実行し、PVE のログイン画面 (1024x768) のキャプチャに成功。

```
[12:42:10] Logging in to BMC at 10.10.10.24
[12:42:11] Login successful (SID: fqmkD932...)
[12:42:11] Opening KVM viewer...
[12:42:13] Waiting for KVM canvas to render...
[12:42:18] Canvas size: 1024x768
[12:42:18] Capturing canvas content...
[12:42:18] Screenshot saved: tmp/2c228e3f/test-screenshot.png (1024x768)
```

実行時間: 約 8 秒 (ログイン 1s + ページロード 2s + canvas 描画待機 3s + キャプチャ 2s)

## 変更ファイル

| ファイル | 操作 |
|---------|------|
| `scripts/bmc-kvm-screenshot.py` | 新規作成 |
| `.claude/skills/os-setup/SKILL.md` | スクリプト一覧に追加 |
| `.gitignore` | `.venv/` を追加 |
