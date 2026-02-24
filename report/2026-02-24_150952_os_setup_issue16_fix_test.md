# OS Setup 通しテスト (Issue #16 修正 + Phase 1-8)

- **実施日時**: 2026年2月24日 14:00 - 15:09

## 前提・目的

Issue #16 (sol-monitor.py の PowerState Off 誤検出) を修正した上で、OS セットアップ全フェーズ (Phase 1-8) を再実行し、修正の検証と通しテストの完了を確認する。

- **背景**: 前回テスト (2026-02-24 04:05) で全フェーズ完了したが、issue #16 が未修正のまま残っていた。sol-monitor.py の SOL EOF パスと定期ポーリングパスで PowerState Off を即座に信頼してしまい、IPMI の過渡的な Off 応答で誤完了する可能性があった
- **目的**: `confirm_powerstate_off()` ヘルパーを追加し、10秒後の再確認で誤検出を防止する。修正後に通しテストで正常動作を検証する
- **前提条件**: 既存 Debian + PVE インストール済みサーバを再インストール

### 参照レポート

- [report/2026-02-24_054040_os_setup_phase_timing_test.md](2026-02-24_054040_os_setup_phase_timing_test.md) — 前回の通しテスト (85m17s, POST 92 スタック含む)

## 環境情報

| 項目 | 値 |
|------|-----|
| サーバ | Supermicro X11DPU (ayase-web-service-4) |
| BMC IP | 10.10.10.24 |
| サーバ IP | 10.10.10.204 (static, eno2np1) |
| OS | Debian 13.3 (Trixie) |
| PVE | pve-manager/9.1.5 |
| カーネル | 6.17.9-1-pve |
| ISO | debian-13.3.0-amd64-netinst.iso (preseed 組み込みリマスター版) |
| ディスク | /dev/nvme0n1 |

## Issue #16 修正内容

コミット: `b73707b` (Fix #16: add confirm_powerstate_off to sol-monitor.py)

### 追加: `confirm_powerstate_off()` ヘルパー

```python
def confirm_powerstate_off(bmc_ip, bmc_user, bmc_pass, context=""):
    """Double-check PowerState Off to avoid false positives."""
    log(f"PowerState Off detected ({context}), confirming in 10s...")
    time.sleep(10)
    state2 = check_powerstate(bmc_ip, bmc_user, bmc_pass)
    log(f"PowerState re-check: {state2}")
    if state2 == "Off":
        return True
    log(f"PowerState changed to {state2} - was transient Off, continuing")
    return False
```

### 修正パス

| パス | 修正内容 |
|------|---------|
| SOL EOF (line 154-162) | `check_powerstate` → Off → `confirm_powerstate_off` で二重確認。過渡的 Off なら異常終了として処理 |
| 定期ポーリング (line 170-173) | `check_powerstate` → Off → `confirm_powerstate_off` で二重確認。過渡的 Off なら監視続行 |
| "Power down" テキスト検出 (line 143-152) | **変更なし** — SOL テキスト "Power down" + 30秒待機で十分なコンテキスト確認済み |

## フェーズ実行結果

| Phase | Name | 所要時間 | 前回比 | 備考 |
|-------|------|---------|--------|------|
| 1 | iso-download | 0m13s | -6s | sha256 検証のみ |
| 2 | preseed-generate | 0m06s | -1s | |
| 3 | iso-remaster | 1m35s | -5s | xorriso による ISO 再構築 |
| 4 | bmc-mount-boot | 23m56s | +13m38s | VirtualMedia マウント不具合 (後述) + 3回パワーサイクル |
| 5 | install-monitor | 10m54s | **-42m31s** | POST 92 スタックなし、正常インストール完了 |
| 6 | post-install-config | 3m10s | +1s | SOL 経由ログイン・設定 + SSH 確認 |
| 7 | pve-install | 14m00s | -1m35s | pre-reboot + reboot + post-reboot + final reboot |
| 8 | cleanup | 0m53s | +9s | VirtualMedia アンマウント + 最終検証 |
| | **合計** | **54m47s** | **-30m30s** | 前回 85m17s |

### 前回比の分析

- **Phase 4 増加 (+13m38s)**: VirtualMedia マウントの CSRF トークン不一致問題 (後述) により、3回のパワーサイクルが必要だった
- **Phase 5 大幅短縮 (-42m31s)**: 前回の POST 92 スタック (約40分のリカバリ時間) が今回発生しなかった。実インストール時間は前回と同等 (約9分)
- **合計で 30分30秒短縮**: POST 92 スタック回避が最大の改善要因

## 注記・トラブルシューティング

### VirtualMedia マウント不具合 (Phase 4)

CGI API (`/cgi/op.cgi op=mount_iso`) が `VMCOMCODE=001` (成功レスポンス) を返すにもかかわらず、Redfish API (`/redfish/v1/Managers/1/VirtualMedia/CD1`) で確認すると `Inserted: false, ConnectedVia: NotConnected` となるケースが発生した。

**原因**: CSRF トークンの有効期限切れ。BMC ログイン後にパワーサイクル等で時間が経過し、CGI セッションが暗黙的に失効。CGI API はエラーを返さず `VMCOMCODE=001` を返すが、実際のマウント操作は実行されていなかった。

**対策**: マウント操作前に必ず BMC 再ログイン + CSRF トークン再取得を行うこと。また、マウント後に Redfish API で `Inserted: true` を確認すること。

**KVM スクリーンショット**: `tmp/65968776/screenshot-phase4-post01.png` — POST code 0x01 停滞の調査時にキャプチャ。画面は PVE ログインプロンプトが表示されており、POST code は stale だった (サーバは既にブート完了)。

### sol-monitor.py 修正検証 (Phase 5)

sol-monitor.py のログ出力:
```
[14:40:21] Monitoring started (timeout=2700s, powerstate_interval=60s)
[14:44:08] Stage: LOADING_COMPONENTS (3.7min)
[14:44:28] Stage: CONFIGURING_APT (4.0min)
[14:47:28] Stage: INSTALLING_SOFTWARE (7.0min)
[14:48:48] Stage: INSTALLING_GRUB (8.4min)
[14:49:28] Stage: POWER_DOWN (9.0min)
[14:49:28] Power down detected, waiting 30s for shutdown...
[14:49:58] PowerState after shutdown wait: Off
[14:49:58] Installation completed successfully (PowerState Off)
```

- インストールは "Power down" テキスト検出パス (変更なし) で正常完了
- `confirm_powerstate_off` は呼ばれなかった (正常動作: Power down テキスト + 30秒待機の後 Off が確認されたため)
- SOL EOF パスや定期ポーリングパスでの誤検出は発生しなかった

## 最終検証

```
OS:      Debian GNU/Linux 13 (trixie) 13.3
PVE:     pve-manager/9.1.5/80cf92a64bef6889 (running kernel: 6.17.9-1-pve)
Kernel:  6.17.9-1-pve
Network: eno1np0 UP 192.168.39.197/24
         eno2np1 UP 10.10.10.204/8
Web UI:  https://10.10.10.204:8006 → HTTP 200
```

## 再現方法

```sh
# Issue #16 修正コミットを適用済みであること (b73707b)

# 全フェーズリセット
for phase in iso-download preseed-generate iso-remaster bmc-mount-boot install-monitor post-install-config pve-install cleanup; do
  ./scripts/os-setup-phase.sh reset "$phase"
done

# os-setup スキルに従って Phase 1-8 を順次実行
# 各フェーズ開始時: ./scripts/os-setup-phase.sh start <phase>
# 各フェーズ完了時: ./scripts/os-setup-phase.sh mark <phase>

# 所要時間サマリ
./scripts/os-setup-phase.sh times
```
