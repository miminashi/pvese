# TX1320 BIOS 網羅リファレンス — KVM 全タブ実機存在確認レポート

- **実施日時**: 2026年6月10日 17:39 (JST)
- **対象機**: training-tx1320 (Fujitsu PRIMERGY TX1320 M3 / iRMC S4 FW 9.69F / 10.254.254.9)
- **成果**: `irmc-bios-raid` スキルの `bios/` リファレンス全 per-tab ファイルを、WinSCU XML(2026-05-16 取得)を主データ源にしつつ **全 7 タブ + Advanced 全サブメニューを KVM/OEM screenshot で巡回し実機存在確認**して充足。最重要発見 = **「XML ⊋ Setup UI」**(NVRAM 全集合 vs HW 構成依存の可視部分集合)。

## 添付ファイル

- [実装プラン](attachment/2026-06-10_173934_tx1320_bios_reference_kvm_alltabs_verification/plan.md)

## 前提・目的

`irmc-bios-raid` スキルに TX1320 M3(board D3373-B1x / AMI Aptio)の全 BIOS 設定項目を網羅した
per-tab リファレンス(`bios/`)を作成した。データ源は **WinSCU XML を主にしつつ、ユーザ要請により
各設定が実機 BIOS Setup にも存在することを KVM で必ず確認**する方針(2026-06-07 承認)。

- **背景**: XML(Redfish BSPBR で取得、91 設定)は値・選択肢・デフォルト・ヘルプを構造化保持するが、
  タブ/サブメニュー所属情報を持たず(setupItemID 順のフラットリスト)、`name` から best-effort で振り分けた。
- **目的**: 各設定が実機の Setup UI に実在することを確認し、所属を確定し、XML に無い項目(読み取り専用情報・
  メニュー構造)を補い、各 per-tab ファイルの「KVM 確認」を更新する。
- **前提条件**: 同一プランのリグレッション e2e ×3([別レポート](2026-06-10_063116_tx1320_bios_reference_regression_e2e_3run.md)、
  試行1-2=2026-06-07 / 試行3=2026-06-10)の**試行3 完了直後**で機械は PVE 稼働状態。本作業(全タブ巡回)は
  試行3 と同じ 2026-06-10 に、BIOS Setup へ再進入(非破壊、Discard Changes and Exit で退出)して実施した。

## 環境情報

- **サーバ**: Fujitsu PRIMERGY TX1320 M3 / board S26361-D3373-B12(Board GS D3373-B12 3)
- **CPU**: Intel(R) Xeon(R) CPU E3-1220 v6 @ 3.00GHz(4C/4T、**HT なし**、L1 4x64KB / L2 4x256KB / L3 8MB、CPUID 906E9)
- **メモリ**: 24576 MB = 24 GiB(ECC、2400 MHz、DIMM-1A/2B/1B 実装・DIMM-2A 空)
- **BMC**: iRMC S4 FW 9.69F / SDRR 3.18 ID 0458
- **BIOS**: AMI Aptio Setup Utility 2.18.1263 / Core 5.0.0.11 / `V5.0.0.11 R1.22.0 for D3373-B1x`(Build 2018-12-18)
- **RAID**: PRAID EP400i(AVAGO MegaRAID SAS3008, FW 03.25.05.10)/ SAS HDD 900GB × 4 → RAID10 1.635 TB
- **NIC**: Intel I210 ×2(LAN1 MAC 4C:52:62:14:A5:5C / LAN2 MAC 4C:52:62:14:DE:F0 = eno2 dark-net、FW 1.40)
- **使用ツール**: `scripts/irmc-kvm-recover.sh`(BIOS 進入 + KVM 健全化)/ `scripts/irmc-kvm/server.py`(永続 KVM、コマンドファイル駆動)

## 🎯 最重要発見: XML ⊋ Setup UI(NVRAM 全集合 vs 可視部分集合)

WinSCU XML の 91 設定は **NVRAM 変数の全集合**であり、実機 BIOS Setup UI に実際に表示される設定は
**HW 構成依存の部分集合**である。全タブ巡回の結果、XML にあっても Setup UI 上で**抑制(非表示)**される
設定が多数あると判明した。training-tx1320 の構成で抑制される主因と対象:

| 抑制の主因 | 抑制される XML 設定 |
|---|---|
| **CPU が E3-1220 v6 = iGPU なし** | Primary Display / Internal Graphics / DVMT Shared Memory Size / DVMT Total Graphics Memory Size |
| **CPU が 4C4T = HT なし** | Hyper-Threading |
| (E3 でサポート外/抑制) | Execute Disable Bit / Intel TXT(LT) / Limit CPUID Maximum / SGX / X2APIC Opt Out / Power Limit 1-4 + Platform PL1/PL2 系 / CPU C states / PM Support |
| **物理 TPM 非搭載** | TPM State / Skip PPI during next Boot / Pending TPM operation |
| **Launch CSM = Disabled(UEFI 運用)** | Boot option filter / Launch PXE/Storage/Video OpROM policy / Other PCI device ROM priority |
| (条件付き/別画面/抑制) | PCI Error Logging / PERR# Generation / SERR# Generation / ECC Memory Error Logging / USB 各種(Onboard USB Controllers・USB transfer time-out・Port 61h・Port 60/64)/ Password Severity / PXE boot wait time |

> **含意**: 抑制設定も NVRAM 変数としては存在するため、Redfish BSPBR(XML)経由では読み書きできる場合がある
> (Setup UI に出ないだけ)。他の Fujitsu / AMI Aptio 機の BIOS リファレンス作成時も、この「XML = 全集合 /
> Setup = HW 構成依存の可視部分集合」を前提とすること。各 per-tab ファイル冒頭の「🔬 KVM 実機確認」節が
> 実機の正であり、XML 由来のマスターテーブル「配置(推定)」は参考値。

## タブ別 実機確認結果サマリ

### Main(✅ 全可視)
System Information サブメニューを採取: CPU E3-1220 v6 / Mem 24576MB@2400(3枚) / SPS FW 4.1.4.54 /
BIOS Build 2018-12-18 R1.22.0 / LAN MAC ×2 等。

### Advanced(サブメニューごとに可視/非表示を確定)
- **Onboard Devices**: LAN1/2 Controller [Enabled]・LAN1/2 Oprom [PXE] 可視 / iGPU・DVMT 系 ❌
- **PCI Status**: Slot1-3 [Empty]・**Slot4 [Enabled]**(RAID コントローラ)
- **PCI Subsystem Settings**: ASPM [Disabled]・Above 4G [Disabled] 可視 / PCI Error Logging・PERR#・SERR# ❌
- **CPU Configuration**: 9 項目可視(**Intel VT [Enabled]・VT-d [Enabled]** 含む)/ HT・Power Limit 群等 ❌
- **Memory Status**: DIMM-2A [Empty]・1A/2B/1B [Enabled] / ECC Mem Error Logging ❌
- **SATA Configuration**: **SATA Mode [RAID Mode]**
- **CSM Configuration**: Launch CSM [Disabled] / OpROM policy 群は CSM 無効で ❌
- **Trusted Computing**: TPM Support [Enabled] / "NO Security Device Found" / TPM State 系 ❌
- **USB Configuration**: Legacy USB [Enabled] + USB Port Security>USB Port Control [Enable all ports] / 他 ❌
- **Super IO**: PILOT3 + Serial Port 1 Config>Serial Port [Enabled]・IO=3F8h IRQ=4(SOL の COM1)・Change Settings [Auto]
- **Network Stack**: **Network Stack [Enabled]・Ipv4 PXE [Enabled]・Ipv6 PXE [Enabled]**(PXE deploy 必須 3 項目)
- **Option ROM**: Launch Slot1-3 OpROM [Disabled]・**Slot4 [Enabled]**(RAID OpROM)
- **VIOM**: VIOM-flag [Disabled](XML 非対象の新規項目)
- iSCSI / LSI SW RAID / Intel I210 ×2 / Driver Health: サブメニュー存在のみ確認

### Security
メイン: Password on Boot [Disabled]・Skip Password on WOL [Disabled]・FLASH Write [Enabled](+ Admin/User Password)。
Secure Boot Configuration サブ: System Mode=User・Secure Boot Control [Disabled]・Secure Boot Mode [Custom]。
Password Severity は ❌ 非表示、Factory Default Key Provision は Key Management サブ内。

### Power
Power-on Source [BIOS Controlled](メイン)+ Wake-Up Resources サブ内 LAN [Enabled]・Wake On LAN boot [Boot Sequence]。3/3 可視。

### Server Mgmt(XML 非対象、メイン全項目採取)
FW 9.69F / SDRR 3.18 / Onboard Video [Enabled] / BIOS Parameter Backup [Disabled] / Boot Retry Counter 3 /
Power Cycle Delay 7 / ASR&R Boot Delay 2 / Temperature Monitoring [Disabled] / Fan Control [Auto] /
Event Log Full Mode [Overwrite] / Load iRMC Default Values [No] / **Power Failure Recovery [Always On]** /
**Serial Multiplexer [System]** / Boot Watchdog [Disabled](Timeout 100 / Action [Continue]）/
▶ iRMC LAN Parameters Configuration / ▶ Console Redirection。

### Boot(XML 8/9 可視)
NumLock [On] / Quiet Boot [Disabled] / Check controllers health status [Enabled] / Boot error handling [Continue] /
Keep Void Boot Options [Disabled] / New Boot Option Policy [Place First] / PXE Boot Option Retry [Disabled] /
Boot Removable Media [Enabled]。**PXE boot wait time ❌ 非表示**。Boot Option Priorities #1/#2=debian、#3-6=UEFI IP4/IP6 Intel I210。

### Save & Exit(アクションタブ、全項目採取)
Save/Discard Changes and Exit、Save/Discard Changes and Reset、Save/Discard Changes、Restore Defaults、
Save as/Restore User Defaults、Boot Override(debian ×2 + UEFI IP4/IP6 Intel I210 ×4)。

## PVE/PXE 運用に効く確認結果

| 用途 | 確認した設定 | 状態 |
|---|---|---|
| PXE/iPXE deploy | Network Stack / Ipv4 PXE / Ipv6 PXE | すべて [Enabled] ✅ |
| RAID ブート | PCI Slot 4 / Launch Slot 4 OpROM / SATA Mode | [Enabled] / [Enabled] / [RAID Mode] ✅ |
| 仮想化(PVE) | Intel Virtualization Technology / VT-d | [Enabled] / [Enabled] ✅ |
| 電源復帰 | Power Failure Recovery(Server Mgmt) | [Always On] ✅(復電で自動起動) |
| SOL | Serial Port(IO=3F8h IRQ=4)/ Serial Multiplexer | [Enabled] / [System] ✅ |

## 再現方法

1. **BIOS 進入 + KVM 健全化**
   ```sh
   ./oplog.sh ./scripts/irmc-kvm-recover.sh config/training_tx1320.yml tmp/<sid>/tabsweep/recover.jpg 175
   ```
   → OEM screenshot で Main 着地確認 → KVM 永続サーバ起動:
   ```sh
   .venv/bin/python scripts/irmc-kvm/server.py --bmc-ip 10.254.254.9 --bmc-user claude --bmc-pass Claude123 \
     --srv-dir tmp/<sid>/tabsweep/srv --idle-timeout 3600
   ```
2. **巡回**: コマンドファイル(`<srv-dir>/in/NNN.cmd`)で `press ArrowRight`(タブ移動)/ `press Enter`(サブメニュー進入)/
   `press Escape`(サブメニュー戻り)/ `press ArrowDown`(項目移動)/ `shot`(KVM canvas 撮影)を投入。各 shot を Read で判読し、
   右ヘルプ全文でカーソル行を一意特定。**上位タブで Escape 禁止**(Exit modal 罠)、サブメニュー内 Escape は安全。
3. **退出**: Save & Exit タブ > **Discard Changes and Exit**(変更を一切保存しない)→ `quit` で KVM サーバ停止。
4. **編纂**: 各 per-tab ファイル冒頭に「🔬 KVM 実機確認(2026-06-10)」節を追加、サブメニューごとの可視✅/非表示❌を一覧化。
   `⏳ 未確認` 行を「2026-06-10 確認」へ統一更新。

> 注: KVM canvas は本作業では全 BIOS テキスト画面で正常描画した。黒画 artifact が出る場合は
> `scripts/irmc-oem-screenshot.sh`(真 VGA)を一次情報に使う。

## 成果物(更新ファイル)

- `.claude/skills/irmc-bios-raid/bios/index.md` — HW 表に CPU/NIC 実測反映 + 「XML ⊋ Setup UI」をリファレンス全体注記として追加
- `.claude/skills/irmc-bios-raid/bios/main.md` — System Information 全採取
- `.claude/skills/irmc-bios-raid/bios/advanced.md` — 全サブメニュー実機確認 + 抑制設定の理由付き一覧
- `.claude/skills/irmc-bios-raid/bios/{boot,security,power}.md` — 可視/非表示 + サブメニュー所属を確定
- `.claude/skills/irmc-bios-raid/bios/{server-mgmt,save-exit}.md` — 推測表を実測に置換
- `.claude/skills/irmc-bios-raid/bios/_capture-runbook.md` — 進捗チェックリストを全タブ完了に更新

## 参照レポート

- [リグレッション e2e ×3](2026-06-10_063116_tx1320_bios_reference_regression_e2e_3run.md) — 本 skill 修正のリグレッション検証(3/3 PASS)
- [TX1320 RAID10 BIOS HII 成功](2026-06-02_020652_tx1320_raid10_bios_hii_success.md) — AVAGO HII RAID 操作の典拠

## 結論

WinSCU XML を主データ源にしつつ、全 7 タブ + Advanced 全サブメニューを KVM/OEM screenshot で巡回し、
各設定の実機 Setup UI 上の存在を確認した。最重要の発見は **「XML ⊋ Setup UI」**(XML は NVRAM 全集合、
Setup UI は HW 構成依存の可視部分集合)であり、E3-1220 v6(iGPU/HT なし)・TPM 非搭載・CSM 無効という
構成に起因する多数の設定抑制を、理由とともに各 per-tab ファイルに記録した。PVE/PXE 運用に必須の設定
(Network Stack/PXE・RAID OpROM・SATA RAID Mode・VT/VT-d・Power Failure Recovery・SOL)はすべて実機で
可視・適正値を確認した。BIOS は非破壊(Discard Changes and Exit)で退出している。
