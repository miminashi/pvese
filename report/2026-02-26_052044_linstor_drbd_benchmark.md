# LINSTOR/DRBD 分散ストレージ構築 + VM ベンチマークレポート

- **実施日時**: 2026年2月26日 03:30 〜 05:20
- **実施者**: Claude Code セッション 8ad53f64

## 前提・目的

Proxmox VE 9 上に LINSTOR/DRBD 分散ストレージを構築し、SATA HDD ベースのミラーリングストレージ上で VM の I/O 性能を計測する。

- **背景**: pvese プロジェクトで分散ストレージ (Ceph, GlusterFS, LINSTOR 等) の比較評価を行っている。本レポートは LINSTOR/DRBD の初回構築・ベンチマーク結果をまとめる
- **目的**: 2ノード LINSTOR クラスタを構築し、DRBD Protocol C (同期レプリケーション) over IPoIB で VM ディスク I/O の IOPS・スループット・レイテンシを計測する
- **前提条件**: 2台の PVE ノード (server 4/5) が管理ネットワーク + InfiniBand ネットワークで接続済み。各ノードに 500GB SATA HDD が 4本ずつ搭載

## 環境情報

| 項目 | 詳細 |
|------|------|
| **Server 4** | 10.10.10.204 / IB: 192.168.100.1 (Supermicro X11DPU) |
| **Server 5** | 10.10.10.205 / IB: 192.168.100.2 (Supermicro X11DPU) |
| **OS** | Debian 13.3 (Trixie) |
| **PVE** | Proxmox VE 9.1.6 (pve-manager 9.1.6/71482d1833ded40a) |
| **カーネル** | 6.17.9-1-pve |
| **DRBD** | 9.3.0 (drbd-dkms 9.3.0-1, drbd-utils 9.33.0-1) |
| **LINSTOR** | Controller/Satellite 1.33.1-1, Client 1.27.1-1 |
| **linstor-proxmox** | 8.2.0-1 |
| **IB** | Mellanox ConnectX-3 QDR 40 Gbps (IPoIB Connected Mode) |
| **ストレージ HDD** | 各ノード 4 x 500GB SATA HDD (約 1.86 TB raw / ノード) |
| **ストレージプール** | LVM thin pool (`linstor_vg/thinpool`, 1.73 TiB / ノード) |
| **DRBD 設定** | Protocol C (同期), quorum=off, auto-promote=yes, PrefNic=ib0 |
| **レプリケーション** | place-count=2 (両ノードに完全ミラー) |
| **ベンチ VM** | 4 vCPU (host passthrough), 4 GB RAM, 32 GB disk on LINSTOR |
| **VM OS** | Debian 13 cloud image (kernel 6.12.73+deb13-amd64) |
| **fio** | 3.39 |

## 構築手順

### Phase 1: PVE クラスタ構成

```bash
# Server 4 でクラスタ作成
pvecm create pvese-cluster --link0 10.10.10.204

# Server 5 を参加 (expect + fingerprint で非対話実行)
pvecm add 10.10.10.204 --link0 10.10.10.205 --force \
  --fingerprint <server4-pve-ssl-fingerprint>

# 2ノードクォーラム対策 (corosync.conf で two_node: 1 を設定)
```

### Phase 2: LINSTOR/DRBD インストール

```bash
# LINBIT 公開リポジトリ追加 (両ノード)
wget -O /tmp/linbit-keyring.deb https://packages.linbit.com/public/linbit-keyring.deb
dpkg -i /tmp/linbit-keyring.deb
echo 'deb [signed-by=/etc/apt/trusted.gpg.d/linbit-keyring.gpg] http://packages.linbit.com/public/ proxmox-9 drbd-9' \
  > /etc/apt/sources.list.d/linbit.list
apt-get update

# インストール (両ノード)
apt-get install -y proxmox-default-headers drbd-dkms drbd-utils
apt-get install -y linstor-satellite linstor-client linstor-proxmox

# Server 4 のみ controller も追加
apt-get install -y linstor-controller

# サービス起動
systemctl enable --now linstor-controller  # Server 4 のみ
systemctl enable --now linstor-satellite   # 両ノード
```

### Phase 3: LINSTOR ストレージ構成

```bash
# LINSTOR ノード登録
linstor node create ayase-web-service-4 10.10.10.204 --node-type Combined
linstor node create ayase-web-service-5 10.10.10.205 --node-type Satellite

# IB インターフェース登録 + PrefNic 設定
linstor node interface create ayase-web-service-4 ib0 192.168.100.1
linstor node interface create ayase-web-service-5 ib0 192.168.100.2
linstor node set-property ayase-web-service-4 PrefNic ib0
linstor node set-property ayase-web-service-5 PrefNic ib0

# LVM thin pool 作成 (各ノード)
wipefs -af /dev/sd{a,b,c,d}
pvcreate /dev/sd{a,b,c,d}
vgcreate linstor_vg /dev/sd{a,b,c,d}
lvcreate -l 95%FREE -T linstor_vg/thinpool

# LINSTOR ストレージプール
linstor storage-pool create lvmthin ayase-web-service-4 thinpool linstor_vg/thinpool
linstor storage-pool create lvmthin ayase-web-service-5 thinpool linstor_vg/thinpool

# リソースグループ + DRBD オプション
linstor resource-group create pve-rg --place-count 2 --storage-pool thinpool
linstor volume-group create pve-rg
linstor resource-group drbd-options --protocol C pve-rg
linstor resource-group drbd-options --quorum off pve-rg
linstor resource-group drbd-options --auto-promote yes pve-rg

# PVE ストレージ追加
pvesm add drbd linstor-storage --resourcegroup pve-rg --content images,rootdir --controller 10.10.10.204
```

### Phase 4: VM 作成 + ベンチマーク

```bash
# Debian cloud image インポート
qm create 100 --name bench-vm --memory 4096 --cores 4 --cpu host \
  --net0 virtio,bridge=vmbr1 --ostype l26 --scsihw virtio-scsi-single
qm importdisk 100 /path/to/debian-13-generic-amd64.qcow2 linstor-storage
qm set 100 --scsi0 linstor-storage:<disk-id>,discard=on,iothread=1
qm set 100 --boot order=scsi0
qm resize 100 scsi0 32G
qm set 100 --ide2 linstor-storage:cloudinit
qm set 100 --ciuser debian --cipassword password --ipconfig0 ip=dhcp

# VM 内で fio 実行 (各テスト 60 秒)
fio --name=<test> --ioengine=libaio --direct=1 --bs=<bs> --rw=<pattern> \
  --size=1G --numjobs=1 --iodepth=<qd> --runtime=60 --time_based \
  --group_reporting --output-format=json
```

## ベンチマーク結果

### サマリーテーブル

| テスト | BS | パターン | QD | IOPS | スループット (KiB/s) | 平均レイテンシ (ms) | p99 レイテンシ (ms) |
|--------|------|----------|------|------|---------------------|--------------------|--------------------|
| 4K Random Read | 4K | randread | 1 | **132** | 529 | 7.52 | 12.3 |
| 4K Random Read | 4K | randread | 32 | **270** | 1,080 | 118.4 | 683.7 |
| 4K Random Write | 4K | randwrite | 1 | **26** | 104 | 38.1 | 198.2 |
| 4K Random Write | 4K | randwrite | 32 | **33** | 131 | 975.0 | 3,338.7 |
| 1M Seq Read | 1M | read | 32 | 133 | **135,694** (132.5 MiB/s) | 241.4 | 299.9 |
| 1M Seq Write | 1M | write | 32 | 13 | **13,164** (12.9 MiB/s) | 2,481.1 | 4,177.5 |
| Mixed R/W 70/30 | 4K | randrw | 32 | R: 103 / W: 45 | R: 412 / W: 180 | R: 267.8 / W: 97.1 | R: 1,853.9 / W: 1,803.6 |

### 分析

#### ランダム Read 性能
- **QD1: 132 IOPS** (7.5 ms avg latency) — SATA HDD の典型的な単発ランダム読み取り性能。回転待ち + シーク時間が支配的
- **QD32: 270 IOPS** (118 ms avg latency) — QD を上げても IOPS は 2 倍程度。HDD のメカニカルな限界が見える。DRBD レプリケーションのオーバーヘッドは読み取りでは軽微

#### ランダム Write 性能
- **QD1: 26 IOPS** (38 ms avg latency) — DRBD Protocol C の同期書き込みコスト。ローカル HDD 書き込み + IB 経由でリモートノードに同期書き込みが完了するまでレイテンシが増加
- **QD32: 33 IOPS** (975 ms avg latency) — キュー深度を上げても IOPS はほぼ横ばい。p99 が 3.3 秒と高く、HDD の書き込みキュー飽和 + DRBD 同期待ちが顕著

#### シーケンシャル性能
- **Read: 132.5 MiB/s** — 4 本の HDD ストライプ相当の速度。LVM thin pool 上の単一 LV だが、DRBD のローカル読み取りで HDD の物理帯域に近い値
- **Write: 12.9 MiB/s** — シーケンシャル書き込みも DRBD 同期書き込みのボトルネック。平均レイテンシ 2.5 秒は 1 MB ブロックをローカル + リモートに同期書き込みするコスト

#### Mixed R/W 性能
- Read 103 IOPS / Write 45 IOPS — 書き込みが混在すると全体的にレイテンシが悪化。p99 が約 1.8 秒と高い

### ボトルネック分析

1. **SATA HDD のメカニカル性能**: 500GB 7200RPM SATA HDD のランダム IOPS は単体 80-120 程度。LVM thin pool 上で 4 本を束ねているが、thin LV は通常ストライピングしないため単一ディスクの性能に制約される
2. **DRBD Protocol C の同期書き込みペナルティ**: 書き込みは必ず両ノードでの永続化完了を待つため、ローカル書き込みの 2-3 倍のレイテンシ
3. **IB ネットワークは余裕あり**: 40 Gbps QDR に対して HDD のスループットは最大 132 MiB/s (約 1 Gbps) でネットワークはボトルネックではない

## 検証結果

| チェック項目 | 結果 |
|-------------|------|
| `pvecm status` — クラスタ正常 | OK (2 nodes, Quorate, two_node mode) |
| `linstor node list` — 両ノード Online | OK (ayase-web-service-4: COMBINED, ayase-web-service-5: SATELLITE) |
| `linstor storage-pool list` — プール正常 | OK (thinpool: 1.73 TiB / node, State: Ok) |
| `drbdadm status` — Connected, UpToDate | OK (Primary/UpToDate ↔ Secondary/UpToDate) |
| `pvesm status` — linstor-storage 表示 | OK (linstor-storage: drbd, active, 1.73 TiB) |
| VM 起動成功 | OK (VM 100 on LINSTOR storage, booted with cloud-init) |
| fio 全 7 テスト完了 | OK |

## 改善の方向性

- **SSD への移行**: SATA HDD → NVMe SSD に変更すれば IOPS は 100-1000 倍、レイテンシは 1/100 に改善が見込まれる
- **DRBD Protocol A (非同期)**: レイテンシを削減できるがデータ安全性のトレードオフ
- **RDMA トランスポート**: `drbd_transport_rdma` モジュールがビルド済み。IPoIB TCP → RDMA に変更することでネットワークレイテンシをさらに削減可能 (ただし HDD がボトルネックの現状では効果は限定的)
- **LVM ストライピング**: thin pool ではなく通常の LV で 4 本ストライプにすればシーケンシャル性能が向上する可能性

## 構成ファイル

| ファイル | 説明 |
|----------|------|
| `config/linstor.yml` | LINSTOR 設定値 (ノード情報, ストレージプール, リソースグループ) |
| `tmp/8ad53f64/fio-results/*.json` | fio JSON 結果ファイル (7 テスト分) |
