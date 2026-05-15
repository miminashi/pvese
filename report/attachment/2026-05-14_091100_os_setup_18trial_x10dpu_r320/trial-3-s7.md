# Trial 3 server7 レポート

- **結果**: success
- **開始時刻**: 2026-05-15 01:14:57 JST
- **完了時刻**: 2026-05-15 02:24:51 JST
- **所要時間 (wall)**: 約 1h 10m
- **attempt 数**: 2 (Phase 4-5 で初回失敗 → re-mount + 再 boot で 2 回目成功)

## 発動したリカバリ

- Phase 4 attempt 1: VirtualMedia mount 残存状態で boot once 後 Off 検出 (sol-monitor exit 4, false positive) → umount → 5s → re-mount → boot-once 再設定 → power on → attempt 2 で installer 到達
- Phase 6 disk first boot: SSH 鍵未配置のため SSH 不到達 → 既知通り SOL 経由で鍵配置 + sshd 設定
- Phase 7 ステップ 0: pre-pve-setup.sh 内の DHCP 取得 timeout → `dhcpcd -1 -t 60 eno2` で事前取得 → 再実行
- Phase 7 post-reboot 中 default route 消失 → pre-pve-setup.sh 再実行で apt 復旧 → linstor インストール成功
- Phase 7 final reboot 後 default route 消失 → `dhclient -1 -v eno2` で復旧

## 観察した問題

### 既知 (Round 1+2 で既出)
- VirtualMedia "remote image already configured" → umount + re-mount
- Debian 13 minimal の DHCP 初回タイムアウト → dhcpcd 経由で取得
- post-reboot 中の default route 消失 (proxmox-ve install による ifupdown2 再初期化)
- final reboot 後の default route 消失 → dhclient で復旧

### 新規問題: なし (Round 1+2 で既知の罠と一致)

## 最終検証 (machine-id mtime チェック含む)

- install-monitor.start = 1778775528 (01:18:48 JST)
- /etc/machine-id mtime = 1778776727 (01:38:47 JST) → **fresh install 確認 OK**
- SSH `pveversion` 応答: pve-manager/9.1.11/8eac2c86f015bdda (running kernel: 7.0.2-2-pve)
- vmbr0 UP (10.10.10.207/8) + vmbr1 UP (192.168.39.200/24)
- `default via 192.168.39.1 dev vmbr1` 確認
- Web UI https://10.10.10.207:8006 → HTTP 200

## ログ参照

- Trial summary log: `tmp/e28df8d0/trial-3-s7.log`
- SOL install log (attempt 1, false positive): `tmp/e28df8d0/sol-install-s7-r3.log`
- SOL install log (attempt 2, success): `tmp/e28df8d0/sol-install-s7-r3-a2.log`
- Installer syslog: `tmp/e28df8d0/installer-syslog-s7-r3.log`
- pve-setup pre-reboot: `tmp/e28df8d0/pve-pre-reboot-s7-r3.log`
- pve-setup post-reboot (attempt 2): `tmp/e28df8d0/pve-post-reboot-s7-r3-attempt2.log`
- bridge setup: `tmp/e28df8d0/pve-bridge-s7-r3.log`
- Phase times: `tmp/e28df8d0/phase-times-s7-r3.txt`

## Phase 別所要時間

| Phase | 所要時間 |
|-------|---------|
| iso-download | 0m19s (cached) |
| preseed-generate | 0m02s (手動管理確認のみ) |
| iso-remaster | 0m08s (preseed ハッシュ一致でスキップ) |
| bmc-mount-boot | 2m20s |
| install-monitor | 34m24s (attempt 1 false positive 約 10 分 + attempt 2 約 24 分) |
| post-install-config | 7m10s |
| pve-install | 22m41s (DHCP + LINBIT 含む) |
| cleanup | 1m29s |
| **合計** | **68m33s** |
