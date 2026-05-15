# Trial 1 server6 レポート

- **結果**: success
- **開始時刻**: 2026-05-14T13:13 JST (init 開始)
- **完了時刻**: 2026-05-14T13:46:49 JST
- **所要時間 (wall)**: 33m38s
- **attempt 数**: 1 (リカバリなしで完走)

## preseed workaround の必要性: あり (generate-preseed.sh デグレが再現)

- 出力: `choose_interface=eno2np1` + `apt_use_mirror=false` + `no_mirror=true` + `cdrom/set-next=false`
- 修正: `choose_interface=auto` + `apt_use_mirror=true` + `no_mirror=false` + `cdrom/set-next=true` (s5 と同形)
- → server5 で確定したデグレが server6 でも 100% 再現することを実証

## 発動したリカバリ

なし (1 attempt で完走)

## 観察した問題

### 既知問題 (Round 1 共通、s4/s5 で発見済)

- **preseed degradation**: `generate-preseed.sh` が依然 `eno2np1` + `apt_use_mirror=false` を出力。s5 と同じ手動修正で解決
- **Problem 1**: `find-boot-entry "ATEN Virtual CDROM"` 失敗予防 → `boot-override Cd UEFI` で代替成功 (BIOS 4.0 で安定動作)
- **Problem 4**: Phase 6 のディスクブート時に iPXE 競合の可能性 → `boot-override Hdd UEFI` を事前設定し disk boot に成功
- **Problem 5**: Final reboot 後 SSH 一時 connection refused → `ssh-wait pve6` 成功するも `pveversion` 実行時に refused。再度 `ssh-wait` (90秒待機) で復旧

### 新規問題

観察なし。 既知の workaround 群 (Problem 1, 4, 5) はすべて期待通り機能した。

## 最終検証 (success)

```
pveversion           = pve-manager/9.1.11/8eac2c86f015bdda (running kernel: 7.0.2-2-pve)
ip route show default = default via 192.168.39.1 dev vmbr1
vmbr0                = 10.10.10.206/8 UP
vmbr1                = 192.168.39.184/24 UP (DHCP)
Web UI               = https://10.10.10.206:8006 接続可 (HTML 返却)
OS                   = Debian GNU/Linux 13 (trixie)
```

## ログ参照

- `tmp/e28df8d0/trial-1-s6.log` (trial log)
- `tmp/e28df8d0/sol-install-s6.log` (SOL monitor)
- `tmp/e28df8d0/installer-syslog-s6.log` (3277 行)
- `tmp/e28df8d0/kvm-s6-postboot.png` (boot 後 login プロンプト確認)
- `tmp/e28df8d0/trial-1-s6-summary.txt`

## Phase 別所要時間

| Phase | Duration |
|-------|----------|
| iso-download | 0m13s |
| preseed-generate | 0m49s |
| iso-remaster | 1m52s |
| bmc-mount-boot | 0m58s |
| install-monitor | 8m59s |
| post-install-config | 7m47s |
| pve-install | 12m03s |
| cleanup | 0m57s |
| **total** | **33m38s** |

## 特記事項

Round 1 server6 trial-1 は 1 attempt で完走 (s4/s5 と同等の安定性確認)。Monitor ツール禁止指示は厳守 — 全長時間待機 (sol-monitor.py / ssh-wait.sh / pve-setup-remote.sh) は Bash blocking で実行。 既知 workaround 群はすべて期待通り機能した。
