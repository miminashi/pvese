# Trial 2 server8 レポート (再実行)

- **結果**: success
- **開始時刻**: 2026-05-14 20:35:58 JST
- **完了時刻**: 2026-05-14 21:30:00 JST 頃 (cleanup mark)
- **所要時間 (wall)**: 約 54 分 (os-setup-phase times 合計 53m53s)
- **attempt 数**: 1 (Phase 1-8 を 1 回で完走)

## 経緯

先行 subagent が state リセット指示を無視し Round 1 の install を Round 2 として記録したため、親が ipmitool power off + state 削除 + known_hosts 削除を実行し、本 subagent が Phase 1 から正しく実行。

## 発動したリカバリ

- Phase 7 で DHCP timeout → `dhcpcd -1 -t 60 eno2` 手動取得後に `pre-pve-setup.sh` 再実行 (1 回)
- Phase 7 post-reboot 中の default route 消失 → `pre-pve-setup.sh` 再実行で resume (1 回、既知)
- Phase 7 final reboot 後の default route 消失 → `pre-pve-setup.sh` 再実行で復旧 (1 回、既知)
- Phase 6 で SSH 鍵が preseed 経由で配置されないため SOL 経由で `sol-login.py` から authorized_keys を配置

## 観察した問題

- 初回 `dhcpcd -1 -t 30 eno2` (`pre-pve-setup.sh` 内部) が 30 秒以内に DHCP を取得できず timeout。手動 `dhcpcd -1 -t 60 eno2` (60 秒延長) で acquire 成功 (DHCP サーバの応答が遅延気味)
- post-reboot 中の default route 消失問題は既知 (`pve-setup-remote.sh` 経由 `proxmox-ve` インストール時に発生)、`/etc/network/if-up.d/z-fix-default-route` hook は final reboot 後の loss は防げないため pre-pve-setup を都度再走させる必要あり
- 新規問題なし

## build-essential pre-install で drbd-dkms 失敗予防できたか

**YES**。Phase 7 step 0 で build-essential を事前 install したため、`--linstor` 後の `drbd-dkms 9.3.2-1` の DKMS ビルドが `stdio.h` エラー無しで一発通過。Module 4 個 (drbd, drbd_transport_tcp, drbd_transport_lb-tcp, drbd_transport_rdma) を `/lib/modules/7.0.2-2-pve/updates/dkms/` に正常 install

## 最終検証 (success)

- `install-monitor.start = 1778758677` (2026-05-14 20:37:57 JST)
- `/etc/machine-id mtime = 1778759071` (2026-05-14 20:44:31 JST) — install start より **+6m34s 新しい、fresh install 確定**
- `/etc/hostname mtime = 1778759077` — 同上
- `pveversion`: pve-manager/9.1.11/8eac2c86f015bdda (running kernel: 7.0.2-2-pve)
- vmbr0: 10.10.10.208/8 UP / vmbr1: 192.168.39.130/24 UP
- `default via 192.168.39.1 dev vmbr1`
- Web UI https://10.10.10.208:8006: HTTP 200

## ログ参照

- 試行ログ: `tmp/e28df8d0/trial-2-s8.log`
- SOL install log: `tmp/e28df8d0/sol-install-s8-r2.log`
- SOL commands: `tmp/e28df8d0/sol-commands-s8-r2.txt`
- Installer syslog: `tmp/e28df8d0/installer-syslog-s8-r2.log` (2213 lines)
- State dir: `state/os-setup/server8/` (全 8 phase done)
- oplog: `log/oplog.log`

## Phase 別所要時間

| Phase | 所要時間 |
|-------|---------|
| iso-download | 0m16s |
| preseed-generate | 0m07s |
| iso-remaster | 0m00s (cache hit) |
| bmc-mount-boot | 1m19s |
| install-monitor | 10m34s |
| post-install-config | 13m45s (SSH 鍵配置含む) |
| pve-install | 26m21s (DRBD/LINSTOR + 複数の route 復旧含む) |
| cleanup | 1m31s |
| **total** | **53m53s** |
