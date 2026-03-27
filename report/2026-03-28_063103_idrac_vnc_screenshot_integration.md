# iDRAC7 VNC スクリーンショット統合レポート

- **実施日時**: 2026年3月28日 15:31 (JST)

## 添付ファイル

- [実装プラン](attachment/2026-03-28_063103_idrac_vnc_screenshot_integration/plan.md)
- [VNC スクリーンショット (800x600)](attachment/2026-03-28_063103_idrac_vnc_screenshot_integration/vnc-screenshot.png)
- [capconsole フォールバック (400x300)](attachment/2026-03-28_063103_idrac_vnc_screenshot_integration/capconsole-fallback.png)

## 前提・目的

iDRAC7 (7-9号機) の KVM スクリーンショット取得方式を改善する。

- **背景**: 従来の capconsole API は 400x300 グレースケールサムネイルしか取得できず、画面内容の確認が困難だった
- **目的**: VNC 直接接続による 800x600 フルカラースクリーンショットを主要方式として統合し、capconsole API をフォールバックとして残す
- **前提条件**: iDRAC7 FW 2.65.65.65、VNCServer が有効であること

## 環境情報

| サーバ | iDRAC IP | VNCServer | VNC ポート | VNC パスワード |
|--------|----------|-----------|-----------|---------------|
| 7号機 | 10.10.10.27 | Enabled (既存) | 5901 | Claude1 |
| 8号機 | 10.10.10.28 | Enabled (既存) | 5901 | Claude1 |
| 9号機 | 10.10.10.29 | **Enabled (今回有効化)** | 5901 | Claude1 (今回設定) |

全サーバ共通: SSL = Disabled, RFB 3.008, VNC Auth (Type 2)

## 調査結果

### VNC プロトコル

| 項目 | 値 |
|------|-----|
| ポート | 5901 (VirtualConsole の 5900 とは別) |
| プロトコル | RFB 003.008 (標準 VNC) |
| 認証 | VNC Authentication (Type 2, DES) |
| 解像度 | 800x600 |
| ピクセル形式 | 16bpp RGB555 (little-endian) |
| サーバ名 | OpenVNC |
| エンコーディング | Raw (0) をサポート |

### VirtualConsole.AccessPrivilege との関係

`iDRAC.VirtualConsole.AccessPrivilege` は VNC ポート 5901 の接続には影響しない。
VNCServer は独立した設定 (`iDRAC.VNCServer`) で制御される。

### 方式比較

| 項目 | VNC (主) | capconsole API (副) |
|------|---------|-------------------|
| 解像度 | 800x600 | 400x300 |
| 色深度 | フルカラー (15bit) | 5色グレースケール |
| 所要時間 | ~3 秒 | ~4 秒 |
| 依存 | cryptography + Pillow | stdlib のみ |
| Playwright | 不要 | 不要 |

## 実施内容

### 1. 9号機 VNCServer 有効化

```sh
ssh -F ssh/config idrac9 racadm set iDRAC.VNCServer.Enable Enabled
ssh -F ssh/config idrac9 racadm set iDRAC.VNCServer.Password Claude1
```

### 2. `scripts/idrac-kvm-screenshot.py` の修正

既存の capconsole 専用スクリプトを VNC + capconsole 統合スクリプトに改修。

**動作フロー**:
1. VNC を最大 3 回試行 (リトライ間隔 2 秒)
2. 全失敗時 → capconsole API にフォールバック
3. 依存ライブラリ不足時 → VNC スキップして capconsole へ

**CLI 互換維持**: 既存の `--bmc-ip`, `--bmc-user`, `--bmc-pass`, `--output`, `--timeout` はそのまま。
追加オプション: `--vnc-pass` (default: Claude1), `--vnc-port` (default: 5901)

### 3. スキル更新

- `.claude/skills/idrac7/SKILL.md`: 「KVM スクリーンショット」セクション追加、VNC セクションの参照更新
- `.claude/skills/os-setup/SKILL.md`: iDRAC スクリーンショット参照を統一スクリプトに変更

## 検証結果

### VNC 正常系 (8号機)

```
[06:27:25] VNC: Attempt 1/3 (10.10.10.28:5901)
[06:27:25] VNC: 800x600 16bpp
[06:27:28] VNC: Saved tmp/vnc8test/test-vnc.png (800x600, 6467 bytes)
```

結果: 800x600 フルカラー PNG を正常取得。

### capconsole フォールバック (8号機、VNC ポートを故意に間違い)

```
[06:27:38] VNC: Attempt 1/3 (10.10.10.28:59999)
[06:27:38] VNC: [Errno 111] Connection refused
[06:27:40] VNC: Attempt 2/3 ...
[06:27:42] VNC: Attempt 3/3 ...
[06:27:42] VNC: All 3 attempts failed, falling back to capconsole API
[06:27:43] capconsole: Login OK (ST2: c7c445ba...)
[06:27:46] capconsole: Saved tmp/vnc8test/test-fallback.png (5899 bytes, 400x300 grayscale)
```

結果: VNC 3 回失敗後に capconsole にフォールバックし、400x300 グレースケール PNG を正常取得。

## 変更ファイル一覧

| ファイル | 変更内容 |
|---------|---------|
| `scripts/idrac-kvm-screenshot.py` | VNC 主要方式追加 + capconsole フォールバック統合 |
| `.claude/skills/idrac7/SKILL.md` | KVM スクリーンショットセクション追加、VNC 参照更新 |
| `.claude/skills/os-setup/SKILL.md` | iDRAC スクリーンショット参照を統一スクリプトに変更 |
