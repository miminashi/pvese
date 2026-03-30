# Supermicro X11DPU BIOS 設定リファレンス

## はじめに

本ドキュメントは Supermicro X11DPU マザーボード (4-6号機) の AMI Aptio UEFI BIOS 設定項目の技術リファレンスである。

- **対象ハードウェア**: Supermicro X11DPU / X11DPU-Z+ (Dual Socket LGA 3647)
- **CPU**: Intel Xeon Scalable (Skylake-SP / Cascade Lake-SP), 4号機: Xeon Gold 6130 x2
- **BIOS**: AMI Aptio Setup Utility, Version 2.20.1276 (Build Date 08/11/2023)
- **CPLD Version**: 03.B0.06
- **BMC Firmware**: 01.73.06

各設定項目について、技術的な解説・PVE 推奨値・変更リスクを記載する。BIOS 操作手順は [SKILL.md](SKILL.md) を参照。

### リスクレベル定義

| レベル | 意味 |
|--------|------|
| **Safe** | 変更してもハードウェアに影響なし。機能の有効/無効切替のみ |
| **Moderate** | OS やドライバの動作に影響する可能性がある。変更前に影響を理解すること |
| **High** | 起動不能やハードウェア障害のリスクがある。十分な検証が必要 |
| **Critical** | データ消失やセキュリティ設定の不可逆変更のリスクがある |

---

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

## 参考資料

- Supermicro X11DPU User's Manual (ManualsLib)
- AMI Aptio V UEFI Firmware BIOS Setup Guide
- Proxmox VE PCI Passthrough Wiki — IOMMU, VT-d 設定
- Intel Xeon Scalable Processor Tuning Guide
- Red Hat Enterprise Linux — SR-IOV Configuration Guide
- SPEC CPU2017 Supermicro Platform Settings
- Thomas-Krenn BIOS Settings Wiki
