# iDRAC7 VNC スクリーンショット統合計画

## Context

iDRAC7 の VNC ポート 5901 に直接 RFB プロトコルで接続し、800x600 フルカラーのスクリーンショットが取れることを確認した。
従来の capconsole API（400x300 グレースケールサムネイル）より高品質。
VNC を主要方式、capconsole を 3 回リトライ後のフォールバックとしてスクリプトに統合する。

## 変更ファイル

### 1. `scripts/idrac-kvm-screenshot.py` — VNC 追加 + フォールバック統合

既存スクリプトを in-place で修正。CLI インターフェースは互換維持。

**追加する関数:**
- `vnc_des_encrypt(password, challenge)` — VNC DES 認証（`cryptography` ライブラリ使用）
- `recv_exact(sock, n)` — 指定バイト数を確実に受信
- `vnc_screenshot(host, port, password, output, timeout)` — VNC 経由スクリーンショット
  - RFB 3.008 ハンドシェイク → VNC Auth → ServerInit
  - Wake キーイベント送信（SYSTEM IDLE 対策）
  - Raw エンコーディングでフレームバッファ取得
  - PIL で PNG 保存
  - 成功: 0, 失敗: 2 を返す

**追加する引数:**
- `--vnc-pass` (default: `Claude1`)
- `--vnc-port` (default: `5901`)

**main() のフロー変更:**
```
1. VNC を最大 3 回試行（リトライ間隔 2 秒）
2. 全失敗 → capconsole API にフォールバック（既存コードそのまま）
3. exit code: 0=成功, 1=認証失敗, 2=キャプチャ失敗
```

**VNC タイムアウト:** `--timeout` の半分（デフォルト 15 秒）を各 VNC 試行に使用。合計 ~50 秒で capconsole に移行。

**依存関係:** `cryptography`（system python にあり）、`PIL`（.venv にあり）。スクリプト冒頭で import 失敗時は VNC スキップして capconsole へ。

### 2. `.claude/skills/idrac7/SKILL.md` — スクリーンショット手順の更新

**VNC セクション (L234-257) の更新:**
- スクリーンショットツールの参照を `tmp/<session-id>/vnc-screenshot.py` → `./scripts/idrac-kvm-screenshot.py` に変更
- pycryptodome → cryptography に変更

**新規セクション「KVM スクリーンショット」を追加（VNC セクションの前あたり）:**
- 使用例: `.venv/bin/python3 ./scripts/idrac-kvm-screenshot.py --bmc-ip $BMC_IP --bmc-user claude --bmc-pass Claude123 --output tmp/<session-id>/screenshot.png`
- 方式: VNC (3回リトライ) → capconsole フォールバック
- 前提: `iDRAC.VirtualConsole.AccessPrivilege` が 0 (Allow) であること

### 3. `.claude/skills/os-setup/SKILL.md` — iDRAC スクリーンショット参照の更新

- L47: `VNC (vnc-wake-screenshot.py, port 5901)` → `./scripts/idrac-kvm-screenshot.py (VNC primary + capconsole fallback)`
- L356-359: `tmp/<session-id>/vnc-wake-screenshot.py` → `.venv/bin/python3 ./scripts/idrac-kvm-screenshot.py --bmc-ip "$BMC_IP" --bmc-user "$BMC_USER" --bmc-pass "$BMC_PASS" --output tmp/<session-id>/screenshot.png`

## 前提条件（実装前に確認）

- 7号機・9号機の `iDRAC.VirtualConsole.AccessPrivilege` を 0 に設定（8号機は設定済み）

## 検証方法

1. 8号機で VNC スクリーンショット取得:
   ```sh
   .venv/bin/python3 ./scripts/idrac-kvm-screenshot.py --bmc-ip 10.10.10.28 --bmc-user claude --bmc-pass Claude123 --output tmp/<session-id>/test-vnc.png
   ```
2. VNC を無効にして capconsole フォールバック確認:
   ```sh
   .venv/bin/python3 ./scripts/idrac-kvm-screenshot.py --bmc-ip 10.10.10.28 --bmc-user claude --bmc-pass Claude123 --output tmp/<session-id>/test-fallback.png --vnc-port 59999
   ```
3. 出力画像を Read ツールで目視確認

## レポート

完了後に `report/` にレポートを作成する（REPORT.md フォーマットに従う）。
