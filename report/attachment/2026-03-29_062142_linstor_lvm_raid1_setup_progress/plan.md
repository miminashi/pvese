# 7,8,9号機 ディスク増設 → HW RAID1 OS + LVM RAID1 LINSTOR セットアップ + ベンチマーク

## Context

7,8,9号機 (DELL PowerEdge R320, PERC H710 Mini) に物理ディスクを増設済み。以下を実施する:

1. ディスク健全性チェック → 正常にアクセスできないディスクはローレベルフォーマット
2. 300GB or 600GB × 2本 → PERC H710 RAID-1 → OS (Debian 13 + PVE 9)
3. 残りの 900GB ディスク → LINSTOR ストレージ (LVM RAID1 `--type raid1 -m 1`)
4. 過去と同じ fio ベンチマーク実施

## Phase 1: ディスク検出・健全性チェック

各サーバに SSH して現在のディスク構成を確認する。

```
対象: pve7 (10.10.10.207), pve8 (10.10.10.208), pve9 (10.10.10.209)
```

### 1-1. racadm でディスク一覧取得

```sh
ssh -F ssh/config idrac7 racadm raid get pdisks -o -p State,Size,MediaType,BusProtocol,SerialNumber
ssh -F ssh/config idrac8 racadm raid get pdisks -o -p State,Size,MediaType,BusProtocol,SerialNumber
ssh -F ssh/config idrac9 racadm raid get pdisks -o -p State,Size,MediaType,BusProtocol,SerialNumber
```

- 各ディスクの Bay 番号、容量、状態 (Online/Ready/Blocked/Failed) を記録
- 現在の VD 構成も確認: `racadm raid get vdisks`

### 1-2. OS 上での確認 (SSH 接続可能な場合)

```sh
ssh -F ssh/config pveN lsblk -d -o NAME,SIZE,MODEL,SERIAL,STATE
ssh -F ssh/config pveN smartctl -a /dev/sdX   # 各ディスクごと
```

- SMART の `Reallocated_Sector_Ct`, `Current_Pending_Sector`, `Offline_Uncorrectable` を確認
- `blockdev --getpbsz /dev/sdX` で physical block size を確認

### 1-3. 障害ディスクの対処

- **State=Blocked/Failed**: racadm でクリアを試みる
  ```sh
  ssh -F ssh/config idracN racadm raid clearconfig:RAID.Integrated.1-1
  ```
- **SMART 異常**: `sg_format --format /dev/sdX` でローレベルフォーマット、または `dd if=/dev/zero of=/dev/sdX bs=1M status=progress` でゼロフィル
- フォーマット後に再度 SMART チェック

## Phase 2: PERC H710 RAID 構成

### 2-1. 既存 VD 削除

```sh
ssh -F ssh/config idracN racadm raid deletevd:Disk.Virtual.X:RAID.Integrated.1-1
ssh -F ssh/config idracN racadm jobqueue create RAID.Integrated.1-1 -r pwrcycle -s TIME_NOW -e TIME_NA
```

- **注意**: VD 削除と RAID 作成は別バッチで実行（同一バッチだと失敗する既知問題）
- 各ジョブの完了に 5-10 分かかる

### 2-2. RAID-1 (OS用) 作成

300GB or 600GB の同サイズディスク 2本を使用:

```sh
ssh -F ssh/config idracN racadm raid createvd:RAID.Integrated.1-1 -rl r1 \
  -pdkey:Disk.Bay.X:Enclosure.Internal.0-1:RAID.Integrated.1-1,Disk.Bay.Y:Enclosure.Internal.0-1:RAID.Integrated.1-1 \
  -name system
```

### 2-3. 残りの 900GB ディスクは個別 RAID-0 または JBOD

LINSTOR ストレージ用の 900GB ディスクは、PERC H710 上で個別の RAID-0 VD として作成（JBOD 非対応の場合）:

```sh
ssh -F ssh/config idracN racadm raid createvd:RAID.Integrated.1-1 -rl r0 \
  -pdkey:Disk.Bay.Z:Enclosure.Internal.0-1:RAID.Integrated.1-1 \
  -name data-N
```

### 2-4. ジョブ適用・再起動

```sh
ssh -F ssh/config idracN racadm jobqueue create RAID.Integrated.1-1 -r pwrcycle -s TIME_NOW -e TIME_NA
```

- PERC H710 "Missing VDs" プロンプト対策: SOL 経由で Enter 定期送信
- 各ジョブ完了後に `racadm raid get vdisks` で VD 構成を確認

## Phase 3: OS セットアップ (Debian 13 + PVE 9)

`os-setup` スキルを使用。3台順次または並列にセットアップ。

### 主要ステップ

1. preseed 生成 (`./scripts/generate-preseed.sh config/serverN.yml`)
2. ISO リマスター (`--serial-unit=0`)
3. iDRAC VirtualMedia マウント + boot-once VCD-DVD
4. Debian preseed インストール (~10-12 分)
5. post-install: SSH 鍵設定、静的 IP 設定
6. PVE インストール (~20-30 分)
7. PVE クラスタ構築 (region-b)

### 注意事項

- `config/serverN.yml` の `disk:` を RAID-1 VD のデバイスパス (`/dev/sda`) に更新する必要がある場合あり
- BootMode: Legacy BIOS (現状維持、前回の UEFI 切替済みならそのまま)
- PERC Missing VDs プロンプト: SOL Enter 送信で通過

## Phase 4: LINSTOR セットアップ (LVM RAID1)

### 4-1. LINBIT リポジトリ + パッケージ

```sh
# drbd-dkms, linstor-satellite, linstor-proxmox 等
# gcc も必要 (DKMS ビルド)
```

### 4-2. LVM VG 作成

900GB ディスク（RAID-0 VD 経由で見えるブロックデバイス）を全部1つの VG に:

```sh
pvcreate /dev/sdb /dev/sdc /dev/sdd ...
vgcreate linstor_vg /dev/sdb /dev/sdc /dev/sdd ...
```

- **physical block size の順序に注意**: 512B PV を VG の先頭に配置

### 4-3. LINSTOR ストレージプール (LVM RAID1)

```sh
linstor storage-pool create lvm <node> striped-pool linstor_vg
linstor storage-pool set-property <node> striped-pool \
  StorDriver/LvcreateOptions -- '--type raid1 -m 1'
```

- **今回の変更点**: 従来の `-i4 -I64`（ストライプ）ではなく `--type raid1 -m 1`
- ディスク本数が 3, 4, 5 本でも同じ LvcreateOptions で動作

### 4-4. リソースグループ + PVE ストレージ

```sh
# リソースグループ (既存 pve-rg-b を再利用 or 再作成)
linstor resource-group create pve-rg-b --place-count 2 --storage-pool striped-pool
linstor resource-group drbd-options --protocol C pve-rg-b
linstor resource-group drbd-options --quorum off pve-rg-b
linstor resource-group drbd-options --auto-promote yes pve-rg-b

# PVE ストレージ
pvesh create /storage --storage linstor-storage-b --type drbd --redundancy 2
```

### 4-5. IPoIB セットアップ (オプション)

前回 GbE で実施、IB が使えることが判明済み。今回 IB を使う場合:

```sh
modprobe ib_ipoib
ip link set ibp134s0 up  # デバイス名はサーバにより異なる
ip addr add 192.168.101.X/24 dev ibp134s0
```

## Phase 5: ベンチマーク (GbE + IPoIB の2回実施)

`linstor-bench` スキルを使用。過去と同じ fio テスト6種を **2つのネットワーク構成** で実施:

### 5-1. GbE ベンチマーク

DRBD transport を GbE (10.10.10.x) で実施。前回 Region B ベンチマークと同条件。

### 5-2. IPoIB ベンチマーク

DRBD transport を IPoIB (192.168.101.x) に切り替えて再実施。
- `modprobe ib_ipoib` + IP 割当
- LINSTOR ノードインターフェースに ib0 を追加 + PrefNic=ib0
- GbE との性能差を定量化

### fio テスト

| # | テスト名 | rw | bs | iodepth | size |
|---|---------|----|----|---------|------|
| 1 | randread-4k-qd1 | randread | 4k | 1 | 1G |
| 2 | randread-4k-qd32 | randread | 4k | 32 | 1G |
| 3 | randwrite-4k-qd1 | randwrite | 4k | 1 | 1G |
| 4 | randwrite-4k-qd32 | randwrite | 4k | 32 | 1G |
| 5 | seqread-1m-qd32 | read | 1m | 32 | 4G |
| 6 | seqwrite-1m-qd32 | write | 1m | 32 | 4G |

VM 構成: 4 vCPU, 4 GiB RAM, 32 GiB DRBD ディスク, Debian 13 cloud image

各テストを **3回** 実施し、中央値を採用する。結果のばらつき（最小・最大）もレポートに記載する。

### 比較対象 (3方向比較)

| 構成 | Transport | ストレージ |
|------|-----------|-----------|
| 今回 GbE | GbE (1Gbps) | LVM RAID1 |
| 今回 IPoIB | IPoIB (PCIe x4 制約で ~16Gbps) | LVM RAID1 |
| 過去 Region B (2026-03-19) | GbE | thick-stripe (-i3) |
| 過去 Region A (2026-02-26) | IPoIB (FDR10 56Gbps) | thick-stripe (-i4) |

## Phase 6: レポート作成

結果をレポートにまとめる。

### グラフ作成 (matplotlib)

Python matplotlib で以下のグラフを作成し、レポートの添付ファイルに含める:

1. **IOPS 比較棒グラフ**: Random Read/Write (4K QD1, QD32) — GbE vs IPoIB vs 過去データ
2. **スループット比較棒グラフ**: Sequential Read/Write (1M QD32) — 同上
3. **エラーバー付き**: 3回実施の min/max をエラーバーとして表示

グラフは `report/attachment/<レポート名>/` に PNG で保存し、レポート本文から `![グラフ名](attachment/.../*.png)` でリンクする。

### ディスク構成の記載

Phase 1 で確認した各サーバのディスク構成をレポートの「環境情報」セクションに記載する:
- 各 Bay のディスク型番、容量、インターフェース (SAS/SATA)、状態
- PERC H710 VD 構成 (RAID-1 OS + データ VD)
- ローレベルフォーマットを実施した場合はその対象ディスクと結果
- LVM VG 構成 (PV 一覧、physical block size)

### プランファイル添付

REPORT.md ルールに従い、プランファイル (`calm-waddling-stallman.md`) を `report/attachment/<レポート名>/plan.md` にコピーし、レポート本文の「添付ファイル」セクションからリンクする。

## 主要ファイル

| ファイル | 用途 |
|---------|------|
| `config/server7.yml`, `server8.yml`, `server9.yml` | サーバ設定 |
| `config/linstor.yml` | LINSTOR 構成定義 |
| `.claude/skills/os-setup/SKILL.md` | OS セットアップスキル |
| `.claude/skills/linstor-bench/SKILL.md` | ベンチマークスキル |
| `.claude/skills/idrac7/SKILL.md` | iDRAC7 操作スキル |
| `scripts/idrac-virtualmedia.sh` | VirtualMedia 操作 |
| `scripts/generate-preseed.sh` | preseed 生成 |

## 検証方法

1. `racadm raid get vdisks` で VD 構成を確認 (RAID-1 + RAID-0 or JBOD)
2. `ssh -F ssh/config pveN lsblk` で OS とデータディスクを確認
3. `pvecm status` で PVE クラスタ状態を確認
4. `linstor storage-pool list` でストレージプール確認
5. `linstor storage-pool list-properties <node> striped-pool` で LvcreateOptions 確認
6. fio ベンチマーク結果を過去データと比較
