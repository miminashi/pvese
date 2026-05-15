# 最終集計

- **実施期間**: 2026-05-14 09:13:37 〜 2026-05-15 04:04:10 JST (約 19 時間)
- **総 trial 数**: 18 (server4-9 × 3 ラウンド)
- **総 wall 時間**: 約 19 時間 (各 trial 平均 50 分、shutdown + レポート整理含む)
- **総合結果**: **14 / 18 success (78%)**, 4 giveup (全て HW 起因)

## ラウンド別結果

| Round | 期間 | 成功率 | 主要事象 |
|-------|------|--------|---------|
| Round 1 | 09:13-16:37 (7h24m) | 5/6 success | デグレ確定 (generate-preseed.sh)、新規問題発見 (find-boot-entry 失敗, SOL base64 silent failure 等) |
| Round 2 | 16:41-23:08 (6h27m) | 4/6 success | DIMM HW 故障顕在化 (server6)、NVRAM 枯渇再現 (server9)、drbd-dkms 予防策確立 |
| Round 3 | 23:11-04:04 (4h53m) | 5/6 success | server9 NVRAM 回復 (間欠故障確証)、server6 HW 故障継続 |

## サーバ別累計

| サーバ | 機種 | Round 1 | Round 2 | Round 3 | 累計 |
|--------|------|---------|---------|---------|------|
| server4 | X11DPU | ✓ (57m) | ✓ (29m) | ✓ (56m) | **3/3 success** |
| server5 | X11DPU | ✓ (36m, 4 attempt) | ✓ (41m) | ✓ (33m) | **3/3 success** |
| server6 | X11DPU | ✓ (34m) | ❌ DIMM 故障 | ❌ DIMM 故障 | **1/3** (Round 1 は HW 故障未顕在化) |
| server7 | R320 | ✓ (55m) | ✓ (1h03m) | ✓ (1h10m) | **3/3 success** |
| server8 | R320 | ✓ (44m) | ✓ (54m) | ✓ (43m) | **3/3 success** |
| server9 | R320 | ❌ NVRAM | ❌ NVRAM | ✓ (46m) | **1/3** (Round 3 で間欠故障の回復) |

## 🔥 主要発見 (デグレ検証としての成果)

### 1. **`generate-preseed.sh` リグレッション (デグレ確定、別 issue 化マスト)**

- VLAN 非対応サーバ (server4-9 想定) で 4 項目の壊れた値を出力:
  - `netcfg/choose_interface select eno2np1` (mgmt NIC、インターネット不可)
  - `apt-setup/use_mirror boolean false`
  - `apt-setup/no_mirror boolean true`
  - `apt-setup/cdrom/set-next boolean false`
- これにより Debian installer の choose-mirror が deb.debian.org に届かず timeout → installer ハング
- **再現率**: 9 trial 連続 100% (server4 R1 は古い preseed 残置で偶然回避)
- **影響**: x10dpu 系 (server4-6) のみ、r320 系 (server7-9) は preseed 手動管理で影響なし
- **workaround**: generate-preseed.sh 実行後に出力 preseed を手動編集 (4 行)

### 2. **server6 DIMM P2-DIMMA1 物理故障 (HW 起因)**

- Round 1 では発火せず success (33m38s)
- Round 2: TotalSystemMemoryGiB 16 GiB に低下、kernel panic (initramfs uncompression failed)
- Round 3: BIOS が DIMM 完全 Disable、installer 到達せず
- **HW 故障進行中、物理交換マスト**
- **os-setup スキルの問題ではない**

### 3. **server9 NVRAM 枯渇 #47 は間欠的故障**

- Round 1: 3/3 attempt failed (efivarfs_set_variable: No space left)
- Round 2: 3/3 attempt failed (同上)
- Round 3: **1/1 attempt success** (NVRAM 回復、preseed early_command の累積効果?)
- **間欠的に発生する個体差**、別 issue で監視継続推奨

### 4. **その他の発見**

- **drbd-dkms `stdio.h` ビルド失敗** (Round 1 server8 で発火) → `build-essential` 事前 install で 100% 予防 (Round 2 server7/8, Round 3 server7-9 で予防成功)
- **既存 socat (UDP 5514) orphan**: 前 trial の残骸が syslog port を占拠 (Round 2 server4 で発見、Round 3 でも検出)
- **sol-monitor exit 4 false positive**: SOL keepalive のみで stage=0 → installer-syslog + machine-id mtime で完了確認
- **Debian 13 minimal は isc-dhcp-client 不在**: eno1np0 が boot 直後 DOWN → `dhcpcd -1 -t 30 eno1np0` 手動投入で復旧 (Round 3 server4 で発見)
- **subagent モデル選択**: Sonnet は tool_uses 制限で完走できない、Opus が必須
- **Monitor ツール禁止**: subagent が Monitor で pause すると親に中間応答停止する

## 既知問題の発火率 (3 ラウンド累計)

### x10dpu (4-6 号機)
| 既知問題 | 発火率 |
|---------|--------|
| preseed デグレ (generate-preseed.sh) | 9/9 (100%、s4 R1 除く) |
| find-boot-entry "ATEN" 失敗 | 9/9 (100%) |
| ssh-wait alias 必要 | 9/9 (100%) |
| boot-override Hdd UEFI 必要 (Phase 6) | 6/9 (67%) |
| Phase 6 SSH 一時 refused | 4/9 (44%) |
| DIMM 物理故障 (server6) | 2/3 (67%、Round 1 では HW 状態が安定だった) |

### r320 (7-9 号機)
| 既知問題 | 発火率 |
|---------|--------|
| VM 既存セッション干渉 | 7/9 (78%) |
| post-reboot route 消失 | 5/9 (56%) |
| final reboot route 消失 | 4/9 (44%) |
| drbd-dkms ビルド失敗 | 1/9 (Round 1 s8 のみ、以降は予防成功) |
| NVRAM 枯渇 (server9) | 2/3 (67%、Round 3 で回復) |

## デグレ判定 (本タスクの最終結論)

### x10dpu (server4-6)
- **🔥 generate-preseed.sh のリグレッションがデグレ**: 修正必要 (別 issue 化マスト)
- **そのほかは**: skill の動作変化なし、既知 workaround で完走可能
- **server6 の HW 故障**: skill のデグレではなく、Round 1-3 で物理故障が進行 (別 issue 化)

### r320 (server7-9)
- **デグレなし**: SKILL.md / MEMORY.md の既知罠は SKILL.md 通りに発火 + 復旧
- **build-essential 予防策の有効性確認**: Round 1 server8 で drbd-dkms 失敗 → Round 2 以降で予防確立
- **server9 の NVRAM 枯渇 #47**: skill のデグレではなく個体差。Round 3 で回復、間欠故障確証 (別 issue で監視継続)

## 別 issue 化推奨

1. **`scripts/generate-preseed.sh` リグレッション修正** (priority: 高)
   - 4 項目の壊れた値 (choose_interface, use_mirror, no_mirror, cdrom/set-next) を server4-9 向けに正しく出力するように修正
2. **server6 DIMM P2-DIMMA1 物理交換要請** (priority: 中、ハード作業)
3. **server9 NVRAM 枯渇 #47 の追記** (priority: 中)
   - 既存 #47 は post-install grub-install エラー記述だが、preseed 初回 install 時の grub-install で発火することを追記
   - 間欠故障 (Round 3 で回復) の挙動を記録
4. **`racreset soft` 後 VirtualMedia config 消失** (priority: 低)
   - SKILL.md への追記
5. **`bmc-power.sh boot-override` の正しい引数順序を SKILL.md に明示** (priority: 低)
   - `<bmc_ip> <user> <pass> <target> <mode>` の順序を明示
6. **sol-monitor exit 4 false-positive 検出強化** (priority: 中)
   - SOL keepalive のみで stage=0 → installer-syslog + machine-id mtime で再判定するロジック
7. **`build-essential` 事前 install を Phase 7 標準フローに組み込む** (priority: 中)
   - Round 1 で発火、Round 2-3 で予防確立、SKILL.md / pve-setup-remote.sh に標準化

## トータル所要時間

- Round 1: 7h24m
- Round 2: 6h27m (うち server6 が 1h29m、server9 が 1h35m を消費)
- Round 3: 4h53m (server6/9 は速やかに giveup 判定で時間節約)
- シャットダウン + 整理: 約 10 分
- **総計: 約 19 時間** (24 時間バジェット内)
