# Region B RAID再構成 + OS再セットアップ

- **実施日時**: 2026年4月1日 08:30 JST (開始) - 09:49 JST (完了)
- **所要時間**: 約80分

## 添付ファイル

- [実装プラン](attachment/2026-04-01_004941_region_b_raid_os_setup/plan.md)

## 前提・目的

ユーザが7-9号機 (Dell PowerEdge R320, Region B) の物理ディスクを交換・追加した。
既存の RAID VD を全削除し、新しい物理ディスク構成に合わせて RAID を再構成し、
Debian 13 + Proxmox VE 9 を再インストールする。

## 環境情報

### サーバ構成

| サーバ | BMC IP | 静的 IP | RAID コントローラ |
|--------|--------|---------|------------------|
| 7号機 | 10.10.10.27 (iDRAC) | 10.10.10.207 | PERC H710 Mini |
| 8号機 | 10.10.10.28 (iDRAC) | 10.10.10.208 | PERC H710 Mini |
| 9号機 | 10.10.10.29 (iDRAC) | 10.10.10.209 | PERC H710 Mini |

### 物理ディスク構成 (変更後)

**7号機** (8 disks):

| Bay | Size | Vendor | State |
|-----|------|--------|-------|
| 0 | 278.88 GB | - | Ready |
| 1 | 278.88 GB | - | Ready |
| 2-7 | 837.75 GB each | - | Ready |

**8号機** (8 disks):

| Bay | Size | Vendor | State |
|-----|------|--------|-------|
| 0 | 273.00 GB | SEAGATE | **Blocked** (PERC H710 非互換) |
| 1 | 273.00 GB | SEAGATE | **Blocked** (PERC H710 非互換) |
| 2 | 837.75 GB | HITACHI | Ready |
| 3 | 837.75 GB | SEAGATE | Ready (以前の Blocked NETAPP から交換) |
| 4-6 | 837.75 GB each | SEAGATE/HITACHI | Ready |
| 7 | 837.75 GB | SEAGATE | Ready (新規追加) |

**9号機** (8 disks): 8号機と同様の構成。Bay 0-1 は 273GB Blocked。

### VD 構成 (再構成後)

**7号機**: VD0 (RAID-1, Bay 0-1, 278GB, system) + VD1-6 (6x RAID-0, Bay 2-7, data0-data5)

**8号機・9号機**: Bay 0-1 が Blocked のため Bay 2-7 のみ使用
- VD0 (RAID-1, Bay 2-3, 837GB, system) + VD1-4 (4x RAID-0, Bay 4-7, data0-data3)

## 再現方法

### RAID 再構成

```sh
# 1. 全 VD 削除
ssh -F ssh/config idrac7 racadm raid deletevd:Disk.Virtual.0:RAID.Integrated.1-1
# ... (VD1-6 も同様)

# 2. 新 VD 作成
ssh -F ssh/config idrac7 racadm raid createvd:RAID.Integrated.1-1 -rl r1 \
    -pdkey:Disk.Bay.0:Enclosure.Internal.0-1:RAID.Integrated.1-1,Disk.Bay.1:Enclosure.Internal.0-1:RAID.Integrated.1-1 \
    -name system

ssh -F ssh/config idrac7 racadm raid createvd:RAID.Integrated.1-1 -rl r0 \
    -pdkey:Disk.Bay.2:Enclosure.Internal.0-1:RAID.Integrated.1-1 -name data0
# ... (data1-data5 も同様)

# 3. ジョブキュー作成 + パワーサイクル
ssh -F ssh/config idrac7 racadm jobqueue create RAID.Integrated.1-1 -s TIME_NOW -r pwrcycle

# 4. ジョブ完了確認
ssh -F ssh/config idrac7 racadm jobqueue view -i JID_xxxxx
```

### OS セットアップ

os-setup スキルで Phase 4-8 を実行。3台を並行処理。

## 結果

### 最終状態

| サーバ | OS | PVE | Kernel | System Disk | Data Disks |
|--------|-----|-----|--------|-------------|------------|
| 7号機 | Debian 13 | 9.1.6 | 6.17.13-2-pve | sda (278.9GB, RAID-1) | sdb-sdg (6x 837.8GB) |
| 8号機 | Debian 13 | 9.1.6 | 6.17.13-2-pve | sda (837.8GB, RAID-1) | sdb-sde (4x 837.8GB) |
| 9号機 | Debian 13 | 9.1.6 | 6.17.13-2-pve | sda (837.8GB, RAID-1) | sdb-sde (4x 837.8GB) |

### 設定ファイル更新

- `config/linstor.yml`: storage_disks と lvcreate_options を更新
  - 7号機: sdb-sdg (6 disks), `-i6 -I64`
  - 8号機: sdb-sde (4 disks), `-i4 -I64`
  - 9号機: sdb-sde (4 disks), `-i4 -I64`
- `config/server7.yml`: TBD コメント削除

## 問題と対処

### 1. 8号機・9号機 Bay 0-1 の Blocked ディスク

racadm は VD 削除前に Bay 0-1 を 558GB Online と報告していたが、VNC PERC BIOS 画面では
273GB Blocked と表示されていた。実際には物理ディスクが 558GB から 273GB に交換されており、
新しい 273GB SEAGATE ディスクが PERC H710 と互換性がなく Blocked 状態。

**対処**: Bay 0-1 を使用せず、Bay 2-7 の 837GB ディスクのみで VD を構成。
System は Bay 2-3 で RAID-1 (837GB)、Data は Bay 4-7 で個別 RAID-0。

### 2. 9号機 RAID ジョブ失敗 (PR21)

最初の VD 作成時に Bay 0-1 (273GB Blocked) を含めて RAID-1 を作成したところ、
ジョブ実行時に PR21 (Job failed) で失敗。

**対処**: `racadm jobqueue delete --all` + `racadm serveraction powercycle` で
pending config をクリアし、Bay 2-7 のみで再作成して成功。

### 3. 8号機 LC 長時間使用中 (JCP024)

8号機の VD 削除ジョブが "Lifecycle Controller in use" で10分以上待機。

**対処**: `racadm serveraction powercycle` で LC をリセットし、ジョブが実行開始。
