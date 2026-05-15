# Trial 2 server7 レポート

- **結果**: success
- **開始時刻**: 2026-05-14T19:26:54+09:00
- **完了時刻**: 2026-05-14T20:30:12+09:00
- **所要時間 (wall)**: 約 1 時間 3 分 (Phase 合計 62m24s)
- **attempt 数**: 1 (install-monitor 1 attempt 成功 / post-reboot 2 attempt で resume 完走)

## 発動したリカバリ

1. **Phase 7 Step 0**: `pre-pve-setup.sh` 1 回目の DHCP gateway 自動検出失敗 → `dhcpcd -1 -t 60 eno2` で手動取得 → `pre-pve-setup.sh` 2 回目で apt 取得成功
2. **Phase 7 Step 4 post-reboot**: proxmox-ve install 中の default route 喪失 → packages.linbit.com 解決失敗 → `pre-pve-setup.sh` で route 復元 → post-reboot を冪等再実行で完走
3. **Phase 7 Step 5 final reboot**: default route 再喪失 → `dhclient -1 -v eno2` で復旧

## 観察した問題

- DHCP gateway 取得不安定 (既知)
- post-reboot 中の default route 消失 (既知、Round 1 server7 で再現)
- final reboot 後の default route 消失 (既知)
- **新規問題なし**

## build-essential pre-install で drbd-dkms 失敗予防できたか

**予防成功**: post-reboot 完了ログに DKMS ビルド失敗の痕跡なし。`linstor-common / linstor-satellite / linstor-proxmox` が `Setting up` で完走。drbd-dkms の `stdio.h` エラーは Round 1 server8 では発火していたが、Round 2 server7 では `apt-get install -y build-essential` の事前実行により未発火

## 最終検証

- `ssh root@pve7 pveversion`: `pve-manager/9.1.11/8eac2c86f015bdda (running kernel: 7.0.2-2-pve)` OK
- vmbr0 = 10.10.10.207/8 UP / vmbr1 = 192.168.39.199/24 UP
- `default via 192.168.39.1 dev vmbr1` OK
- Web UI: `https://10.10.10.207:8006` → HTTP 200
- IB: `ibp10s0 = 192.168.101.7/24 connected mode MTU 65520` UP + 永続化済み

## ログ参照

- 試行ログ: `tmp/e28df8d0/trial-2-s7.log`
- SOL install: `tmp/e28df8d0/sol-install-s7-r2.log` (4752 行)
- Installer syslog: `tmp/e28df8d0/installer-syslog-s7-r2.log` (4224 行)

## Phase 別所要時間

| Phase | 所要時間 |
|-------|---------|
| iso-download | 0m19s (cached) |
| preseed-generate | 0m00s (手動管理 preseed 再利用) |
| iso-remaster | 0m11s (preseed hash 一致で再利用) |
| bmc-mount-boot | 4m41s |
| install-monitor | 21m34s |
| post-install-config | 10m26s |
| pve-install | 22m55s |
| cleanup | 2m18s |
| **total** | **62m24s** |
