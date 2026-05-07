# Supermicro BIOS 設定リファレンス (X11DPU / X10DRT-P)

## はじめに

本ドキュメントは pvese プロジェクトで使用する Supermicro マザーボード (X11DPU = 4-6号機, X10DRT-P = 10号機) の AMI Aptio UEFI BIOS 設定項目の技術リファレンスである。

- **対象ハードウェア (X11DPU)**: Supermicro X11DPU / X11DPU-Z+ (Dual Socket LGA 3647)
  - CPU: Intel Xeon Scalable (Skylake-SP / Cascade Lake-SP), 4号機: Xeon Gold 6130 x2
  - BIOS: AMI Aptio Setup Utility, Version 2.20.1276 (Build Date 08/11/2023)
  - CPLD Version: 03.B0.06
  - BMC Firmware: 01.73.06
- **対象ハードウェア (X10DRT-P)**: Supermicro X10DRT-P-G5-NI22 (Twin Server, Nutanix NX-1065-G5 OEM)
  - CPU: Intel Xeon E5-2620 v4 x2 (Broadwell-EP, LGA2011-3, 8C/16T, 2.10GHz)
  - BIOS: AMI Aptio Setup Utility, Version 2.17.1249 (Build Date 07/14/2021), Version G4G5T8.0
  - CPLD Version: 03.a1.30
  - BMC Firmware: 3.65 (Nutanix OEM 制約により Supermicro stock FW 更新不可)

各設定項目について、技術的な解説・PVE 推奨値・変更リスクを記載する。BIOS 操作手順は [SKILL.md](SKILL.md) を参照。

ドキュメントは X11DPU の詳細記述を主軸とし、末尾に **「X10DRT-P (10号機) BIOS 設定リファレンス」** 節を設けて X10DRT-P 固有の値・項目を全タブ全サブメニューで網羅する。X11DPU 節も参照しながら読むとよい (タブ構成・キーバインド・基本概念は共通)。

### リスクレベル定義

| レベル | 意味 |
|--------|------|
| **Safe** | 変更してもハードウェアに影響なし。機能の有効/無効切替のみ |
| **Moderate** | OS やドライバの動作に影響する可能性がある。変更前に影響を理解すること |
| **High** | 起動不能やハードウェア障害のリスクがある。十分な検証が必要 |
| **Critical** | データ消失やセキュリティ設定の不可逆変更のリスクがある |

---

# X11DPU (4-6号機) BIOS 設定リファレンス

## Main タブ

読み取り専用の情報表示タブ。設定変更可能な項目は System Date/Time のみ。

#### System Date
- **オプション**: MM/DD/YYYY 形式
- **4号機の現在値**: 03/20/2026 (Fri)
- **解説**: システム日付。OS が NTP で上書きするため通常は変更不要
- **リスク**: Safe

#### System Time
- **オプション**: HH:MM:SS 形式
- **4号機の現在値**: 12:21:12
- **解説**: システム時刻 (ローカルタイム)。OS が NTP で上書きする
- **リスク**: Safe

#### 読み取り専用情報

| 項目 | 4号機の値 |
|------|----------|
| Supermicro X11DPU | (マザーボード型番) |
| BIOS Version | 4.0 |
| Build Date | 08/11/2023 |
| CPLD Version | 03.B0.06 |
| Total Memory | 32768 MB |

---

## Advanced タブ

### 1. Boot Feature

起動時の動作に関する設定。

#### Quiet Boot
- **オプション**: Enabled / Disabled
- **デフォルト**: Enabled
- **4号機の現在値**: Enabled
- **解説**: POST 中に OEM ロゴを表示する。Disabled にすると POST メッセージ (メモリテスト、デバイス検出等) がテキストで表示される
- **PVE 推奨**: Disabled (トラブルシューティング時に POST 情報が見えて便利)
- **リスク**: Safe

#### Option ROM Messages
- **オプション**: Force BIOS / Keep Current
- **デフォルト**: Force BIOS
- **4号機の現在値**: Force BIOS
- **解説**: Option ROM (NIC, RAID コントローラ等) の初期化メッセージの表示方法。Force BIOS は BIOS 表示設定に従う。Keep Current は各 Option ROM の設定に従う
- **PVE 推奨**: Force BIOS
- **リスク**: Safe

#### Bootup NumLock State
- **オプション**: On / Off
- **デフォルト**: On
- **4号機の現在値**: On
- **解説**: 起動時の NumLock キーの初期状態
- **PVE 推奨**: On
- **リスク**: Safe

#### Wait For "F1" If Error
- **オプション**: Enabled / Disabled
- **デフォルト**: Enabled
- **4号機の現在値**: Enabled
- **解説**: POST 中にエラーが検出された場合、F1 キー入力を待つかどうか。Disabled にするとエラーがあっても自動で起動を続行する
- **PVE 推奨**: Enabled (ヘッドレス運用では Disabled も可。ただしエラー見逃しのリスクあり)
- **リスク**: Safe

#### INT19 Trap Response
- **オプション**: Immediate / Postponed
- **デフォルト**: Immediate
- **4号機の現在値**: Immediate
- **解説**: INT19 (ブートストラップローダ) トラップの応答タイミング。Option ROM がブートプロセスに介入するタイミングを制御する。Postponed にすると一部の PXE ブートや RAID コントローラで互換性が改善する場合がある
- **PVE 推奨**: Immediate
- **リスク**: Safe

#### Re-try Boot
- **オプション**: Disabled / Legacy Boot / EFI Boot
- **デフォルト**: Disabled
- **4号機の現在値**: Disabled
- **解説**: ブートデバイスからの起動に失敗した場合にリトライする。Legacy Boot は Legacy デバイスのみ、EFI Boot は UEFI デバイスのみリトライ
- **PVE 推奨**: EFI Boot (UEFI ブート時の回復力向上)
- **リスク**: Safe

#### Power Configuration (サブセクション)

##### Watch Dog Function
- **オプション**: Enabled / Disabled
- **デフォルト**: Disabled
- **4号機の現在値**: Disabled
- **解説**: POST ウォッチドッグタイマー。POST が一定時間内に完了しない場合にシステムをリセットする。POST 92 スタック時に自動回復できるが、正常な長い POST でも誤動作する可能性がある
- **PVE 推奨**: Disabled (4号機の POST 92 スタック問題があるため、有効化する場合はタイムアウト値を十分に長く設定すること)
- **リスク**: Moderate

##### Restore on AC Power Loss
- **オプション**: Stay Off / Power On / Last State
- **デフォルト**: Last State
- **4号機の現在値**: Last State
- **解説**: AC 電源復帰時の動作。Stay Off は電源オフ維持、Power On は自動起動、Last State は電源喪失前の状態を復元する
- **PVE 推奨**: Last State (停電復帰後に自動的に前の状態に復帰)
- **リスク**: Safe

##### Power Button Function
- **オプション**: Instant Off / 4 Seconds Override
- **デフォルト**: Instant Off
- **4号機の現在値**: Instant Off
- **解説**: 電源ボタンの動作。Instant Off は即座にパワーオフ。4 Seconds Override は4秒長押しでパワーオフ (誤操作防止)
- **PVE 推奨**: Instant Off (IPMI 経由の操作には影響しない)
- **リスク**: Safe

##### Throttle on Power Fail
- **オプション**: Disabled / Enabled
- **デフォルト**: Disabled
- **4号機の現在値**: Disabled
- **解説**: 電源冗長性喪失時にCPUスロットリングを行い消費電力を抑制する。冗長電源構成でない場合は無関係
- **PVE 推奨**: Disabled (非冗長電源構成のため)
- **リスク**: Safe

##### Allow In-band BIOS Updates
- **オプション**: Enabled / Disabled
- **デフォルト**: Enabled
- **4号機の現在値**: Enabled
- **解説**: OS 上からの BIOS フラッシュ更新を許可する。Disabled にすると BIOS ファイルの書き換えが BIOS Setup 内からのみに制限される
- **PVE 推奨**: Enabled (リモート BIOS 更新が可能)
- **リスク**: Moderate (有効にすると悪意あるソフトウェアから BIOS を書き換えられるリスクがある。ラボ環境では問題ない)

---

### 2. CPU Configuration

CPU の機能設定。4号機は Intel Xeon Gold 6130 x2 (16C/32T, 2.10GHz, L3 22MB) を搭載。

#### Hyper-Threading (ALL)
- **オプション**: Enable / Disable
- **デフォルト**: Enable
- **4号機の現在値**: Enable
- **解説**: Intel Hyper-Threading Technology。1物理コアあたり2論理スレッドを提供する。仮想化環境では vCPU リソースが倍増するため有効が推奨。ただし HPC やレイテンシクリティカルなワークロードでは無効が有利な場合もある
- **PVE 推奨**: Enable (VM の vCPU キャパシティが倍増)
- **リスク**: Safe

#### Cores Enabled
- **オプション**: 0 (全コア) / 1～最大コア数
- **デフォルト**: 0 (全コア有効)
- **4号機の現在値**: 0
- **解説**: 有効にするコア数を指定。0 は全コア有効。消費電力削減やライセンス制限対応で使用する。ソフトウェアライセンスがコア数ベースの場合に有用
- **PVE 推奨**: 0 (全コア有効)
- **リスク**: Safe (コア数を減らしても故障しない。パフォーマンスが低下するだけ)

#### Monitor/Mwait
- **オプション**: Enabled / Disabled
- **デフォルト**: Enabled
- **4号機の現在値**: Enabled
- **解説**: CPU の MONITOR/MWAIT 命令を有効にする。C-State (省電力状態) への遷移に使用される。Disabled にすると C1E 以上の C-State が使えなくなり、CPU は常にフルパワーで動作する
- **PVE 推奨**: Enabled (省電力と低レイテンシの自動バランス)
- **リスク**: Safe

#### Execute Disable Bit
- **オプション**: Enabled / Disabled
- **デフォルト**: Enabled
- **4号機の現在値**: Enabled
- **解説**: Intel XD (eXecute Disable) ビット。NX ビットとも呼ばれる。メモリページに「実行不可」属性を設定し、バッファオーバーフロー攻撃を防止する。Linux カーネルおよび KVM が必要とする
- **PVE 推奨**: Enabled (必須。Disabled にすると KVM が動作しない)
- **リスク**: Moderate (Disabled にすると仮想化が動作しなくなる)

#### Intel Virtualization Technology
- **オプション**: Enable / Disable
- **デフォルト**: Enable
- **4号機の現在値**: Enable
- **解説**: Intel VT-x。CPU がハードウェア仮想化をサポートするための拡張命令セット。KVM/QEMU が仮想マシンを実行するために必須
- **PVE 推奨**: Enable (必須。Disable にすると VM が起動しない)
- **リスク**: Moderate (Disable にすると仮想化が使えなくなる)

#### PPIN Control
- **オプション**: Unlock/Enable / Unlock/Disable / Lock/Disable
- **デフォルト**: Unlock/Enable
- **4号機の現在値**: Unlock/Enable
- **解説**: Protected Processor Inventory Number。CPU 固有の識別番号を OS から読み取れるようにする。Intel のハードウェア障害分析やマシンチェック例外 (MCE) のレポートに使用される
- **PVE 推奨**: Unlock/Enable (MCE デバッグに有用)
- **リスク**: Safe

#### Hardware Prefetcher
- **オプション**: Enable / Disable
- **デフォルト**: Enable
- **4号機の現在値**: Enable
- **解説**: CPU のハードウェアプリフェッチャ。メモリアクセスパターンを検出し、必要なデータを事前に L2 キャッシュにロードする。ほとんどのワークロードでパフォーマンスが向上する
- **PVE 推奨**: Enable
- **リスク**: Safe

#### Adjacent Cache Line Prefetch
- **オプション**: Enable / Disable
- **デフォルト**: Enable
- **4号機の現在値**: Enable
- **解説**: 隣接キャッシュラインプリフェッチ。キャッシュミス時に隣接する64バイトのキャッシュラインも同時にフェッチする。シーケンシャルアクセスパターンで効果的。ランダムアクセスが主のワークロードでは無効化で帯域幅を節約できる場合がある
- **PVE 推奨**: Enable
- **リスク**: Safe

#### DCU Streamer Prefetcher
- **オプション**: Enable / Disable
- **デフォルト**: Enable
- **4号機の現在値**: Enable
- **解説**: Data Cache Unit (L1) ストリーマプリフェッチャ。ページ境界を跨がないストリーミングアクセスを検出して L1 キャッシュにプリフェッチする
- **PVE 推奨**: Enable
- **リスク**: Safe

#### DCU IP Prefetcher
- **オプション**: Enable / Disable
- **デフォルト**: Enable
- **4号機の現在値**: Enable
- **解説**: Data Cache Unit IP ベースプリフェッチャ。命令ポインタ (IP) のアクセスパターンを記録し、次のアクセスを予測してプリフェッチする
- **PVE 推奨**: Enable
- **リスク**: Safe

#### LLC Prefetch
- **オプション**: Enable / Disable
- **デフォルト**: Disable
- **4号機の現在値**: Disable
- **解説**: Last Level Cache (L3) プリフェッチ。L3 キャッシュにデータを積極的にプリフェッチする。帯域幅集約型ワークロードではキャッシュ汚染を引き起こす可能性があるためデフォルト無効
- **PVE 推奨**: Disable (デフォルトのまま)
- **リスク**: Safe

---

### 3. Chipset Configuration

チップセット (Intel C621/C622 PCH) の設定。North Bridge と South Bridge の2つのサブサブメニューを持つ。

#### North Bridge

##### Intel VT-d
- **オプション**: Enabled / Disabled
- **デフォルト**: Enabled
- **4号機の現在値**: Enabled
- **解説**: Intel Virtualization Technology for Directed I/O。IOMMU (I/O Memory Management Unit) を有効にし、デバイスの DMA をハードウェアレベルで分離する。PCI パススルーや VFIO に必須
- **PVE 推奨**: Enabled (必須。PCI パススルー、SR-IOV、VFIO に必要。カーネルパラメータ `intel_iommu=on` も必要)
- **リスク**: Moderate (Disabled にすると PCI パススルーが使えなくなる)

##### IIO Configuration

###### PCIe Port Bifurcation
- **オプション**: Auto / x4x4x4x4 / x4x4x8 / x8x4x4 / x8x8 / x16
- **デフォルト**: Auto
- **解説**: PCIe スロットのレーン分割。x16 スロットを複数の低幅スロットに分割する。例えば x4x4x4x4 は1つの x16 スロットを4つの x4 として使用。NVMe アダプタカード (Quad M.2 等) で複数の NVMe SSD を個別認識させるのに使用
- **PVE 推奨**: Auto (特殊なアダプタカードを使わない限りデフォルト)
- **リスク**: Moderate (誤設定するとPCIeデバイスが認識されなくなる)

##### Memory Configuration

###### Memory Frequency
- **オプション**: Auto / 1866 / 2133 / 2400 / 2666
- **デフォルト**: Auto
- **解説**: DDR4 メモリの動作周波数。Auto は DIMM の SPD に従う。手動で下げるとメモリ帯域幅が低下する
- **PVE 推奨**: Auto
- **リスク**: High (誤った周波数を設定するとメモリエラーや起動失敗の原因になる)

###### Memory RAS Configuration
- **解説**: ECC、メモリミラーリング、Patrol Scrub 等のメモリ信頼性設定。サーバグレードのメモリ保護機能

###### Patrol Scrub
- **オプション**: Enabled / Disabled
- **デフォルト**: Enabled
- **解説**: バックグラウンドで定期的にメモリ全域を読み出し、ECC で訂正可能なエラーを事前に修復する。メモリ信頼性を向上させるが、わずかなメモリ帯域幅を消費する
- **PVE 推奨**: Enabled (ECC メモリの信頼性向上)
- **リスク**: Safe

#### South Bridge

##### USB Configuration
- **解説**: USB コントローラ、USB ポートの有効/無効、レガシー USB サポート等。通常はデフォルトで問題ない
- **PVE 推奨**: デフォルト
- **リスク**: Safe

---

### 4. Server ME Information

Intel Management Engine の情報表示。すべて読み取り専用。

| 項目 | 4号機の値 |
|------|----------|
| ME FW Version | 4.1.5.2 |
| ME FW Status | Operational |
| Error Code | No Error |

---

### 5. PCH SATA Configuration

PCH (Platform Controller Hub) の SATA コントローラ設定。

#### SATA Controller
- **オプション**: Enable / Disable
- **デフォルト**: Enable
- **4号機の現在値**: Enable
- **解説**: PCH 内蔵 SATA コントローラの有効/無効。Disable にすると接続された SATA デバイスがすべて認識されなくなる
- **PVE 推奨**: Enable
- **リスク**: High (Disable にするとストレージデバイスが見えなくなり起動不能になる可能性がある)

#### Configure SATA as
- **オプション**: AHCI / RAID
- **デフォルト**: AHCI
- **4号機の現在値**: AHCI
- **解説**: SATA コントローラの動作モード。AHCI は各ドライブを個別に OS に見せる標準モード。RAID は Intel VROC/RSTe でソフトウェア RAID を構成する場合に使用
- **PVE 推奨**: AHCI (PVE/Linux は mdadm や ZFS を使うため、BIOS RAID は不要)
- **リスク**: High (モード変更後は OS が既存ドライブを認識できなくなる可能性がある。変更する場合は OS 再インストールを想定すること)

#### SATA HDD Unlock
- **オプション**: Enabled / Disabled
- **デフォルト**: Enabled
- **解説**: SATA パスワードでロックされたドライブの自動アンロック
- **PVE 推奨**: Enabled
- **リスク**: Safe

#### Port 0-7 (個別ポート設定)

##### Hot Plug
- **オプション**: Enabled / Disabled
- **デフォルト**: Disabled
- **4号機の現在値**: Disabled
- **解説**: SATA ポートのホットプラグ (活線挿抜) サポート。Enabled にするとドライブの活線挿抜が可能になる。ホットスワップベイを使用する場合に有効化する
- **PVE 推奨**: ホットスワップ対応ベイのポートのみ Enabled
- **リスク**: Safe

##### Spin Up Device
- **オプション**: Enabled / Disabled
- **デフォルト**: Disabled
- **4号機の現在値**: Disabled
- **解説**: Staggered Spin Up。SATA ドライブの回転開始を順次行い、起動時の突入電流を抑制する。多数の HDD を搭載する場合に電源負荷を分散する
- **PVE 推奨**: Disabled (4台程度では不要)
- **リスク**: Safe

##### SATA Device Type
- **オプション**: Hard Disk Drive / Solid State Drive
- **デフォルト**: Hard Disk Drive
- **解説**: デバイスタイプのヒント。SSD 接続時にアクセスパターンを最適化する
- **PVE 推奨**: 接続デバイスに合わせて設定
- **リスク**: Safe

#### 接続デバイス情報 (4号機)

| ポート | デバイス |
|--------|---------|
| Port 0 | ST3500418AS (Seagate 500GB) |
| Port 1 | SAMSUNG HD502HJ (Samsung 500GB) |
| Port 2 | ST500DM002-1BD142 (Seagate 500GB) |
| Port 3 | WDC WD5000AAKS-402AA (WD 500GB) |

---

### 6. PCH eSATA Configuration

PCH の sSATA (secondary SATA) コントローラ設定。構造は PCH SATA Configuration と同じ。

#### sSATA Controller
- **オプション**: Enable / Disable
- **デフォルト**: Enable
- **4号機の現在値**: Enable
- **解説**: セカンダリ SATA コントローラ。追加の SATA ポートを提供する。4号機ではすべて未接続 (Not Installed)
- **PVE 推奨**: Enable (未接続でも有効のままで問題ない)
- **リスク**: High (接続デバイスがある場合、Disable で認識不能になる)

---

### 7. PCIe/PCI/PnP Configuration

PCI Express と PCI デバイスの設定。PCI パススルーや SR-IOV に重要。

#### Above 4G Decoding
- **オプション**: Enabled / Disabled
- **デフォルト**: Enabled
- **4号機の現在値**: Enabled
- **解説**: 4GB 以上のメモリアドレス空間を PCIe デバイスの BAR (Base Address Register) に割り当てることを許可する。大量の MMIO リソースを必要とする GPU や NVMe デバイスに必須。UEFI ブート時に特に重要
- **PVE 推奨**: Enabled (必須。GPU パススルーや多数の NVMe デバイス使用時に必要)
- **リスク**: Moderate (Disabled にすると大容量 BAR を持つデバイスが正しく初期化されない)

#### SR-IOV Support
- **オプション**: Enabled / Disabled
- **デフォルト**: Disabled
- **4号機の現在値**: Disabled
- **解説**: Single Root I/O Virtualization。1つの物理 PCIe デバイス (NIC 等) を複数の仮想デバイス (VF: Virtual Function) に分割し、各 VM に直接割り当てる。ネットワーク仮想化のオーバーヘッドを大幅に削減する
- **PVE 推奨**: 必要に応じて Enabled (NIC の SR-IOV パススルーを使用する場合)。VT-d も同時に有効にすること
- **リスク**: Moderate (有効化後にドライバの再設定が必要な場合がある)

#### ARI Support
- **オプション**: Enabled / Disabled
- **デフォルト**: Disabled
- **4号機の現在値**: Disabled
- **解説**: Alternative Routing-ID Interpretation。PCIe の Function 番号を8ビットから拡張し、256 Virtual Function をサポートする。SR-IOV と組み合わせて使用する
- **PVE 推奨**: SR-IOV を使用する場合は Enabled
- **リスク**: Safe

#### MMIO High Base
- **オプション**: 56T / 40T / 24T / 16T / 4T / 2T / 1T / 512G / 256G
- **デフォルト**: 56T
- **解説**: MMIO (Memory-Mapped I/O) 空間の上位ベースアドレス。大量の PCIe デバイスや大容量 BAR を持つデバイスがある場合に調整する
- **PVE 推奨**: デフォルト (56T)
- **リスク**: High (変更するとデバイス認識に問題が発生する可能性がある)

#### MMIO High Granularity Size
- **オプション**: 1G / 4G / 16G / 64G / 256G / 1024G
- **デフォルト**: 256G
- **4号機の現在値**: 256G
- **解説**: MMIO 空間の割り当て単位サイズ
- **PVE 推奨**: 256G (デフォルト)
- **リスク**: High

#### Maximum Read Request
- **オプション**: Auto / 128B / 256B / 512B / 1024B / 2048B / 4096B
- **デフォルト**: Auto
- **解説**: PCIe デバイスの Maximum Read Request Size。大きい値ほどスループットが向上するが、レイテンシが増加する場合がある
- **PVE 推奨**: Auto
- **リスク**: Safe

#### VGA Priority
- **オプション**: Onboard / Offboard
- **デフォルト**: Onboard
- **4号機の現在値**: Onboard
- **解説**: 複数の VGA デバイスがある場合の優先順位。Onboard は BMC (ASPEED AST2500) の統合 VGA を使用する。外付け GPU を主画面にする場合は Offboard
- **PVE 推奨**: Onboard (BMC の KVM/IPMI コンソールで使用するため)
- **リスク**: Safe

#### NVMe Firmware Source
- **オプション**: Vendor Defined Firmware / AMI Native Support
- **デフォルト**: Vendor Defined Firmware
- **解説**: NVMe デバイスのファームウェアソース。Vendor Defined は NVMe デバイス内蔵のファームウェア、AMI Native は BIOS に内蔵された汎用 NVMe ドライバを使用する
- **PVE 推奨**: Vendor Defined Firmware
- **リスク**: Safe

#### Onboard LAN Device / Option ROM

##### Onboard LAN1 Enable
- **オプション**: Enabled / Disabled
- **デフォルト**: Enabled
- **解説**: オンボード NIC の有効/無効
- **PVE 推奨**: Enabled
- **リスク**: Moderate (Disabled にするとネットワーク接続が失われる)

##### Onboard LAN1 Option ROM
- **オプション**: Disabled / Legacy / EFI
- **デフォルト**: Legacy
- **解説**: NIC の Option ROM (PXE ブート等)。Legacy は Legacy BIOS 用、EFI は UEFI 用の PXE ブートを提供する。ネットワークブートが不要なら Disabled で POST 時間が短縮される
- **PVE 推奨**: Disabled (PXE ブートが不要な場合。POST 時間短縮の効果あり)
- **リスク**: Safe (PXE ブートが不要な場合)

#### NVMe1 OPROM
- **オプション**: Disabled / EFI
- **デフォルト**: EFI
- **4号機の現在値**: EFI
- **解説**: NVMe デバイスの Option ROM。EFI を選択すると NVMe から UEFI ブートが可能になる
- **PVE 推奨**: EFI (NVMe ブートを使用する場合)
- **リスク**: Safe

#### PCIe スロット情報 (4号機)

| スロット | デバイス |
|---------|---------|
| Slot 1-4 | RSC-R1UW-2E16 (ライザーカード) |
| AOC | AOC-UR-i4XTF (Intel X550-T4 10GbE) |

---

### 8. Super IO Configuration

Super I/O チップ (ASPEED AST2500) の設定。

#### Super IO Chip
- **値**: AST2500 (読み取り専用)
- **解説**: BMC 兼 Super I/O チップ。シリアルポート、PS/2 等のレガシー I/O を管理する

#### Serial Port 1 Configuration
- **オプション**: Enabled / Disabled
- **デフォルト**: Enabled
- **解説**: 物理シリアルポート (COM1) の有効/無効と I/O アドレス、IRQ の設定
- **PVE 推奨**: Enabled (SOL と併用する場合は Serial Port Console Redirection で設定)
- **リスク**: Safe

#### Serial Port 2 Configuration
- **オプション**: Enabled / Disabled
- **デフォルト**: Enabled
- **解説**: 2番目のシリアルポート (COM2) の設定
- **PVE 推奨**: Enabled
- **リスク**: Safe

---

### 9. Serial Port Console Redirection

シリアルコンソールリダイレクション設定。IPMI SOL (Serial over LAN) やシリアルポート経由の BIOS コンソールを制御する。

#### COM1 Console Redirection
- **オプション**: Enabled / Disabled
- **デフォルト**: Disabled
- **4号機の現在値**: Disabled
- **解説**: 物理 COM1 ポートへの BIOS コンソール出力リダイレクト。物理シリアルケーブルで接続して BIOS 操作を行う場合に有効化する
- **PVE 推奨**: Disabled (KVM 経由で操作するため不要)
- **リスク**: Safe

#### SOL Console Redirection
- **オプション**: Enabled / Disabled
- **デフォルト**: Enabled
- **4号機の現在値**: Enabled
- **解説**: Serial over LAN (SOL) コンソールリダイレクト。IPMI の SOL 機能で BIOS/OS のシリアルコンソール出力をネットワーク経由で表示する。`ipmitool sol activate` で接続する
- **PVE 推奨**: Enabled (リモートシリアルコンソールに必要)
- **リスク**: Safe

#### SOL Console Redirection Settings (サブセクション)

##### Terminal Type
- **オプション**: VT100 / VT100+ / VT-UTF8 / ANSI
- **デフォルト**: VT100+
- **解説**: SOL 出力のターミナルタイプ。VT100 は基本的なエスケープシーケンス、VT100+ は拡張版、VT-UTF8 は UTF-8 文字対応、ANSI は ANSI カラー対応
- **PVE 推奨**: VT-UTF8 (UTF-8 端末との互換性)
- **リスク**: Safe

##### Bits per second
- **オプション**: 9600 / 19200 / 38400 / 57600 / 115200
- **デフォルト**: 115200
- **解説**: SOL のボーレート。高い値ほどデータ転送が速い。OS 側の serial console 設定 (`console=ttyS1,115200n8`) と一致させる必要がある
- **PVE 推奨**: 115200
- **リスク**: Safe (ただし OS 側の設定と不一致だと文字化けする)

##### Flow Control
- **オプション**: None / Hardware RTS/CTS
- **デフォルト**: None
- **解説**: シリアルフロー制御。ハードウェアフロー制御は物理シリアル接続で使用する。SOL では None で問題ない
- **PVE 推奨**: None
- **リスク**: Safe

#### Legacy Serial Redirection Port
- **オプション**: COM1 / SOL
- **デフォルト**: COM1
- **4号機の現在値**: COM1
- **解説**: レガシー (非 UEFI) のシリアルリダイレクション先ポート
- **PVE 推奨**: COM1
- **リスク**: Safe

#### EMS (Emergency Management Services)
- **オプション**: Enabled / Disabled
- **デフォルト**: Disabled
- **4号機の現在値**: Disabled
- **解説**: Windows EMS/SAC (Special Administration Console) 機能。Linux では使用しない
- **PVE 推奨**: Disabled
- **リスク**: Safe

---

### 10. ACPI Settings

ACPI (Advanced Configuration and Power Interface) 設定。

#### NUMA
- **オプション**: Enabled / Disabled
- **デフォルト**: Enabled
- **4号機の現在値**: Enabled
- **解説**: Non-Uniform Memory Access。マルチソケットシステムで各 CPU がローカルメモリに高速アクセスできるようにメモリトポロジを OS に通知する。Linux カーネルは NUMA トポロジに基づいてメモリ割り当てとスケジューリングを最適化する。Dual Socket 構成では必須
- **PVE 推奨**: Enabled (必須。Dual Socket 構成でのメモリアクセス最適化に不可欠)
- **リスク**: Moderate (Disabled にするとメモリパフォーマンスが大幅に低下する)

#### WHEA Support
- **オプション**: Enabled / Disabled
- **デフォルト**: Enabled
- **4号機の現在値**: Enabled
- **解説**: Windows Hardware Error Architecture。ハードウェアエラー (MCE, PCIe AER 等) を OS に報告する ACPI テーブル (HEST, BERT, EINJ 等) を提供する。Linux でも `mcelog` や `rasdaemon` がこれらのテーブルを使用してハードウェアエラーを記録する
- **PVE 推奨**: Enabled
- **リスク**: Safe

#### High Precision Event Timer
- **オプション**: Enabled / Disabled
- **デフォルト**: Enabled
- **4号機の現在値**: Enabled
- **解説**: HPET (High Precision Event Timer)。高精度タイマーハードウェア。TSC (Time Stamp Counter) が利用できない環境でのタイマーソースとして使用される。最近の Linux カーネルでは TSC が優先されるため、HPET の有無はパフォーマンスに大きく影響しない
- **PVE 推奨**: Enabled
- **リスク**: Safe

---

### 11. Trusted Computing

TPM (Trusted Platform Module) と TxT (Trusted Execution Technology) の設定。

#### Security Device Support
- **オプション**: Enable / Disable
- **デフォルト**: Enable
- **4号機の現在値**: Enable
- **解説**: TPM デバイスの有効化。TPM は暗号鍵の安全な保管、セキュアブート、ディスク暗号化 (LUKS) のキー保護等に使用される
- **PVE 推奨**: Enable (Secure Boot やディスク暗号化を使用する場合)
- **リスク**: Moderate (Disable にすると TPM に保存された鍵にアクセスできなくなる)

#### SHA-1 PCR Bank / SHA256 PCR Bank
- **オプション**: Enabled / Disabled
- **デフォルト**: Enabled (両方)
- **解説**: TPM の PCR (Platform Configuration Register) で使用するハッシュアルゴリズム。SHA-256 が推奨される
- **PVE 推奨**: SHA256 Enabled
- **リスク**: Safe

#### Pending operation
- **オプション**: None / TPM Clear
- **デフォルト**: None
- **解説**: 次回起動時に実行する TPM 操作。TPM Clear はすべての TPM データを消去する
- **PVE 推奨**: None
- **リスク**: Critical (TPM Clear を実行すると暗号鍵が失われ、暗号化データにアクセスできなくなる)

#### Platform Hierarchy / Storage Hierarchy / Endorsement Hierarchy
- **オプション**: Enabled / Disabled
- **デフォルト**: Enabled (すべて)
- **解説**: TPM 2.0 の階層 (Hierarchy) 制御。Platform は BIOS 用、Storage はデータ保護用、Endorsement は認証用
- **PVE 推奨**: Enabled (すべて)
- **リスク**: Moderate

#### TPM State (読み取り専用情報)

| 項目 | 4号機の値 |
|------|----------|
| TPM State | Enabled |
| TPM Active | Activated |
| TPM Owner | Owned |

#### Intel TXT Support
- **オプション**: Enabled / Disabled
- **デフォルト**: Disabled
- **4号機の現在値**: Disabled
- **解説**: Intel Trusted Execution Technology。CPU とチップセットの機能を使い、起動チェーンの完全性を検証する (Measured Launch)。VT-x と VT-d が有効である必要がある。一般的なサーバ運用ではほとんど使用されない
- **PVE 推奨**: Disabled (特別な要件がない限り不要)
- **リスク**: Moderate (有効化するとブートプロセスが変わり、互換性の問題が発生する可能性がある)

---

### 12. HTTP BOOT Configuration

HTTP/HTTPS ネットワークブート設定。

#### HTTP Boot One Time
- **オプション**: Enabled / Disabled
- **デフォルト**: Disabled
- **4号機の現在値**: Disabled
- **解説**: HTTP 経由のネットワークブート。URL を指定して ISO やカーネルをダウンロードしてブートする。PXE の代替手段
- **PVE 推奨**: Disabled (PXE または VirtualMedia を使用するため不要)
- **リスク**: Safe

---

### 13. Supermicro KMS Server Configuration

Key Management Server (KMS) 設定。TCG Opal 準拠の自己暗号化ドライブ (SED) の鍵管理に使用する。

#### 主な設定項目

| 設定 | デフォルト | 4号機の現在値 |
|------|----------|-------------|
| KMS Server IP | (空) | (空) |
| TCP Port | 5696 | 5696 |
| Timeout | 5 | 5 |
| Retry Count | 2 | 2 |
| TimeZone | 0 | 0 |
| TCG NVMe KMS Policy | Do Nothing | Do Nothing |

- **PVE 推奨**: デフォルトのまま (SED を使用しない場合)
- **リスク**: Safe (変更しない場合)

---

### 14. TLS Authenticate Configuration

TLS 証明書の管理。HTTPS ブートや KMS の TLS 認証で使用する CA 証明書の登録・削除を行う。

#### Server CA Configuration
- **解説**: 信頼する CA 証明書の管理サブメニュー。HTTPS ブートや KMS サーバへの接続に使用する CA 証明書を登録する
- **PVE 推奨**: デフォルトのまま
- **リスク**: Safe

---

### 15. iSCSI Configuration

iSCSI イニシエータ設定。iSCSI ブートに使用する。

#### iSCSI Initiator Name
- **解説**: iSCSI Qualified Name (IQN)。`iqn.yyyy-mm.com.domain:uniqueid` 形式
- **PVE 推奨**: iSCSI ブートを使用する場合のみ設定
- **リスク**: Safe

#### Add an Attempt / Delete Attempts / Change Attempt Order
- **解説**: iSCSI ターゲットへの接続試行の管理。ターゲット IP、ポート、LUN、認証情報等を設定する
- **PVE 推奨**: 設定不要 (iSCSI ブートを使用しない場合)
- **リスク**: Safe

---

### 16. Driver Health

ドライバの状態表示。すべて読み取り専用。

| ドライバ | 4号機の状態 |
|---------|-----------|
| Intel VROC 8.0.0.4006 VMD | Healthy |
| Intel DCPMM 1.0.0.3536 | Healthy |

---

## Event Logs タブ

### Change SMBIOS Event Log Settings

#### SMBIOS Event Log
- **オプション**: Enabled / Disabled
- **デフォルト**: Enabled
- **4号機の現在値**: Enabled
- **解説**: SMBIOS 仕様に基づくイベントログの記録。ハードウェアイベント (メモリエラー、POST エラー等) を記録する
- **PVE 推奨**: Enabled
- **リスク**: Safe

#### Erase Event Log
- **オプション**: No / Yes, Next reset / Yes, Every reset
- **デフォルト**: No
- **4号機の現在値**: No
- **解説**: イベントログの消去。Yes, Next reset は次回リセット時に消去、Yes, Every reset は毎回リセット時に消去
- **PVE 推奨**: No (ログは保持。容量に問題がある場合のみ消去)
- **リスク**: Moderate (ログ消去は不可逆)

#### When Log is Full
- **オプション**: Do Nothing / Erase Immediately
- **デフォルト**: Do Nothing
- **4号機の現在値**: Do Nothing
- **解説**: ログが満杯になった場合の動作。Do Nothing はログ記録を停止、Erase Immediately は即座に消去して記録を続行
- **PVE 推奨**: Do Nothing (重要なログが消えないように)
- **リスク**: Safe

#### Log System Boot Event
- **オプション**: Enabled / Disabled
- **デフォルト**: Disabled
- **4号機の現在値**: Disabled
- **解説**: システム起動イベントをログに記録するかどうか
- **PVE 推奨**: Disabled (ログ容量の節約)
- **リスク**: Safe

### View SMBIOS Event Log

イベントログの表示。日付、エラーコード、重要度が一覧表示される。読み取り専用。

---

## IPMI タブ

BMC (Baseboard Management Controller) 関連の設定。

### 読み取り専用情報

| 項目 | 4号機の値 |
|------|----------|
| BMC Firmware Revision | 01.73.06 |
| IPMI STATUS | Working |

### System Event Log

#### SEL Components
- **オプション**: Enabled / Disabled
- **デフォルト**: Enabled
- **4号機の現在値**: Enabled
- **解説**: IPMI System Event Log の有効/無効。BMC がハードウェアイベント (温度、電圧、ファン、電源等) を記録する
- **PVE 推奨**: Enabled
- **リスク**: Safe

#### Erase SEL
- **オプション**: No / Yes, On next reset / Yes, On every reset
- **デフォルト**: No
- **4号機の現在値**: No
- **解説**: SEL の消去。ipmitool sel clear と同等
- **PVE 推奨**: No
- **リスク**: Moderate (ログ消去は不可逆)

#### When SEL is Full
- **オプション**: Do Nothing / Erase Immediately
- **デフォルト**: Do Nothing
- **4号機の現在値**: Do Nothing
- **解説**: SEL が満杯時の動作
- **PVE 推奨**: Do Nothing
- **リスク**: Safe

### BMC Network Configuration

#### Update IPMI LAN Configuration
- **オプション**: No / Yes
- **デフォルト**: No
- **4号機の現在値**: No
- **解説**: BIOS から BMC のネットワーク設定を変更するかどうか。Yes にすると以下の設定が BMC に適用される
- **PVE 推奨**: No (BMC のネットワーク設定は ipmitool や BMC Web UI から行う)
- **リスク**: High (誤設定すると BMC へのリモートアクセスが失われる)

#### IPMI LAN Selection
- **オプション**: Dedicated / Shared / Failover
- **デフォルト**: Dedicated
- **4号機の現在値**: Dedicated
- **解説**: BMC ネットワークポートの選択。Dedicated は BMC 専用ポート、Shared は管理ネットワークと共有、Failover は専用→共有の自動切替
- **PVE 推奨**: Dedicated
- **リスク**: Moderate

#### Address Source
- **オプション**: Static / DHCP
- **4号機の現在値**: Static
- **解説**: BMC の IP アドレス取得方法
- **PVE 推奨**: Static

#### Station IP Address
- **4号機の現在値**: 010.010.010.024
- **解説**: BMC の静的 IP アドレス

---

## Security タブ

パスワードとセキュリティ設定。

#### Administrator Password
- **4号機の現在値**: Not Installed
- **解説**: BIOS Setup に入る際のパスワード。設定すると BIOS Setup へのアクセスにパスワードが必要になる
- **PVE 推奨**: 設定しない (ラボ環境。本番環境では設定すること)
- **リスク**: Moderate (パスワードを忘れると CMOS クリアが必要)

#### User Password
- **4号機の現在値**: Not Installed
- **解説**: 制限付きアクセス用パスワード。設定すると一部の設定のみ変更可能
- **PVE 推奨**: 設定しない (ラボ環境)
- **リスク**: Safe

#### Password Check
- **オプション**: Setup / Always
- **デフォルト**: Setup
- **4号機の現在値**: Setup
- **解説**: パスワード入力を求めるタイミング。Setup は BIOS Setup 進入時のみ、Always は起動時にも入力を求める
- **PVE 推奨**: Setup (Always にするとリモートリブート後に OS が起動しなくなる)
- **リスク**: High (Always に設定してパスワードをかけると、リモートからの起動が不可能になる)

#### Secure Boot

##### Secure Boot
- **オプション**: Enabled / Disabled
- **デフォルト**: Disabled
- **解説**: UEFI Secure Boot。署名されたブートローダとカーネルのみ起動を許可する。UEFI モードでのみ有効
- **PVE 推奨**: Disabled (PVE のデフォルト。有効化する場合は MOK の登録が必要)
- **リスク**: Moderate (有効化すると署名されていないブートローダ・カーネルモジュールが読み込めなくなる)

##### Secure Boot Mode
- **オプション**: Standard / Custom
- **デフォルト**: Standard
- **解説**: Standard は Microsoft の標準鍵を使用。Custom では PK (Platform Key)、KEK、db、dbx を手動管理できる
- **PVE 推奨**: Standard (有効化する場合)
- **リスク**: Moderate

#### Supermicro Security Erase Configuration
- **解説**: ストレージデバイスのセキュリティ消去。ATA Secure Erase や TCG Opal に対応したデバイスのデータ消去を BIOS から実行する
- **PVE 推奨**: 必要時のみ使用
- **リスク**: Critical (データが完全に消去され復旧不可能)

---

## Boot タブ

ブートモードとブートオーダーの設定。

#### Boot Mode Select
- **オプション**: DUAL / Legacy / UEFI
- **デフォルト**: DUAL
- **4号機の現在値**: DUAL
- **解説**: ブートモード選択。DUAL は Legacy と UEFI の両方のブートデバイスを表示、Legacy は Legacy のみ、UEFI は UEFI のみ
- **PVE 推奨**: UEFI (PVE 9 は UEFI ブート推奨)
- **リスク**: Moderate (モード変更後に既存の OS が起動しなくなる場合がある)

#### LEGACY to EFI support
- **オプション**: Enabled / Disabled
- **デフォルト**: Disabled
- **4号機の現在値**: Disabled
- **解説**: Legacy ブートに失敗した場合に UEFI ブートにフォールバックする
- **PVE 推奨**: Disabled
- **リスク**: Safe

#### FIXED BOOT ORDER Priorities

ブートデバイスの優先順位 (4号機の現在値)。**DUAL モードでは 17 個の Boot Option** がある（初期画面では #15 までしか見えないが、スクロールで #16, #17 が出現する）:

| 順位 | デバイス |
|------|---------|
| Boot Option #1 | UEFI Hard Disk:debian |
| Boot Option #2 | CD/DVD |
| Boot Option #3 | UEFI USB CD/DVD |
| Boot Option #4 | USB CD/DVD |
| Boot Option #5 | Network:IBA 40-10G Slot 1800 v1060 |
| Boot Option #6 | USB Key |
| Boot Option #7 | Hard Disk: ST3500418AS |
| Boot Option #8 | UEFI AP:UEFI: Built-in EFI Shell |
| Boot Option #9 | USB Hard Disk |
| Boot Option #10 | USB Floppy |
| Boot Option #11 | USB Lan |
| Boot Option #12 | UEFI CD/DVD |
| Boot Option #13 | UEFI USB Hard Disk |
| Boot Option #14 | UEFI USB Key |
| Boot Option #15 | UEFI USB Floppy |
| Boot Option #16 | UEFI USB Lan |
| Boot Option #17 | UEFI USB Floppy |

Boot Option 下部にはサブメニューがある:
- **► Add New Boot Option** — EFI ブートオプション追加
- **► Delete Boot Option** — EFI ブートオプション削除
- **► UEFI Hard Disk Drive BBS Priorities** — debian (NVMe) の優先順位
- **► UEFI Application Boot Priorities** — UEFI: Built-in EFI Shell
- **► Hard Disk Drive BBS Priorities** — SATA 4台 (Port 0-3) の優先順位
- **► Network Drive BBS Priorities** — IBA 40-10G + FlexBoot v3.4.746

- **PVE 推奨**: UEFI Hard Disk:debian を #1 に設定。efibootmgr (`efibootmgr -o 0004`) も併用すると BIOS Boot Order に関わらず OS 起動が保証される
- **リスク**: Safe (ブート順序の変更は非破壊的)。ただし Boot mode select を変更すると Boot Option 数とレイアウトが変わるため注意

---

## Save & Exit タブ

設定の保存・復元・ブートオーバーライド。

#### Save Options

| 項目 | 動作 | リスク |
|------|------|--------|
| **Discard Changes and Exit** | 変更を破棄して終了 (再起動) | Safe |
| **Save Changes and Reset** | 変更を保存して再起動 | Safe |
| **Save Changes** | 変更を保存 (BIOS Setup に留まる) | Safe |
| **Discard Changes** | 変更を破棄 (BIOS Setup に留まる) | Safe |

#### Default Options

| 項目 | 動作 | リスク |
|------|------|--------|
| **Restore Optimized Defaults** | すべての設定を出荷時デフォルトに戻す | High (VT-x, VT-d 等の重要設定もリセットされる) |
| **Save as User Defaults** | 現在の設定をユーザデフォルトとして保存 | Safe |
| **Restore User Defaults** | ユーザデフォルトに戻す | Moderate |

#### Boot Override

Boot Order を変更せず、次回起動時のみ特定デバイスからブートする。一回限りの起動デバイス選択。

4号機のブートオーバーライドデバイス:

| デバイス |
|---------|
| IBA 40-10G Slot 1800 v1060 |
| ISATA: P1: ST3500418AS |
| ISATA: P1: SAMSUNG HD502HJ |
| ISATA: P2: ST500DM002-1BD142 |
| ISATA: P3: ADC WD5000AAKS-402AA |
| UEFI: Built-in EFI Shell |
| debian (BC711 NVMe SK hynix 128GB) |
| Launch EFI Shell from filesystem device |

- **PVE 推奨**: OS インストール時やリカバリ時に使用
- **リスク**: Safe (一回限りの変更)

---

## PVE 推奨設定サマリー

PVE (Proxmox VE) 環境で推奨される設定の一覧。デフォルトから変更が必要な項目は **太字** で表示。

| カテゴリ | 設定 | 推奨値 | デフォルト | 理由 |
|---------|------|--------|----------|------|
| CPU | Hyper-Threading | Enable | Enable | vCPU キャパシティ倍増 |
| CPU | Intel Virtualization | Enable | Enable | KVM 必須 |
| CPU | Execute Disable Bit | Enabled | Enabled | KVM 必須 |
| Chipset | Intel VT-d | Enabled | Enabled | PCI パススルー必須 |
| ACPI | NUMA | Enabled | Enabled | Dual Socket メモリ最適化 |
| PCIe | Above 4G Decoding | Enabled | Enabled | GPU/NVMe パススルー |
| PCIe | SR-IOV | 要件に応じて | Disabled | NIC パススルー時に有効化 |
| Serial | SOL Console Redirection | Enabled | Enabled | リモートシリアルコンソール |
| Boot | Boot Mode | **UEFI** | DUAL | PVE 9 推奨 |
| Boot Feature | **Quiet Boot** | **Disabled** | Enabled | POST 情報の視認性 |
| Boot Feature | Restore on AC Power Loss | Last State | Last State | 停電復帰後の自動起動 |

---

## 危険な設定一覧

変更時に特別な注意が必要な設定項目。

| 設定 | リスク | 影響 |
|------|--------|------|
| SATA Controller: Disable | High | ストレージが認識されず起動不能 |
| Configure SATA as: RAID | High | 既存 OS が認識不能 |
| Intel Virtualization: Disable | Moderate | VM が起動しない |
| Intel VT-d: Disabled | Moderate | PCI パススルー不能 |
| Execute Disable Bit: Disabled | Moderate | KVM 動作不能 |
| Password Check: Always + パスワード設定 | High | リモート起動不能 |
| Secure Boot: Enabled | Moderate | 署名なしカーネル/ドライバが読み込めない |
| Restore Optimized Defaults | High | 全設定がリセット |
| TPM Clear (Pending operation) | Critical | 暗号鍵消失 |
| Security Erase | Critical | データ完全消去 |
| Memory Frequency: 手動設定 | High | メモリエラー・起動失敗 |
| PCIe Bifurcation: 誤設定 | Moderate | PCIe デバイス認識不能 |
| BMC Network: Update = Yes + 誤設定 | High | BMC リモートアクセス喪失 |
| NUMA: Disabled | Moderate | メモリパフォーマンス大幅低下 |

---

## カーネルブートパラメータとの対応

BIOS 設定と Linux カーネルブートパラメータの関連。

| BIOS 設定 | カーネルパラメータ | 説明 |
|-----------|-----------------|------|
| Intel VT-d: Enabled | `intel_iommu=on` | IOMMU を有効化。PCI パススルーに必要 |
| Intel VT-d: Enabled | `iommu=pt` | パススルーモード。仮想化環境でのパフォーマンス最適化 |
| SOL: Enabled, 115200 | `console=ttyS1,115200n8` | SOL 経由のシリアルコンソール |
| NUMA: Enabled | (自動認識) | カーネルが SRAT テーブルから NUMA トポロジを取得 |
| HPET: Enabled | `clocksource=tsc` | TSC が優先されるが HPET がフォールバック |
| Execute Disable: Enabled | (自動認識) | NX ビットが有効化される |

---

---

# X10DRT-P (10号機) BIOS 設定リファレンス

## はじめに (X10DRT-P)

本節は Supermicro X10DRT-P-G5-NI22 マザーボード (10号機, Nutanix NX-1065-G5 OEM) の AMI Aptio UEFI BIOS 設定項目を全タブ全サブメニューで網羅した技術リファレンスである。観測時点 (2026-04-30) の実機状態を反映する。

- **対象ハードウェア**: Supermicro X10DRT-P-G5-NI22 (Twin Server 2U, Nutanix NX-1065-G5 OEM)
- **CPU**: Intel Xeon E5-2620 v4 x2 (Broadwell-EP, LGA2011-3, 8C/16T per socket = 16C/32T total, 2.10GHz, L3 20MB)
- **チップセット**: Intel C612 系 (推定)
- **BIOS**: AMI Aptio Setup Utility, Version 2.17.1249
- **BIOS Version**: G4G5T8.0
- **Build Date**: 07/14/2021
- **CPLD Version**: 03.a1.30
- **BMC**: ASPEED 2400, Firmware 3.65 (Supermicro stock)
- **Super IO Chip**: AST2400
- **メモリ**: 65536 MB (64GB), 2133 MHz (DDR4)
- **タブ構成**: X11DPU と同一 (Main / Advanced / Event Logs / IPMI / Security / Boot / Save & Exit の 7 タブ循環)
- **キーバインド**: X11DPU と完全一致 (ArrowKeys / Enter / Esc / +/- / F2-F4 / PageUp/PageDown / Tab)
- **キャンバス解像度**: 800x600 (BIOS Setup), 720x400 (POST)
- **特記**: Nutanix OEM 由来のため、BMC FW 更新は Supermicro 公式 FW では silent reject される。BIOS Setup 操作には影響なし

リスクレベル定義は X11DPU 節と共通 (Safe / Moderate / High / Critical)。

---

## Main タブ (X10DRT-P)

設定可能項目: System Date, System Time のみ。

#### System Date
- **オプション**: MM/DD/YYYY 形式
- **10号機の現在値**: Thu 01/01/2015 (BMC 3.65 リブート由来でリセット済み)
- **解説**: NTP で OS 起動後に上書きされる
- **リスク**: Safe

#### System Time
- **オプション**: HH:MM:SS 形式
- **10号機の現在値**: 10:08:21 (観測時点)
- **解説**: NTP で OS 起動後に上書きされる
- **リスク**: Safe

#### 読み取り専用情報

| 項目 | 10号機の値 |
|------|-----------|
| Supermicro X10DRT-P | (マザーボード型番) |
| BIOS Version | G4G5T8.0 |
| Build Date | 07/14/2021 |
| CPLD Version | 03.a1.30 |
| Total Memory | 65536 MB (64GB) |
| Memory Speed | 2133 MHz |

> **X11DPU との差分**: X11DPU には Memory Speed 表示がない。X10DRT-P には DDR4 動作周波数が直接表示される。

---

## Advanced タブ (X10DRT-P)

サブメニュー一覧 (10 個、X11DPU の 16 より少ない):

1. Boot Feature
2. CPU Configuration
3. Chipset Configuration (► North Bridge / ► South Bridge)
4. SATA Configuration
5. sSATA Configuration
6. Server ME Configuration
7. PCIe/PCI/PnP Configuration
8. Super IO Configuration (► Serial Port 1 / ► Serial Port 2 Configuration)
9. Serial Port Console Redirection
10. ACPI Settings

> **X11DPU にあって X10DRT-P にないサブメニュー (BIOS UI に項目自体が存在しない)**: Trusted Computing, HTTP BOOT Configuration, Supermicro KMS Server Configuration, TLS Authenticate Configuration, iSCSI Configuration, Driver Health (合計 6 個)。これらは X10 世代 (Broadwell-EP) BIOS の機能セット差分であり、TPM 2.0・HTTP Boot・TCG Opal などの新世代機能は本機では BIOS から直接設定できない。

> **サブメニュー名の差分**: X11DPU の `PCH SATA Configuration` → X10DRT-P の `SATA Configuration`、X11DPU の `PCH eSATA Configuration` → X10DRT-P の `sSATA Configuration`、X11DPU の `Server ME Information` → X10DRT-P の `Server ME Configuration`。

### 1. Boot Feature (X10DRT-P)

#### Quiet Boot
- **オプション**: Enabled / Disabled
- **10号機の現在値**: Enabled
- **PVE 推奨**: Disabled (POST 情報の視認性向上)
- **リスク**: Safe

#### AddOn ROM Display Mode
- **オプション**: Force BIOS / Keep Current
- **10号機の現在値**: Force BIOS
- **解説**: Option ROM (NIC, RAID 等) の初期化メッセージ表示方法。X11DPU では同等項目が "Option ROM Messages" という名称
- **PVE 推奨**: Force BIOS
- **リスク**: Safe

#### Bootup NumLock State
- **オプション**: On / Off
- **10号機の現在値**: On

#### Wait For "F1" If Error
- **オプション**: Enabled / Disabled
- **10号機の現在値**: **Disabled** (X11DPU デフォルトは Enabled)
- **解説**: ヘッドレス運用ではこのデフォルトが便利。Disabled でもエラーは IPMI System Event Log に記録される
- **リスク**: Safe

#### INT19 Trap Response
- **オプション**: Immediate / Postponed
- **10号機の現在値**: Immediate

#### Re-try Boot
- **オプション**: Disabled / Legacy Boot / EFI Boot (X11DPU と同様と推定)
- **10号機の現在値**: Disabled
- **PVE 推奨**: EFI Boot (UEFI 切替後)、現状 LEGACY モードでは Legacy Boot
- **リスク**: Safe

#### Power Configuration

##### Watch Dog Function
- **オプション**: Enabled / Disabled
- **10号機の現在値**: Disabled
- **解説**: POST ウォッチドッグタイマー
- **リスク**: Moderate

##### Power Button Function
- **オプション**: Instant Off / 4 Seconds Override
- **10号機の現在値**: Instant Off

##### Restore on AC Power Loss
- **オプション**: Stay Off / Power On / Last State
- **10号機の現在値**: Last State
- **PVE 推奨**: Last State

> **注**: X11DPU には `Throttle on Power Fail` / `Allow In-band BIOS Updates` 項目があるが、X10DRT-P の Boot Feature サブメニュー初期画面には表示されていない (PageDown でさらに項目があるかは未確認)。

### 2. CPU Configuration (X10DRT-P)

#### CPU 情報 (読み取り専用)

| 項目 | CPU1 | CPU2 |
|------|------|------|
| Processor Socket | CPU1 | CPU2 |
| Processor ID | 000406F1* | 000406F1 |
| Processor Frequency | 2.100GHz | 2.100GHz |
| Processor Max Ratio | 15H | 15H |
| Processor Min Ratio | 0CH | 0CH |
| Microcode Revision | 0B00003E | 0B00003E |
| L1 Cache RAM | 512KB | 512KB |
| L2 Cache RAM | 2048KB | 2048KB |
| L3 Cache RAM | 20480KB | 20480KB |
| Version | Intel(R) Xeon(R) CPU E5-2620 v4 @ 2.10GHz | 同左 |

#### Clock Spread Spectrum
- **オプション**: Enabled / Disabled
- **10号機の現在値**: Disabled
- **解説**: クロック広帯域化による EMI 削減。X10DRT-P 固有 (X11DPU には見えない)
- **PVE 推奨**: Disabled
- **リスク**: Safe

#### Hyper-Threading (ALL)
- **オプション**: Enable / Disable
- **10号機の現在値**: Enable
- **PVE 推奨**: Enable

#### Cores Enabled
- **オプション**: 0 (全コア) / 1～8
- **10号機の現在値**: 0
- **PVE 推奨**: 0

#### Monitor/Mwait
- **オプション**: Enable / Disable
- **10号機の現在値**: Enable

#### Execute Disable Bit
- **オプション**: Enable / Disable
- **10号機の現在値**: Enable
- **PVE 推奨**: Enable (KVM 必須)
- **リスク**: Moderate (Disable で KVM 不可)

#### PPIN Control
- **オプション**: Unlock/Enable / Unlock/Disable / Lock/Disable
- **10号機の現在値**: Unlock/Enable

#### Hardware Prefetcher
- **オプション**: Enable / Disable
- **10号機の現在値**: Enable

#### Adjacent Cache Prefetch
- **オプション**: Enable / Disable
- **10号機の現在値**: Enable
- **解説**: X11DPU では "Adjacent Cache Line Prefetch" (名称差)

#### DCU Streamer Prefetcher
- **オプション**: Enable / Disable
- **10号機の現在値**: Enable

> **注**: X11DPU の `Intel Virtualization Technology`, `DCU IP Prefetcher`, `LLC Prefetch` 項目は本観測 (1ページ目) では確認できなかった。PageDown で続きがあると推定される。CPU Configuration の続きを観測する場合は別タスクで PageDown を送信する。

### 3. Chipset Configuration (X10DRT-P)

警告メッセージ: `WARNING: Setting wrong values in below sections may cause...`

サブサブメニュー: ► North Bridge, ► South Bridge

詳細項目は本観測では未取得 (Intel VT-d, IIO Configuration, Memory Configuration などが含まれると推定)。設定変更時は X11DPU の Chipset Configuration 節を参照しつつ、必ず実機で項目構成を確認すること。

### 4. SATA Configuration (X10DRT-P)

X11DPU の "PCH SATA Configuration" に相当。X10DRT-P 命名では "PCH" プレフィックスが省略されている。

#### SATA Controller
- **オプション**: Enabled / Disabled
- **10号機の現在値**: Enabled
- **リスク**: High (Disabled で起動不能の可能性)

#### Configure SATA as
- **オプション**: AHCI / RAID
- **10号機の現在値**: AHCI
- **PVE 推奨**: AHCI

#### SATA Support Aggressive Link Power Mgmt
- **オプション**: Enabled / Disabled
- **10号機の現在値**: Disabled
- **解説**: X10DRT-P 固有項目 (X11DPU には見えない)。SATA リンクの省電力モード
- **PVE 推奨**: Disabled
- **リスク**: Moderate

#### SATA Port 0-4

10号機は **全 5 ポート Not Installed** (Twin Server 構成のため SATA HDD は搭載されていない、ブートは NVMe 想定)。

##### Port N Hot Plug
- **オプション**: Enabled / Disabled
- **10号機の現在値**: **Enabled** (X11DPU デフォルトは Disabled)

##### Port N Spin Up Device
- **オプション**: Enabled / Disabled
- **10号機の現在値**: Disabled

##### Port N SATA Device Type
- **オプション**: Hard Disk Drive / Solid State Drive
- **10号機の現在値**: Hard Disk Drive

> **注**: X11DPU の `SATA HDD Unlock` 項目は X10DRT-P には見えない。

### 5. sSATA Configuration (X10DRT-P)

X11DPU の "PCH eSATA Configuration" に相当。secondary SATA コントローラ。

#### sSATA Controller
- **オプション**: Enabled / Disabled
- **10号機の現在値**: Enabled

#### Configure sSATA as
- **10号機の現在値**: AHCI

#### sSATA Support Aggressive Link Power Mgmt
- **10号機の現在値**: Disabled

#### sSATA Port 0-3

10号機は **全 4 ポート Not Installed** (X11DPU は 0-4 で 5 ポート構成)。各ポートの設定構造は SATA Configuration と同形式。

### 6. Server ME Configuration (X10DRT-P)

X11DPU の "Server ME Information" に相当 (本観測では読み取り専用情報のみ確認)。

#### General ME Configuration (読み取り専用)

| 項目 | 10号機の値 |
|------|-----------|
| Operational Firmware Version | 3.1.3.72 |
| ME Firmware Type | SPS |
| Recovery Firmware Version | 3.1.3.72 |
| ME Firmware Features | SiEn+NM+PECIProxy+ICC+ |
| ME Firmware Status #1 | 0x000F0345 |
| ME Firmware Status #2 | 0x38002000 |
| Current State | Operational |
| Error Code | No Error |

> **X11DPU との差分**: X10DRT-P は ME FW Status #1/#2 raw 値を表示する (X11DPU には見えない)。X11DPU は ME FW 4.1.5.2 (Skylake 世代)、X10DRT-P は 3.1.3.72 (Broadwell 世代の SPS = Server Platform Services)。

### 7. PCIe/PCI/PnP Configuration (X10DRT-P)

#### PCI Bus Driver Version
- **値**: A5.01.05 (読み取り専用)

#### PCI PERR/SERR Support
- **オプション**: Enabled / Disabled
- **10号機の現在値**: Disabled
- **解説**: PCI Parity/System Error の OS 通知。X10DRT-P 固有 (X11DPU には見えない)
- **リスク**: Safe

#### Above 4G Decoding
- **オプション**: Enabled / Disabled
- **10号機の現在値**: Enabled
- **PVE 推奨**: Enabled (大容量 BAR を持つデバイスに必須)

#### SR-IOV Support
- **オプション**: Enabled / Disabled
- **10号機の現在値**: **Enabled** (X11DPU デフォルトは Disabled)
- **解説**: X10DRT-P は出荷時 SR-IOV が有効。NIC パススルーに即対応可能だが、不要なら Disabled でセキュリティ向上
- **リスク**: Moderate

#### ARI Forwarding
- **オプション**: Enabled / Disabled
- **10号機の現在値**: Disabled

#### Completion Timeout
- **オプション**: Default / Shorter / Longer / Disabled (推定)
- **10号機の現在値**: Default

#### Maximum Payload
- **オプション**: Auto / 128B / 256B / 512B / 1024B / 2048B / 4096B
- **10号機の現在値**: Auto

#### Maximum Read Request
- **オプション**: Auto / 128B / 256B / 512B / 1024B / 2048B / 4096B
- **10号機の現在値**: Auto

#### ASPM Support
- **オプション**: Auto / Disabled / Force L0s / Force L1 (推定)
- **10号機の現在値**: Disabled
- **解説**: PCIe Active State Power Management。X10DRT-P 固有項目 (X11DPU には見えない)
- **PVE 推奨**: Disabled (ストレージレイテンシ最適化)
- **リスク**: Moderate

#### MMIOHBase
- **オプション**: 56 TB / 40 TB / 24 TB / 16 TB / 4 TB / 2 TB / 1 TB / 512 GB / 256 GB (X11DPU 同等の選択肢と推定)
- **10号機の現在値**: **2 TB** (X11DPU デフォルトは 56T)
- **解説**: MMIO 上位ベースアドレス。X11DPU では同等項目が "MMIO High Base"
- **PVE 推奨**: デフォルトのまま
- **リスク**: High

#### MMIO High Size
- **オプション**: 1G / 4G / 16G / 64G / 128G / 256G / 1024G (推定)
- **10号機の現在値**: **128 GB** (X11DPU デフォルトは 256G)
- **解説**: X11DPU では "MMIO High Granularity Size" (名称差)
- **リスク**: High

#### MMCFG BASE
- **オプション**: Auto / 1 GB / 1.5 GB / ... (推定)
- **10号機の現在値**: Auto

#### CPU2 SLOT1 PCI-E 3.0 X16 OPROM
- **オプション**: Disabled / Legacy / EFI
- **10号機の現在値**: Legacy

#### CPU2 SLOT2 PCI-E 3.0 X8 OPROM
- **10号機の現在値**: Legacy

#### CPU2 SAS PCI-E 3.0 X8 OPROM
- **10号機の現在値**: Legacy

#### CPU2 SXB1 PCI-E 3.0 X16 OPROM
- **10号機の現在値**: Legacy

> **注**: X10DRT-P は Twin Server 構成のため、片ノードでは CPU2 配下のスロットのみ列挙される (ノード A vs ノード B でラベルが変わる可能性あり)。

#### LSI HBA OPROM
- **オプション**: Disabled / Legacy / EFI (推定。Legacy 動作は 2026-05-02 確認済み、Enabled = Legacy 想定)
- **出荷時 (Nutanix OEM) default**: Disabled
- **10号機の現在値**: **Enabled** (2026-05-02 変更、Issue #53 対応)
- **解説**: X10DRT-P 内蔵 LSI SAS HBA の Option ROM。X11DPU には見えない項目。
- **Linux Legacy boot 必須**: 10号機 OS disk (`/dev/sda` = Toshiba THNSNJ240PCSZ 240GB) は **LSI SAS HBA 配下 (mpt3sas)** なので、`LSI HBA OPROM=Disabled` だと BIOS が disk を boot device として列挙せず、preseed install 完走後の disk first boot で `Reboot and Select proper Boot device` で停止 → PXE フォールバック → DHCP 失敗ループに陥る。Legacy boot を使う場合は **Enabled が必須**。Nutanix OEM 出荷時は AOS (Foundation/Phoenix) 起動前提のため Disabled になっている。
- **Disabled 時の症状**:
  - Save & Exit > Boot Override に PXE (`IBA GE Slot 0300 v1572`) のみ表示
  - Boot タブの "Hard Disk Drive BBS Priorities" サブメニューが出ない (HDD list 空)
  - Legacy Boot Order #5 = "Hard Disk" スロットは存在するが backing physical device 無し
- **Enabled への変更手順**:
  1. POST 中 Delete x60 で BIOS Setup 入場 (`bios-setup` スキル、`--prefer vkbd` で安定)
  2. Advanced タブ → PCIe/PCI/PnP Configuration → Enter
  3. ArrowDown 連打で `LSI HBA OPROM` までスクロール (項目 16 番目程度、help text "Enable/Disable LSI HBA firmware to be loaded" で同定)
  4. Enter → ArrowDown で "Enabled" 選択 → Enter
  5. F4 → Enter で Save & Reset (POST が長くなるが約 1.5-2 分で boot 完了)
- **検証**: 設定後 SSH 到達 (`ssh -F ssh/config pve10 hostname`) で確認可能
- **関連**: Issue #53, レポート 2026-04-30_094039 / 2026-05-02_060639, メモリ `server10_lsi_hba_oprom.md`

#### Onboard LAN OPROM Type
- **オプション**: Legacy / EFI
- **10号機の現在値**: Legacy

#### Onboard LAN1 OPROM
- **オプション**: Disabled / PXE / iSCSI (推定)
- **10号機の現在値**: **PXE** (X11DPU デフォルトは Legacy)
- **解説**: NIC PXE ブート用 Option ROM
- **PVE 推奨**: Disabled (PXE 不要時) または PXE (PXE インストール時)

#### Onboard LAN2 OPROM
- **10号機の現在値**: Disabled

#### Onboard Video OPROM
- **オプション**: Disabled / Legacy / EFI
- **10号機の現在値**: Legacy

### 8. Super IO Configuration (X10DRT-P)

#### Super IO Chip
- **値**: AST2400 (読み取り専用、X11DPU は AST2500)
- **解説**: BMC 兼 Super I/O。世代差で COM ポート IRQ などが異なる可能性

#### Serial Port 1 Configuration / Serial Port 2 Configuration
- サブサブメニュー (本観測では詳細未取得)

### 9. Serial Port Console Redirection (X10DRT-P)

#### COM1
- **COM1 Console Redirection**: Disabled
- **COM1 Console Redirection Settings**: ► サブサブメニュー (Terminal Type, Bits per second 等)

#### COM2/SOL (X11DPU では SOL Console Redirection に相当)
- **COM2/SOL Console Redirection**: **Enabled**
- **COM2/SOL Console Redirection Settings**: ► サブサブメニュー
- **解説**: SOL は COM2 経由で動作する。OS 側の `console=ttyS1,115200n8` (config/server10.yml の `serial_unit: 1`) が正しい設定
- **PVE 推奨**: Enabled (SOL リモートコンソールに必須)

#### Serial Port for Out-of-Band Management/Windows EMS
- **EMS Console Redirection**: Disabled (Linux では使用しない)

### 10. ACPI Settings (X10DRT-P)

#### WHEA Support
- **オプション**: Enabled / Disabled
- **10号機の現在値**: Enabled
- **PVE 推奨**: Enabled

#### High Precision Event Timer
- **オプション**: Enabled / Disabled
- **10号機の現在値**: Enabled

#### NUMA
- **オプション**: Enabled / Disabled
- **10号機の現在値**: Enabled
- **PVE 推奨**: Enabled (Dual Socket 必須)
- **リスク**: Moderate

#### PCI AER Support
- **オプション**: Enabled / Disabled
- **10号機の現在値**: Disabled
- **解説**: PCI Advanced Error Reporting。X10DRT-P 固有 (X11DPU には見えない)。Linux カーネル `pci=noaer` と関連
- **リスク**: Safe

---

## Event Logs タブ (X10DRT-P)

X11DPU と同一構成。サブメニュー:
- ► Change SMBIOS Event Log Settings (SMBIOS Event Log [Enabled], Erase Event Log, When Log is Full, Log System Boot Event)
- ► View SMBIOS Event Log

詳細項目は X11DPU と同等と推定。

---

## IPMI タブ (X10DRT-P)

#### 読み取り専用情報

| 項目 | 10号機の値 |
|------|-----------|
| BMC Firmware Revision | 3.65 |

#### サブメニュー

- ► **System Event Log** (SEL Components, Erase SEL, When SEL is Full)
- ► **BMC Network Configuration** (Update IPMI LAN Configuration, IPMI LAN Selection, Address Source, Station IP)

詳細項目は X11DPU と同等と推定。BMC Network Configuration は出荷時 Static / 10.10.10.30 で動作確認済み。

---

## Security タブ (X10DRT-P)

#### Password Description (情報表示)

X11DPU と同様の文言:
- "If ONLY the Administrator's password is set, then this only limits access to Setup and is only asked for when entering Setup."
- "The User's password cannot be set up until system reboot after Administrator Password is set and saved."
- パスワード長: 最小 3 / 最大 20 文字

#### Password Check
- **オプション**: Setup / Always
- **10号機の現在値**: Setup
- **PVE 推奨**: Setup
- **リスク**: High (Always に設定するとリモート起動が困難)

#### Administrator Password
- **10号機の現在値**: Not Installed
- **PVE 推奨**: 設定しない (ラボ環境)

#### Secure Boot Menu (サブメニュー)

##### 読み取り専用情報

| 項目 | 10号機の値 |
|------|-----------|
| System Mode | Setup |
| Secure Boot | Not Active |
| Vendor Keys | Not Active |

##### Secure Boot
- **オプション**: Enabled / Disabled
- **10号機の現在値**: Disabled
- **PVE 推奨**: Disabled (PVE のデフォルト)

##### Secure Boot Mode
- **オプション**: Standard / Custom
- **10号機の現在値**: **Custom** (X11DPU デフォルトは Standard)
- **解説**: Custom は PK/KEK/db/dbx を手動管理可能 (Key Management サブメニューから)
- **リスク**: Moderate

##### CSM Support
- **オプション**: Enabled / Disabled
- **10号機の現在値**: **Enabled** (X11DPU の Secure Boot Menu には項目なし)
- **解説**: Compatibility Support Module。Legacy ブートを有効にする。CSM Enabled の状態で Secure Boot を有効化することは通常できない (CSM は Legacy 互換のため UEFI Secure Boot と排他的)
- **PVE 推奨**: UEFI ブートを使用する場合は Disabled に変更
- **リスク**: Moderate (Disabled に切替えると Boot Mode も UEFI に変更が必要)

##### Key Management (サブメニュー)
- 詳細未取得 (Secure Boot を使用しない場合は変更不要)

> **重要**: 10号機は出荷時 **Boot Mode = LEGACY + CSM Support = Enabled + Secure Boot Mode = Custom** という組み合わせ。UEFI セキュアブートを使うには CSM を Disabled にして Boot Mode を UEFI に変更する必要がある。`config/server10.yml` で UEFI ブート前提のセットアップを行う場合、本タブの 3 項目を事前に変更すること。

---

## Boot タブ (X10DRT-P)

> **重要差分**: 10号機は出荷時 **LEGACY モード**。X11DPU の DUAL モードと構造が大きく異なる。

#### Boot Configuration (見出し)

#### Setup Prompt Timeout
- **オプション**: 1～65535 (65535 = 無制限待ち)
- **10号機の現在値**: 1 (秒)
- **解説**: POST 中に "Press DEL" 入力受付秒数

#### Boot Mode Select
- **オプション**: LEGACY / UEFI / DUAL (X11DPU と同様の 3 選択肢と推定)
- **10号機の現在値**: **LEGACY** (X11DPU デフォルトは DUAL)
- **解説**: ブートモード変更時は Boot Order とサブメニュー構成がリセットされる
- **リスク**: Moderate (UEFI ブート用に変更する際は CSM Support も Disabled に揃えること)

#### FIXED BOOT ORDER Priorities (LEGACY モード固有レイアウト)

LEGACY モードでは "Legacy Boot Order #1〜#7" が並ぶ (X11DPU の DUAL モードは 17 個の Boot Option):

| 順位 | 10号機の現在値 |
|------|--------------|
| Legacy Boot Order #1 | CD/DVD |
| Legacy Boot Order #2 | USB CD/DVD |
| Legacy Boot Order #3 | USB Hard Disk |
| Legacy Boot Order #4 | USB Key |
| Legacy Boot Order #5 | Hard Disk |
| Legacy Boot Order #6 | Network: IBA GE Slot 0300 v1572 |
| Legacy Boot Order #7 | Disabled |

#### サブメニュー (LEGACY モード時)

- ► **NETWORK Drive BBS Priorities** (BIOS Boot Specification)

(DUAL モード固有の `► Add New Boot Option` / `► UEFI Hard Disk Drive BBS Priorities` 等は LEGACY モードでは表示されない)

#### Legacy Boot Order ドロップダウン値 (8 項目)

LEGACY モードの Boot Order #N で Enter を押した時のドロップダウンリスト:

| Index | 値 |
|-------|-----|
| 0 | Hard Disk |
| 1 | CD/DVD |
| 2 | USB Hard Disk |
| 3 | USB CD/DVD |
| 4 | USB Key |
| 5 | USB Floppy |
| 6 | Network: IBA GE Slot 0300 v1572 |
| 7 | Disabled |

UEFI 系 (UEFI Hard Disk, UEFI CD/DVD, UEFI: Built-in EFI Shell 等) は LEGACY モードでは表示されない。X11DPU DUAL モードの 18 項目とは大きく異なる。

#### キーバインド (X11DPU と同等)

| キー | 動作 |
|------|------|
| ArrowDown/ArrowUp | 値を選択 (双方向ラップ) |
| PageDown | 末尾 (Disabled) にジャンプ |
| PageUp | 先頭 (Hard Disk) にジャンプ |
| Enter | 選択値を確定 |
| Escape | キャンセル |

#### +/- キー (ダイアログ不要の値変更)

X11DPU と同様、Boot Order にカーソルを合わせて `+` / `Shift+Equal` または `-` / `Minus` で値を変更可能 (ダイアログなしで即時確定、双方向ラップ)。

> **UEFI 切替時の注意**: Boot Mode Select を UEFI に変更すると Boot Order の項目数が大きく減る (UEFI 系のみ表示)。Save & Exit で保存する前に必ず F2 (Previous Values) で復元できる状態にしておくこと。

---

## Save & Exit タブ (X10DRT-P)

### Save Options

| 項目 | 動作 | リスク |
|------|------|--------|
| **Discard Changes and Exit** | 変更を破棄して終了 (再起動) | Safe |
| **Save Changes and Reset** | 変更を保存して再起動 (X11DPU では "Save Changes and Exit") | Safe |
| **Save Changes** | 変更を保存 (BIOS Setup に留まる) | Safe |
| **Discard Changes** | 変更を破棄 (BIOS Setup に留まる) | Safe |

> **X11DPU との名称差**: X10DRT-P は "Save Changes and Reset" だが X11DPU は "Save Changes and Exit"。動作は同等 (どちらも保存後に再起動)。

### Default Options

| 項目 | 動作 | リスク |
|------|------|--------|
| **Restore Optimized Defaults** | 工場出荷時デフォルトに戻す | High (VT-x, NUMA 等もリセット) |
| **Save as User Defaults** | 現在の設定をユーザデフォルトとして保存 | Safe |
| **Restore User Defaults** | ユーザデフォルトに戻す | Moderate |

### Boot Override (10号機の現在値)

| デバイス |
|---------|
| IBA GE Slot 0300 v1572 |

(LEGACY モードのため UEFI 系のオーバーライドエントリは表示されない。Hard Disk が Boot Override に表示されないのは現状 NVMe が認識されていないためと推定)

### Exit Without Saving ダイアログ

BIOS のトップレベルで Escape を押すと "Exit Without Saving - Quit without saving?" ダイアログが表示される。

| 操作 | 方法 |
|------|------|
| "No" を選択 (BIOS に留まる) | Tab → Enter |
| "Yes" を選択 (保存せず終了) | Enter (Yes がデフォルト選択) |

X11DPU と同等の挙動。

---

## X11DPU と X10DRT-P の主要差分サマリー

| 項目 | X11DPU (4-6号機) | X10DRT-P (10号機) |
|------|-----------------|-------------------|
| マザーボード | Supermicro X11DPU | Supermicro X10DRT-P-G5-NI22 (Twin Server) |
| OEM | Supermicro 公式 | **Nutanix NX-1065-G5 OEM** |
| CPU | Xeon Gold 6130 (Skylake-SP, LGA3647) | Xeon E5-2620 v4 (Broadwell-EP, LGA2011-3) |
| PCH | C621/C622 | C612 系 (推定) |
| BMC チップ | ASPEED AST2500 | ASPEED AST2400 |
| BMC FW | 01.73.06 | **3.65 (Nutanix OEM 制約で更新不可)** |
| Super IO | AST2500 | AST2400 |
| BIOS | AMI Aptio V 2.20.1276 / Version 4.0 | AMI Aptio V 2.17.1249 / Version G4G5T8.0 |
| ME FW | 4.1.5.2 (PCH 内蔵) | 3.1.3.72 (SPS) |
| Total Memory (実機) | 32 GB | 64 GB |
| Memory Speed 表示 | なし | あり (2133 MHz) |
| BIOS タブ構成 | 7 タブ | 同左 (構成は同一) |
| キーバインド | AMI Aptio 標準 | 同左 (完全一致) |
| キャンバス解像度 | 800x600 (BIOS), 720x400 (POST) | 同左 |
| **Advanced サブメニュー数** | 16 | **10** |
| Trusted Computing / TPM 2.0 | あり | **なし** |
| HTTP Boot / KMS / TLS / iSCSI / Driver Health | あり | **なし** |
| SATA サブメニュー名 | PCH SATA / PCH eSATA Configuration | SATA / sSATA Configuration |
| Server ME 名 | Server ME Information | Server ME Configuration |
| AddOn ROM Display Mode 名称 | "Option ROM Messages" | "AddOn ROM Display Mode" |
| Wait For F1 If Error デフォルト | Enabled | **Disabled** |
| SATA Hot Plug デフォルト | Disabled | **Enabled** |
| SR-IOV Support デフォルト | Disabled | **Enabled** |
| MMIOH 設定名 | High Base + High Granularity Size | **MMIOHBase + MMIO High Size** |
| Onboard LAN1 OPROM デフォルト | Legacy | **PXE** |
| ACPI 固有項目 | (なし) | **PCI AER Support** |
| PCIe 固有項目 (X10DRT-P 側) | (なし) | **PCI PERR/SERR Support, ASPM Support, Clock Spread Spectrum, LSI HBA OPROM** |
| **Boot Mode デフォルト** | DUAL | **LEGACY** |
| Boot Order 数 | 17 (DUAL) | **7 (LEGACY)** |
| Boot Order ドロップダウン値数 | 18 | **8** |
| Secure Boot Mode デフォルト | Standard | **Custom** |
| **CSM Support 項目** | Secure Boot Menu に項目なし | **あり (Enabled)** |
| Save & Exit 主要メニュー | "Save Changes and Exit" | **"Save Changes and Reset"** |
| 設定変更時の安全策 | F2 (Previous Values) | 同左 (動作確認済み) |

---

## X10DRT-P 観測未完了項目 (将来追加観測候補)

以下は本観測では未取得。将来的に reference.md を拡充する場合のチェックリスト:

- Advanced > Boot Feature Page 2 (PageDown 後の項目: Throttle on Power Fail, Allow In-band BIOS Updates 等の有無)
- Advanced > CPU Configuration Page 2 (Intel Virtualization Technology, DCU IP Prefetcher, LLC Prefetch 等)
- Advanced > Chipset Configuration > North Bridge (Intel VT-d, IIO Configuration, Memory Configuration 詳細)
- Advanced > Chipset Configuration > South Bridge (USB Configuration 等)
- Advanced > Super IO Configuration > Serial Port 1/2 Configuration 詳細
- Advanced > Serial Port Console Redirection > COM2/SOL Console Redirection Settings (Terminal Type, Bits per second, Flow Control)
- Boot Mode Select ドロップダウン (LEGACY / UEFI / DUAL の 3 選択肢確認)
- Security > Secure Boot Menu > Key Management

これらは LEGACY → UEFI 切替時、または PCI パススルー設定時に必要となる。

---

## 参考資料

- Supermicro X11DPU User's Manual (ManualsLib)
- Supermicro X10DRT-P / X10DRT-P-G5-NI22 (Nutanix NX-1065-G5 OEM) User's Manual
- AMI Aptio V UEFI Firmware BIOS Setup Guide
- Proxmox VE PCI Passthrough Wiki — IOMMU, VT-d 設定
- Intel Xeon Scalable Processor Tuning Guide
- Intel Xeon E5-2600 v4 Family Datasheet (Broadwell-EP)
- Red Hat Enterprise Linux — SR-IOV Configuration Guide
- SPEC CPU2017 Supermicro Platform Settings
- Thomas-Krenn BIOS Settings Wiki
