# OS Setup 通しテスト (Phase 1-8) — sol-monitor.py 実地検証

- **実施日時**: 2026年2月24日 01:53 - 02:34
- **課題**: #15 Phase 5 インストール監視で SOL ログを活用する (Step 5: 通しテスト)

## 前提・目的

sol-monitor.py の実地テストとして、os-setup Phase 1-8 の通しテストを実行する。Phase 5 で sol-monitor.py がインストーラのステージ進行を正しく検出し、完了時に正常終了するかを確認する。

## 環境情報

- サーバ: Supermicro X11DPU (BMC: 10.10.10.24)
- OS: Debian 13.3 (Trixie) + Proxmox VE 9.1.5
- カーネル: 6.17.9-1-pve
- NIC: eno1np0 (DHCP: 192.168.39.200), eno2np1 (static: 10.10.10.204)
- Web UI: https://10.10.10.204:8006 (HTTP 200)

## フェーズ実行結果

| Phase | 所要時間 | 結果 | 備考 |
|-------|---------|------|------|
| 1. iso-download | 即時 | OK | 既存 ISO 再利用 (sha256 一致) |
| 2. preseed-generate | 即時 | OK | |
| 3. iso-remaster | ~1分 | OK | efi.img Option B rebuild |
| 4. bmc-mount-boot | ~4分 | OK | Boot ID: Boot000E |
| 5. install-monitor | **~9分** | **OK** | **sol-monitor.py 実地テスト (後述)** |
| 6. post-install-config | ~3分 | OK | SOL 経由で SSH + static IP 設定 |
| 7. pve-install | ~12分 | OK | PVE 9.1.5 インストール |
| 8. cleanup | ~1分 | OK | VirtualMedia umount, boot override reset |

**合計: 約30分**

## Phase 5: sol-monitor.py 実地テスト結果

### 実行コマンド

```sh
./scripts/sol-monitor.py --bmc-ip 10.10.10.24 --bmc-user claude --bmc-pass Claude123 \
    --log-file tmp/17cc085d/sol-install.log --timeout 2700
```

### ステージ進行ログ (stderr)

```
[02:02:21] Monitoring started (timeout=2700s, powerstate_interval=60s)
[02:03:25] PowerState poll: On (1.0min)
[02:04:27] PowerState poll: On (2.1min)
[02:05:57] PowerState check failed: ... timed out after 30 seconds
[02:06:02] Stage: CONFIGURING_APT (3.6min)
[02:06:29] PowerState poll: On (4.1min)
[02:07:32] PowerState poll: On (5.1min)
[02:08:38] PowerState poll: On (6.2min)
[02:09:13] Stage: INSTALLING_SOFTWARE (6.8min)
[02:09:35] PowerState poll: On (7.2min)
[02:10:25] Stage: INSTALLING_GRUB (8.0min)
[02:10:38] PowerState poll: On (8.2min)
[02:11:13] Stage: POWER_DOWN (8.8min)
[02:11:13] Power down detected, waiting 30s for shutdown...
[02:11:45] PowerState after shutdown wait: Off
[02:11:45] Installation completed successfully (PowerState Off)
```

### 検証結果

| 確認項目 | 結果 |
|---------|------|
| ステージ進行が stderr に表示 | OK (4ステージ検出: CONFIGURING_APT, INSTALLING_SOFTWARE, INSTALLING_GRUB, POWER_DOWN) |
| SOL ログファイル記録 | OK (15.7 MB, 119,548行) |
| "Power down" 検出 → PowerState Off → exit 0 | OK |
| SOL 切断後に sol-login.py 接続可能 | OK |
| 終了コード | 0 (正常完了) |

### 観察事項

1. **初期ステージ未検出**: LOADING_COMPONENTS, DETECTING_NETWORK, RETRIEVING_PRESEED, INSTALLING_BASE は POST/GRUB 中に通過したため SOL 接続前に完了していた。これは期待通り (POST に約2分、GRUB auto-boot に5秒かかるため)。
2. **PowerState タイムアウト**: 3.1分時点で bmc-power.sh が30秒タイムアウト。BMC 負荷が高い時に発生しうるが、次回ポーリングでは回復。`None` は正常にスキップされた。
3. **完了シーケンス**: "Power down" 検出 (8.8min) → 30秒待機 → PowerState Off 確認 → exit 0。設計通り。

## 最終検証サマリ

```
OS:      Debian GNU/Linux 13 (trixie)
PVE:     pve-manager/9.1.5/80cf92a64bef6889 (running kernel: 6.17.9-1-pve)
Kernel:  6.17.9-1-pve
Network: eno1np0 UP 192.168.39.200/24, eno2np1 UP 10.10.10.204/8
Web UI:  https://10.10.10.204:8006 → HTTP 200
```
