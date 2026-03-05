# 3ノード LINSTOR クラスタ構築試行レポート

- **実施日時**: 2026年3月1日 12:30 〜 3月2日 01:18
- **Issue**: #30

## 前提・目的

4号機・5号機・6号機の全3台で、OS 再インストールから LINSTOR 3ノードクラスタ構築、ベンチマーク、全ノード離脱テストまでの一貫検証を実施する計画だった。

- **背景**: 既存の 2ノード LINSTOR クラスタ (4号機・5号機) を 3ノードに拡張し、place-count 2 での冗長性・離脱テスト・ベンチマークを包括的に検証する
- **目的**: 3ノード構成の構築手順確立、thick-stripe ベンチマーク、全ノードの障害・離脱・復帰テスト
- **前提条件**: 3台の Supermicro X11DPU サーバ、SX6036 IB スイッチ、各サーバに ConnectX-3 HCA 搭載

## 環境情報

| 項目 | 4号機 | 5号機 | 6号機 |
|------|-------|-------|-------|
| ホスト名 | ayase-web-service-4 | ayase-web-service-5 | ayase-web-service-6 |
| BMC IP | 10.10.10.24 | 10.10.10.25 | 10.10.10.26 |
| 静的 IP | 10.10.10.204 | 10.10.10.205 | 10.10.10.206 |
| IPoIB IP | 192.168.100.1/24 | 192.168.100.2/24 | 192.168.100.3/24 |
| HCA | ConnectX-3 CX354A | ConnectX-3 CX354A | ConnectX-3 CX354A |
| HCA FW | 2.40.5030 | 2.40.5030 | 2.40.5030 |
| IB ケーブル | DAC (パッシブ銅線) | DAC (パッシブ銅線) | **CWDM4 光モジュール** |
| OS | Debian 13.3 (Trixie) | Debian 13.3 (Trixie) | Debian 13.3 (Trixie) |
| PVE | 9.1.6 | 9.1.6 | 9.1.6 |
| カーネル | 6.17.13-1-pve | 6.17.13-1-pve | 6.17.13-1-pve |

| 項目 | 値 |
|------|-----|
| IB スイッチ | Mellanox SX6036 (MSX6036F-1SFS) |
| MLNX-OS | 3.6.8012 |
| スイッチポート | IB1/23 (4号機), IB1/21 (5号機), IB1/19 (6号機) |
| Subnet Manager | 内蔵 SM (OpenSM 4.8.1) |

## 計画フェーズと実施結果

| Phase | 内容 | 状態 | 備考 |
|-------|------|------|------|
| 1 | OS セットアップ (3台) | **完了** | 全3台 Debian 13 + PVE 9 インストール成功 |
| 2 | PVE クラスタ構成 | **完了** | 3ノード pvese-cluster 構成完了 |
| 3 | InfiniBand セットアップ | **部分完了** | 4/5号機のみ LinkUp、6号機は CWDM4 電力問題で中断 |
| 4 | LINSTOR 3ノード構築 | 未実施 | Phase 3 中断のため |
| 5 | ベンチマーク (thick-stripe) | 未実施 | 同上 |
| 6 | 離脱テスト (全3ノード) | 未実施 | 同上 |
| 7 | レポート作成 | **本レポート** | — |

## Phase 1: OS セットアップ

全3台に対して `os-setup` スキルを順次実行。BMC VirtualMedia 経由の preseed 自動インストール。

### フェーズ別所要時間

| フェーズ | 4号機 | 5号機 | 6号機 |
|----------|-------|-------|-------|
| iso-download | 0m22s | 0m10s | 0m11s |
| preseed-generate | 0m09s | 0m07s | 0m09s |
| iso-remaster | 1m37s | 1m43s | 1m43s |
| bmc-mount-boot | 4m43s | 4m52s | 9m12s |
| install-monitor | 10m08s | 9m37s | 6m27s |
| post-install-config | 3m23s | 2m30s | 3m23s |
| pve-install | 22m08s | 15m49s | 23m31s |
| cleanup | 0m35s | 0m33s | 0m36s |
| **合計** | **43m05s** | **35m21s** | **45m12s** |

### 特記事項

- **4号機**: pve-install フェーズで POST code 92 (PCI bus init) スタックが発生。KVM スクリーンショットで確認後、パワーサイクルでリカバリ
- **5号機**: 問題なく完了（最速）
- **6号機**: bmc-mount-boot が長め (9m12s)。install-monitor は最速 (6m27s)。pve-install でパッケージダウンロードに時間がかかった

### 最終状態

```
4号機: pve-manager/9.1.6/71482d1833ded40a (running kernel: 6.17.13-1-pve)
5号機: pve-manager/9.1.6/71482d1833ded40a (running kernel: 6.17.13-1-pve)
6号機: pve-manager/9.1.6/71482d1833ded40a (running kernel: 6.17.13-1-pve)
```

## Phase 2: PVE クラスタ構成

### 手順

1. 全3ノード間で SSH 鍵交換 (`tmp/b38b3c37/ssh-key-exchange.sh`)
2. 4号機でクラスタ作成: `pvecm create pvese-cluster --link0 10.10.10.204`
3. 5号機参加: `pvecm add 10.10.10.204 --link0 10.10.10.205 --force` (expect で自動化)
4. 6号機参加: `pvecm add 10.10.10.204 --link0 10.10.10.206 --force` (expect で自動化)

### 最終状態

```
Cluster: pvese-cluster
Nodes: 3
Quorum: 2/3 (majority)
Node 0x00000001: 10.10.10.204 (local)
Node 0x00000002: 10.10.10.205
Node 0x00000003: 10.10.10.206
Status: Quorate
```

3ノード構成のため `two_node: 1` は不要（通常の majority quorum）。

## Phase 3: InfiniBand セットアップ

### 手順

全3ノードに IB パッケージ (`rdma-core`, `infiniband-diags`, `ibverbs-utils`) をインストールし、`ib-setup-remote.sh` で IPoIB を設定。

| ノード | IPoIB IP | モード | 結果 |
|--------|----------|--------|------|
| 4号機 | 192.168.100.1/24 | Connected | **Active/LinkUp QDR 40 Gbps** |
| 5号機 | 192.168.100.2/24 | Connected | **Active/LinkUp QDR 40 Gbps** |
| 6号機 | 192.168.100.3/24 | Connected | **Down/Polling — リンク確立不可** |

### 6号機の IB リンク障害

#### 症状

- サーバ側 (`ibstat`): 両ポートとも `Physical state: Polling`、`Rate: 10` (リンクダウン時のデフォルト)
- スイッチ側 (`show interfaces ib 1/19`): `Warning: High power transceiver is not supported`
- dmesg に `Link INIT` / `Link ACTIVE` メッセージなし（4号機・5号機では起動時に出現）

#### 調査手順

##### 1. サーバ側 IB ポート物理状態の確認

6号機の両ポートが Polling 状態であることを確認:

```
$ ssh root@10.10.10.206 'cat /sys/class/infiniband/mlx4_0/ports/1/phys_state'
2: Polling

$ ssh root@10.10.10.206 'cat /sys/class/infiniband/mlx4_0/ports/2/phys_state'
2: Polling
```

4号機 (正常) との比較:

```
$ ssh root@10.10.10.204 'cat /sys/class/infiniband/mlx4_0/ports/1/phys_state'
5: LinkUp
```

##### 2. HCA 型番・ファームウェアの比較

6号機の HCA が 4/5号機と同一であることを確認:

```
$ ssh root@10.10.10.206 'lspci -vvs 86:00.0' | grep "Product Name"
Product Name: CX354A - ConnectX-3 QSFP
Part number: 050-0050-02
Serial number: MT1531X10442

$ ssh root@10.10.10.206 'ibstat'
CA 'mlx4_0'
    CA type: MT4099
    Firmware version: 2.40.5030
    Port 1:
        State: Down
        Physical state: Polling
        Rate: 10
        Link layer: InfiniBand
    Port 2:
        State: Down
        Physical state: Polling
        Rate: 10
        Link layer: InfiniBand
```

4号機 (正常) の ibstat:

```
$ ssh root@10.10.10.204 'ibstat'
CA 'mlx4_0'
    CA type: MT4099
    Firmware version: 2.40.5030
    Port 1:
        State: Active
        Physical state: LinkUp
        Rate: 40
        Link layer: InfiniBand
```

HCA 型番 (MT4099 / CX354A)、ファームウェア (2.40.5030)、リンクレイヤー (InfiniBand) はすべて同一。差異はリンク状態のみ。

##### 3. dmesg でのリンクイベント比較

4号機 (正常) ではカーネル起動時に Link INIT → Link ACTIVE が出現:

```
$ ssh root@10.10.10.204 'dmesg | grep -i "mlx4.*link"'
[   16.337462] mlx4_core 0000:86:00.0 mlx4_0: Port: 1 Link INIT
[   16.378335] mlx4_core 0000:86:00.0 mlx4_0: Port: 1 Link ACTIVE
```

6号機では Link INIT / Link ACTIVE メッセージなし（物理層でリンクが確立されていない）:

```
$ ssh root@10.10.10.206 'dmesg | grep -i "mlx4.*link"'
(出力なし — リンクイベントが発生していない)
```

mlx4 ドライバ自体はロードされている:

```
$ ssh root@10.10.10.206 'dmesg | grep mlx4'
[   11.711927] mlx4_core 0000:86:00.0: DMFS high rate steer mode is: disabled performance optimized steering
[   11.712222] mlx4_core 0000:86:00.0: 63.008 Gb/s available PCIe bandwidth (8.0 GT/s PCIe x8 link)
[   12.298968] <mlx4_ib> mlx4_ib_probe: mlx4_ib: Mellanox ConnectX InfiniBand driver v4.0-0
```

##### 4. スイッチ側ポート状態の確認

SX6036 のシリアルコンソール経由 (4号機 → USB シリアル → SX6036) で IB1/19 の詳細を取得:

```
$ ssh root@10.10.10.204 'python3 /tmp/sx6036-console.py show interfaces ib 1/19'
IB1/19 state:
    Logical port state          : Down
    Physical port state         : Polling
    Current line rate           : -
    Supported speeds            : sdr, ddr, qdr, fdr10, fdr
    Speed                       : -
    Width                       : -
    Description                 :
    IB Subnet                   : infiniband-default
    Phy-profile                 : high-speed-ber
    Warning                     : High power transceiver is not supported
```

正常な IB1/23 (4号機) との比較:

```
$ ssh root@10.10.10.204 'python3 /tmp/sx6036-console.py show interfaces ib 1/23'
IB1/23 state:
    Logical port state          : Active
    Physical port state         : LinkUp
    Current line rate           : 40.0 Gbps
    Speed                       : qdr
    Width                       : 4X
    (Warning なし)
```

**IB1/19 にのみ `Warning: High power transceiver is not supported` が表示**されており、これがリンクダウンの直接原因。

##### 5. スイッチ側トランシーバ詳細情報の取得試行

MLNX-OS 3.6 で利用可能なトランシーバ情報コマンドを複数試行したが、IB インターフェースではいずれも非対応:

```
$ ssh root@10.10.10.204 'python3 /tmp/sx6036-console.py show interfaces ib 1/19 transceiver'
% Unrecognized command "transceiver".

$ ssh root@10.10.10.204 'python3 /tmp/sx6036-console.py enable-cmd show interfaces ib 1/19 module-info'
% Unrecognized command "module-info".

$ ssh root@10.10.10.204 'python3 /tmp/sx6036-console.py enable-cmd show cables'
% Unrecognized command "cables".

$ ssh root@10.10.10.204 'python3 /tmp/sx6036-console.py enable-cmd show ib port 1/19'
% Unrecognized command "port".

$ ssh root@10.10.10.204 'python3 /tmp/sx6036-console.py enable-cmd show running-config interface ib 1/19'
% Unrecognized command "interface".
```

capabilities コマンドのみ応答あり:

```
$ ssh root@10.10.10.204 'python3 /tmp/sx6036-console.py enable-cmd show interfaces ib 1/19 capabilities'
IB1/19
LLR: FDR10, FDR,
```

スイッチの inventory にはポート単位のトランシーバ情報は含まれなかった:

```
$ ssh root@10.10.10.204 'python3 /tmp/sx6036-console.py show inventory'
CHASSIS  MSX6036F-1SFS  MT1809K36681  N/A  AE
MGMT     MSX6036F-1SFS  MT1809K36681  2    AE
FAN      MSX60-FF       MT1808K34831  N/A  A1
PS1      MSX60-PF       MT1808K34635  N/A  A1
PS2      MSX60-PF       MT1804X02433  N/A  A1
```

##### 6. サーバ側からのモジュール情報取得試行

ethtool の `-m` (module info) オプションは IB インターフェースでは非対応:

```
$ ssh root@10.10.10.206 'ethtool -m ibp134s0'
netlink error: Operation not supported

$ ssh root@10.10.10.204 'ethtool -m ibp134s0'
netlink error: Operation not supported
```

##### 7. Mellanox ファームウェアツールによる設定確認試行

mstflint をインストールし、NIC のファームウェア設定を読み取ろうとしたが失敗:

```
$ ssh root@10.10.10.206 'apt-get install -y mstflint'
Setting up mstflint (4.31.0+1-4) ...

$ ssh root@10.10.10.206 'mstconfig -d 86:00.0 query'
(出力なし)

$ ssh root@10.10.10.206 'mstflint -d 0000:86:00.0 q'
Segmentation fault
```

MST (Mellanox Software Tools) のカーネルモジュールが未ロードのため、PCI デバイスへの直接アクセスに失敗。`mst start` コマンドは MFT フルパッケージに含まれるが Debian リポジトリの mstflint パッケージには含まれない:

```
$ ssh root@10.10.10.206 'mst start'
bash: mst: command not found
```

##### 8. 結論の導出

上記の調査から以下を確認:
- HCA・ファームウェア・ドライバは 4/5号機と同一で問題なし
- リンクが物理層 (Polling) で停滞しており、スイッチ側が `High power transceiver is not supported` を報告
- MLNX-OS 3.6 にはトランシーバの電力設定を変更するコマンドが存在しない

ユーザへのヒアリングにより、6号機は DAC ではなく **CWDM4 光モジュール** を使用していることが判明。Web 調査の結果:

- SX6036 (SwitchX-2 ファミリー) はポートあたり **最大 2W** の電力供給 ([StorageReview](https://www.storagereview.com/review/mellanox-sx6036-56gb-infiniband-switch-review), [製品仕様書](https://cw.infinibandta.org/files/showcase_product/120330.104655.244.PB_SX6036.pdf))
- CWDM4 モジュールは 4波長レーザー + TEC 冷却で **2.5〜3.5W** を消費 (QSFP Power Class 2-3)
- 高消費電力トランシーバのサポートは **Switch-IB ファミリー以降** ([MLNX-OS ドキュメント](https://docs.nvidia.com/networking/display/mlnxosv3103002/infiniband+interface)): "NVIDIA switch systems offer high power transceiver support on all ports of the Switch-IB family switch systems."
- MLNX-OS にパワークラスオーバーライドや送信電力調整のコマンドは存在しない（ハードウェア制限）

#### 比較

| 項目 | 4/5号機 (正常) | 6号機 (障害) |
|------|---------------|-------------|
| HCA | CX354A (MT4099) | CX354A (MT4099) |
| FW | 2.40.5030 | 2.40.5030 |
| ケーブル種別 | DAC (パッシブ銅線) ~1.0W | CWDM4 光モジュール ~3.0W |
| スイッチポート | IB1/23, IB1/21 | IB1/19 |
| スイッチ警告 | なし | High power transceiver is not supported |
| リンク状態 | Active/LinkUp QDR 40 Gbps | Down/Polling |

### 結論

6号機の CWDM4 光モジュールは SX6036 の電力制限 (2W/port) を超過するため使用不可。解決策:

1. **DAC ケーブルに交換** (推奨): 4/5号機と同じパッシブ銅線 DAC ケーブル (~1.0W)
2. **Mellanox FDR AOC**: アクティブ光ケーブル (MC220731V シリーズ、<2W、光ファイバー対応)
3. **Switch-IB 以降のスイッチに移行**: SB7700/SB7800 は全ポートで高消費電力トランシーバをサポート

## 中断理由

Phase 3 で 6号機の IB 接続が CWDM4 モジュールの電力制限により確立できず、3ノード IB 構成が実現不可能なため、Phase 4 以降の LINSTOR 構築・ベンチマーク・離脱テストを中断した。

## 完了した成果物

Phase 3 の中断により当初計画は未完了だが、以下は正常に完了:

1. **全3台の OS 再インストール** (Debian 13 + PVE 9): 自動化パイプライン検証済み
2. **3ノード PVE クラスタ** (pvese-cluster): 構成完了、quorum 正常動作
3. **4/5号機の IPoIB**: Active/LinkUp QDR 40 Gbps

## 参照レポート

- [SX6036 スイッチ経由 IB ベンチマーク](2026-02-25_203745_ib_switch_benchmark.md)
- [SX6036 FW 更新](2026-02-26_011138_sx6036_firmware_update.md)
- [5号機 OS セットアップ](2026-02-25_120621_server5_os_setup.md)
- [6号機 OS セットアップ](2026-03-01_172457_server6_os_setup.md)
