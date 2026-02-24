# SOL 監視スクリプト (sol-monitor.py) 実装レポート

- **実施日時**: 2026年2月24日 01:51
- **課題**: #15 Phase 5 インストール監視で SOL ログを活用する

## 前提・目的

Phase 5 (install-monitor) は POST code ポーリング + PowerState ポーリングのみで監視しており、インストーラの進行状況がブラックボックスだった。SOL 経由のインストーラ出力をパースしてステージ進行を可視化するパッシブ監視スクリプトを作成する。

- 背景: テスト #4 で SOL 経由のインストーラ出力が確認済み（efi.img シリアルパッチ後）
- 目的: `sol-monitor.py` を作成し、Phase 5 の主要監視手段として組み込む
- 前提条件: sol-login.py が動作すること、pexpect がインストール済みであること

## 環境情報

- BMC: Supermicro X11DPU (10.10.10.24)
- OS: Debian 13.3 (Trixie) + Proxmox VE 9.1.5
- Python: 3.x + pexpect

## 実施内容

### 1. scripts/sol-monitor.py 作成 (新規 ~170行)

sol-login.py から接続管理コード (`deactivate_sol`, `sol_connect`, `disconnect_sol`, `log`) を複製し、パッシブ監視専用のスクリプトを作成。

主な機能:
- **インストーラステージ検出**: 9段階のキーワードマッチングで進行を可視化
  - LOADING_COMPONENTS → DETECTING_NETWORK → RETRIEVING_PRESEED → INSTALLING_BASE → CONFIGURING_APT → INSTALLING_SOFTWARE → INSTALLING_GRUB → INSTALL_COMPLETE → POWER_DOWN
- **完了検出**: "Power down" 検出 + 30秒待機 + PowerState 確認のデュアル方式
- **PowerState ポーリング**: 60秒間隔（デフォルト）
- **ログ出力**: SOL 生出力をファイルに記録
- **キー入力なし**: パッシブ監視のみ（preseed 自動インストールのため入力不要）
- **シグナル処理**: SIGTERM/SIGINT でクリーンアップ

CLI:
```sh
./scripts/sol-monitor.py --bmc-ip IP --bmc-user USER --bmc-pass PASS \
    [--log-file PATH] [--timeout 2700] [--powerstate-interval 60]
```

終了コード: 0=完了(PowerState Off), 1=タイムアウト, 2=接続エラー, 3=異常終了

### 2. SKILL.md Phase 5 書き換え

- SOL 監視を主要監視手段に変更
- POST code ポーリングをフォールバック（sol-monitor.py が exit 2 の場合）に格下げ
- SOL 監視の「非推奨」ラベルを削除
- BMC スクリーンショット（DCMS 要）セクションを削除（実用性なし）

### 3. reference.md 更新

SOL 監視パターンセクション末尾に sol-monitor.py の使用方法を追加。

## テスト結果 (Tier 1 — オフライン)

| テスト | 結果 |
|--------|------|
| 構文チェック (`py_compile`) | OK |
| `--help` 出力 | OK |
| 無効 BMC IP (127.0.0.1) | exit 3 (SOL EOF 検出、PowerState Off なし → 異常終了) |

## 再現方法

```sh
python3 -c "import py_compile; py_compile.compile('scripts/sol-monitor.py', doraise=True)"
./scripts/sol-monitor.py --help
timeout 60 ./scripts/sol-monitor.py --bmc-ip 127.0.0.1 --bmc-user test --bmc-pass test --timeout 10
```

## 変更ファイル

| ファイル | 変更 |
|---------|------|
| `scripts/sol-monitor.py` | 新規作成 |
| `.claude/skills/os-setup/SKILL.md` | Phase 5 書き換え |
| `.claude/skills/os-setup/reference.md` | sol-monitor.py 使用パターン追加 |

## 残タスク

- Step 5 (通しテスト): os-setup Phase 1-8 の実地テスト（ユーザの明示的指示で実行）
