# TX1320 M3 (D3373-B1x) BIOS 設定リファレンス — 索引

Fujitsu PRIMERGY TX1320 M3 (board **D3373-B1x** / AMI Aptio Setup Utility) の BIOS 全設定項目の
技術リファレンス。**1 ファイル肥大化を避けるためタブ単位で分割**している。BIOS 操作手順 (KVM/Redfish)
は [../SKILL.md](../SKILL.md) を、Redfish/WinSCU XML プロトコルは [../reference.md](../reference.md) を参照。

> 対象機: **training-tx1320** (10.254.254.9, iRMC S4, 一時設置・クラスタ非参加)。
> Supermicro 機の同種リファレンスは `bios-setup` スキルの `reference.md` を参照 (本ファイルはその TX1320 版)。

## はじめに — 対象ハードウェア

| 項目 | 値 |
|------|----|
| マザーボード | Fujitsu D3373-B1x (PRIMERGY TX1320 M3, Board GS D3373-B12 3) |
| BIOS | AMI Aptio, **V5.0.0.11 R1.22.0 for D3373-B1x** (sysId `TX1320M3F2`、Build 12/18/2018) |
| iRMC | iRMC S4, FW 9.69F (取得時 9.08F) / SDRR 3.18 ID 0458 |
| CPU | **Intel(R) Xeon(R) CPU E3-1220 v6 @ 3.00GHz** (4C/4T、HT なし、L1 4x64KB / L2 4x256KB / L3 8MB、CPUID 906E9) |
| メモリ | 24576 MB = 24 GiB (ECC、2400 MHz、DIMM-1A/2B/1B 実装・DIMM-2A 空) |
| ストレージ | PRAID EP400i (AVAGO MegaRAID SAS3008, FW 03.25.05.10) + SAS HDD 900GB × 4 → RAID10 実効 1.635 TB |
| NIC | Onboard LAN ×2 (Intel I210、LAN1 MAC 4C:52:62:14:A5:5C / LAN2 MAC 4C:52:62:14:DE:F0=eno2 dark-net、FW 1.40) |
| 設置 | 別拠点 (10.254.254.0/24 + 192.168.33.0/24 DHCP) |

> CPU・メモリ・NIC 詳細は Main > System Information を 2026-06-10 に KVM/OEM で実測 ([main.md](main.md) 参照)。
> **CPU が E3-1220 v6 (iGPU なし・HT なし) であることが、Advanced タブで iGPU/DVMT/Hyper-Threading 設定が
> Setup UI に出ない (抑制される) 主因**である (下記「XML ⊋ Setup UI」参照)。

## データの出処 (provenance)

- **値・選択肢・デフォルト・ヘルプ**: 実機から Redfish BSPBR で取得した **WinSCU XML**
  (`report/attachment/2026-05-16_130950_tx1320_bios_uefi_auto/bios-backup-initial.xml`、2026-05-16) 由来。
  91 設定を網羅。`scripts/irmc-bios.py backup` で再取得可能。
- **現在値**: 上記 XML の `current` 属性 = **2026-05-16 時点のスナップショット**。その後 UEFI 化・RAID 操作で
  一部変わっている可能性があるため、各項目に取得日を明記している。
- **デフォルト**: XML の `default` 属性 (工場出荷値)。`Load Setup Defaults` は実施していない。
- **タブ/サブメニュー所属**: WinSCU XML は所属情報を持たない (setupItemID 順のフラットリスト) ため、
  `name` から **best-effort で振り分けた推定値**。下記マスターテーブルの「配置(推定)」列 + 各 per-tab ファイルの
  項目は、**KVM 実機確認で確定**する (各項目の「KVM 確認」フィールド)。
- **読み取り専用情報・メニュー構造・AVAGO RAID HII**: XML 非対象。KVM/OEM screenshot で採取する
  ([_capture-runbook.md](_capture-runbook.md))。

### ⚠️ XML ⊋ Setup UI — NVRAM 全集合 vs 実機可視部分集合 (2026-06-10 全タブ KVM 確認で確定)

WinSCU XML の 91 設定は **NVRAM 変数の全集合**であり、実機 BIOS Setup UI に実際に表示される設定は
**HW 構成依存の部分集合**である。2026-06-10 に全 7 タブ + Advanced 全サブメニューを KVM/OEM で巡回した
結果、XML にあっても Setup UI 上で**抑制 (非表示)** される設定が多数あると判明した。training-tx1320 の
構成 (**Intel Xeon E3-1220 v6 = iGPU なし / HT なし (4C4T)**、**TPM 物理非搭載**、**SATA = RAID Mode**、
**Launch CSM = Disabled**) で抑制される主な設定:

- **iGPU 系** (Primary Display / Internal Graphics / DVMT ×2) — CPU に iGPU が無いため
- **Hyper-Threading** — E3-1220 v6 は 4C4T (HT 非対応) のため
- **CPU 詳細** (Execute Disable / TXT / Limit CPUID / SGX / X2APIC / Power Limit 1-4 / PM Support / CPU C states)
- **TPM 詳細** (TPM State / Skip PPI / Pending TPM operation) — 物理 TPM 非搭載のため
- **CSM OpROM policy 群** (Boot option filter / Launch PXE/Storage/Video OpROM policy / Other PCI device ROM priority) — Launch CSM=Disabled のため
- **その他** (PCI Error Logging / PERR# / SERR# / ECC Memory Error Logging / USB 各種 / Password Severity / PXE boot wait time)

→ 各 per-tab ファイル冒頭の **「🔬 KVM 実機確認 (2026-06-10)」節**に、サブメニューごとの**可視項目 (✅) と
非表示項目 (❌)** を一覧化した。下記マスターテーブルの「配置(推定)」は XML name からの推定であり、
**実機の正は各 per-tab ファイルの実機確認節**である。抑制設定も NVRAM 変数としては存在するため Redfish
BSPBR (XML) では読み書きできる場合がある (Setup UI に出ないだけ)。

## リスクレベル定義

| レベル | 意味 |
|--------|------|
| **Safe** | 変更してもハードウェアに影響なし。機能の有効/無効切替のみ |
| **Moderate** | OS やドライバの動作に影響する可能性がある。変更前に影響を理解すること |
| **High** | 起動不能やハードウェア障害のリスクがある。十分な検証が必要 |
| **Critical** | データ消失やセキュリティ設定の不可逆変更のリスクがある |

## タブ構成とナビゲーション

BIOS Setup は **7 タブ**: `Main / Advanced / Security / Power / Server Mgmt / Boot / Save & Exit`。

- タブ移動は `ArrowRight` / `ArrowLeft`。**タブ列は wrap する** (Main で ArrowLeft → 最右 Save & Exit)。
- Advanced の cursor は `Onboard Devices Configuration` から起動し `ArrowDown` で下る (空行は skip)。
  `ArrowDown ×14` で最下の AVAGO MegaRAID 行に到達。
- **上位タブで `Esc` を押さない** (「Exit Without Saving」モーダルが開き入力をブロックする)。サブメニュー内の Esc は安全。
- 画面取得は **OEM screenshot (`irmc-oem-screenshot.sh`) が一次情報** (KVM canvas は黒画 artifact のことがある)。

| タブ | ファイル | 主な内容 |
|------|---------|---------|
| Main | [main.md](main.md) | System Date/Time + 読み取り専用情報 (BIOS版/CPU/メモリ) |
| Advanced | [advanced.md](advanced.md) | 15 サブメニュー (Onboard Devices / PCI / CPU / Memory / SATA / CSM / TPM / USB / Super IO / Network Stack / Option ROM / VIOM / iSCSI / AVAGO RAID) |
| Security | [security.md](security.md) | Secure Boot / パスワード / FLASH Write 保護 |
| Power | [power.md](power.md) | Wake-on-LAN / 電源復帰ソース |
| Server Mgmt | [server-mgmt.md](server-mgmt.md) | iRMC 連携 / FRB / ASR&R / OS Watchdog (XML 非対象、KVM 採取) |
| Boot | [boot.md](boot.md) | ブート順 / NumLock / Quiet Boot / POST 挙動 |
| Save & Exit | [save-exit.md](save-exit.md) | Save/Discard/Load Defaults / Boot Override (KVM 採取) |
| (RAID HII) | [raid-avago-hii.md](raid-avago-hii.md) | AVAGO MegaRAID `<PRAID EP400i>` HII の全画面・操作 |

### Advanced サブメニュー順 (実機キーシーケンス)

`Onboard Devices Configuration → PCI Status → PCI Subsystem Settings → CPU Configuration →
Memory Status → SATA Configuration → CSM Configuration → Trusted Computing → USB Configuration →
Super IO Configuration → Network Stack Configuration → Option ROM Configuration → VIOM →
iSCSI Configuration → AVAGO MegaRAID <PRAID EP400i> Configuration Utility`

> iSCSI≈caret y368 / AVAGO≈y393 / LSI SW RAID≈y406 が近接。caret 検出だけで進入せず画面文字 (右ヘルプ) を確認すること。

## 項目記述フォーマット (凡例)

各設定項目は per-tab ファイルで以下の統一フォーマットで記述する:

```markdown
#### <設定項目名>  (`<XML id>`, setupItemID `<0xNNNN>`)
- **選択肢**: <値1> / <値2> / ...        ← XML possibleValue (数値項目は範囲)
- **デフォルト**: <値>                     ← XML default 属性
- **現在値 (2026-05-16)**: <値>           ← XML current 属性 (スナップショット日)。⚠️=デフォルトと相違
- **ヘルプ**: "<BIOS ヘルプ全文>"          ← XML description CDATA
- **KVM 確認**: ✅ <日付> / ⏳ 未確認      ← 実機 BIOS Setup に存在することを KVM/OEM で確認した日
- **解説**: <技術背景>
- **PVE/PXE 推奨**: <推奨値 + 理由>
- **リスク**: Safe / Moderate / High / Critical
```

## マスターテーブル (全 91 設定, setupItemID 順)

> 「配置(推定)」は best-effort。⚠️ = 現在値がデフォルトと相違 (2026-05-16 時点)。所属は KVM 確認で確定する。

| setupItemID | id | 項目名 (name) | デフォルト | 現在値(05-16) | 配置(推定) |
|---|---|---|---|---|---|
| `0x0001` | SerialPort1 | Serial Port | Enabled | Enabled | advanced / Super IO Configuration |
| `0x0007` | LAN | LAN 1 Controller | Enabled | Enabled | advanced / Onboard Devices Configuration |
| `0x0009` | USBHostController | Onboard USB Controllers | Enabled | Enabled | advanced / USB Configuration |
| `0x000B` | USBLegacySupport | Legacy USB Support | Enabled | Enabled | advanced / USB Configuration |
| `0x000D` | LANRemoteBoot | Launch PXE OpROM Policy | Legacy only | Legacy only | advanced / CSM Configuration |
| `0x0010` | FlashWrite | FLASH Write | Enabled | Enabled | security |
| `0x0011` | WakeupLAN | LAN | Enabled | Enabled | power |
| `0x0013` | OnAutomaticWakeupm | Skip Password on WOL | Disabled | Disabled | security |
| `0x001A` | PasswordOnBoot | Password on Boot | Disabled | Disabled | security |
| `0x001B` | ForceLANBoot | Wake On LAN boot | Boot Sequence | Boot Sequence | power |
| `0x0024` | Numlock | Bootup NumLock State | Off | On ⚠️ | boot |
| `0x0032` | CoreProcessingMode | Active Processor Cores | All | All | advanced / CPU Configuration |
| `0x0033` | EnhancedSpeedStep | Enhanced SpeedStep | Enabled | Enabled | advanced / CPU Configuration |
| `0x0036` | XDBitfunctionalityAndNXMemoryProtection | Execute Disable Bit | Enabled | Enabled | advanced / CPU Configuration |
| `0x0037` | VirtualizationTechnology | Intel Virtualization Technology | Enabled | Enabled | advanced / CPU Configuration |
| `0x0048` | BootfromRemovableMedia | Boot Removable Media | Enabled | Enabled | boot |
| `0x0057` | HyperThreading | Hyper-Threading | Enabled | Enabled | advanced / CPU Configuration |
| `0x005C` | SecurityChip | TPM Support | Enabled | Enabled | advanced / Trusted Computing |
| `0x005D` | ChangeTPMState | TPM State | Enabled | Enabled | advanced / Trusted Computing |
| `0x0067` | IntelVTd | VT-d | Enabled | Enabled | advanced / CPU Configuration |
| `0x0068` | Intel_TxT | Intel TXT(LT) Support | Disabled | Disabled | advanced / CPU Configuration |
| `0x0080` | QuietBoot | Quiet Boot | Disabled | Disabled | boot |
| `0x0082` | TpmSkipPPI | Skip PPI during next Boot | Disabled | Disabled | advanced / Trusted Computing |
| `0x0087` | SATAControllerModeSelection | SATA Mode Selection | AHCI Mode | RAID Mode ⚠️ | advanced / SATA Configuration |
| `0x009A` | PendingTPMOperation | Pending TPM operation | None | None | advanced / Trusted Computing |
| `0x009F` | ECCMemoryErrorLogging | ECC Memory Error Logging | Enabled | Enabled | advanced / Memory Status |
| `0x00A0` | PCIErrorLogging | PCI Error Logging | Enabled | Enabled | advanced / PCI Subsystem Settings |
| `0x00A6` | TurboMode | Turbo Mode | Enabled | Enabled | advanced / CPU Configuration |
| `0x00B0` | BootErrorHandling | Boot error handling | Continue | Continue | boot |
| `0x00B1` | PerrGeneration | PERR# Generation | Enabled | Enabled | advanced / PCI Subsystem Settings |
| `0x00B2` | SerrGeneration | SERR# Generation | Enabled | Enabled | advanced / PCI Subsystem Settings |
| `0x00B3` | Lan2 | LAN 2 Controller | Enabled | Enabled | advanced / Onboard Devices Configuration |
| `0x00C5` | UsbPortControl | USB Port Control | Enable all ports | Enable all ports | advanced / USB Configuration |
| `0x00D3` | UsbTransferTimeOut | USB transfer time-out | 20 sec | 20 sec | advanced / USB Configuration |
| `0x00D7` | PrimaryDisplay | Primary Display | Auto | Auto | advanced / Onboard Devices Configuration |
| `0x00D8` | InternalGraphics | Internal Graphics | Disabled | Disabled | advanced / Onboard Devices Configuration |
| `0x00E0` | Lan1Oprom | LAN 1 Oprom | PXE | PXE | advanced / Onboard Devices Configuration |
| `0x00E1` | Lan2Oprom | LAN 2 Oprom | Disabled | Disabled | advanced / Onboard Devices Configuration |
| `0x00E2` | AspmSupport | ASPM Support | Disabled | Disabled | advanced / PCI Subsystem Settings |
| `0x00E5` | NetworkStack | Network Stack | Disabled | Disabled | advanced / Network Stack Configuration |
| `0x00E6` | IPv4PxeSupport | Ipv4 PXE Support | Enabled | Enabled | advanced / Network Stack Configuration |
| `0x00E7` | IPv6PxeSupport | Ipv6 PXE Support | Enabled | Enabled | advanced / Network Stack Configuration |
| `0x00E8` | SecureBoot | Secure Boot Control | Disabled | Disabled | security |
| `0x00E9` | DefaultKeyProvisioning | Factory Default Key Provision | Enabled | Enabled | security |
| `0x00EA` | Csm | Launch CSM | Disabled | Disabled | advanced / CSM Configuration |
| `0x00EC` | LaunchSlot1Oprom | Launch Slot 1 OpROM | Disabled | Disabled | advanced / Option ROM Configuration |
| `0x00ED` | LaunchSlot2Oprom | Launch Slot 2 OpROM | Disabled | Disabled | advanced / Option ROM Configuration |
| `0x00EE` | LaunchSlot3Oprom | Launch Slot 3 OpROM | Disabled | Disabled | advanced / Option ROM Configuration |
| `0x00EF` | LaunchSlot4Oprom | Launch Slot 4 OpROM | Enabled | Enabled | advanced / Option ROM Configuration |
| `0x00FF` | PowerOnSource | Power-on Source | BIOS Controlled | BIOS Controlled | power |
| `0x0101` | Above4GDecoding | Above 4G Decoding | Disabled | Disabled | advanced / PCI Subsystem Settings |
| `0x0102` | KeepOrphanFwBootOption | Keep Void Boot Options | Disabled | Disabled | boot |
| `0x0103` | BootOptionFilter | Boot option filter | Legacy only | Legacy only | advanced / CSM Configuration |
| `0x0104` | LaunchPxeOpRomPolicy | Launch PXE OpROM Policy | Legacy only | Legacy only | advanced / CSM Configuration |
| `0x0105` | LaunchStorageOpRomPolicy | Launch Storage OpROM policy | Legacy only | Legacy only | advanced / CSM Configuration |
| `0x0106` | LaunchVideoOpRomPolicy | Launch Video OpROM policy | Legacy only | Legacy only | advanced / CSM Configuration |
| `0x0107` | OtherPciDeviceRomPriority | Other PCI device ROM priority | Legacy only | Legacy only | advanced / CSM Configuration |
| `0x011D` | PxeBootOptionRetry | PXE Boot Option Retry | Disabled | Disabled | boot |
| `0x012E` | HardwarePrefetcher | Hardware Prefetcher | Enabled | Enabled | advanced / CPU Configuration |
| `0x012F` | AdjacentCacheLinePrefetch | Adjacent Cache Line Prefetch | Enabled | Enabled | advanced / CPU Configuration |
| `0x0130` | DcuStreamerPrefecher | DCU Streamer Prefetcher | Enabled | Enabled | advanced / CPU Configuration |
| `0x0136` | PackageCStateLimit | Package C State limit | C7 | C7 | advanced / CPU Configuration |
| `0x0140` | LimitCpuIdMaximum | Limit CPUID Maximum | Disabled | Disabled | advanced / CPU Configuration |
| `0x014D` | PxeBootWaitTime | PXE boot wait time | 0 | 0 | boot |
| `0x014E` | CheckControllersHealthStatus | Check controllers health status | Enabled | Enabled | boot |
| `0x0174` | PasswordSeverity | Password Severity | Standard | Standard | security |
| `0x0196` | StatusPCISlot1 | PCI Slot 1 | Enabled | Empty ⚠️ | advanced / PCI Status |
| `0x0197` | StatusPCISlot2 | PCI Slot 2 | Enabled | Empty ⚠️ | advanced / PCI Status |
| `0x0198` | StatusPCISlot3 | PCI Slot 3 | Enabled | Empty ⚠️ | advanced / PCI Status |
| `0x0199` | StatusPCISlot4 | PCI Slot 4 | Enabled | Enabled | advanced / PCI Status |
| `0x01AC` | ChangeSettingsSerialPort | Change Settings | Auto | Auto | advanced / Super IO Configuration |
| `0x01B0` | SecureBootMode | Secure Boot Mode | Standard | Custom ⚠️ | security |
| `0x01BC` | wBootOptionPolicy | New Boot Option Policy | Place First | Place First | boot |
| `0x01BF` | SwGuardExtensions_SGX | SW Guard Extensions (SGX) | Disabled | Disabled | advanced / CPU Configuration |
| `0x01C0` | X2APIC_OptOut | X2APIC Opt Out | Disabled | Disabled | advanced / CPU Configuration |
| `0x01CB` | PowerLimit1Override | Power Limit 1 Override | Disabled | Disabled | advanced / CPU Configuration |
| `0x01CD` | PowerLimit1Window | Power Limit 1 Window | 0 | 0 | advanced / CPU Configuration |
| `0x01CE` | PowerLimit2Override | Power Limit 2 Override | Enabled | Enabled | advanced / CPU Configuration |
| `0x01D0` | PlatformPL1Enable | Platform PL1 Enable | Disabled | Disabled | advanced / CPU Configuration |
| `0x01D2` | PlatformPL1TimeWindow | Platform PL1 Time Window | 0 | 0 | advanced / CPU Configuration |
| `0x01D3` | PlatformPL2Enable | Platform PL2 Enable | Disabled | Disabled | advanced / CPU Configuration |
| `0x01D5` | PowerLimit3Override | Power Limit 3 Override | Disabled | Disabled | advanced / CPU Configuration |
| `0x01D7` | PowerLimit3TimeWindow | Power Limit 3 Time Window | 0 | 0 | advanced / CPU Configuration |
| `0x01D8` | PowerLimit3DutyCycle | Powet Limit 3 Duty Cycle | 0 | 0 | advanced / CPU Configuration |
| `0x01D9` | PowerLimit4Override | Power Limit 4 Override | Disabled | Disabled | advanced / CPU Configuration |
| `0x01DF` | DVMTSharedMemorySize | DVMT Shared Memory Size | 32 MB | 32 MB | advanced / Onboard Devices Configuration |
| `0x01E0` | DVMTTotalGraphicsMemorySize | DVMT Total Graphics Memory Size | 256 MB | 256 MB | advanced / Onboard Devices Configuration |
| `0x023B` | (SetupVariableId unknown) | CPU C states | Enabled | Enabled | advanced / CPU Configuration |
| `0x0255` | Port61Bit4Emulation | Port 61h Bit-4 Emulation | Enabled | Enabled | advanced / USB Configuration |
| `0x0257` | Port60h64hEmulation | Port 60/64 Emulation | Enabled | Enabled | advanced / USB Configuration |
| `0x0258` | PmSupport | PM Support | Enabled | Enabled | advanced / CPU Configuration |

## デフォルトと相違している現在値 (2026-05-16, 要注意)

| 項目 | デフォルト | 現在値 | 備考 |
|------|-----------|--------|------|
| Bootup NumLock State | Off | On | 無害 |
| SATA Mode Selection | AHCI Mode | **RAID Mode** | onboard SATA を RAID 化 (要因確認) |
| Secure Boot Mode | Standard | **Custom** | Secure Boot キー管理が Custom |
| PCI Slot 1/2/3 | Enabled | Empty | スロット未実装 (status 表示) |

> これらは 2026-05-16 スナップショット。その後の UEFI 化作業 (BootOptionFilter 等を `Legacy only`→`UEFI only`)
> も反映されている可能性があるため、最新値は KVM 確認または新規 `bios backup` で裏取りする。

## PVE/PXE で意味を持つ主な設定

| 項目 | id | 効果 |
|------|----|------|
| Boot option filter | `BootOptionFilter` | UEFI/Legacy ブート種別。pvese は UEFI install → `UEFI only` |
| Launch Storage OpROM policy | `LaunchStorageOpRomPolicy` | RAID/HBA ブート OpROM。UEFI 化対象 |
| Launch PXE OpROM Policy | `LaunchPxeOpRomPolicy` | PXE ブート OpROM。UEFI PXE 化対象 |
| Launch CSM | `Csm` | 純 UEFI なら `Disabled` 維持 |
| Network Stack | `NetworkStack` | UEFI PXE/HTTP boot に必須 (PXE pivot 時) |
| Intel VT / VT-d | `VirtualizationTechnology` / `IntelVTd` | KVM 仮想化・PCI パススルー |
| SATA Mode Selection | `SATAControllerModeSelection` | OS のディスク認識に影響 |

詳細は各 per-tab ファイルおよび [../reference.md](../reference.md) の「UEFI 化に必要な主な supported settings」を参照。
