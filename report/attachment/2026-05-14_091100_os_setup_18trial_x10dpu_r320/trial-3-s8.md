# Trial 3 server8 レポート (再実行)

- **結果**: success
- **開始時刻**: 2026-05-15 02:33:15 JST
- **完了時刻**: 2026-05-15 03:16:31 JST
- **所要時間 (wall)**: 約 43 分 16 秒 (phase 合計 43m05s)
- **attempt 数**: 1 (一発で install 完走)

## 経緯

先行 subagent が Phase 5 install-monitor 開始直後で中間応答停止 → 親が強制リセット (chassis power off + state 削除 + known_hosts + iDRAC VirtualMedia umount) → 本 subagent が Phase 1 から完走。

## 発動したリカバリ

- Phase 7 pre-pve-setup の DHCP 30s timeout → 手動 `dhcpcd -1 -t 60 eno2` で取得後に再実行 (既知 workaround)
- **Phase 7 post-reboot 中の default route 消失 → exit 100** で `Temporary failure resolving 'deb.debian.org'` (既知/必発): `pre-pve-setup.sh` 再実行で route 復元 → `pve-setup-remote.sh --phase post-reboot --linstor` 再実行で完走
- Phase 7 final reboot 後にも default route 消失 → `pre-pve-setup.sh` 再実行 (`vmbr1` 経由 `192.168.39.1` 復元)
- LINBIT keyring 事前配置 (preventive): wget 404 を回避
- build-essential 事前 install (preventive): drbd-dkms `stdio.h` 失敗を回避

## 観察した問題

すべて既知。**新規問題なし**:
- DHCP 30s timeout (Debian 13 minimal `isc-dhcp-client` 不在)
- post-reboot の default route 消失 (5 trial 連続再現の既知)
- final reboot 後の default route 消失 (`/etc/network/if-up.d/z-fix-default-route` hook が機能していない)

## 最終検証 (success)

- SSH: `ssh -F ssh/config root@pve8 pveversion` → `pve-manager/9.1.11/8eac2c86f015bdda (running kernel: 7.0.2-2-pve)` OK
- ネットワーク: `vmbr0 UP 10.10.10.208/8`, `vmbr1 UP 192.168.39.131/24` OK
- default route: `default via 192.168.39.1 dev vmbr1` OK
- Web UI: `curl -sk https://10.10.10.208:8006` → HTTP 200 OK
- **machine-id mtime: 1778780531 (02:42:11) > install-monitor.start 1778780154 (02:35:54) — fresh install 確認 OK (+6m17s)**
- hostname mtime: 1778780537 (02:42:17) — fresh OK

## ログ参照

- 全体ログ: `tmp/e28df8d0/trial-3-s8.log`
- SOL install: `tmp/e28df8d0/sol-install-s8-r3.log` (2.66 MB)
- Installer syslog: `tmp/e28df8d0/installer-syslog-s8-r3.log` (190 KB)
- State dir: `state/os-setup/server8/`

## Phase 別所要時間

| Phase | 時間 |
|-------|------|
| iso-download | 0m17s |
| preseed-generate | 0m07s |
| iso-remaster | 0m17s (sha256 reuse hit) |
| bmc-mount-boot | 1m47s |
| install-monitor | 10m18s |
| post-install-config | 6m54s |
| pve-install | 22m21s (default route 消失 2 回 + DHCP timeout 1 回のリカバリ込み) |
| cleanup | 1m04s |
| **total** | **43m05s** |

Monitor ツール未使用、sol-monitor / ssh-wait はすべて Bash foreground で block 実行。
