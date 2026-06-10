<!-- 自動生成 (tmp/biosref/gen_bios_md.py) — WinSCU XML bios-backup-initial.xml (2026-05-16, D3373-B1x) 由来。
     手で 解説/PVE推奨 を追補し、KVM 確認後に「KVM 確認」を更新する。再生成時は手追補が消えるので注意。 -->

# Advanced タブ — TX1320 M3 (D3373-B1x) BIOS 設定リファレンス

> 値・選択肢・ヘルプは 2026-05-16 取得の WinSCU XML 由来。`現在値` はそのスナップショット。
> サブメニュー順は実機キーシーケンス (Main→ArrowRight→Advanced、cursor は Onboard Devices から ArrowDown)。
> 各**設定項目**のサブメニュー所属は best-effort (name 推定) であり、KVM で個別確定する。

> **Advanced サブメニュー一覧の存在は KVM 確認済 (✅ 2026-06-07)**。実機の Advanced タブに以下が
> この順で並ぶ (OEM 真 VGA で確認):
> `Onboard Devices Configuration / PCI Status / PCI Subsystem Settings / CPU Configuration /
> Memory Status / SATA Configuration / CSM Configuration / Trusted Computing / USB Configuration /
> Super IO Configuration / Network Stack Configuration / Option ROM Configuration / VIOM /
> iSCSI Configuration / AVAGO MegaRAID <PRAID EP400i> Configuration Utility - 03.25.05.10 /
> LSI Software RAID Configuration Utility / Intel(R) I210 Gigabit Network Connection - 4C:52:62:14:A5:5C /
> Intel(R) I210 Gigabit Network Connection - 4C:52:62:14:DE:F0 / Driver Health`
> (末尾 4 つ = LSI SW RAID / Intel I210 NIC ×2 [DE:F0 が eno2 dark-net] / Driver Health は XML 非対象。
> 各 NIC の Link Speed / Wake On LAN 等は KVM で個別採取する)。
> **個々の設定項目が実機の各サブメニュー内に存在することの確認は今後**: 各設定の「KVM 確認」を参照。

## 🔬 KVM 実機確認 (2026-06-10、training-tx1320)

全 Advanced サブメニューを OEM/KVM screenshot で巡回し、各 XML 設定の**実機 Setup UI 上の可視性**を
確認した。

### ⚠️ 最重要: XML ⊋ Setup UI (NVRAM 全集合 vs 実機可視部分集合)

WinSCU XML は **NVRAM 変数の全集合**で、実機 Setup UI に表示される設定は **HW 構成依存の部分集合**。
training-tx1320 の構成 (**CPU = Intel Xeon E3-1220 v6 = iGPU なし / HT なし (4C4T)**、**TPM 物理非搭載**、
**SATA = RAID Mode**、**Launch CSM = Disabled**) では、多数の XML 設定が Setup UI 上で**抑制 (非表示)**
される。XML に値があっても Setup 画面に出ない設定は ❌ 非表示 として明記する。

### 各サブメニューの実機可視項目 (2026-06-10)

| サブメニュー | 実機に可視な項目と現在値 | XML にあるが ❌ 非表示 |
|---|---|---|
| **Onboard Devices Configuration** | LAN 1 Controller [Enabled] / LAN 2 Controller [Enabled] / LAN 1 Oprom [PXE] / LAN 2 Oprom [PXE] | Primary Display / Internal Graphics / DVMT Shared Memory Size / DVMT Total Graphics Memory Size (全て **iGPU 非搭載**のため抑制) |
| **PCI Status** | PCI Slot 1 [Empty] / PCI Slot 2 [Empty] / PCI Slot 3 [Empty] / **PCI Slot 4 [Enabled]** (RAID コントローラ) | — (PCI Error Logging / PERR# / SERR# はここに無し→下記参照) |
| **PCI Subsystem Settings** | ASPM Support [Disabled] (警告: ASPM 有効化で一部 PCI-E デバイスが fail) / Above 4G Decoding [Disabled] | PCI Error Logging (`0x00A0`) / PERR# Generation (`0x00B1`) / SERR# Generation (`0x00B2`) — この画面に非表示 |
| **CPU Configuration** | Active Processor Cores [All] / Hardware Prefetcher [Enabled] / Adjacent Cache Line Prefetch [Enabled] / DCU Streamer Prefetcher [Enabled] / **Intel Virtualization Technology [Enabled]** / **VT-d [Enabled]** / Enhanced SpeedStep [Enabled] / Turbo Mode [Enabled] / Package C State limit [C7] | Execute Disable Bit / **Hyper-Threading (4C4T=HT なし→抑制)** / Intel TXT(LT) / Limit CPUID Maximum / SGX / X2APIC Opt Out / Power Limit 1-4 + Platform PL1/PL2 系 / CPU C states / PM Support — 全て非表示 |
| **Memory Status** | DIMM-2A [Empty] / DIMM-1A [Enabled] / DIMM-2B [Enabled] / DIMM-1B [Enabled] (=3 枚実装 24 GiB) | ECC Memory Error Logging (`0x009F`) — この画面に非表示 |
| **SATA Configuration** | SATA Mode [RAID Mode] | — |
| **CSM Configuration** (= Compatibility Support Module Configuration) | Launch CSM [Disabled] | Boot option filter / Launch PXE OpROM Policy / Launch Storage OpROM policy / Launch Video OpROM policy / Other PCI device ROM priority — **Launch CSM=Disabled のため全て抑制** (UEFI 運用と整合) |
| **Trusted Computing** | TPM Support [Enabled] / 状態 "**NO Security Device Found**" | TPM State / Skip PPI during next Boot / Pending TPM operation — **物理 TPM 非搭載のため抑制** |
| **USB Configuration** | USB Devices: 1 Keyboard, 1 Mouse / Legacy USB Support [Enabled] / ▶ USB Port Security → **USB Port Control [Enable all ports]** | Onboard USB Controllers / USB transfer time-out / Port 61h Bit-4 Emulation / Port 60/64 Emulation — 非表示 |
| **Super IO Configuration** | Super IO Chip: PILOT3 / ▶ Serial Port 1 Configuration → **Serial Port [Enabled]** / Device Settings IO=3F8h IRQ=4 / **Change Settings [Auto]** | — (Serial Port 0x0001 / Change Settings 0x01AC は Serial Port 1 Configuration サブメニュー内) |
| **Network Stack Configuration** | **Network Stack [Enabled]** / **Ipv4 PXE Support [Enabled]** / **Ipv6 PXE Support [Enabled]** | — (PXE deploy 必須 3 項目すべて可視・有効) |
| **Option ROM Configuration** | Launch Slot 1 OpROM [Disabled] / Slot 2 [Disabled] / Slot 3 [Disabled] / **Slot 4 [Enabled]** (RAID OpROM) | — |
| **VIOM** | VIOM-flag [Disabled] | (XML 非対象の新規項目) |
| iSCSI Configuration / LSI Software RAID / Intel I210 NIC ×2 / Driver Health | サブメニュー存在のみ確認 (XML 設定なし) | — |

### 重要ポイント (PVE/PXE 運用)

- **PXE/iPXE deploy に必須**の `Network Stack [Enabled]` + `Ipv4/Ipv6 PXE Support [Enabled]` を実機で可視・有効と確認。
- **RAID ブート**に必要な `PCI Slot 4 [Enabled]` + `Launch Slot 4 OpROM [Enabled]` + `SATA Mode [RAID Mode]` を確認。
- **仮想化** `Intel Virtualization Technology [Enabled]` + `VT-d [Enabled]` を確認 (PVE で利用)。
- **抑制設定への注意**: Hyper-Threading・iGPU/DVMT・TPM State・CSM OpROM policy 群は当機の HW/構成では
  Setup UI に出ない。これらを「設定したい」場合、HW 条件 (HT 対応 CPU / TPM 実装 / CSM 有効化) を満たすと
  Setup に現れる。XML 経由 (Redfish BSPBR) では NVRAM 変数として読み書きできる場合がある。

## Onboard Devices Configuration

#### LAN 1 Controller  (`LAN`, setupItemID `0x0007`)
- **選択肢**: Disabled / Enabled
- **デフォルト**: Enabled
- **現在値 (2026-05-16)**: Enabled
- **ヘルプ**: "Enable/Disable Onboard LAN1 Contoller."
- **KVM 確認**: 2026-06-10 確認 (可視/非表示・所属は冒頭「🔬 KVM 実機確認」節を参照)
- **解説**: (XML ヘルプ要約) Enable/Disable Onboard LAN1 Contoller.
- **PVE/PXE 推奨**: デフォルト維持で可。
- **リスク**: Moderate

#### LAN 2 Controller  (`Lan2`, setupItemID `0x00B3`)
- **選択肢**: Disabled / Enabled
- **デフォルト**: Enabled
- **現在値 (2026-05-16)**: Enabled
- **ヘルプ**: "Enable/Disable Onboard LAN2 Contoller."
- **KVM 確認**: 2026-06-10 確認 (可視/非表示・所属は冒頭「🔬 KVM 実機確認」節を参照)
- **解説**: (XML ヘルプ要約) Enable/Disable Onboard LAN2 Contoller.
- **PVE/PXE 推奨**: デフォルト維持で可。
- **リスク**: Moderate

#### Primary Display  (`PrimaryDisplay`, setupItemID `0x00D7`)
- **選択肢**: Auto / Internal Graphics / PCI Express for Graphics (PEG) / PCI Express (PCIE)
- **デフォルト**: Auto
- **現在値 (2026-05-16)**: Auto
- **ヘルプ**: "Selects which graphics controller has connected the primary display."
- **KVM 確認**: 2026-06-10 確認 (可視/非表示・所属は冒頭「🔬 KVM 実機確認」節を参照)
- **解説**: (XML ヘルプ要約) Selects which graphics controller has connected the primary display.
- **PVE/PXE 推奨**: デフォルト維持で可。
- **リスク**: Safe

#### Internal Graphics  (`InternalGraphics`, setupItemID `0x00D8`)
- **選択肢**: Auto / Disabled / Enabled
- **デフォルト**: Disabled
- **現在値 (2026-05-16)**: Disabled
- **ヘルプ**: "The BIOS detects automatically if the internal graphics controller can be disabled, but it can manually be forced to enabled or disabled."
- **KVM 確認**: 2026-06-10 確認 (可視/非表示・所属は冒頭「🔬 KVM 実機確認」節を参照)
- **解説**: (XML ヘルプ要約) The BIOS detects automatically if the internal graphics controller can be disabled, but it can manually be forced to enabled or disabled.
- **PVE/PXE 推奨**: デフォルト維持で可。
- **リスク**: Safe

#### LAN 1 Oprom  (`Lan1Oprom`, setupItemID `0x00E0`)
- **選択肢**: Disabled / PXE / iSCSI
- **デフォルト**: PXE
- **現在値 (2026-05-16)**: PXE
- **ヘルプ**: 
  > Controls which OptionROM will be loaded for the respective onboard LAN port.
  > [Disabled] No OptionROM is loaded.
  > [PXE] Load the PXE OptionROM.
  > [iSCSI] Load the iSCSI OptionROM.
- **KVM 確認**: 2026-06-10 確認 (可視/非表示・所属は冒頭「🔬 KVM 実機確認」節を参照)
- **解説**: (XML ヘルプ要約) Controls which OptionROM will be loaded for the respective onboard LAN port.
- **PVE/PXE 推奨**: デフォルト維持で可。
- **リスク**: Safe

#### LAN 2 Oprom  (`Lan2Oprom`, setupItemID `0x00E1`)
- **選択肢**: Disabled / PXE / iSCSI
- **デフォルト**: Disabled
- **現在値 (2026-05-16)**: Disabled
- **ヘルプ**: 
  > Controls which OptionROM will be loaded for the respective onboard LAN port.
  > [Disabled] No OptionROM is loaded.
  > [PXE] Load the PXE OptionROM.
  > [iSCSI] Load the iSCSI OptionROM.
- **KVM 確認**: 2026-06-10 確認 (可視/非表示・所属は冒頭「🔬 KVM 実機確認」節を参照)
- **解説**: (XML ヘルプ要約) Controls which OptionROM will be loaded for the respective onboard LAN port.
- **PVE/PXE 推奨**: デフォルト維持で可。
- **リスク**: Safe

#### DVMT Shared Memory Size  (`DVMTSharedMemorySize`, setupItemID `0x01DF`)
- **選択肢**: 32 MB / 64 MB / 128 MB / 256 MB / 512 MB / 1024 MB / 1536 MB
- **デフォルト**: 32 MB
- **現在値 (2026-05-16)**: 32 MB
- **ヘルプ**: "Select DVMT 5.0 pre-allocated (fixed) memory size used by the internal graphics controller."
- **KVM 確認**: 2026-06-10 確認 (可視/非表示・所属は冒頭「🔬 KVM 実機確認」節を参照)
- **解説**: (XML ヘルプ要約) Select DVMT 5.0 pre-allocated (fixed) memory size used by the internal graphics controller.
- **PVE/PXE 推奨**: デフォルト維持で可。
- **リスク**: Safe

#### DVMT Total Graphics Memory Size  (`DVMTTotalGraphicsMemorySize,`, setupItemID `0x01E0`)
- **選択肢**: 128 MB / 256 MB / MAX
- **デフォルト**: 256 MB
- **現在値 (2026-05-16)**: 256 MB
- **ヘルプ**: "Select DVMT 5.0 total memory size used by the internal graphics controller."
- **KVM 確認**: 2026-06-10 確認 (可視/非表示・所属は冒頭「🔬 KVM 実機確認」節を参照)
- **解説**: (XML ヘルプ要約) Select DVMT 5.0 total memory size used by the internal graphics controller.
- **PVE/PXE 推奨**: デフォルト維持で可。
- **リスク**: Safe

## PCI Status

#### PCI Slot 1  (`StatusPCISlot1`, setupItemID `0x0196`)
- **選択肢**: Enabled / Failed / Empty
- **デフォルト**: Enabled
- **現在値 (2026-05-16)**: Empty  ⚠️ デフォルトと相違
- **ヘルプ**: "PCI Slot Control"
- **KVM 確認**: 2026-06-10 確認 (可視/非表示・所属は冒頭「🔬 KVM 実機確認」節を参照)
- **解説**: (XML ヘルプ要約) PCI Slot Control
- **PVE/PXE 推奨**: デフォルト維持で可。
- **リスク**: Safe

#### PCI Slot 2  (`StatusPCISlot2`, setupItemID `0x0197`)
- **選択肢**: Enabled / Failed / Empty
- **デフォルト**: Enabled
- **現在値 (2026-05-16)**: Empty  ⚠️ デフォルトと相違
- **ヘルプ**: "PCI Slot Control"
- **KVM 確認**: 2026-06-10 確認 (可視/非表示・所属は冒頭「🔬 KVM 実機確認」節を参照)
- **解説**: (XML ヘルプ要約) PCI Slot Control
- **PVE/PXE 推奨**: デフォルト維持で可。
- **リスク**: Safe

#### PCI Slot 3  (`StatusPCISlot3`, setupItemID `0x0198`)
- **選択肢**: Enabled / Failed / Empty
- **デフォルト**: Enabled
- **現在値 (2026-05-16)**: Empty  ⚠️ デフォルトと相違
- **ヘルプ**: "PCI Slot Control"
- **KVM 確認**: 2026-06-10 確認 (可視/非表示・所属は冒頭「🔬 KVM 実機確認」節を参照)
- **解説**: (XML ヘルプ要約) PCI Slot Control
- **PVE/PXE 推奨**: デフォルト維持で可。
- **リスク**: Safe

#### PCI Slot 4  (`StatusPCISlot4`, setupItemID `0x0199`)
- **選択肢**: Enabled / Failed / Empty
- **デフォルト**: Enabled
- **現在値 (2026-05-16)**: Enabled
- **ヘルプ**: "PCI Slot Control"
- **KVM 確認**: 2026-06-10 確認 (可視/非表示・所属は冒頭「🔬 KVM 実機確認」節を参照)
- **解説**: (XML ヘルプ要約) PCI Slot Control
- **PVE/PXE 推奨**: デフォルト維持で可。
- **リスク**: Safe

## PCI Subsystem Settings

#### PCI Error Logging  (`PCIErrorLogging`, setupItemID `0x00A0`)
- **選択肢**: Disabled / Enabled
- **デフォルト**: Enabled
- **現在値 (2026-05-16)**: Enabled
- **ヘルプ**: "Enable/Disable PCI Error Logging."
- **KVM 確認**: 2026-06-10 確認 (可視/非表示・所属は冒頭「🔬 KVM 実機確認」節を参照)
- **解説**: (XML ヘルプ要約) Enable/Disable PCI Error Logging.
- **PVE/PXE 推奨**: デフォルト維持で可。
- **リスク**: Safe

#### PERR# Generation  (`PerrGeneration`, setupItemID `0x00B1`)
- **選択肢**: Disabled / Enabled
- **デフォルト**: Enabled
- **現在値 (2026-05-16)**: Enabled
- **ヘルプ**: "Enables or Disables PCI Device to Generate PERR#."
- **KVM 確認**: 2026-06-10 確認 (可視/非表示・所属は冒頭「🔬 KVM 実機確認」節を参照)
- **解説**: (XML ヘルプ要約) Enables or Disables PCI Device to Generate PERR#.
- **PVE/PXE 推奨**: デフォルト維持で可。
- **リスク**: Safe

#### SERR# Generation  (`SerrGeneration`, setupItemID `0x00B2`)
- **選択肢**: Disabled / Enabled
- **デフォルト**: Enabled
- **現在値 (2026-05-16)**: Enabled
- **ヘルプ**: "Enables or Disables PCI Device to Generate SERR#."
- **KVM 確認**: 2026-06-10 確認 (可視/非表示・所属は冒頭「🔬 KVM 実機確認」節を参照)
- **解説**: (XML ヘルプ要約) Enables or Disables PCI Device to Generate SERR#.
- **PVE/PXE 推奨**: デフォルト維持で可。
- **リスク**: Safe

#### ASPM Support  (`AspmSupport`, setupItemID `0x00E2`)
- **選択肢**: Disabled / Auto / Force L0s
- **デフォルト**: Disabled
- **現在値 (2026-05-16)**: Disabled
- **ヘルプ**: 
  > Configures Active State Power Management (ASPM) energy saving.
  > [Disabled]
  > No energy saving. Best stability.
  > [L1 Only]
  > Tradeoff between stability and energy saving.
- **KVM 確認**: 2026-06-10 確認 (可視/非表示・所属は冒頭「🔬 KVM 実機確認」節を参照)
- **解説**: (XML ヘルプ要約) Configures Active State Power Management (ASPM) energy saving.
- **PVE/PXE 推奨**: デフォルト維持で可。
- **リスク**: Safe

#### Above 4G Decoding  (`Above4GDecoding`, setupItemID `0x0101`)
- **選択肢**: Disabled / Enabled
- **デフォルト**: Disabled
- **現在値 (2026-05-16)**: Disabled
- **ヘルプ**: "Enables or Disables 64bit capable Devices to be Decoded in Above 4G Address Space (Only if System Supports 64 bit PCI Decoding)."
- **KVM 確認**: 2026-06-10 確認 (可視/非表示・所属は冒頭「🔬 KVM 実機確認」節を参照)
- **解説**: (XML ヘルプ要約) Enables or Disables 64bit capable Devices to be Decoded in Above 4G Address Space (Only if System Supports 64 bit PCI Decoding).
- **PVE/PXE 推奨**: デフォルト維持で可。
- **リスク**: Safe

## CPU Configuration

#### Active Processor Cores  (`CoreProcessingMode`, setupItemID `0x0032`)
- **選択肢**: All / 1 / 2 / 3
- **デフォルト**: All
- **現在値 (2026-05-16)**: All
- **ヘルプ**: "Number of cores to enable in each processor package."
- **KVM 確認**: 2026-06-10 確認 (可視/非表示・所属は冒頭「🔬 KVM 実機確認」節を参照)
- **解説**: (XML ヘルプ要約) Number of cores to enable in each processor package.
- **PVE/PXE 推奨**: デフォルト維持で可。
- **リスク**: Moderate

#### Enhanced SpeedStep  (`EnhancedSpeedStep`, setupItemID `0x0033`)
- **選択肢**: Disabled / Enabled
- **デフォルト**: Enabled
- **現在値 (2026-05-16)**: Enabled
- **ヘルプ**: "When enabled, OS sets CPU frequency according load. When disabled, CPU frequency is set at max non-turbo."
- **KVM 確認**: 2026-06-10 確認 (可視/非表示・所属は冒頭「🔬 KVM 実機確認」節を参照)
- **解説**: (XML ヘルプ要約) When enabled, OS sets CPU frequency according load. When disabled, CPU frequency is set at max non-turbo.
- **PVE/PXE 推奨**: デフォルト維持で可。
- **リスク**: Safe

#### Execute Disable Bit  (`XDBitfunctionalityAndNXMemoryProtection`, setupItemID `0x0036`)
- **選択肢**: Disabled / Enabled
- **デフォルト**: Enabled
- **現在値 (2026-05-16)**: Enabled
- **ヘルプ**: "When disabled, forces the XD feature flag to always return 0."
- **KVM 確認**: 2026-06-10 確認 (可視/非表示・所属は冒頭「🔬 KVM 実機確認」節を参照)
- **解説**: (XML ヘルプ要約) When disabled, forces the XD feature flag to always return 0.
- **PVE/PXE 推奨**: デフォルト維持で可。
- **リスク**: Safe

#### Intel Virtualization Technology  (`VirtualizationTechnology`, setupItemID `0x0037`)
- **選択肢**: Disabled / Enabled
- **デフォルト**: Enabled
- **現在値 (2026-05-16)**: Enabled
- **ヘルプ**: "When enabled, a VMM can utilize the additional hardware capabilities provided by Vanderpool Technology."
- **KVM 確認**: 2026-06-10 確認 (可視/非表示・所属は冒頭「🔬 KVM 実機確認」節を参照)
- **解説**: Intel VT-x。VMM がハードウェア仮想化支援を利用可能にする。
- **PVE/PXE 推奨**: `Enabled` 必須 (KVM/QEMU のハードウェア仮想化)。
- **リスク**: Moderate

#### Hyper-Threading  (`HyperThreading`, setupItemID `0x0057`)
- **選択肢**: Disabled / Enabled
- **デフォルト**: Enabled
- **現在値 (2026-05-16)**: Enabled
- **ヘルプ**: "Enables Hyper-Threading (Software Method to Enable/Disable logical Processor threads)."
- **KVM 確認**: 2026-06-10 確認 (可視/非表示・所属は冒頭「🔬 KVM 実機確認」節を参照)
- **解説**: Intel Hyper-Threading。1 物理コアあたり 2 論理スレッド。仮想化では vCPU キャパが倍増。
- **PVE/PXE 推奨**: `Enabled` (VM の vCPU 容量増)。
- **リスク**: Moderate

#### VT-d  (`IntelVTd`, setupItemID `0x0067`)
- **選択肢**: Enabled / Disabled
- **デフォルト**: Enabled
- **現在値 (2026-05-16)**: Enabled
- **ヘルプ**: "Enable/Disable Intel Virtualization Technology for Directed I/O (VT-d) by reporting the I/O device assignment to VMM through DMAR ACPI Tables."
- **KVM 確認**: 2026-06-10 確認 (可視/非表示・所属は冒頭「🔬 KVM 実機確認」節を参照)
- **解説**: Intel VT-d (Directed I/O)。PCI パススルー (IOMMU) に必要。
- **PVE/PXE 推奨**: PCI パススルーを使うなら `Enabled`。pvese 通常運用では必須ではないが有効で問題なし。
- **リスク**: Moderate

#### Intel TXT(LT) Support  (`Intel_TxT`, setupItemID `0x0068`)
- **選択肢**: Disabled / Enabled
- **デフォルト**: Disabled
- **現在値 (2026-05-16)**: Disabled
- **ヘルプ**: "Enables or Disables Intel(R) TXT(LT) support."
- **KVM 確認**: 2026-06-10 確認 (可視/非表示・所属は冒頭「🔬 KVM 実機確認」節を参照)
- **解説**: (XML ヘルプ要約) Enables or Disables Intel(R) TXT(LT) support.
- **PVE/PXE 推奨**: デフォルト維持で可。
- **リスク**: Safe

#### Turbo Mode  (`TurboMode`, setupItemID `0x00A6`)
- **選択肢**: Disabled / Enabled
- **デフォルト**: Enabled
- **現在値 (2026-05-16)**: Enabled
- **ヘルプ**: "Turbo mode allows a CPU logical processor to execute a higher frequency when enough power is available not exceed CPU defined limits."
- **KVM 確認**: 2026-06-10 確認 (可視/非表示・所属は冒頭「🔬 KVM 実機確認」節を参照)
- **解説**: (XML ヘルプ要約) Turbo mode allows a CPU logical processor to execute a higher frequency when enough power is available not exceed CPU defined limits.
- **PVE/PXE 推奨**: デフォルト維持で可。
- **リスク**: Safe

#### Hardware Prefetcher  (`HardwarePrefetcher`, setupItemID `0x012E`)
- **選択肢**: Disabled / Enabled
- **デフォルト**: Enabled
- **現在値 (2026-05-16)**: Enabled
- **ヘルプ**: "To turn on/off the MLC streamer prefetcher."
- **KVM 確認**: 2026-06-10 確認 (可視/非表示・所属は冒頭「🔬 KVM 実機確認」節を参照)
- **解説**: (XML ヘルプ要約) To turn on/off the MLC streamer prefetcher.
- **PVE/PXE 推奨**: デフォルト維持で可。
- **リスク**: Safe

#### Adjacent Cache Line Prefetch  (`AdjacentCacheLinePrefetch`, setupItemID `0x012F`)
- **選択肢**: Disabled / Enabled
- **デフォルト**: Enabled
- **現在値 (2026-05-16)**: Enabled
- **ヘルプ**: "To turn on/off prefetching of adjacent cache lines."
- **KVM 確認**: 2026-06-10 確認 (可視/非表示・所属は冒頭「🔬 KVM 実機確認」節を参照)
- **解説**: (XML ヘルプ要約) To turn on/off prefetching of adjacent cache lines.
- **PVE/PXE 推奨**: デフォルト維持で可。
- **リスク**: Safe

#### DCU Streamer Prefetcher  (`DcuStreamerPrefecher`, setupItemID `0x0130`)
- **選択肢**: Enabled / Disabled
- **デフォルト**: Enabled
- **現在値 (2026-05-16)**: Enabled
- **ヘルプ**: "Enable/Disable DCU Streamer Prefetcher."
- **KVM 確認**: 2026-06-10 確認 (可視/非表示・所属は冒頭「🔬 KVM 実機確認」節を参照)
- **解説**: (XML ヘルプ要約) Enable/Disable DCU Streamer Prefetcher.
- **PVE/PXE 推奨**: デフォルト維持で可。
- **リスク**: Safe

#### Package C State limit  (`PackageCStateLimit`, setupItemID `0x0136`)
- **選択肢**: C0 / C2 / C3 / C6 / C7 / C7s
- **デフォルト**: C7
- **現在値 (2026-05-16)**: C7
- **ヘルプ**: "Package C State limit"
- **KVM 確認**: 2026-06-10 確認 (可視/非表示・所属は冒頭「🔬 KVM 実機確認」節を参照)
- **解説**: (XML ヘルプ要約) Package C State limit
- **PVE/PXE 推奨**: デフォルト維持で可。
- **リスク**: Safe

#### Limit CPUID Maximum  (`LimitCpuIdMaximum`, setupItemID `0x0140`)
- **選択肢**: Disabled / Enabled
- **デフォルト**: Disabled
- **現在値 (2026-05-16)**: Disabled
- **ヘルプ**: "This should be enabled in order to boot legacy OSes that cannot support CPUs with extended CPUID functions."
- **KVM 確認**: 2026-06-10 確認 (可視/非表示・所属は冒頭「🔬 KVM 実機確認」節を参照)
- **解説**: (XML ヘルプ要約) This should be enabled in order to boot legacy OSes that cannot support CPUs with extended CPUID functions.
- **PVE/PXE 推奨**: デフォルト維持で可。
- **リスク**: Safe

#### SW Guard Extensions (SGX)  (`SwGuardExtensions_SGX`, setupItemID `0x01BF`)
- **選択肢**: Disabled / Enabled / Software Controlled
- **デフォルト**: Disabled
- **現在値 (2026-05-16)**: Disabled
- **ヘルプ**: "Enable/Disable Software Guard Extensions (SGX)"
- **KVM 確認**: 2026-06-10 確認 (可視/非表示・所属は冒頭「🔬 KVM 実機確認」節を参照)
- **解説**: (XML ヘルプ要約) Enable/Disable Software Guard Extensions (SGX)
- **PVE/PXE 推奨**: デフォルト維持で可。
- **リスク**: Safe

#### X2APIC Opt Out  (`X2APIC_OptOut`, setupItemID `0x01C0`)
- **選択肢**: Enabled / Disabled
- **デフォルト**: Disabled
- **現在値 (2026-05-16)**: Disabled
- **ヘルプ**: "Enable/Disable X2APIC_OPT_OUT bit"
- **KVM 確認**: 2026-06-10 確認 (可視/非表示・所属は冒頭「🔬 KVM 実機確認」節を参照)
- **解説**: (XML ヘルプ要約) Enable/Disable X2APIC_OPT_OUT bit
- **PVE/PXE 推奨**: デフォルト維持で可。
- **リスク**: Safe

#### Power Limit 1 Override  (`PowerLimit1Override`, setupItemID `0x01CB`)
- **選択肢**: Disabled / Enabled
- **デフォルト**: Disabled
- **現在値 (2026-05-16)**: Disabled
- **ヘルプ**: "Enable/Disable Power Limit 1 Override. If this option is disabled, BIOS will program the default values for Power Limit 1 and Power Limit 1 Time Window."
- **KVM 確認**: 2026-06-10 確認 (可視/非表示・所属は冒頭「🔬 KVM 実機確認」節を参照)
- **解説**: (XML ヘルプ要約) Enable/Disable Power Limit 1 Override. If this option is disabled, BIOS will program the default values for Power Limit 1 and Power Limit 1 Time Window.
- **PVE/PXE 推奨**: デフォルト維持で可。
- **リスク**: Safe

#### Power Limit 1 Window  (`PowerLimit1Window`, setupItemID `0x01CD`)
- **選択肢**: 0 / 1 / 2 / 3 / 4 / 5 / 6 / 7 / 8 / 10 / 12 / 14 / 16 / 20 / 24 / 28 / 32 / 40 / 48 / 56 / 64 / 80 / 96 / 112 / 128
- **デフォルト**: 0
- **現在値 (2026-05-16)**: 0
- **ヘルプ**: "Power Limit 1 Time Window value in seconds. The value may vary from 0 to 128. If the value is 0, default values will be programmed (28 sec for Mobile and 1 sec for Desktop). Indicates the time window over which TDP value should be maintained."
- **KVM 確認**: 2026-06-10 確認 (可視/非表示・所属は冒頭「🔬 KVM 実機確認」節を参照)
- **解説**: (XML ヘルプ要約) Power Limit 1 Time Window value in seconds. The value may vary from 0 to 128. If the value is 0, default values will be programmed (28 sec for Mobile and 1 sec for Desktop). Indicates the time window over which TDP value should be maintained.
- **PVE/PXE 推奨**: デフォルト維持で可。
- **リスク**: Safe

#### Power Limit 2 Override  (`PowerLimit2Override`, setupItemID `0x01CE`)
- **選択肢**: Disabled / Enabled
- **デフォルト**: Enabled
- **現在値 (2026-05-16)**: Enabled
- **ヘルプ**: "Enable/Disable Power Limit 2 Override. If this option is disabled, BIOS will program the default values for Power Limit 2."
- **KVM 確認**: 2026-06-10 確認 (可視/非表示・所属は冒頭「🔬 KVM 実機確認」節を参照)
- **解説**: (XML ヘルプ要約) Enable/Disable Power Limit 2 Override. If this option is disabled, BIOS will program the default values for Power Limit 2.
- **PVE/PXE 推奨**: デフォルト維持で可。
- **リスク**: Safe

#### Platform PL1 Enable  (`PlatformPL1Enable`, setupItemID `0x01D0`)
- **選択肢**: Disabled / Enabled
- **デフォルト**: Disabled
- **現在値 (2026-05-16)**: Disabled
- **ヘルプ**: "Enable/Disable Platform Power Limit 1 programming. If this option is enabled, it activates the PL1 value to be used by the processor to limit the average power of given time window."
- **KVM 確認**: 2026-06-10 確認 (可視/非表示・所属は冒頭「🔬 KVM 実機確認」節を参照)
- **解説**: (XML ヘルプ要約) Enable/Disable Platform Power Limit 1 programming. If this option is enabled, it activates the PL1 value to be used by the processor to limit the average power of given time window.
- **PVE/PXE 推奨**: デフォルト維持で可。
- **リスク**: Safe

#### Platform PL1 Time Window  (`PlatformPL1TimeWindow`, setupItemID `0x01D2`)
- **選択肢**: 0 / 1 / 2 / 3 / 4 / 5 / 6 / 7 / 8 / 10 / 12 / 14 / 16 / 20 / 24 / 28 / 32 / 40 / 48 / 56 / 64 / 80 / 96 / 112 / 128
- **デフォルト**: 0
- **現在値 (2026-05-16)**: 0
- **ヘルプ**: "Platform Power Limit 1 Time Window value in seconds. The value may vary from 0 to 128. If the value is 0,g default values will be programmed Indicates the time window over which Platform TDP value should be maintained."
- **KVM 確認**: 2026-06-10 確認 (可視/非表示・所属は冒頭「🔬 KVM 実機確認」節を参照)
- **解説**: (XML ヘルプ要約) Platform Power Limit 1 Time Window value in seconds. The value may vary from 0 to 128. If the value is 0,g default values will be programmed Indicates the time window over which Platform TDP value should be maintained.
- **PVE/PXE 推奨**: デフォルト維持で可。
- **リスク**: Safe

#### Platform PL2 Enable  (`PlatformPL2Enable`, setupItemID `0x01D3`)
- **選択肢**: Disabled / Enabled
- **デフォルト**: Disabled
- **現在値 (2026-05-16)**: Disabled
- **ヘルプ**: "Enable/Disable Platform Power Limit 2 programming. If this option is disabled, BIOS will program the default values for Platform Power Limit 2."
- **KVM 確認**: 2026-06-10 確認 (可視/非表示・所属は冒頭「🔬 KVM 実機確認」節を参照)
- **解説**: (XML ヘルプ要約) Enable/Disable Platform Power Limit 2 programming. If this option is disabled, BIOS will program the default values for Platform Power Limit 2.
- **PVE/PXE 推奨**: デフォルト維持で可。
- **リスク**: Safe

#### Power Limit 3 Override  (`PowerLimit3Override`, setupItemID `0x01D5`)
- **選択肢**: Disabled / Enabled
- **デフォルト**: Disabled
- **現在値 (2026-05-16)**: Disabled
- **ヘルプ**: "Enable/DisablePower Limit 3 override. If this option is disabled, BIOS will leave the default values for Power Limit 3 and Power Limit 3 Time Window."
- **KVM 確認**: 2026-06-10 確認 (可視/非表示・所属は冒頭「🔬 KVM 実機確認」節を参照)
- **解説**: (XML ヘルプ要約) Enable/DisablePower Limit 3 override. If this option is disabled, BIOS will leave the default values for Power Limit 3 and Power Limit 3 Time Window.
- **PVE/PXE 推奨**: デフォルト維持で可。
- **リスク**: Safe

#### Power Limit 3 Time Window  (`PowerLimit3TimeWindow`, setupItemID `0x01D7`)
- **選択肢**: 範囲 0–64 (数値)
- **デフォルト**: 0
- **現在値 (2026-05-16)**: 0
- **ヘルプ**: "Power Limit 3 Time Window value in Milli seconds. The value may vary from 3 to 64(max).Indicates the time window over which Power Limit 3 value should be maintained. If the value is 0, BIOS leaves default value"
- **KVM 確認**: 2026-06-10 確認 (可視/非表示・所属は冒頭「🔬 KVM 実機確認」節を参照)
- **解説**: (XML ヘルプ要約) Power Limit 3 Time Window value in Milli seconds. The value may vary from 3 to 64(max).Indicates the time window over which Power Limit 3 value should be maintained. If the value is 0, BIOS leaves default value
- **PVE/PXE 推奨**: デフォルト維持で可。
- **リスク**: Safe

#### Powet Limit 3 Duty Cycle  (`PowerLimit3DutyCycle`, setupItemID `0x01D8`)
- **選択肢**: 範囲 0–100 (数値)
- **デフォルト**: 0
- **現在値 (2026-05-16)**: 0
- **ヘルプ**: "Specify the duty cycle in percentage that the CPU is required to maintain over the configured Power Limit3 time windows."
- **KVM 確認**: 2026-06-10 確認 (可視/非表示・所属は冒頭「🔬 KVM 実機確認」節を参照)
- **解説**: (XML ヘルプ要約) Specify the duty cycle in percentage that the CPU is required to maintain over the configured Power Limit3 time windows.
- **PVE/PXE 推奨**: デフォルト維持で可。
- **リスク**: Safe

#### Power Limit 4 Override  (`PowerLimit4Override`, setupItemID `0x01D9`)
- **選択肢**: Disabled / Enabled
- **デフォルト**: Disabled
- **現在値 (2026-05-16)**: Disabled
- **ヘルプ**: "Enable/Disable Power Limit 4 override. If this option is disabled, BIOS will leave the default values for Power Limit 4."
- **KVM 確認**: 2026-06-10 確認 (可視/非表示・所属は冒頭「🔬 KVM 実機確認」節を参照)
- **解説**: (XML ヘルプ要約) Enable/Disable Power Limit 4 override. If this option is disabled, BIOS will leave the default values for Power Limit 4.
- **PVE/PXE 推奨**: デフォルト維持で可。
- **リスク**: Safe

#### CPU C states  (`??? SetupVariableId unknown ???`, setupItemID `0x023B`)
- **選択肢**: Disabled / Enabled
- **デフォルト**: Enabled
- **現在値 (2026-05-16)**: Enabled
- **ヘルプ**: "Enable or disable CPU C states"
- **KVM 確認**: 2026-06-10 確認 (可視/非表示・所属は冒頭「🔬 KVM 実機確認」節を参照)
- **解説**: (XML ヘルプ要約) Enable or disable CPU C states
- **PVE/PXE 推奨**: デフォルト維持で可。
- **リスク**: Safe

#### PM Support  (`PmSupport`, setupItemID `0x0258`)
- **選択肢**: Enabled / Disabled
- **デフォルト**: Enabled
- **現在値 (2026-05-16)**: Enabled
- **ヘルプ**: "Enable/Disable PM Support"
- **KVM 確認**: 2026-06-10 確認 (可視/非表示・所属は冒頭「🔬 KVM 実機確認」節を参照)
- **解説**: (XML ヘルプ要約) Enable/Disable PM Support
- **PVE/PXE 推奨**: デフォルト維持で可。
- **リスク**: Safe

## Memory Status

#### ECC Memory Error Logging  (`ECCMemoryErrorLogging`, setupItemID `0x009F`)
- **選択肢**: Enabled / Multi-bit Errors Only / Disabled
- **デフォルト**: Enabled
- **現在値 (2026-05-16)**: Enabled
- **ヘルプ**: "Configure ECC Memory Error Logging Support."
- **KVM 確認**: 2026-06-10 確認 (可視/非表示・所属は冒頭「🔬 KVM 実機確認」節を参照)
- **解説**: (XML ヘルプ要約) Configure ECC Memory Error Logging Support.
- **PVE/PXE 推奨**: デフォルト維持で可。
- **リスク**: Safe

## SATA Configuration

#### SATA Mode Selection  (`SATAControllerModeSelection`, setupItemID `0x0087`)
- **選択肢**: AHCI Mode / RAID Mode
- **デフォルト**: AHCI Mode
- **現在値 (2026-05-16)**: RAID Mode  ⚠️ デフォルトと相違
- **ヘルプ**: "Determines how SATA controller(s) operate."
- **KVM 確認**: 2026-06-10 確認 (可視/非表示・所属は冒頭「🔬 KVM 実機確認」節を参照)
- **解説**: SATA コントローラの動作モード。AHCI は各ドライブを個別に OS へ提示、RAID は Intel RSTe ソフト RAID。TX1320 の OS ディスクは PRAID EP400i (AVAGO MegaRAID) 配下なので、この onboard SATA モードは光学ドライブ等の扱いに影響する。
- **PVE/PXE 推奨**: 現状 `RAID Mode` (出荷時 AHCI Mode から変更されている)。PVE/Linux は mdadm/ZFS/LVM を使うため通常 AHCI で良いが、TX1320 のデータは MegaRAID 配下なので onboard SATA の使用状況に依存。変更時は OS のディスク認識が変わるため要検証。
- **リスク**: High

## CSM Configuration

#### Launch PXE OpROM Policy  (`LANRemoteBoot`, setupItemID `0x000D`)
- **選択肢**: Do not launch / UEFI only / Legacy only
- **デフォルト**: Legacy only
- **現在値 (2026-05-16)**: Legacy only
- **ヘルプ**: "Controls the execution of UEFI and Legacy PXE OpROM."
- **KVM 確認**: 2026-06-10 確認 (可視/非表示・所属は冒頭「🔬 KVM 実機確認」節を参照)
- **解説**: (XML ヘルプ要約) Controls the execution of UEFI and Legacy PXE OpROM.
- **PVE/PXE 推奨**: デフォルト維持で可。
- **リスク**: Moderate

#### Launch CSM  (`Csm`, setupItemID `0x00EA`)
- **選択肢**: Disabled / Enabled
- **デフォルト**: Disabled
- **現在値 (2026-05-16)**: Disabled
- **ヘルプ**: "This option controls if CSM will be launched."
- **KVM 確認**: 2026-06-10 確認 (可視/非表示・所属は冒頭「🔬 KVM 実機確認」節を参照)
- **解説**: CSM (Compatibility Support Module) を起動するか。Disabled=純 UEFI ブート、Enabled=Legacy OpROM 実行を許可。Secure Boot は CSM 無効が前提。
- **PVE/PXE 推奨**: `Disabled` 維持 (純 UEFI)。pvese の TX1320 install は iPXE-CD/UEFI 経路なので CSM 不要。CSM を有効化すると Legacy/UEFI 混在でブート順が不安定化する。
- **リスク**: High

#### Boot option filter  (`BootOptionFilter`, setupItemID `0x0103`)
- **選択肢**: UEFI and Legacy / Legacy only / UEFI only
- **デフォルト**: Legacy only
- **現在値 (2026-05-16)**: Legacy only
- **ヘルプ**: "This option controls what devices system can boot to."
- **KVM 確認**: 2026-06-10 確認 (可視/非表示・所属は冒頭「🔬 KVM 実機確認」節を参照)
- **解説**: システムがブート可能なデバイス種別を UEFI/Legacy で絞る。`UEFI only` / `Legacy only` / `UEFI and Legacy`。
- **PVE/PXE 推奨**: `UEFI only` 推奨 (pvese の TX1320 は UEFI install)。reference.md の UEFI 化手順でこの id を `Legacy only`→`UEFI only` に変更する。出荷時 `Legacy only`。
- **リスク**: High

#### Launch PXE OpROM Policy  (`LaunchPxeOpRomPolicy`, setupItemID `0x0104`)
- **選択肢**: Do not launch / UEFI only / Legacy only
- **デフォルト**: Legacy only
- **現在値 (2026-05-16)**: Legacy only
- **ヘルプ**: "Controls the execution of UEFI and Legacy PXE OpROM."
- **KVM 確認**: 2026-06-10 確認 (可視/非表示・所属は冒頭「🔬 KVM 実機確認」節を参照)
- **解説**: PXE (ネットワークブート) OpROM を UEFI/Legacy どちらで実行するか。
- **PVE/PXE 推奨**: UEFI PXE を使うなら `UEFI only`。reference.md UEFI 化手順の対象 id。出荷時 `Legacy only`。
- **リスク**: Moderate

#### Launch Storage OpROM policy  (`LaunchStorageOpRomPolicy`, setupItemID `0x0105`)
- **選択肢**: Do not launch / UEFI only / Legacy only
- **デフォルト**: Legacy only
- **現在値 (2026-05-16)**: Legacy only
- **ヘルプ**: "Controls the execution of UEFI and Legacy Storage OpROM"
- **KVM 確認**: 2026-06-10 確認 (可視/非表示・所属は冒頭「🔬 KVM 実機確認」節を参照)
- **解説**: Storage コントローラの OpROM を UEFI/Legacy どちらで実行するか。RAID/HBA のブート可否に直結。
- **PVE/PXE 推奨**: UEFI install では `UEFI only`。reference.md UEFI 化手順の対象 id。出荷時 `Legacy only`。
- **リスク**: Moderate

#### Launch Video OpROM policy  (`LaunchVideoOpRomPolicy`, setupItemID `0x0106`)
- **選択肢**: Do not launch / UEFI only / Legacy only
- **デフォルト**: Legacy only
- **現在値 (2026-05-16)**: Legacy only
- **ヘルプ**: "Controls the execution of UEFI and Legacy Video OpROM."
- **KVM 確認**: 2026-06-10 確認 (可視/非表示・所属は冒頭「🔬 KVM 実機確認」節を参照)
- **解説**: Video OpROM を UEFI/Legacy どちらで実行するか。
- **PVE/PXE 推奨**: UEFI 化では `UEFI only`。reference.md UEFI 化手順の対象 id。
- **リスク**: Moderate

#### Other PCI device ROM priority  (`OtherPciDeviceRomPriority`, setupItemID `0x0107`)
- **選択肢**: Do not launch / UEFI only / Legacy only
- **デフォルト**: Legacy only
- **現在値 (2026-05-16)**: Legacy only
- **ヘルプ**: "For PCI devices other than Network, Mass storage or Video defines which OpROM to launch."
- **KVM 確認**: 2026-06-10 確認 (可視/非表示・所属は冒頭「🔬 KVM 実機確認」節を参照)
- **解説**: (XML ヘルプ要約) For PCI devices other than Network, Mass storage or Video defines which OpROM to launch.
- **PVE/PXE 推奨**: デフォルト維持で可。
- **リスク**: Moderate

## Trusted Computing

#### TPM Support  (`SecurityChip`, setupItemID `0x005C`)
- **選択肢**: Disabled / Enabled
- **デフォルト**: Enabled
- **現在値 (2026-05-16)**: Enabled
- **ヘルプ**: "Enables or Disables TPM support. O.S. will not show TPM. Reset of platform is required."
- **KVM 確認**: 2026-06-10 確認 (可視/非表示・所属は冒頭「🔬 KVM 実機確認」節を参照)
- **解説**: (XML ヘルプ要約) Enables or Disables TPM support. O.S. will not show TPM. Reset of platform is required.
- **PVE/PXE 推奨**: デフォルト維持で可。
- **リスク**: Moderate

#### TPM State  (`ChangeTPMState`, setupItemID `0x005D`)
- **選択肢**: Disabled / Enabled
- **デフォルト**: Enabled
- **現在値 (2026-05-16)**: Enabled
- **ヘルプ**: "Turn TPM Enable/Disable. NOTE: Your Computer will reboot during restart in order to change State of TPM."
- **KVM 確認**: 2026-06-10 確認 (可視/非表示・所属は冒頭「🔬 KVM 実機確認」節を参照)
- **解説**: (XML ヘルプ要約) Turn TPM Enable/Disable. NOTE: Your Computer will reboot during restart in order to change State of TPM.
- **PVE/PXE 推奨**: デフォルト維持で可。
- **リスク**: Moderate

#### Skip PPI during next Boot  (`TpmSkipPPI`, setupItemID `0x0082`)
- **選択肢**: Disabled / Enabled
- **デフォルト**: Disabled
- **現在値 (2026-05-16)**: Disabled
- **ヘルプ**: "Skip Physical Presence confirmation during the next Boot"
- **KVM 確認**: 2026-06-10 確認 (可視/非表示・所属は冒頭「🔬 KVM 実機確認」節を参照)
- **解説**: (XML ヘルプ要約) Skip Physical Presence confirmation during the next Boot
- **PVE/PXE 推奨**: デフォルト維持で可。
- **リスク**: Safe

#### Pending TPM operation  (`PendingTPMOperation`, setupItemID `0x009A`)
- **選択肢**: None / TPM Clear
- **デフォルト**: None
- **現在値 (2026-05-16)**: None
- **ヘルプ**: "Schedule TPM operation. NOTE: Your Computer will reboot during restart in order to change State of TPM."
- **KVM 確認**: 2026-06-10 確認 (可視/非表示・所属は冒頭「🔬 KVM 実機確認」節を参照)
- **解説**: 次回再起動時に実行する TPM 操作。`TPM Clear` は TPM 内の鍵を全消去する (不可逆)。
- **PVE/PXE 推奨**: `None` 維持。BitLocker 等で TPM 鍵を使っている場合 Clear するとデータ復号不能。pvese では通常変更不要。
- **リスク**: Critical

## USB Configuration

#### Onboard USB Controllers  (`USBHostController`, setupItemID `0x0009`)
- **選択肢**: Enabled / Disabled
- **デフォルト**: Enabled
- **現在値 (2026-05-16)**: Enabled
- **ヘルプ**: 
  > [Enabled] Onboard USB controllers are enabled and work as configured.
  > [Disabled] Onboard USB controllers are disabled. All connected USB devices are not available:
  > - external keyboard and mouse
  > - keyboard and mouse via IRMC
  > - internally connected USB devices
- **KVM 確認**: 2026-06-10 確認 (可視/非表示・所属は冒頭「🔬 KVM 実機確認」節を参照)
- **解説**: オンボード USB コントローラ全体。Disabled にすると外部/iRMC 経由のキーボード・マウス・内部 USB すべてが使用不能。
- **PVE/PXE 推奨**: `Enabled` 維持。Disabled は iRMC KVM の USB HID emulation も殺すため BIOS 操作不能になる。
- **リスク**: High

#### Legacy USB Support  (`USBLegacySupport`, setupItemID `0x000B`)
- **選択肢**: Enabled / Disabled / Auto
- **デフォルト**: Enabled
- **現在値 (2026-05-16)**: Enabled
- **ヘルプ**: "Enables Legacy USB support. AUTO option disables legacy support if no USB devices are connected. DISABLE option will keep USB devices available only for EFI applications."
- **KVM 確認**: 2026-06-10 確認 (可視/非表示・所属は冒頭「🔬 KVM 実機確認」節を参照)
- **解説**: (XML ヘルプ要約) Enables Legacy USB support. AUTO option disables legacy support if no USB devices are connected. DISABLE option will keep USB devices available only for EFI applications.
- **PVE/PXE 推奨**: デフォルト維持で可。
- **リスク**: Moderate

#### USB Port Control  (`UsbPortControl`, setupItemID `0x00C5`)
- **選択肢**: Enable all ports / Enable front and internal ports / Enable rear and internal ports / Enable internal ports only
- **デフォルト**: Enable all ports
- **現在値 (2026-05-16)**: Enable all ports
- **ヘルプ**: 
  > Configures how USB ports are enabled.
  > [Enable all ports]
  > All USB ports are enabled.
  > [Disable all ports]
  > All USB ports are disabled.
  > [Enable front and internal ports]
  > All rear USB ports are disabled.
  > [Enable rear and internal ports]
  > All front USB ports are disabled.
  > [Enable internal ports only]
  > All external USB ports are disabled.
  > [Enable used ports]
  > All unused USB ports are disabled.
- **KVM 確認**: 2026-06-10 確認 (可視/非表示・所属は冒頭「🔬 KVM 実機確認」節を参照)
- **解説**: (XML ヘルプ要約) Configures how USB ports are enabled.
- **PVE/PXE 推奨**: デフォルト維持で可。
- **リスク**: Safe

#### USB transfer time-out  (`UsbTransferTimeOut`, setupItemID `0x00D3`)
- **選択肢**: 1 sec / 5 sec / 10 sec / 20 sec
- **デフォルト**: 20 sec
- **現在値 (2026-05-16)**: 20 sec
- **ヘルプ**: "The time-out value for Control, Bulk, and Interrupt transfers."
- **KVM 確認**: 2026-06-10 確認 (可視/非表示・所属は冒頭「🔬 KVM 実機確認」節を参照)
- **解説**: (XML ヘルプ要約) The time-out value for Control, Bulk, and Interrupt transfers.
- **PVE/PXE 推奨**: デフォルト維持で可。
- **リスク**: Safe

#### Port 61h Bit-4 Emulation  (`Port61Bit4Emulation`, setupItemID `0x0255`)
- **選択肢**: Disabled / Enabled
- **デフォルト**: Enabled
- **現在値 (2026-05-16)**: Enabled
- **ヘルプ**: "Emulation of Port 61h bit-4 toggling in SMM"
- **KVM 確認**: 2026-06-10 確認 (可視/非表示・所属は冒頭「🔬 KVM 実機確認」節を参照)
- **解説**: (XML ヘルプ要約) Emulation of Port 61h bit-4 toggling in SMM
- **PVE/PXE 推奨**: デフォルト維持で可。
- **リスク**: Safe

#### Port 60/64 Emulation  (`Port60h64hEmulation`, setupItemID `0x0257`)
- **選択肢**: Disabled / Enabled
- **デフォルト**: Enabled
- **現在値 (2026-05-16)**: Enabled
- **ヘルプ**: "Enables I/O port 60h/64h emulation support. This should be enabled for the complete USB keyboard legacy support for non-USB aware OSes."
- **KVM 確認**: 2026-06-10 確認 (可視/非表示・所属は冒頭「🔬 KVM 実機確認」節を参照)
- **解説**: (XML ヘルプ要約) Enables I/O port 60h/64h emulation support. This should be enabled for the complete USB keyboard legacy support for non-USB aware OSes.
- **PVE/PXE 推奨**: デフォルト維持で可。
- **リスク**: Safe

## Super IO Configuration

#### Serial Port  (`SerialPort1`, setupItemID `0x0001`)
- **選択肢**: Disabled / Enabled
- **デフォルト**: Enabled
- **現在値 (2026-05-16)**: Enabled
- **ヘルプ**: "Enable or Disable Serial Port (COM)"
- **KVM 確認**: 2026-06-10 確認 (可視/非表示・所属は冒頭「🔬 KVM 実機確認」節を参照)
- **解説**: (XML ヘルプ要約) Enable or Disable Serial Port (COM)
- **PVE/PXE 推奨**: デフォルト維持で可。
- **リスク**: Safe

#### Change Settings  (`ChangeSettingsSerialPort`, setupItemID `0x01AC`)
- **選択肢**: Auto / IO=3F8h; IRQ=4; / IO=3F8h; IRQ=3,4,5,6,7,9,10,11,12; / IO=2F8h; IRQ=3,4,5,6,7,9,10,11,12; / IO=3E8h; IRQ=3,4,5,6,7,9,10,11,12; / IO=2E8h; IRQ=3,4,5,6,7,9,10,11,12;
- **デフォルト**: Auto
- **現在値 (2026-05-16)**: Auto
- **ヘルプ**: "Select an optimal settings for Super IO Device"
- **KVM 確認**: 2026-06-10 確認 (可視/非表示・所属は冒頭「🔬 KVM 実機確認」節を参照)
- **解説**: (XML ヘルプ要約) Select an optimal settings for Super IO Device
- **PVE/PXE 推奨**: デフォルト維持で可。
- **リスク**: Safe

## Network Stack Configuration

#### Network Stack  (`NetworkStack`, setupItemID `0x00E5`)
- **選択肢**: Disabled / Enabled
- **デフォルト**: Disabled
- **現在値 (2026-05-16)**: Disabled
- **ヘルプ**: "Enable/Disable UEFI Network Stack"
- **KVM 確認**: 2026-06-10 確認 (可視/非表示・所属は冒頭「🔬 KVM 実機確認」節を参照)
- **解説**: UEFI ネットワークスタック (PXE/HTTP boot 等) の有効/無効。無効だと UEFI ネットワークブートオプションが生成されない。
- **PVE/PXE 推奨**: UEFI PXE/iPXE ネットワークブートを使う場合は `Enabled`。pvese の TX1320 は iPXE-CD (VirtualMedia) 経由なので必須ではないが、PXE pivot 時は要有効化。出荷時 `Disabled`。
- **リスク**: Moderate

#### Ipv4 PXE Support  (`IPv4PxeSupport`, setupItemID `0x00E6`)
- **選択肢**: Disabled / Enabled
- **デフォルト**: Enabled
- **現在値 (2026-05-16)**: Enabled
- **ヘルプ**: "Enable Ipv4 PXE Boot Support. If disabled IPV4 PXE boot option will not be created"
- **KVM 確認**: 2026-06-10 確認 (可視/非表示・所属は冒頭「🔬 KVM 実機確認」節を参照)
- **解説**: (XML ヘルプ要約) Enable Ipv4 PXE Boot Support. If disabled IPV4 PXE boot option will not be created
- **PVE/PXE 推奨**: デフォルト維持で可。
- **リスク**: Safe

#### Ipv6 PXE Support  (`IPv6PxeSupport`, setupItemID `0x00E7`)
- **選択肢**: Disabled / Enabled
- **デフォルト**: Enabled
- **現在値 (2026-05-16)**: Enabled
- **ヘルプ**: "Enable Ipv6 PXE Boot Support. If disabled IPV6 PXE boot option will not be created"
- **KVM 確認**: 2026-06-10 確認 (可視/非表示・所属は冒頭「🔬 KVM 実機確認」節を参照)
- **解説**: (XML ヘルプ要約) Enable Ipv6 PXE Boot Support. If disabled IPV6 PXE boot option will not be created
- **PVE/PXE 推奨**: デフォルト維持で可。
- **リスク**: Safe

## Option ROM Configuration

#### Launch Slot 1 OpROM  (`LaunchSlot1Oprom`, setupItemID `0x00EC`)
- **選択肢**: Disabled / Enabled
- **デフォルト**: Disabled
- **現在値 (2026-05-16)**: Disabled
- **ヘルプ**: "Enable or disable option ROM execution for device in slot 1."
- **KVM 確認**: 2026-06-10 確認 (可視/非表示・所属は冒頭「🔬 KVM 実機確認」節を参照)
- **解説**: (XML ヘルプ要約) Enable or disable option ROM execution for device in slot 1.
- **PVE/PXE 推奨**: デフォルト維持で可。
- **リスク**: Safe

#### Launch Slot 2 OpROM  (`LaunchSlot2Oprom`, setupItemID `0x00ED`)
- **選択肢**: Disabled / Enabled
- **デフォルト**: Disabled
- **現在値 (2026-05-16)**: Disabled
- **ヘルプ**: "Enable or disable option ROM execution for device in slot 2."
- **KVM 確認**: 2026-06-10 確認 (可視/非表示・所属は冒頭「🔬 KVM 実機確認」節を参照)
- **解説**: (XML ヘルプ要約) Enable or disable option ROM execution for device in slot 2.
- **PVE/PXE 推奨**: デフォルト維持で可。
- **リスク**: Safe

#### Launch Slot 3 OpROM  (`LaunchSlot3Oprom`, setupItemID `0x00EE`)
- **選択肢**: Disabled / Enabled
- **デフォルト**: Disabled
- **現在値 (2026-05-16)**: Disabled
- **ヘルプ**: "Enable or disable option ROM execution for device in slot 3."
- **KVM 確認**: 2026-06-10 確認 (可視/非表示・所属は冒頭「🔬 KVM 実機確認」節を参照)
- **解説**: (XML ヘルプ要約) Enable or disable option ROM execution for device in slot 3.
- **PVE/PXE 推奨**: デフォルト維持で可。
- **リスク**: Safe

#### Launch Slot 4 OpROM  (`LaunchSlot4Oprom`, setupItemID `0x00EF`)
- **選択肢**: Disabled / Enabled
- **デフォルト**: Enabled
- **現在値 (2026-05-16)**: Enabled
- **ヘルプ**: "Enable or disable option ROM execution for device in slot 4."
- **KVM 確認**: 2026-06-10 確認 (可視/非表示・所属は冒頭「🔬 KVM 実機確認」節を参照)
- **解説**: (XML ヘルプ要約) Enable or disable option ROM execution for device in slot 4.
- **PVE/PXE 推奨**: デフォルト維持で可。
- **リスク**: Safe

## VIOM

<!-- TODO: capture — XML 非対象。Virtual I/O Manager。KVM で項目採取 -->

## iSCSI Configuration

<!-- TODO: capture — XML 非対象。KVM で項目採取 -->

## AVAGO MegaRAID `<PRAID EP400i>` Configuration Utility

RAID HII の全画面・操作は [raid-avago-hii.md](raid-avago-hii.md) を参照。
