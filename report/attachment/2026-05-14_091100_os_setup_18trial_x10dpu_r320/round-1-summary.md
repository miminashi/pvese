# Round 1 集計

- **期間**: 2026-05-14 09:13:37 〜 16:37:33 JST (約 7h24m)
- **結果**: **5 / 6 success** (83%), 1 giveup
- **総 trial 数**: 6 (server4-9 × 1 trial)

## Trial 別結果

| Trial | サーバ | 機種 | 結果 | wall | attempt | 主要事象 |
|-------|--------|------|------|------|---------|---------|
| 1-s4 | server4 | X11DPU | ✓ success | 57m03s | 1 | 古い preseed (前セッション残置) 流用で偶然成功、新規問題3件発見 |
| 1-s5 | server5 | X11DPU | ✓ success | 35m51s | 4 (Sonnet x2 中間応答, Opus 解析, Opus 完走) | 🔥 generate-preseed.sh デグレ確定、手動修正で完走 |
| 1-s6 | server6 | X11DPU | ✓ success | 33m38s | 1 | s5 と同 workaround で 1 attempt 完走 |
| 1-s7 | server7 | R320 | ✓ success | 54m46s | 1 | preseed 手動管理で影響なし、SKILL.md 既知罠通り |
| 1-s8 | server8 | R320 | ✓ success | 43m54s | 1 | drbd-dkms `stdio.h` 失敗 (build-essential 不在) → 事後復旧 |
| 1-s9 | server9 | R320 | ❌ giveup | 1h02m | 3 | 🚨 NVRAM 枯渇 #47 発火?、grub-install fail + kernel boot 不能 |

## 🔥 デグレ確定 (本タスクの主成果)

### Degradation 1: `generate-preseed.sh` リグレッション

**症状**:
- VLAN 非対応サーバ (server4-9 想定) で `choose_interface=eno2np1` (mgmt NIC) + `apt_use_mirror=false` を出力
- preseed.cfg.template が `mirror/http/hostname=deb.debian.org` を残すため、anna が choose-mirror udeb を依然インストール
- eno2np1 (10.0.0.0/8 mgmt) からは deb.debian.org に届かないため `wget` が timeout → "mirror does not support trixie" WARNING ループ → installer ハング

**再現性**: server5 (新規生成 preseed で発火) + server6 (新規生成 preseed で発火) で 100% 再現
- server4 は前セッションの古い preseed (`choose_interface=auto` + `use_mirror=true` 形) が残置していたためたまたま成功

**Workaround (本 trial で適用)**:
- generate-preseed.sh 実行後、出力 preseed の以下を手動編集:
  - `d-i netcfg/choose_interface select eno2np1` → `select auto`
  - `d-i apt-setup/use_mirror boolean false` → `boolean true`
  - `no_mirror=true` → `no_mirror=false`
  - `cdrom/set-next=false` → `cdrom/set-next=true`
- iso-remaster は preseed sha256 変更で自動再リマスター

**影響範囲**: server4-6 (X11DPU + generate-preseed.sh 使用) のみ。server7-9 (R320) は preseed 手動管理 (preseed-server7/8/9.cfg) のため影響なし

**別 issue 化**: 必要 (本タスクのスコープは検証で、修正は別 issue 提案)

### Degradation 2 (軽微): `racreset soft` 後 VirtualMedia config 消失

- iDRAC racreset soft 完了後、`Remote File Share is Disabled` になり、再 mount + boot-once 再設定が必要
- SKILL.md には記載なし (server9 attempt 2 で発見)
- 別 issue 化: SKILL.md への追記推奨

## 既知問題の再現状況

| 既知問題 | server4 | server5 | server6 | server7 | server8 | server9 |
|---------|---------|---------|---------|---------|---------|---------|
| find-boot-entry ATEN 失敗 | ✓ | ✓ | ✓ | N/A | N/A | N/A |
| SOL base64 silent 失敗 | ✓ (workaround) | preseed late_command で回避 | preseed late_command で回避 | N/A | N/A | N/A |
| ssh-wait raw IP key auth 失敗 | ✓ | workaround 適用 | workaround 適用 | N/A | N/A | N/A |
| VirtualMedia 既存セッション干渉 | N/A | N/A | N/A | ✓ | ✓ | ✓ |
| Phase 7 post-reboot route 消失 | × | × | × | ✓ | × (z-fix hook 機能) | 未到達 |
| Phase 7 final reboot route 消失 | × | × | × | ✓ | × | 未到達 |
| drbd-dkms stdio.h ビルド失敗 | × | × | × | × | ✓ (事後復旧) | 未到達 |
| LINBIT keyring 事前配置 | × | × | × | ✓ (preventive) | ✓ (preventive) | 未到達 |
| Phase 6 SSH 一時 refused | × | ✓ | ✓ | × | × | 未到達 |
| boot-override-reset 後 iPXE 起動 | × | ✓ | ✓ | N/A | N/A | N/A |

## 機種別観察 (デグレ判定)

### x10dpu (server4-6) — Supermicro X11DPU

- **過去観察と比較**: skill 改善前の動作は不明だが、preseed 手動修正で 3/3 success
- **新規 workaround 要件**: find-boot-entry (BIOS 4.0 BootOptions API 空)、boot-override Hdd UEFI (Phase 6 disk first boot)
- **デグレ判定**: 🔥 **generate-preseed.sh のリグレッションがデグレ**。手動修正で完走可能だが、skill としての自動化が破綻
- **POST 92 ハング**: server4 で観測されず (memory 記載の傾向だが今回は発火せず)

### r320 (server7-9) — DELL PowerEdge R320

- **過去観察と比較**: server7/8 は 1 attempt で完走 (R430 系 10x training と同等の安定性)
- **デグレ判定**: server7/8 については **デグレなし**。server9 は個体差で giveup (#47 NVRAM 枯渇疑い)
- **NVRAM 枯渇予防**: preseed の `early_command` が efivarfs クリーンアップを実行。server7/8 では効いたが server9 では効かず → preseed の EFI clear が不十分なケースあり

## Round 2 への申し送り事項

1. **server4-6**: generate-preseed.sh デグレが残っているなら手動修正を継続。修正されたら自動化で進む
2. **server7-9 (R320 共通)**:
   - VirtualMedia 既存セッション干渉は必ず発火する想定 → umount → 5s → 再 mount を Phase 4 標準フローに
   - Phase 7 post-reboot / final reboot route 消失は個体差あり (server7=発火、server8=非発火、server9=未到達)
   - LINBIT keyring 事前配置 + build-essential 事前 install を Phase 7 標準前処理に
   - `racreset soft` 後は VirtualMedia config 消失を想定して再 mount
3. **server9**: NVRAM 枯渇問題のため BIOS F3 Load Defaults (VNC BIOS Setup 経由、racadm BootMode 変更は禁止) を試す
4. **subagent モデル**: Opus 必須 (Sonnet では tool_uses 制限で完走不能)、Monitor ツール禁止厳守

## Round 2 への影響予測

- Round 2 server9 で NVRAM クリーンアップが効けば success、効かなければ別 issue 化
- generate-preseed.sh が未修正なら server5/6 で再度 workaround 必要 (本 trial 中の修正済 preseed は state リセットで上書きされる可能性)
- 他の既知罠は予防策込みで 1 attempt 完走を期待
