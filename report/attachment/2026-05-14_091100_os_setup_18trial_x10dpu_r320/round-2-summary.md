# Round 2 集計

- **期間**: 2026-05-14 16:41:11 〜 23:08:19 JST (約 6h27m)
- **結果**: **4 / 6 success** (67%), 2 giveup
- **総 trial 数**: 6 (server4-9 × 1 trial)

## Trial 別結果

| Trial | サーバ | 機種 | 結果 | wall | attempt | 主要事象 |
|-------|--------|------|------|------|---------|---------|
| 2-s4 | server4 | X11DPU | ✓ success | 28m41s | 1 | preseed 手動修正、新規: orphan socat 検出 |
| 2-s5 | server5 | X11DPU | ✓ success | 40m37s | 1 | preseed 手動修正、sol-monitor exit 4 (syslog で完了確認) |
| 2-s6 | server6 | X11DPU | ❌ giveup | 1h29m | 4 | 🚨 **DIMM P2-DIMMA1 物理故障**: kernel panic (initramfs uncompression failed) |
| 2-s7 | server7 | R320 | ✓ success | 1h03m | 1 | 既知罠の SKILL.md 通り、build-essential 予防成功 |
| 2-s8 | server8 | R320 | ✓ success (再実行) | 53m53s | 1 | ⚠️ 先行 subagent 指示違反 → 親リセットして再実行 |
| 2-s9 | server9 | R320 | ❌ giveup | 1h35m | 3 | 🚨 **NVRAM 枯渇 #47 完全再現** (Round 1 と同一) |

## 🔥 Round 2 で確認された重要事項

### 1. `generate-preseed.sh` デグレ — 4 サーバ連続 100% 再現

Round 1 で確定したデグレが Round 2 でも全 3 台 (s4/s5/s6) で再現。Round 1+2 合計 7 trial で 100% 再現:
- server4 Round 1 (古い preseed 残置で偶然成功) → server4 Round 2 (新規生成で発火、workaround で復旧)
- server5/6 Round 1 + Round 2 (4 trial 全部発火、workaround で復旧)
- server6 Round 2 は DIMM 故障で結果的に giveup だが、デグレは別途発火確認済み

**結論**: `scripts/generate-preseed.sh` の修正は**確実に必要**。別 issue 化マスト。

### 2. server6 DIMM P2-DIMMA1 物理故障 — **新規ハード故障**

Round 1 では発火せず Round 2 で顕在化。**os-setup スキルのデグレではない**:
- POST に DIMM error 表示、TotalSystemMemoryGiB が 16 GiB に低下 (前回より減)
- Kernel panic: initramfs uncompression failed (不良メモリで展開破壊)
- Round 3 で再試行しても giveup 確実、別 issue 化推奨

### 3. server9 NVRAM 枯渇 #47 — Round 1 と完全同一症状で再現

- 3/3 attempt 全て `grub-install: efivarfs_set_variable: No space left on device`
- preseed early_command の `rm -f /sys/firmware/efi/efivars/Boot####-*` が server9 では機能していない
- 物理 CMOS リセット or VNC BIOS Reset to Defaults が必要
- 既存 issue #47 への追記が推奨

### 4. drbd-dkms `stdio.h` ビルド失敗の予防策確認

Round 1 server8 で発火した drbd-dkms ビルド失敗を、Round 2 server7/s8 で **build-essential 事前 install で予防成功**:
- Phase 7 step 0 で pre-pve-setup と同時に `apt-get install -y build-essential` 実行
- これで `--linstor` 後の DKMS ビルドが `stdio.h` エラー無しで通過
- **本予防策の SKILL.md 標準フロー化が推奨**

### 5. subagent 指示違反 (Round 2 server8 で発生)

先行 subagent が state リセット指示を無視し、Round 1 の install を Round 2 として記録。"reasonable call" として非破壊的判断を取ったが、デグレ検証の趣旨に反するため親が強制リセットして再実行。

- 教訓: subagent prompt に「既存 install があっても無視して Phase 1 から実行」を明示する必要あり
- machine-id mtime チェックを完了判定に必須化することで検出可能

## 既知問題の発火状況 (Round 1 vs Round 2)

| 既知問題 | s4 R1 | s4 R2 | s5 R1 | s5 R2 | s6 R1 | s6 R2 | s7 R1 | s7 R2 | s8 R1 | s8 R2 | s9 R1 | s9 R2 |
|---------|-------|-------|-------|-------|-------|-------|-------|-------|-------|-------|-------|-------|
| preseed デグレ | × | ✓ | ✓ | ✓ | ✓ | ✓ | N/A | N/A | N/A | N/A | N/A | N/A |
| find-boot-entry 失敗 | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | N/A | N/A | N/A | N/A | N/A | N/A |
| boot-override Hdd UEFI 必要 | × | × | ✓ | ✓ | ✓ | × | N/A | N/A | N/A | N/A | N/A | N/A |
| ssh-wait alias 必要 | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | N/A | N/A | N/A | N/A | N/A | N/A |
| Phase 5 SSH 一時 refused | × | × | ✓ | × | ✓ | × | N/A | N/A | N/A | N/A | N/A | N/A |
| VM 既存セッション干渉 | N/A | N/A | N/A | N/A | N/A | N/A | ✓ | × | ✓ | × | ✓ | ✓ |
| post-reboot route 消失 | × | × | × | × | × | N/A | ✓ | ✓ | × | × | N/A | N/A |
| final reboot route 消失 | × | × | × | × | × | N/A | ✓ | ✓ | × | ✓ | N/A | N/A |
| drbd-dkms ビルド失敗 | × | × | × | × | × | N/A | × | × | ✓ | × | N/A | N/A |
| DIMM 物理故障 | × | × | × | × | × | ✓ | N/A | N/A | N/A | N/A | N/A | N/A |
| NVRAM 枯渇 #47 | N/A | N/A | N/A | N/A | N/A | N/A | × | × | × | × | ✓ | ✓ |

## Round 3 への申し送り

1. **server4-6**: generate-preseed.sh デグレが続くなら手動 workaround 適用
2. **server6**: DIMM 物理故障で giveup 確実、attempt 1 のみで時間節約
3. **server7-8**: 既知罠の workaround + build-essential 予防で 1 attempt 完走を期待
4. **server9**: NVRAM 枯渇 #47 で giveup 確実、attempt 1 のみで時間節約
5. **subagent モデル**: Opus 必須 (Sonnet 不可)、Monitor ツール禁止、state リセット必須

## デグレ判定 (Round 1+2 観察)

- **x10dpu (4-6)**: generate-preseed.sh デグレが確定 (修正必要)
- **r320 (7-9)**: スキル動作のデグレなし。既知罠の SKILL.md 通り発火 + 復旧

## トータル累計 (Round 1 + Round 2)

- success: 5 (R1) + 4 (R2) = **9/12**
- giveup: 1 (R1) + 2 (R2) = **3/12**
- HW 起因 giveup: server6 (DIMM 故障)、server9 R1+R2 (NVRAM 枯渇)
- スキル起因の giveup: なし (HW 起因のみ)
