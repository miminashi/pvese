# LINSTOR/DRBD LVM Thin Pool vs Thick Striped LVM ベンチマーク比較レポート

- **実施日時**: 2026年2月26日 08:45
- **前回レポート**: [2026-02-26_052044_linstor_drbd_benchmark.md](2026-02-26_052044_linstor_drbd_benchmark.md)

## 前提・目的

前回セッションで LINSTOR/DRBD クラスタを LVM thin pool 上に構築し VM ベンチマークを実施した結果、thin LV がストライピングされないため単一ディスク性能に制約され、特にシーケンシャル性能が低かった (Read: 132 MiB/s, Write: 12.9 MiB/s)。

本テストでは、thin pool を解体し **LVM ストライピング (thick LVM, 4本ストライプ)** に再構成して同一ベンチマークを実行し、thin pool との性能差を定量的に比較する。

- **背景**: thin pool 内の LV は CoW (Copy-on-Write) で管理されるため、thin pool 自体がストライプされていても内部 LV は linear 割り当てになる
- **目的**: 4ディスクストライピングによる性能向上量を計測し、LVM thick vs thin のトレードオフを明確にする
- **前提条件**: 前回と同一のハードウェア・DRBD 構成を使用

## 環境情報

### ハードウェア

| 項目 | Server 4 | Server 5 |
|------|----------|----------|
| ホスト名 | ayase-web-service-4 | ayase-web-service-5 |
| マザーボード | Supermicro X11DPU | Supermicro X11DPU |
| 管理 IP | 10.10.10.204 | 10.10.10.205 |
| IPoIB IP | 192.168.100.1 | 192.168.100.2 |
| ストレージディスク | 4 x 500GB SATA HDD (Seagate ST500DM002) | 4 x 500GB SATA HDD (Seagate ST500DM002) |

### ソフトウェア

| 項目 | バージョン |
|------|-----------|
| OS | Debian 13.3 (Trixie) |
| カーネル | 6.17.9-1-pve (6.12.73+deb13) |
| Proxmox VE | 9.1.6 |
| DRBD | 9.3.0 |
| LINSTOR | 1.33.1 |
| linstor-proxmox | 8.2.0 |
| fio | 3.39 |

### DRBD 構成

- Protocol C (同期レプリケーション)
- Quorum: off (2ノードクラスタ)
- Auto-promote: yes
- トランスポート: TCP over IPoIB (40 Gbps QDR InfiniBand)
- PrefNic: ib0 (192.168.100.x)

### テスト構成

| # | 構成名 | LVM タイプ | ストライピング | LINSTOR ドライバ | VG サイズ |
|---|--------|-----------|---------------|-----------------|----------|
| A | thin-nostripe | LVM Thin | なし (linear) | lvmthin | 1.73 TiB / node |
| B | thick-stripe | Thick LVM | 4本, 64 KiB | lvm | 1.82 TiB / node |

### VM スペック

- vCPU: 4 (host passthrough)
- メモリ: 4 GB
- ディスク: 32 GB (LINSTOR ストレージ上)
- NIC: virtio (vmbr1, 192.168.39.0/24 DHCP)
- SCSI: virtio-scsi-single (iothread=1, discard=on)
- OS: Debian 13 (cloud image)

## 技術解説

### LVM Thin Pool の仕組み

LVM thin pool は **Copy-on-Write (CoW)** に基づくプロビジョニング機構である。

```
┌─────────────────────────────────────────────┐
│              Volume Group (VG)              │
│  ┌────────────────────────────────────────┐ │
│  │         Thin Pool (LV)                 │ │
│  │  ┌──────────┐ ┌──────────┐            │ │
│  │  │ Thin LV 1│ │ Thin LV 2│  ...       │ │
│  │  │ (VM disk)│ │ (VM disk)│            │ │
│  │  └──────────┘ └──────────┘            │ │
│  │  ┌──────────────────────────────────┐ │ │
│  │  │     Data Pool (chunks)           │ │ │
│  │  └──────────────────────────────────┘ │ │
│  │  ┌──────────────┐                    │ │
│  │  │ Metadata LV  │                    │ │
│  │  └──────────────┘                    │ │
│  └────────────────────────────────────────┘ │
│  ┌────┐ ┌────┐ ┌────┐ ┌────┐              │
│  │sda │ │sdb │ │sdc │ │sdd │              │
│  └────┘ └────┘ └────┘ └────┘              │
└─────────────────────────────────────────────┘
```

**主な特徴:**
- **オーバープロビジョニング**: 実容量以上のディスクを VM に割り当て可能
- **スナップショット**: CoW により高速・低コストなスナップショットが可能
- **メタデータ管理**: 各チャンクの割り当て状況をメタデータ LV で追跡
- **書き込みペナルティ**: 新ブロックへの書き込みはメタデータ更新 + データ書き込みの2ステップ

### LVM Thick (通常) LV の仕組み

```
┌─────────────────────────────────────────────┐
│              Volume Group (VG)              │
│  ┌──────────────────────────────────────┐   │
│  │ LV (VM disk) - 連続した PE の割り当て │   │
│  └──────────────────────────────────────┘   │
│  ┌────┐ ┌────┐ ┌────┐ ┌────┐              │
│  │sda │ │sdb │ │sdc │ │sdd │              │
│  └────┘ └────┘ └────┘ └────┘              │
└─────────────────────────────────────────────┘
```

**主な特徴:**
- **事前割り当て**: 作成時に全領域を確保 (DRBD の初期同期が全領域に及ぶ)
- **直接 I/O**: メタデータ管理のオーバーヘッドなし
- **スナップショット不可** (LVM thick snapshot は非推奨)
- **ストライピング指定可能**: `lvcreate -i4 -I64` で 4 ディスクストライプ

### LVM ストライピングの仕組み

ストライピングはデータを複数の物理ディスクに分散配置する手法。

```
論理ブロック:  [0] [1] [2] [3] [4] [5] [6] [7] [8] [9] [10] [11] ...
               │   │   │   │   │   │   │   │   │   │   │    │
ストライプ:    ─┼───┼───┼───┼───┼───┼───┼───┼───┼───┼───┼────┼───
               ▼   ▼   ▼   ▼   ▼   ▼   ▼   ▼   ▼   ▼   ▼    ▼
sda:          [0]         [4]         [8]
sdb:              [1]         [5]         [9]
sdc:                  [2]         [6]          [10]
sdd:                      [3]         [7]          [11]

ストライプサイズ = 64 KiB (各ディスクに書き込む単位)
ストライプ数 = 4 (同時に使用するディスク数)
```

**パラメータ:**
- `-i N`: ストライプ数 (N 本のディスクに分散)
- `-I S`: ストライプサイズ (各ディスクに一度に書き込むバイト数, KiB 単位)
- 理論最大スループット: 単一ディスク × N 倍

### Thin Pool がストライプされない理由

前回テストの構成では、LINSTOR が `lvmthin` ドライバで thin pool を作成した。LINSTOR の thin pool 作成時にストライプオプションが指定されなかったため、thin pool 自体が linear (単一ディスク配置) となった。

**重要な制約**: thin pool 内の thin LV は、thin pool のレイアウトを継承するのではなく、thin pool のチャンクアロケータによって動的に割り当てられる。thin pool 自体をストライプ構成で作成すれば内部データは分散されるが、LINSTOR の lvmthin ドライバは thin pool 作成時に `LvcreateOptions` を thin pool 自体には適用しない (thin LV 作成時に適用するが、thin LV にはストライプ指定が意味をなさない)。

結果として、thin pool 構成ではすべての I/O が 1 本の SATA HDD を通過し、単一ディスクの性能上限 (~130 MiB/s read, ~13 MiB/s write) に制約された。

### LINSTOR の `StorDriver/LvcreateOptions` の動作

```
linstor storage-pool set-property <node> <pool> StorDriver/LvcreateOptions '-i4 -I64'
```

- **thick LVM (lvm ドライバ)**: `lvcreate` 時にこのオプションが渡され、LV がストライプ構成で作成される → **効果あり**
- **thin LVM (lvmthin ドライバ)**: `lvcreate --thin` で thin LV を作成する際に渡されるが、thin LV はストライプを指定できない → **効果なし**

### Thick LVM のトレードオフ

| 特性 | Thick LVM (stripe) | Thin Pool |
|------|-------------------|-----------|
| スナップショット | 不可 (非推奨) | 高速・低コスト |
| オーバープロビジョニング | 不可 | 可能 |
| DRBD 初期同期 | 全領域同期 (遅い) | 使用済み領域のみ (速い) |
| I/O 性能 | 高い (ストライプ並列) | 低い (linear + CoW オーバーヘッド) |
| メタデータオーバーヘッド | なし | あり |
| ディスク使用効率 | 低い (事前割り当て) | 高い (動的割り当て) |

## ベンチマーク結果

### 比較テーブル

| テスト | A: Thin NoStripe |  | B: Thick Stripe |  | 性能比 |
|--------|:---:|:---:|:---:|:---:|:---:|
|  | IOPS | スループット | IOPS | スループット | (B/A) |
| **4K Random Read QD1** | 132 | 529 KiB/s | **156** | **623 KiB/s** | **1.18x** |
| **4K Random Read QD32** | 270 | 1,080 KiB/s | **1,185** | **4,740 KiB/s** | **4.39x** |
| **4K Random Write QD1** | 26 | 104 KiB/s | **78** | **313 KiB/s** | **3.01x** |
| **4K Random Write QD32** | 33 | 131 KiB/s | **380** | **1,521 KiB/s** | **11.6x** |
| **1M Seq Read QD32** | 133 | 132.5 MiB/s | **254** | **253.7 MiB/s** | **1.91x** |
| **1M Seq Write QD32** | 13 | 12.9 MiB/s | **79** | **79.3 MiB/s** | **6.17x** |
| **Mixed R/W 70/30 QD32** | R:103 / W:45 | R:412 / W:180 | **R:466 / W:200** | **R:1,865 / W:798** | **R:4.5x / W:4.4x** |

### レイテンシ比較テーブル

| テスト | A: Thin NoStripe |  | B: Thick Stripe |  |
|--------|:---:|:---:|:---:|:---:|
|  | Avg (ms) | p99 (ms) | Avg (ms) | p99 (ms) |
| **4K Random Read QD1** | 7.5 | 12.3 | **6.4** | 12.6 |
| **4K Random Read QD32** | 118.4 | 683.7 | **27.0** | **189.8** |
| **4K Random Write QD1** | 38.1 | 198.2 | **12.7** | **38.5** |
| **4K Random Write QD32** | 975.0 | 3,338.7 | **84.0** | **767.6** |
| **1M Seq Read QD32** | 241.4 | 299.9 | **126.1** | 1,400.9 |
| **1M Seq Write QD32** | 2,481.1 | 4,177.5 | **402.7** | **717.2** |
| **Mixed R/W QD32 (R)** | 267.8 | 1,853.9 | **49.3** | **625.0** |
| **Mixed R/W QD32 (W)** | 97.1 | 1,803.6 | **45.1** | **333.4** |

## 分析

### 性能向上の概要

Thick LVM ストライプ構成は、thin pool に対して **全テストで大幅な性能向上** を示した。

- **最大改善**: 4K Random Write QD32 で **11.6 倍** (33 → 380 IOPS)
- **シーケンシャル Write**: **6.17 倍** (12.9 → 79.3 MiB/s)
- **シーケンシャル Read**: **1.91 倍** (132.5 → 253.7 MiB/s)

### ボトルネック分析

#### 1. ストライピングの効果 (I/O 並列化)

4 ディスクストライプにより、理論上は 4 倍の帯域幅が利用可能になる。実測では:

- **シーケンシャル Read**: 1.91x (理論 4x の 48%) — ディスクキューやブロックサイズアライメントの影響
- **シーケンシャル Write**: 6.17x (理論 4x を超過) — thin pool の CoW オーバーヘッド解消 + ストライプ効果の複合

理論値を超えた Write 性能は、thin pool の CoW オーバーヘッド (メタデータ更新、チャンク割り当て) が排除されたことによる。

#### 2. DRBD Protocol C の影響

DRBD Protocol C は同期レプリケーション (Write 完了待ち) のため、Write 系テストでは DRBD レイテンシが加算される。しかし thick stripe でもランダム Write QD32 で 380 IOPS を達成しており、DRBD のレプリケーション遅延は IPoIB (40 Gbps) により十分に低い。

#### 3. QD1 vs QD32 の差

| テスト | QD1 改善 | QD32 改善 | 理由 |
|--------|---------|---------|------|
| Random Read | 1.18x | 4.39x | QD32 でストライプ間の並列性が活用される |
| Random Write | 3.01x | 11.6x | QD32 でストライプ + DRBD パイプラインの効果 |

QD1 (キュー深度1) ではリクエストが直列化されるため、ストライピングの効果は限定的。QD32 ではコントローラが複数ディスクに同時にリクエストを発行でき、ストライプの並列性が最大限に活かされる。

#### 4. Thin pool 固有のオーバーヘッド

Thin pool は以下の追加処理が発生し、特に Write で大きなペナルティとなる:

1. **チャンク割り当て**: 新ブロックへの初回書き込み時に thin pool のフリーチャンクを検索・割り当て
2. **メタデータ更新**: 割り当て情報をメタデータ LV に書き込み (メタデータ LV 自体も同一ディスク上)
3. **CoW 処理**: スナップショット使用時はさらに追加コピーが発生

これらのオーバーヘッドにより、thin pool の Random Write QD32 は 33 IOPS (thick の 380 IOPS の 8.6%) まで低下した。

### ストレージ構成選択ガイドライン

| ユースケース | 推奨構成 | 理由 |
|------------|---------|------|
| **高性能 I/O が必要** | Thick Stripe | ストライプ並列化 + CoW オーバーヘッドなし |
| **スナップショットが必要** | Thin Pool | Thick LVM のスナップショットは非推奨 |
| **オーバープロビジョニング** | Thin Pool | Thick は事前割り当てのため不可 |
| **大量の VM** | Thin Pool | ディスク使用効率が高い |
| **データベース VM** | Thick Stripe | ランダム Write 性能が重要 |

### 制約・注意事項

1. **Server 4 の /dev/sdc に不良セクタ (8個) が存在した** — テスト前にゼロ書き込みで強制再割り当てして解消 (Current_Pending: 8→0)。ベンチマーク中にディスクエラーは発生しなかった。
2. **Thick LVM の DRBD 初期同期は全領域** — 32 GB ディスクの初期同期に約 9 分 (thin pool では使用済み領域のみ同期のため数十秒)。
3. **テスト構成 A (thin-nostripe) の結果は前回セッションから引用** — 同一ハードウェア・同一 DRBD 構成だが、実行日時が異なる。

## 再現方法

### Phase 0: クリーンアップ

```bash
# VM 停止・削除
qm stop 100 && qm destroy 100 --purge

# LINSTOR リソース確認
linstor resource-definition list

# ストレージプール・リソースグループ削除
linstor storage-pool delete ayase-web-service-4 thinpool
linstor storage-pool delete ayase-web-service-5 thinpool
linstor resource-group delete pve-rg
pvesm remove linstor-storage

# 各ノードで LVM 解体
ssh root@10.10.10.204 'lvremove -f linstor_vg/thinpool && vgremove linstor_vg && pvremove /dev/sd{a,b,c,d}'
ssh root@10.10.10.205 'lvremove -f linstor_vg/thinpool && vgremove linstor_vg && pvremove /dev/sd{a,b,c,d}'
```

### Phase 1: Thick LVM ストライプ構成

```bash
# 各ノードで VG 作成
for node in 10.10.10.204 10.10.10.205; do
  ssh root@$node 'wipefs -af /dev/sd{a,b,c,d} && pvcreate /dev/sd{a,b,c,d} && vgcreate linstor_vg /dev/sd{a,b,c,d}'
done

# LINSTOR thick LVM ストレージプール
linstor storage-pool create lvm ayase-web-service-4 striped-pool linstor_vg
linstor storage-pool create lvm ayase-web-service-5 striped-pool linstor_vg

# ストライピングオプション設定 (-i4: 4本, -I64: 64KiB)
linstor storage-pool set-property ayase-web-service-4 striped-pool StorDriver/LvcreateOptions -- '-i4 -I64'
linstor storage-pool set-property ayase-web-service-5 striped-pool StorDriver/LvcreateOptions -- '-i4 -I64'

# リソースグループ
linstor resource-group create pve-rg --place-count 2 --storage-pool striped-pool
linstor volume-group create pve-rg
linstor resource-group drbd-options --protocol C pve-rg
linstor resource-group drbd-options --quorum off pve-rg
linstor resource-group drbd-options --auto-promote yes pve-rg

# PVE ストレージ
pvesm add drbd linstor-storage --resourcegroup pve-rg --content images,rootdir --controller 10.10.10.204
```

### Phase 2: VM 作成・ベンチマーク

```bash
# VM 作成
qm create 100 --name bench-vm --memory 4096 --cores 4 --cpu host \
  --net0 virtio,bridge=vmbr1 --ostype l26 --scsihw virtio-scsi-single
qm importdisk 100 /var/lib/vz/template/debian-cloud.qcow2 linstor-storage
qm set 100 --scsi0 linstor-storage:<resource-name>_100,discard=on,iothread=1
qm set 100 --boot order=scsi0
qm set 100 --ide2 linstor-storage:cloudinit
qm set 100 --ciuser debian --cipassword password --ipconfig0 ip=dhcp
qm set 100 --cicustom "vendor=local:snippets/ssh-pwauth.yml"
qm set 100 --citype nocloud
qm resize 100 scsi0 32G
qm start 100

# ストライピング確認
lvs -o +stripes,stripe_size linstor_vg

# fio ベンチマーク (VM 内)
sudo apt-get install -y fio
sudo fio --name=randread-4k-qd1 --ioengine=libaio --direct=1 --rw=randread --bs=4k --iodepth=1 --numjobs=1 --size=1G --runtime=60 --time_based --group_reporting --output-format=json
sudo fio --name=randread-4k-qd32 --ioengine=libaio --direct=1 --rw=randread --bs=4k --iodepth=32 --numjobs=1 --size=1G --runtime=60 --time_based --group_reporting --output-format=json
sudo fio --name=randwrite-4k-qd1 --ioengine=libaio --direct=1 --rw=randwrite --bs=4k --iodepth=1 --numjobs=1 --size=1G --runtime=60 --time_based --group_reporting --output-format=json
sudo fio --name=randwrite-4k-qd32 --ioengine=libaio --direct=1 --rw=randwrite --bs=4k --iodepth=32 --numjobs=1 --size=1G --runtime=60 --time_based --group_reporting --output-format=json
sudo fio --name=seqread-1m-qd32 --ioengine=libaio --direct=1 --rw=read --bs=1m --iodepth=32 --numjobs=1 --size=4G --runtime=60 --time_based --group_reporting --output-format=json
sudo fio --name=seqwrite-1m-qd32 --ioengine=libaio --direct=1 --rw=write --bs=1m --iodepth=32 --numjobs=1 --size=4G --runtime=60 --time_based --group_reporting --output-format=json
sudo fio --name=mixed-rw-4k-qd32 --ioengine=libaio --direct=1 --rw=randrw --rwmixread=70 --bs=4k --iodepth=32 --numjobs=1 --size=1G --runtime=60 --time_based --group_reporting --output-format=json
```

### 検証コマンド

```bash
linstor storage-pool list              # striped-pool が lvm ドライバで正常
lvs -o +stripes,stripe_size linstor_vg # 4本ストライプ, 64KiB
drbdadm status                         # Connected, UpToDate/UpToDate
```
