# Round 3 集計

- **期間**: 2026-05-14 23:11:21 〜 2026-05-15 04:04:10 JST (約 4h53m)
- **結果**: **5 / 6 success** (83%), 1 giveup
- **総 trial 数**: 6 (server4-9 × 1 trial)

## Trial 別結果

| Trial | サーバ | 機種 | 結果 | wall | attempt | 主要事象 |
|-------|--------|------|------|------|---------|---------|
| 3-s4 | server4 | X11DPU | ✓ success | 56m25s | 1 | preseed 手動修正、新規: Debian 13 minimal で eno1np0 boot 直後 DOWN |
| 3-s5 | server5 | X11DPU | ✓ success | 33m08s | 1 | sol-monitor exit 4 (SOL keepalive のみ) → installer-syslog で確認 |
| 3-s6 | server6 | X11DPU | ❌ giveup | 22m50s | 1 (即giveup) | 🚨 DIMM HW 故障 3 ラウンド連続、Round 3 では BIOS が DIMM 完全 Disable |
| 3-s7 | server7 | R320 | ✓ success | 1h10m | 2 | Phase 4 attempt 1 で false positive → re-mount で attempt 2 成功 |
| 3-s8 | server8 | R320 | ✓ success (再実行) | 43m05s | 1 | ⚠️ 先行 subagent Monitor pause → 親リセットで再実行 |
| 3-s9 | server9 | R320 | ✓ **success (想定外)** | 45m36s | 1 | 🎯 NVRAM 枯渇 #47 が再現せず install 完走 |

## 🎯 Round 3 の主成果

### server9 NVRAM 枯渇 #47 が再現せず — 間欠故障の確証

- Round 1: 3/3 attempt failed (NVRAM full)
- Round 2: 3/3 attempt failed (NVRAM full)
- **Round 3: 1/1 attempt success**

**Issue #47 は確率的・状態依存** であることが確証された。考えられる原因:
- Round 2 の 6 attempt 連続 fail + racreset soft の累積で NVRAM が解放
- preseed `early_command` の EFI variable cleanup が Round 3 で有効に作用
- 個体差 (NVRAM 枯渇は間欠的、2026-04-11 レポートで既に記録された傾向と整合)

**結論**: server9 NVRAM 枯渇は **間欠的に発生**、複数 attempt + racreset soft で回復する可能性あり

### server6 DIMM 故障が 3 ラウンド連続再現

- Round 1: 発火せず (success 33m)
- Round 2: kernel panic (initramfs uncompression failed)
- Round 3: BIOS が DIMM 完全 Disable、installer 到達せず

→ **HW 故障進行中、物理交換マスト**

### Round 3 で発見した小さな新規問題

- Trial 3-s4: Debian 13 minimal は `isc-dhcp-client` 不在で eno1np0 が boot 直後 DOWN → Phase 7 初回 pre-pve-setup で DNS 解決失敗時は `dhcpcd -1 -t 30 eno1np0` 手動投入

## 既知問題の発火率 (3 ラウンド累計)

| 既知問題 | x10dpu (4-6) 発火率 | r320 (7-9) 発火率 |
|---------|--------------------|--------------------|
| preseed デグレ | 9/9 trial (100%、s4 R1 除く) | N/A (preseed 手動管理) |
| find-boot-entry 失敗 | 9/9 trial (100%) | N/A |
| boot-override Hdd UEFI 必要 | 6/9 trial (67%) | N/A |
| ssh-wait alias 必要 | 9/9 trial (100%) | N/A |
| Phase 5 SSH 一時 refused | 4/9 trial (44%) | N/A |
| VM 既存セッション干渉 | N/A | 7/9 trial (78%) |
| post-reboot route 消失 | 0/9 trial | 5/9 trial (56%) |
| final reboot route 消失 | 0/9 trial | 4/9 trial (44%) |
| drbd-dkms ビルド失敗 | 0/9 trial | 1/9 trial (Round 1 s8 のみ、以降は予防成功) |
| DIMM 物理故障 (server6) | 2/3 trial | N/A |
| NVRAM 枯渇 #47 (server9) | N/A | 2/3 trial |

## デグレ判定 (Round 1+2+3 累計)

- **x10dpu (4-6)**: **`generate-preseed.sh` デグレ** が確定 (9/10 trial で再現、s4 R1 は古い preseed 残置で偶然回避)。修正必要 (別 issue 化)
- **r320 (7-9)**: スキル動作のデグレなし。既知罠の SKILL.md 通り発火 + 復旧

## トータル累計 (Round 1 + Round 2 + Round 3)

- **14 / 18 success (78%)**
- giveup 内訳:
  - server6 (DIMM 故障): Round 2, 3 で 2 件 → **HW 起因、別 issue 化マスト**
  - server9 (NVRAM 枯渇): Round 1, 2 で 2 件 → **間欠故障、別 issue 化推奨**
  - Round 3 で server9 が回復 (success) して間欠性確証
- **スキル起因の giveup: 0 件** (全 giveup は HW 起因)

## デグレ検証としての結論

**os-setup スキル自体は健全** (R430 改善が x10dpu/r320 に副作用を起こしていない)。

唯一の確定デグレは **`generate-preseed.sh` のリグレッション** (x10dpu 系の preseed 自動生成が壊れている)。これは別 issue で修正必要。

server6 (HW) と server9 (NVRAM 間欠) は スキルの問題ではなく、別 issue で個別追跡。
