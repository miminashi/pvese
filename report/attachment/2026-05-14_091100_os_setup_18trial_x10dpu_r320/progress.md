# server4-9 OS setup 18 trial デグレ検証 進捗ログ

- ISSUE: #65
- SESSION_ID: e28df8d0
- REPORT_TS: 2026-05-14_091100
- 開始: 2026-05-14 09:11 JST

## Trial 進捗

| Trial | サーバ | 結果 | 開始 | 終了 | wall | attempt | リカバリ | メモ |
|-------|--------|------|------|------|------|---------|---------|------|
| 1-s4 | server4 | ✓ success | 09:13:37 | 10:10:40 | 57m03s | 0 | なし | 新規問題3件: find-boot-entry失敗(ATEN空)・SOL base64 silent失敗・ssh-wait IP直渡しkey auth失敗 |
| 1-s5 | server5 | ✓ success | 12:31:32 | 13:08:16 | 35m51s | 4 (Sonnet x2 中間応答, Opus 解析, Opus 再走) | preseed手動修正・boot-override Hdd UEFI | 🔥 **デグレ確定**: generate-preseed.sh が choose_interface=eno2np1+use_mirror=false → choose-mirror が mgmt NIC からネット不通でループ。server6 でも再現の可能性大 |
| 1-s6 | server6 | ✓ success | 13:13:00 | 13:46:49 | 33m38s | 1 | preseed手動修正 (s5デグレ 100% 再現) | 新規問題なし、既知 workaround 全機能。Problem 5 (SSH 一時 refused) 再現 |
| 1-s7 | server7 | ✓ success | 13:49:31 | 14:45:44 | 54m46s | 1 | VM 再mount 1回、pre-pve-setup 再実行 2回、post-reboot resume 1回、dhclient 1回 | iDRAC で新規問題なし。generate-preseed.sh デグレは手動 preseed で影響なし。NVRAM #47 は preseed early_command で予防済 |
| 1-s8 | server8 | ✓ success | 14:49:05 | 15:33:48 | 43m54s | 1 | VM 再mount 1回、LINBIT keyring 配置 1回、drbd-dkms 復旧 1回 | drbd-dkms `stdio.h` 失敗 (build-essential 不在、SKILL 既知) → 事後リカバリ。server7 と異なり Phase 7 final route 消失せず、IB 非搭載 |
| 1-s9 | server9 | ❌ giveup | 15:35:52 | 16:37:33 | 1h02m | 3 | VM 再mount 2回, racreset soft 1回, Enter 2回 | 🚨 **NVRAM 枯渇 #47 発火?**: attempt 1=grub-install fail, attempt 2-3=GRUB→kernel boot 不能。個体差。server9 は Round 2 で BIOS F3 Load Defaults 推奨 |
|  |  |  |  |  |  |  |  |  |
| **Round 1 集計** | 6 サーバ | 5/6 success, 1 giveup | 09:13 | 16:37 | 7h24m | - | - | x10dpu 全 3 台 success (s5/s6 は preseed 手動修正), r320 2/3 success (s9 giveup) |
|  |  |  |  |  |  |  |  |  |
| 2-s4 | server4 | ✓ success | 16:41:11 | 17:10:44 | 28m41s | 1 | preseed 手動修正 (デグレ 100% 再現) | 新規: 既存 socat (UDP 5514) orphan 居座り (Phase 5 干渉リスク)。POST 92 ハングなし |
| 2-s5 | server5 | ✓ success | 17:13:00 | 17:54:12 | 40m37s | 1 | preseed 手動修正 | sol-monitor exit 4 (SOL keepalive のみ) → syslog 確認で完了判定。machine-id +264s で真の install 確定 |
| 2-s6 | server6 | ❌ giveup | 17:55:47 | 19:25:08 | 1h29m | 4 | preseed 手動修正、boot-override Cd UEFI | 🚨 **HW故障**: DIMM P2-DIMMA1 Uncorrectable memory → kernel panic (initramfs uncompression failed)。Round 1 で発火せず Round 2 で顕在化。スキルのデグレではなくハード故障 |
| 2-s7 | server7 | ✓ success | 19:26:54 | 20:30:12 | 1h03m | 1 | dhcpcd 手動取得 1回、pre-pve-setup 再実行 2回、post-reboot resume 1回、dhclient 1回 | build-essential pre-install で drbd-dkms 予防成功 (Round 1 s8 で発火、Round 2 s7 で予防) |
| 2-s8 | server8 | ✓ success (再実行) | 20:35:58 | 21:30:00 | 53m53s | 1 | dhcpcd 60s, pre-pve-setup 再実行 x3 | ⚠️ 先行 subagent が state リセット無視 (指示違反) → 親が強制リセットして再実行。再実行は machine-id +6m34s で真の fresh install 確定。build-essential 予防成功 |
| 2-s9 | server9 | ❌ giveup | 21:32:32 | 23:08:19 | 1h35m | 3 | racreset soft x3 | 🚨 **NVRAM 枯渇 #47 完全再現** (Round 1 と同一症状)。3/3 attempt で `efivarfs_set_variable: No space left`。preseed early_command の cleanup が機能せず |
|  |  |  |  |  |  |  |  |  |
| **Round 2 集計** | 6 サーバ | 4/6 success, 2 giveup | 16:41 | 23:08 | 6h27m | - | - | x10dpu 2/3 success (s6 HW故障で giveup), r320 2/3 success (s9 NVRAM 枯渇 giveup) |
|  |  |  |  |  |  |  |  |  |
| 3-s4 | server4 | ✓ success | 23:11:21 | 00:07:55 | 56m25s | 1 | preseed 手動修正, dhcpcd 手動, pre-pve-setup 再実行 | 新規: Debian 13 minimal は isc-dhcp-client 不在で eno1np0 boot 直後 DOWN |
| 3-s5 | server5 | ✓ success | 00:11:41 | 00:44:49 | 33m08s | 1 | preseed 手動修正 | sol-monitor exit 4 false positive 再現 → installer-syslog で確認 |
| 3-s6 | server6 | ❌ giveup | 00:48:26 | 01:11:16 | 22m50s | 1 (即giveup) | preseed 手動修正、boot-override Cd UEFI | 🚨 **HW 故障 3 ラウンド連続**: Round 3 では BIOS が DIMM 完全 Disable (16 GiB のまま)。別 issue 化マスト |
| 3-s7 | server7 | ✓ success | 01:14:57 | 02:24:51 | 1h10m | 2 | VM re-mount, dhcpcd 60s, pre-pve-setup 再実行 x2, dhclient | Phase 4 attempt 1 で false positive (exit 4) → re-mount で attempt 2 成功 |
| 3-s8 | server8 | ✓ success (再実行) | 02:33:15 | 03:16:31 | 43m05s | 1 | dhcpcd 60s, pre-pve-setup 再実行 x2 | ⚠️ 先行 subagent Monitor pause → 親リセットして再実行。machine-id +6m17s で fresh install。既知罠のみ、新規なし |
| 3-s9 | server9 | ✓ **success (想定外)** | 03:18:09 | 04:04:10 | 45m36s | 1 | dhcpcd, pre-pve-setup 再実行 | 🎯 **NVRAM 枯渇 #47 が再現せず install 完走**! Round 1+2 で 6/6 fail だったが Round 3 では成功 → 間欠的故障確定 |
|  |  |  |  |  |  |  |  |  |
| **Round 3 集計** | 6 サーバ | 5/6 success, 1 giveup | 23:11 | 04:04 | 4h53m | - | - | x10dpu 2/3 (s6 HW故障で giveup), r320 3/3 success (s9 NVRAM 復活!) |
|  |  |  |  |  |  |  |  |  |
| **総合計** | 18 trial | **14/18 success (78%)**, 4 giveup | 09:13 (5/14) | 04:04 (5/15) | 約19h | - | - | giveup 全 4 件 すべて HW 起因 (server6 DIMM x2, server9 NVRAM 枯渇 x2)。スキル起因の giveup なし |
