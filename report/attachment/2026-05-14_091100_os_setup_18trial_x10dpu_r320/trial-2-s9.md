# Trial 2 server9 レポート

- **結果**: **giveup** (Round 1 と完全同一の NVRAM exhaustion を再現)
- **開始時刻**: 2026-05-14 21:32:32 JST
- **完了時刻**: 2026-05-14 23:08:19 JST
- **所要時間 (wall)**: 1h 35m 47s
- **attempt 数**: 3 (Round 1 と同じく 3 attempt 全て NVRAM No space left エラー)

## 試行した NVRAM クリーンアップ方法: **Option C (Round 1 と同じ条件で再現性確認)**

- Option A (efibootmgr 経由) は既存 OS が動作しないため不可
- Option B (BIOS F2 NVRAM クリア) は idrac7 BootMode 破壊リスクで非実施
- 各 attempt 前に `racadm racreset soft` を実施 (BMC state clean)
- preseed の early_command 内 NVRAM cleanup (efivars rm -f) が既に組み込まれているが、機能していない

## 発動したリカバリ

- 各 attempt 前: `racadm racreset soft` → VirtualMedia 再 mount → boot-once VCD-DVD → power on
- attempt 失敗判定後: `racadm serveraction powerdown` → 次 attempt 準備

## 観察した問題 (Round 1 と同じ症状が再現したか): **完全再現**

3 attempt 全てで以下のエラー (installer syslog):
```
grub-installer: grub-install: warning: efivarfs_set_variable: writing to fd 12 failed: No space left on device.
grub-installer: grub-install: warning: _efi_set_variable_mode: ops->set_variable() failed: No space left on device.
grub-installer: grub-install: error: failed to register the EFI boot entry: No space left on device.
grub-installer: error: Running 'grub-install --force-extra-removable --force "/dev/sda"' failed.
```

- sol-monitor: stage=7/9 で `<Go Back>` ダイアログにより stuck
- **真因**: preseed/early_command の NVRAM cleanup (`rm -f /sys/firmware/efi/efivars/Boot####-*`) が server9 で機能していない
- 2026-04-11 レポートで記録された「server 9 は本質的に NVRAM 枯渇が間欠的に発生する個体」と整合
- Round 2 は 3/3 attempt 全て NVRAM full で、Round 1 (3/3 fail) と完全に同一

## 最終検証 (machine-id mtime チェック含む): **不可**

- Phase 5 完走せず SSH 到達不能
- PowerState=Off に到達せず、`/etc/machine-id` 更新確認不可
- Web UI (https://10.10.10.209:8006) 接続不可
- vmbr0/vmbr1 未構築

## ログ参照

- 試行ログ: `tmp/e28df8d0/trial-2-s9.log`
- SOL 各 attempt: `tmp/e28df8d0/sol-install-s9-r2-a{1,2,3}.log`
- installer syslog 統合: `tmp/e28df8d0/installer-syslog-s9-r2.log`
- 関連レポート: `report/2026-04-11_123226_grub_install_nvram_exhaustion_confirmed.md` (server 9 間欠 NVRAM 枯渇の既知記録)

## Phase 別所要時間

| Phase | 所要時間 | 状態 |
|-------|---------|------|
| iso-download | 0m22s | done |
| preseed-generate | 0m10s | done |
| iso-remaster | 1m53s | done |
| bmc-mount-boot | 5m41s | done |
| install-monitor | ~1h 24m (3 attempt 計) | **failed** |
| post-install-config 以降 | — | 未実行 |

## 結論

Round 1 (15:35-16:37) で giveup した NVRAM exhaustion (#47) が Round 2 で 3 attempt 全てで完全再現。server 9 の iDRAC7 NVRAM は preseed/early_command の efivars cleanup では空き領域回復できない状態。

根本対処 (本 trial 範囲外):
1. 物理 CMOS リセット
2. BIOS F2 で "Reset to Defaults" (VNC BIOS UI 経由)
3. preseed/early_command の改良 (efivars unlink 後に `efibootmgr -B` を明示実行)

Issue #47 を再確認し、本 Round 2 結果を追記する別 issue 化推奨。
