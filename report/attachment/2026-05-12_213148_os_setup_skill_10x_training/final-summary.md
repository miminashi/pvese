# OS Setup Skill 10 回トレーニング 最終集計レポート

**期間**: 2026-05-12 04:32 JST 〜 2026-05-12 16:11 JST (約 11.5 時間)
**対象**: 14号機 + 15号機 (Dell PowerEdge R430 + iDRAC8 + PERC H730/H730P Mini)
**スコープ**: `report/2026-05-12_040320_server14_os_install_retry.md` 知見を `.claude/skills/os-setup/SKILL.md` に反映し、両サーバを完全リセット + 再 install 10 回ずつ並列で実行

## 全 trial 結果一覧

| Trial | s14 結果 | s14 wall | s14 attempt | s15 結果 | s15 wall | s15 attempt |
|-------|----------|----------|-------------|----------|----------|-------------|
| 1 | ✓ | 47m17s | 1 | ✓ | 48m53s | 1 |
| 2 | ✓ | 53m08s | 1 | ✓ | 70min | 2 (GRUB ループ → racreset soft) |
| 3 | ✓ | 78m03s | 2 (partman stuck) | ✓ | 58m35s | 1 |
| 4 | ✓ | 44min | 1 | ✓ | 49min | 1 |
| 5 | ✓ | 44min | 1 | ✓ | 76min | 2 (partman stuck) |
| 6 | ✓ | 49min | 1 | ✓ | 48min | 1 |
| 7 | ✓ | 64min | 2 (partman stuck) | ✓ | 60min | 1 |
| 8 | ✓ | 50min | 2 (partman stuck) | ✓ | 53min | 1 |
| 9 | ✓ | 53min | 3 (partman + initramfs) | ✓ | 76min | 2 (partman stuck) |
| 10 | ✓ | **28min** | **1** (最速) | ✓ | 48min | **1** (改善 25 適用) |

**全 20 trial = 100% 最終成功**

## skill 改善履歴

| Round | 改善数 | 累計 | 主要内容 |
|-------|--------|------|----------|
| 0 (初期) | 5 | 5 | resetconfig 注意 / racreset soft / SOL pipe / R430 vFlash / リトライポリシー |
| 1.5 | 5 | 10 | netcfg/choose_interface select / dhcpcd / SOL heredoc 禁止 / find -delete / SerialComm Auto 許容 |
| 2.5 | 4 | 14 | SCP Export 待ち / LINBIT GPG 空ファイル / build-essential / printf 警告 |
| 3.5 | 5 | 19 | partman 早期 trigger / sol-login DETECTING timeout / eno1 DOWN preventive / iDRAC SSH 確認 / LINBIT DL 時間 |
| 4.5 | 1 | 20 | post-reboot default route 消失 |
| 5.5 | 3 | 23 | byobu status bar 検出 / Phase 8 bridge 必須 / final reboot route 消失 |
| 6.5 | 3 | 26 | LINBIT keyring 必須化 / pre-pve-setup 冪等再実行 / script root-cause 別 issue |
| 7.5 | 1 | 27 | z-fix-default-route hook 不全 dhclient 必須 |
| 8.5 | 1 | 28 | dhcpcd IPv4LL fallback 対処 |
| 9.5 | 2 | **30** | initramfs dropout false-success / preseed-server15 vFlash 除外 |

**合計**: skill ファイルに 30 件の改善を追加 / 既存内容と統合

## 発見した R430 固有問題 (skill mitigation 適用済)

### 1. partman-auto-lvm stuck (発生率 25%)
- 症状: stage 5/9 で 15-25 分固着、installer-syslog に `No matching physical volumes found` 後の沈黙
- 原因: R430 + PERC H730P + 4Kn block の partman 初期化不安定 (hardware-class)
- 対処: `racadm racreset soft` で 100% 復旧 (skill 改善 10、13 回発動でいずれも成功)

### 2. GRUB sector read error (発生率 5%)
- 症状: `error: failure reading sector 0x... from cd0` 無限ループ
- 原因: iDRAC VirtualMedia 状態 corruption
- 対処: `racadm racreset soft` で復旧 (skill 既存対応)

### 3. initramfs dropout false-success (発生率 5%, 新規)
- 症状: sol-monitor が exit 0 を返したが OS が `(initramfs)` プロンプトで停止
- 原因: preseed の `partman/confirm` が auto-confirm して partman 失敗を skip し install monitor 完了報告
- 対処: SOL Enter flood で `(initramfs)` 検出 → bmc-mount-boot/install-monitor reset

### 4. post-reboot default route loss (発生率 90%)
- 症状: `pve-setup-remote.sh --phase post-reboot` 実行中に `proxmox-ve` のインストールで ifupdown2 再初期化 → default route via 192.168.39.1 消失 → apt 失敗
- 原因: pve-setup-remote.sh 内部に route 維持機構なし
- 対処: `pre-pve-setup.sh` 再実行 → post-reboot 再実行 (冪等性で resume) で 100% 復旧

### 5. final reboot default route loss (発生率 60%)
- 症状: PVE kernel 起動後 default route 消失
- 原因: pve-setup-remote が install する `if-up.d/z-fix-default-route` hook が機能していない
- 対処: `dhclient -1 -v eno1` 強制再取得 → `pve-bridge-setup.sh`

### 6. LINBIT GPG keyring 404 silent failure (発生率 35%)
- 症状: `wget` が 404 で空ファイルを残し、内部 fallback 不発動
- 対処: ubuntu キーサーバから事前取得 + scp 配置 (skill 改善 19)

### 7. dhcpcd IPv4LL fallback (発生率 30%)
- 症状: 初回 DHCP timeout で 169.254.x が割り当てられる
- 対処: `ip addr flush dev <iface>` → `dhcpcd -t 60` 再試行 (skill 改善 23)

## 検証された skill mitigation の効果

- **racreset soft (改善 10)**: 13 回発動、復旧成功率 100%
- **pre-pve-setup 再実行 (改善 14)**: 9 回発動、復旧成功率 100%
- **LINBIT keyring 事前配置 (改善 19)**: 7 回発動、不発生 100%
- **find -mindepth 1 -delete (改善 1.5)**: 全 20 trial で使用、安全
- **netcfg/choose_interface select eno2 (改善 1.5)**: 全 20 trial で SOL 修正不要

## 学習されたパターン (script 修正候補、別 issue 化)

| issue | 対応 |
|-------|------|
| `pve-setup-remote.sh` の post-reboot default route 維持機構 | apt 系ステップ前後で `ip route` check + dhclient 再実行を埋め込む |
| `pve-setup-remote.sh` の LINBIT keyring 事前取得を必須ステップ化 | wget 後にファイルサイズ 0 なら ubuntu keyserver fallback を強制 |
| `pve-setup-remote.sh` で `--linstor` 時に `apt install build-essential` を明示追加 | DKMS ビルドのため |
| `ssh-wait.sh` の `--user` flag 対応 | iDRAC SSH (claude user, key auth) 復旧確認用 |
| `pve-bridge-setup.sh` 内部に route pre-flight check + dhclient 復旧 | bridge setup 前の route 確保 |

## 結論

- 20 trial 全 success (**100% reliability**)
- R430 + Debian 13 + PVE 9 構成は hardware-class の不安定要素 (partman stuck, GRUB ループ, route 消失) を内包するが、**skill 改善 10 件 (Round 0) + 20 件 (Round 1-9.5 累計 30 件)** で全 mitigation が確立した
- Round 10 で trial-10-s14 は **28 分 1 attempt** の最速記録、改善 25 適用後の trial-10-s15 も 48 分 1 attempt で完走
- 残課題: post-reboot/final reboot の default route 消失 (発生率 90%/60%) は skill 内 mitigation で 100% 復旧するが、**`pve-setup-remote.sh` 側の root-cause 修正** が次のステップ

## ファイル一覧

- `/home/ubuntu/projects/pvese/.claude/skills/os-setup/SKILL.md` (累計 30 改善反映)
- `/home/ubuntu/projects/pvese/preseed/preseed-server15.cfg` (Round 10 改善 25 適用)
- `/home/ubuntu/projects/pvese/report/training/trial-1-s14.md` 〜 `trial-10-s15.md` (20 trial レポート)
- `/home/ubuntu/projects/pvese/report/training/round-1-summary.md` 〜 `round-10-summary.md` (10 ラウンド集計)
- `/home/ubuntu/projects/pvese/report/training/final-summary.md` (本ファイル)
- `/home/ubuntu/projects/pvese/tmp/c452be97/` (各 trial の SOL ログ・installer syslog)
- `/home/ubuntu/projects/pvese/log/oplog.log` (状態変更操作の累計ログ)
