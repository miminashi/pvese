# 8-9号機ディスク交換後の健全性再調査

- 作業日時: 2026-03-30 00:15 JST
- 対象: 8号機・9号機 (Dell PowerEdge R320, PERC H710 Mini)
- 前回調査: [2026-03-29 7-9号機ディスク健全性調査](2026-03-29_091500_server789_disk_health.md)

## 目的

前回調査で交換推奨した 8号機 Bay 3 および 9号機 Bay 2 のディスク交換後、新ディスクの健全性と RAID 認識状態を確認する。

## 調査方法

1. `smartctl -d megaraid,N /dev/sda` で PERC H710 パススルー経由の SMART データ取得
2. `racadm storage get pdisks` で iDRAC 経由の物理ディスク状態取得
3. `racadm storage get vdisks` で RAID VD 構成確認

## 結果サマリ

交換ディスクは両方とも **Blocked 解消、SMART 正常、grown defect 0**。VD は未作成 (Ready 状態)。

### 交換前後の比較

| サーバ | Bay | 交換前 (03-29) | 交換後 (03-30) |
|--------|-----|---------------|---------------|
| 8号機 | Bay 3 | **Blocked** (NETAPP X423, INQUIRY failed) | **Ready** (837.75 GB, SMART OK, defect 0) |
| 9号機 | Bay 2 | **Blocked** (STOR062, INQUIRY failed) | **Ready** (837.75 GB, SMART OK, defect 0) |

## 全ディスク詳細

### 8号機 (7 台、6 Online + 1 Ready)

| Bay | Size | VD | State | 稼働時間 | Grown Defects | SMART | 変更 |
|-----|------|----|-------|---------|---------------|-------|------|
| 0 | 558.38 GB | VD0 (RAID-1) | Online | 44,377h | 0 | OK | |
| 1 | 558.38 GB | VD0 (RAID-1) | Online | 53,892h | 0 | OK | |
| 2 | 837.75 GB | VD1 (RAID-0) | Online | 7,367h | 0 | OK | |
| **3** | **837.75 GB** | **なし** | **Ready** | **65,780h** | **0** | **OK** | **交換済** |
| 4 | 837.75 GB | VD2 (RAID-0) | Online | 65,451h | 0 | OK | |
| 5 | 837.75 GB | VD3 (RAID-0) | Online | 7,652h | 0 | OK | |
| 6 | 837.75 GB | VD4 (RAID-0) | Online | 65,336h | 0 | OK | |
| 7 | (空) | — | — | — | — | — | |

### 9号機 (7 台、6 Online + 1 Ready)

| Bay | Size | VD | State | 稼働時間 | Grown Defects | SMART | 変更 |
|-----|------|----|-------|---------|---------------|-------|------|
| 0 | 558.38 GB | VD0 (RAID-1) | Online | 52,891h | 0 | OK | |
| 1 | 558.38 GB | VD0 (RAID-1) | Online | 50,117h | 0 | OK | |
| **2** | **837.75 GB** | **なし** | **Ready** | **65,078h** | **0** | **OK** | **交換済** |
| 3 | 837.75 GB | VD1 (RAID-0) | Online | 65,101h | 0 | OK | |
| 4 | 837.75 GB | VD2 (RAID-0) | Online | 65,683h | 0 | OK | |
| 5 | 837.75 GB | VD3 (RAID-0) | Online | 65,749h | 0 | OK | |
| 6 | 837.75 GB | VD4 (RAID-0) | Online | 65,338h | 0 | OK | |
| 7 | (空) | — | — | — | — | — | |

### RAID VD 構成 (8号機・9号機共通)

| VD | Layout | Size | State | 用途 |
|----|--------|------|-------|------|
| VD0 | RAID-1 | 558.38 GB | Online | OS (/dev/sda) |
| VD1 | RAID-0 | 837.75 GB | Online | ストレージ |
| VD2 | RAID-0 | 837.75 GB | Online | ストレージ |
| VD3 | RAID-0 | 837.75 GB | Online | ストレージ |
| VD4 | RAID-0 | 837.75 GB | Online | ストレージ |

## 次のアクション

### 交換ディスクの VD 作成が必要

交換ディスクは Ready 状態 (PERC に認識済み、VD 未割当)。LINSTOR ストレージとして使用するには RAID-0 VD を作成する必要がある:

- 8号機 Bay 3: `racadm raid createvd:RAID.Integrated.1-1 -rl r0 -pdkey:Disk.Bay.3:Enclosure.Internal.0-1:RAID.Integrated.1-1`
- 9号機 Bay 2: `racadm raid createvd:RAID.Integrated.1-1 -rl r0 -pdkey:Disk.Bay.2:Enclosure.Internal.0-1:RAID.Integrated.1-1`

VD 作成後、LINSTOR config を 3台→4台 (`-i3 -I64` → `-i4 -I64`) に更新できる。

### 残存リスク (前回調査から継続)

| サーバ | Bay | 状態 | Grown Defects | 稼働時間 | 備考 |
|--------|-----|------|---------------|---------|------|
| 7号機 | Bay 0 | Online | 8 | 60,358h (6.9年) | OS RAID-1 ペア |
| 7号機 | Bay 1 | Online | 15 | 76,765h (8.8年) | OS RAID-1 ペア |

7号機の OS ディスクペアは grown defect が増加傾向。予防交換を引き続き推奨する。
