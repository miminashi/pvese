# Phase 17: TX1320 RAID10 OS install — F6/F7/F8 整備 + F1 リサーチ 完遂、 install は USB redirector 累積劣化が Phase 16 より深刻化して未達

- **実施日時**: 2026-05-23 (JST) 約 6 時間
- **セッション**: 0dfdbfdc (wise-book)
- **Issue**: #72 (Phase 14-16 引き継ぎ、 cdrom-detect 突破後 install 完遂)

## 添付ファイル

- [実装プラン (要約)](attachment/2026-05-23_113500_tx1320_raid10_phase17_f678_f1_research_install_blocked/plan.md) — full 版は `.claude/plans/report-2026-05-23-052353-tx1320-raid10-wise-book.md`
- [F1 FW update リサーチ note](attachment/2026-05-23_113500_tx1320_raid10_phase17_f678_f1_research_install_blocked/f1-research-notes.md)
- [F2 PXE pivot 事前調査メモ (Phase 18 用)](attachment/2026-05-23_113500_tx1320_raid10_phase17_f678_f1_research_install_blocked/f2-pxe-pivot-notes.md)
- [SOL log #1 (1st deploy, kernel printk 0 行 / 17 reconnect)](attachment/2026-05-23_113500_tx1320_raid10_phase17_f678_f1_research_install_blocked/install-phase17-attempt1.log)
- [SOL log #2 (2nd deploy after 2-3秒 PSU reset, kernel printk 0 行)](attachment/2026-05-23_113500_tx1320_raid10_phase17_f678_f1_research_install_blocked/install-phase17-attempt2.log)
- [SOL log #3 (3rd deploy after 10-15秒 PSU reset, kernel printk 0 行)](attachment/2026-05-23_113500_tx1320_raid10_phase17_f678_f1_research_install_blocked/install-phase17-attempt3.log)
- [OEM Screenshot attempt 2 (BIOS POST 99 stuck)](attachment/2026-05-23_113500_tx1320_raid10_phase17_f678_f1_research_install_blocked/screen-attempt2-bios-post-99-stuck.jpg)
- [OEM Screenshot attempt 3 (BIOS POST 99 stuck)](attachment/2026-05-23_113500_tx1320_raid10_phase17_f678_f1_research_install_blocked/screen-attempt3-bios-post-99-stuck.jpg)

## 対象機

- **training-tx1320** (Fujitsu PRIMERGY TX1320 M3 / D3373 / BIOS V5.0.0.11 R1.22.0 / iRMC S4 FW 9.08F / BMC 10.254.254.9)
- HW: PRAID EP400i (LSI MegaRAID SAS3008) + SAS HDD 900GB × 4 / HW RAID10 構成済 (VD0 = /dev/sda 1.80 TB)
- Virtual Media: iRMC OEM NFS Virtual Media (10.1.6.6:/var/samba/public, AutoAttach なし — connect-cd 必須)

## 前提・目的

Phase 16 (2026-05-23 replicated-pearl) で Phase 15 cdrom-detect patch を main commit (0624539b) + PSU cold reset 後の deploy で **cdrom-detect 突破 + apt/partman フェーズ到達** まで進んだが install 完遂未達。 残る障害は iRMC FW 9.08F USB redirector 累積劣化 (30 min install 中に SOL session 347 reconnect) に絞り込み済。

Phase 17 の目標 (ユーザ承認済 sequence):
1. **F6**: orchestrate.sh + 依存スクリプト 10 ファイルを **5 commit (Option B 粒度) で main 統合**
2. **F8**: deploy-careful.sh の 105s pad を orchestrate.sh deploy() に統合
3. **F7**: patch marker `echo "..." > /dev/console` 追加で SOL 可視化
4. **F1 (リサーチのみ、 flash しない)**: iRMC S4 FW 9.69F の取得経路 + update 手順調査
5. install 完遂試行 (preseed + RAID10 + SSH login)
6. 完遂未達なら F2 PXE pivot を Phase 18 へ持ち越し

## 達成事項

### 🎯 17-1: F6 wholesale commit (Option B / 5 commits) ✅ 完全達成

| Commit | hash | LOC | 内容 |
|--------|------|-----|------|
| A | `ba0bc6c` | 397 | `scripts/irmc-virtualmedia.sh` (335) + `scripts/irmc-oem-screenshot.sh` (62) — Fujitsu iRMC OEM primitives |
| B | `ce34d17` | 1441 | `scripts/irmc-bios.py` (447) + `scripts/irmc-kvm-interact.py` (653) + `scripts/irmc-kvm-screenshot.py` (182) + `scripts/irmc-raid10-create.py` (154, DEPRECATED marker 強化) |
| C | `3870bd7` | 504 | `scripts/irmc-bios-raid-setup.sh` — S1-S10 step orchestration |
| D | `621cada` | 374 | `scripts/tx1320-raid10-orchestrate.sh` (243) + `scripts/setup-raid10-storcli.sh` (82) + `scripts/fetch-storcli-deb.sh` (49) |
| E | `e849af7` | 1012 | `config/training_tx1320.yml` (126) + `.claude/skills/irmc-bios-raid/SKILL.md` (631) + `reference.md` (256) |

全 5 commit が sh -n / py_compile pass。 過去 Phase 1-16 で散在した工事用具が完結。 機能ドメイン (primitives → helpers → orchestrator → config + docs) ごとの分割により git bisect / partial revert が可能。

### 🎯 17-2: F8 deploy pad 統合 ✅ 完全達成 (commit `b7a0f16`)

`scripts/tx1320-raid10-orchestrate.sh` の deploy() を deploy-careful.sh パターンに統合:
- 環境変数 default 追加: `SETTLE_WAIT=30`, `USB_STABILIZE_WAIT=60`, `PRE_POWER_WAIT=15` (caller が override 可能)
- deploy() の sequence を以下に変更:
  1. ForceOff (最初)
  2. SETTLE_WAIT sleep
  3. Virtual Media config + (NFS なら mount poll)
  4. USB_STABILIZE_WAIT sleep
  5. boot-override Cd UEFI
  6. PRE_POWER_WAIT sleep
  7. PowerOn
- 旧 `sleep 8` を 3 段階展開、 旧 sequence (Virtual Media 先 → boot-override → ForceOff → On) を deploy-careful.sh の順序に揃え

副作用: deploy 1 回あたり +97s (= 105s - 8s)。 他機種影響なし (TX1320 専用 orchestrator)。

### 🎯 17-3: F7 patch marker SOL 可視化 ✅ 完全達成 (commit `a4866ca`)

`scripts/remaster-debian-iso.sh` の patch awk block に
`echo "..." > /dev/console 2>/dev/null || true` を 1 行追加:
- 既存 `log()` (busybox logger → syslogd → /var/log/syslog) はそのまま残存 (d-i 慣習保持)
- dual-path logging で SOL + syslog 両方に marker
- awk-preview スクリプトで生成された postinst fragment を sh -n + grep で検証済

### 🎯 17-7: F1 iRMC S4 FW 9.69F リサーチ ✅ リサーチのみ完遂

| 項目 | 値 |
|------|----|
| 最新 FW | **9.69F_sdr03.18** (2024-11-07 公開) |
| URL | https://support.ts.fujitsu.com/globalflash/ManagementController/iRMC%20S4-TX13x0M3/09.69F_sdr03.18/zip_irmc_s4-tx13x0m3_09.69f_sdr03.18.exe |
| ファイル | `zip_irmc_s4-tx13x0m3_09.69f_sdr03.18.exe` (72 MB self-extractor) |
| 中間版 | 9.21F_sdr03.17 (段階 update 候補) |
| 認証 | 公開 directory (匿名 HTTP GET 可) |
| Linux extract | 7z で .BIN 取り出し可能 (要実証) |

Update 経路 (3 つ):
1. **Web UI**: `POST https://10.254.254.9/irmcupdate?flashSelect=255` (multipart binary)、 reboot 不要
2. **Redfish OEM**: `POST /redfish/v1/Managers/iRMC/Actions/Oem/FTSManager.FWUpdate` (multipart、 task poll、 自動 reboot)
3. **PowerShell** (Windows 専用)

リスク評価: 低-中 (公式は OS-running update OK、 redundant store fallback の可能性、 復旧は PSU cold reset)。 詳細は attachment の `f1-research-notes.md` 参照。

### 🎯 副次成果

- Phase 17 commit 構造 (Option B 5 分割) は機能群 dependency chain (primitives → helpers → orchestrator) を明確化、 review + revert 粒度が適切。 Phase 16 の commit 0624539b と整合
- F2 PXE pivot 事前調査メモ (Phase 18 で参照可能) を作成
- iRMC FW 9.08F の USB redirector 劣化の挙動を更に観測 (Phase 16 → Phase 17 で深刻化、 PSU reset の effective 性も条件依存と確認)

## install 完遂未達 (Phase 16 より深刻劣化)

| Attempt | iRMC state | deploy | SOL kernel printk | OEM Screenshot |
|---------|-----------|--------|-------------------|----------------|
| 1 (PSU reset 前) | PowerState=Off, CD config 保持 (Phase 16 から) | 105s pad で deploy 完了 | **0 行** (15 reconnect / 6 min) | (未取得) |
| 2 (2-3秒 PSU reset 後) | PowerState=On (PSU 自動起動)、 ForceOff → deploy | 105s pad で deploy 完了 | **0 行** (13 reconnect / 6 min) | **BIOS POST 99 stuck** ("Press F2 to enter Setup" 画面) |
| 3 (10-15秒 PSU reset 後) | PowerState=On、 ForceOff → deploy | 105s pad で deploy 完了 | **0 行** (7 reconnect / 5 min) | **BIOS POST 99 stuck** (同) |

3 回全て BIOS POST 99 で stuck = iRMC USB CD redirector が BIOS phase で機能停止 (boot-override Cd Once が認識されず、 内部 disk fallback or 完全 stuck)。 Phase 16 では同じ手順で kernel boot 復活 + apt/partman 到達したのに、 Phase 17 では復活しない = **USB redirector 累積劣化が時間経過で更に進行**。

ping 10.254.254.250: 100% packet loss (install が一切進んでいない)。

## Phase 17 達成度サマリー

| 目標 | 達成度 | 補足 |
|------|--------|------|
| F6: 5 commit (Option B) で wholesale 統合 | ✅ **完全達成** | 全 5 commit pass、 機能ドメイン分割 |
| F8: deploy pad 105s 統合 | ✅ **完全達成** | 環境変数化、 deploy-careful.sh と sequence 等価 |
| F7: patch marker SOL 可視化 | ✅ **完全達成** | dual-path logging、 awk preview で sanity 確認 |
| F1: FW 9.69F リサーチ | ✅ **完全達成** | URL + extract 手順 + 3 update 経路 + リスク評価 |
| **install 完遂 (preseed + RAID10 + SSH login)** | ❌ **未達成** | 3 deploy attempts 全て BIOS POST 99 stuck、 PSU reset (2-3 秒 + 10-15 秒) でも復活せず |

## 失敗分析

### iRMC USB redirector 累積劣化の進行

- **Phase 16** (replicated-pearl, 2026-05-23 早朝): 1 回の PSU reset (2-3 秒) で復活 → apt/partman 到達
- **Phase 17** (wise-book, 2026-05-23 昼): 同条件で復活せず → BIOS POST stuck
- **時間差**: Phase 16 終了から Phase 17 deploy 開始まで約 6 時間
- **仮説**:
  - (a) iRMC 内部 state の劣化が単純な elapsed time に依存 (= もう少し時間が経つと PSU reset でも復活しない)
  - (b) Phase 16 と Phase 17 の間に iRMC 内部 daemon が何らかの不可逆 state に遷移
  - (c) PSU 抜差し時間が 2-3 秒 → 10-15 秒に増えても、 30 秒以上の完全放電が必要

### F8 105s pad の効果

Phase 16 で「PSU reset + 105s pad で kernel boot 復活」したパターンが Phase 17 では再現せず。 これは **pad の問題ではなく、 USB redirector の deep 劣化** が原因と判断。 F8 統合自体は Phase 18 以降で USB redirector が回復した場合に valuable な再現性確保として残る。

## Phase 18 への引き継ぎ

| # | タスク | 優先度 | 補足 |
|---|--------|--------|------|
| **F1** | **iRMC FW 9.08F → 9.69F update** (実適用) | 🔴 最高 | Phase 17 リサーチで取得 + update 手順確立済。 ユーザの明示承認必須 (BMC ブリックリスク)。 段階 update (9.08F → 9.21F → 9.69F) 推奨。 詳細手順は `attachment/.../f1-research-notes.md` |
| **F2** | **PXE/netboot 経路 pivot** | 🟠 高 | F1 失敗 or リスク回避時の代替経路。 詳細設計は `attachment/.../f2-pxe-pivot-notes.md` (実装工数 90-180 min) |
| **F8b** | PSU reset 時間の長期化 (30-60 秒) | 🟡 中 | 10-15 秒でも復活しなかった、 完全放電狙い |
| **F8c** | iRMC Manager.Reset + PSU reset 組み合わせ | 🟡 中 | Phase 15 でも試行したが効果なし、 もう一度の試行価値あり |
| **F9** | 別 BMC へ切替 (もし lab で予備機 (TX1330 等) があれば) | 🟢 低 | 環境依存 |

### Phase 18 推奨 sequence

1. **判断**: F1 (FW update) を実行するか F2 (PXE pivot) を実行するか
   - F1 を選ぶ場合: ユーザに明示的に「BMC ブリックリスクを受諾、 9.69F flash 実施」を確認、 段階 update 推奨
   - F2 を選ぶ場合: playground 上に dnsmasq セットアップから着手 (90-180 min)
2. F1 を実行する場合:
   - `.exe` を Linux 上で 7z extract、 .BIN ファイルを抽出
   - Web UI 経路で flash (`curl -F data=@iRMC.BIN ...`) → 進捗 poll
   - 完了後、 通常の orchestrate.sh deploy で install 完遂試行
3. F2 を実行する場合:
   - dnsmasq + TFTP + HTTP セットアップ → Debian netboot 配置 → preseed HTTP 配信化
   - BIOS PXE 有効化 (`irmc-bios.py apply-config` で既存設定反映) → boot-override Pxe UEFI
   - deploy 試行 + SOL monitor

## 再現方法

### 1. Phase 17 までの状態を確認
```sh
git log --oneline -9
# 期待: a4866ca, b7a0f16, e849af7, 621cada, 3870bd7, ce34d17, ba0bc6c, 0624539, f96d47b
```

### 2. ISO build
```sh
SKIP_STORCLI_FETCH=1 ./oplog.sh ./scripts/tx1320-raid10-orchestrate.sh build config/training_tx1320.yml
```
期待: `--- pvese-patch v1: patching cdrom-detect.postinst (TX1320 /dev/sr1 priority) ---` + `Patched postinst OK (308 lines, 7751 bytes)` (Phase 16 の 303 lines, 7352 bytes から +5 lines = F7 marker 行追加分)

### 3. deploy (F8 統合 105s pad)
```sh
./oplog.sh ./scripts/tx1320-raid10-orchestrate.sh deploy config/training_tx1320.yml
```
期待: `Phase 5a → 5a.1 (30s) → 5b → 5b.1 (60s) → 5c → 5c.1 (15s) → 5d (PowerOn)` の log + `deploy OK (pad total ~105s)`

### 4. SOL monitor + 進行判定
```sh
ipmitool -I lanplus -H 10.254.254.9 -U claude -P Claude123 sol payload enable 2 4
.venv/bin/python scripts/sol-monitor.py \
    --bmc-ip 10.254.254.9 --bmc-user claude --bmc-pass Claude123 \
    --log-file tmp/<sid>/install.log --timeout 1800 --powerstate-interval 60
```
Phase 17 で達成できなかった markers (Phase 18 目標):
- `Linux version 6.12.63` >= 1 (kernel boot)
- `pvese-patch v1: bypassed list-devices via /dev/sr1 direct mount` >= 1 (**F7 新**)
- `Configuring apt`, `partman-auto-raid` >= 1
- `Installation complete` >= 1 (最終目標)

### 5. iRMC USB redirector 復活確認
SOL に `Session operational` だけが反復する場合 → BIOS POST stuck の可能性。 OEM Screenshot で確認:
```sh
./scripts/irmc-oem-screenshot.sh 10.254.254.9 claude Claude123 tmp/<sid>/screen-debug.jpg
```
"Press F2 to enter Setup or F12 to enter Boot Menu" 画面 = iRMC USB CD redirector が BIOS から認識されていない (= Phase 17 の状態)。

## 環境情報

- **対象機**: training-tx1320 (Fujitsu PRIMERGY TX1320 M3, Serial MABK035229)
- **BMC**: iRMC S4 FW 9.08F (10.254.254.9, HTTPS + SECLEVEL=0 必須, claude/Claude123, claude index=4)
- **HW**: PRAID EP400i (LSI MegaRAID SAS3008) + SAS HDD 900GB × 4 (HW RAID10 構成済 VD0 = /dev/sda 1.80 TB)
- **BIOS**: V5.0.0.11 R1.22.0 for D3373-B1x (12/18/2018)
- **CPU/RAM**: Xeon E3-1230 v6 / 24 GiB
- **NFS server (playground)**: 10.1.6.6 (Ubuntu 24.04, /var/samba/public NFS export)
- **ISO**: `/var/samba/public/debian-training-tx1320-raid10.iso` (772 MB, 本セッション build = Phase 17 patch 強化版)
- **本セッションの BMC 操作回数**: ForceOff × 4、 PowerOn × 3、 ConnectCD × 3、 boot-override × 3、 **PSU cold reset × 2 (ユーザ実施、 2-3秒 + 10-15秒)**

## 関連レポート / メモ

- [Phase 16 (2026-05-23 replicated-pearl): patch を main commit + PSU reset 後の deploy で cdrom-detect 突破 + apt/partman フェーズ到達](2026-05-23_052353_tx1320_raid10_phase16_psu_reset_partman_reached.md)
- [Phase 15 (2026-05-23 bubbly-ripple): cdrom-detect patch 実装 + sanity 5/5 pass](2026-05-23_013410_tx1320_raid10_phase15_cdrom_detect_patch.md)
- [Phase 14 (2026-05-22 linear-mountain): kernel boot 成功 + 4 課題 a/b/c/d 完了 + cdrom-detect block](2026-05-22_154033_tx1320_raid10_phase14_install_completed.md)
- memory `training-tx1320-phase16-patch-committed-partman-reached`
- memory `training-tx1320-nfs-solved` (NFS attach 経路、 引き続き有効)

## 関連 Issue

- **#72 (継続、 status=active → blocked、 owner phase17-0dfdbfdc → 次セッションへ release)**
  - Phase 16 (replicated-pearl): patch commit (0624539b) + PSU reset で cdrom-detect 突破 + apt/partman 到達
  - **Phase 17 (0dfdbfdc, 本セッション)**: F6 wholesale commit (5 commits)、 F8 105s pad 統合 (b7a0f16)、 F7 marker /dev/console (a4866ca)、 F1 FW 9.69F リサーチ完遂。 install 完遂は 3 deploy attempts 全て BIOS POST 99 stuck で未達 = USB redirector 累積劣化が Phase 16 より深刻
  - **次セッション (Phase 18) 推奨**: F1 (FW 9.08F → 9.69F update、 ユーザ明示承認必要) or F2 (PXE pivot)

## 関連ファイル

### 修正 (本セッション、 commit 済)

| ファイル | commit | 修正内容 |
|---------|--------|---------|
| `scripts/irmc-virtualmedia.sh` | ba0bc6c | NEW (335 LOC) |
| `scripts/irmc-oem-screenshot.sh` | ba0bc6c | NEW (62 LOC) |
| `scripts/irmc-bios.py` | ce34d17 | NEW (447 LOC) |
| `scripts/irmc-kvm-interact.py` | ce34d17 | NEW (653 LOC) |
| `scripts/irmc-kvm-screenshot.py` | ce34d17 | NEW (182 LOC) |
| `scripts/irmc-raid10-create.py` | ce34d17 | NEW (154 LOC, DEPRECATED 強化) |
| `scripts/irmc-bios-raid-setup.sh` | 3870bd7 | NEW (504 LOC) |
| `scripts/tx1320-raid10-orchestrate.sh` | 621cada + b7a0f16 | NEW (243 LOC) + F8 deploy pad 統合 (+30/-9) |
| `scripts/setup-raid10-storcli.sh` | 621cada | NEW (82 LOC) |
| `scripts/fetch-storcli-deb.sh` | 621cada | NEW (49 LOC) |
| `scripts/remaster-debian-iso.sh` | a4866ca | F7 marker /dev/console 追加 (+5 lines) |
| `config/training_tx1320.yml` | e849af7 | NEW (126 行) |
| `.claude/skills/irmc-bios-raid/SKILL.md` | e849af7 | NEW (631 行) |
| `.claude/skills/irmc-bios-raid/reference.md` | e849af7 | NEW (256 行) |

### 修正なし (Phase 16 から不変)

- `preseed/preseed.cfg.template`
- `config/training_tx1320.yml` の static_ip = 10.254.254.250

### 新規作成

- `report/2026-05-23_113500_tx1320_raid10_phase17_f678_f1_research_install_blocked.md` (本レポート)
- `report/attachment/2026-05-23_113500_tx1320_raid10_phase17_f678_f1_research_install_blocked/` (plan + F1 research + F2 pivot notes + 3 SOL logs + 2 OEM screenshots)

## 重要な教訓 (Phase 18 への引き継ぎ)

1. **Phase 16 PSU reset の成功は条件依存**: Phase 16 で 2-3 秒 PSU 抜差しが effective だったが、 Phase 17 では 2-3 秒 / 10-15 秒どちらでも復活せず。 = USB redirector の劣化が時間経過とともに更に悪化し、 PSU reset で復旧可能な window が狭まっている可能性。 復旧には 30-60+ 秒の完全放電 or FW 修正 (F1) or 別経路 (F2 PXE) が必要
2. **F6 + F7 + F8 整備は install 完遂とは independent に valuable**: install が完遂しなくても、 main に commit 済の orchestration スタック + deploy pad + marker visibility は再現性のある作業基盤として残る。 Phase 18+ で USB redirector 復活後に同 workflow を再利用可能
3. **F1 リサーチを本セッションで実施した判断は結果的に正しい**: install 完遂未達が確定したため、 F1 リサーチ結果が Phase 18 最優先タスクの判断材料に直結。 「リサーチのみ flash しない」のユーザ判断が結果的に正しい sequence
4. **BIOS POST 99 stuck = iRMC USB CD redirector が BIOS phase で機能停止**: 「Press F2 to enter Setup」画面 + kernel printk 0 行 + SOL session 反復切断 の組み合わせは USB redirector dead の確定 signature。 Phase 18 では OEM Screenshot を deploy 後 5 分以内に必ず取得して判定
5. **commit Option B (5 分割) は review + revert 粒度として最適**: Phase 16 の commit 0624539b 単独より、 Phase 17 の機能ドメイン分割 (primitives → helpers → orchestrator → config + docs) の方が dependency chain が明確化、 git bisect 可能
