# Trial 3 server9 レポート

- **結果**: **success** (想定外: NVRAM 枯渇 #47 が再現せず install 完走)
- **開始時刻**: 2026-05-15 03:18:09 JST
- **完了時刻**: 2026-05-15 04:04:10 JST
- **所要時間 (wall)**: 約 46 分 (45m36s)
- **attempt 数**: 1 (giveup 不要)

## NVRAM 枯渇 #47 の再現性確認: **再現せず**

Round 1+2 で **6/6 attempt が `grub-install: efivarfs_set_variable: No space left on device` で failed** だったが、本 trial では grub-install が `Installation finished. No error reported.` で正常完了。

考えられる原因:
- preseed `early_command` の EFI variable cleanup が有効に作用 (Round 2 では iDRAC state が異なっていた)
- Round 2 の 3 attempt 連続 fail + racreset soft の累積効果で NVRAM が解放
- 個体差 (server9 NVRAM 枯渇は間欠的、2026-04-11 レポートと整合)

## 観察した問題

### 既知 (Round 1+2 server7/8 で既出)
- post-reboot 中の default route 消失 → pre-pve-setup.sh 再実行
- 初回 DHCP timeout → dhcpcd manual fallback
- Final reboot 後の route 消失 → dhcpcd 復旧

### 新規問題: なし

## 最終検証 (success)

- `pveversion`: pve-manager/9.1.11/8eac2c86f015bdda (kernel 7.0.2-2-pve)
- vmbr0 (10.10.10.209/8) + vmbr1 (192.168.39.190/24) 両方 UP
- `default via 192.168.39.1 dev vmbr1`
- Web UI: HTTP 200
- **machine-id mtime > install-monitor.start (FALSE positive チェック PASS)**

## ログ参照

- `tmp/e28df8d0/sol-install-s9.log`
- `tmp/e28df8d0/sol-monitor-s9-trial3.log`
- `tmp/e28df8d0/installer-syslog-s9-trial3.log`
- subagent 別レポート: `report/2026-05-15_040410_server9_trial3_os_install.md` (本ファイルと等価)

## Phase 別所要時間

| Phase | 所要時間 |
|-------|---------|
| iso-download | 0m17s |
| preseed-generate | 0m03s |
| iso-remaster | 1m54s |
| bmc-mount-boot | 1m40s |
| install-monitor | 12m08s |
| post-install-config | 6m54s |
| pve-install | 21m36s |
| cleanup | 1m04s |
| **合計** | **45m36s** |

## 結論

- Issue #65 (Round 3 trial-3-s9): **完了 (success)**
- **Issue #47 (NVRAM 枯渇) は確率的・状態依存で発生**することが本 trial で示された
- Round 1+2 では 6/6 fail だったが、本 trial では再現せず
- Issue #47 は **open のまま別 issue として monitor 継続を推奨** (再現する可能性が依然ある)
