# LINSTOR ディスク冗長性実験: RAID5 以外の方法

## Context

前回の実験 (report/2026-03-22_120534) で PERC H710 ハードウェア RAID5 による耐障害性を実証済み。しかし racadm 経由のディスク操作は毎回再起動が必要で運用性が低い。ソフトウェアベースの代替手段を調査・実験する。

過去の知見:
- **LVM RAID10** (`--type raid10`): kernel bug `raid10.c:3454` で**ホットリビルド時にクラッシュ** (6.17.9-1-pve)。コールドリビルドは成功。
- **HW RAID5**: 動作するが forceoffline/forceonline に毎回再起動必要。

## 実験対象

| アプローチ | カーネルモジュール | raid10.c バグの影響 | ホット操作 |
|-----------|------------------|-------------------|----------|
| **A: mdadm RAID1** | md/raid1.c | なし (別コード) | 可能 |
| **B: LVM RAID1** (`--type raid1`) | dm-raid/raid1.c | 低 (raid1 人格) | 可能 |
| **C: LVM mirror** (`--type mirror`) | dm-mirror | なし (別サブシステム) | 可能 |

B が失敗した場合 C にフォールバック。A と B/C を pve8, pve9 で並行テスト。

## 実験手順

### Phase 0: PERC VD 再構成 (RAID-5 → 個別 RAID-0)

現在 pve8/pve9 は RAID-5 VD。個別 RAID-0 VD に戻す (OS には個別ディスクとして見える)。

1. LINSTOR リソース・SP・VG 削除
2. racadm で RAID-5 VD 削除 → ジョブ＋再起動
3. racadm で Bay ごとに個別 RAID-0 VD 作成 → ジョブ＋再起動
   - pve8: Bay 2, 4, 5 → VD1, VD2, VD3 (Bay 3 は Ready/未使用)
   - pve9: Bay 3, 4, 5 → VD1, VD2, VD3 (Bay 2 は Blocked)
4. OS 起動後 `lsblk` で sdb, sdc, sdd を確認

**2台並行実施** (各 ~20分, 2回の再起動サイクル)

### Phase 1: mdadm RAID1 テスト (pve8)

#### セットアップ
1. mdadm RAID1 作成 (2台ミラー + 1台ホットスペア):
   ```
   mdadm --create /dev/md0 --level=1 --raid-devices=2 --spare-devices=1 /dev/sdb /dev/sdc /dev/sdd
   ```
2. 初期 sync 待機 (`/proc/mdstat`, ~30-60分)
3. `/etc/mdadm/mdadm.conf` に保存 + `update-initramfs -u`
4. LVM: `pvcreate /dev/md0 && vgcreate linstor_vg /dev/md0`
5. LINSTOR ストレージプール作成 (LvcreateOptions なし)
6. テストリソース作成 (10 GiB)
7. テストデータ書き込み + md5sum 記録

#### ディスク障害テスト (ホット)
1. `echo 1 > /sys/block/sdc/device/delete` でディスク「故障」
2. `/proc/mdstat` でデグレード確認
3. ホットスペア (sdd) が自動リビルド開始を確認
4. DRBD UpToDate + md5sum 完全一致を確認
5. デグレード中の書き込みテスト

#### ディスク復旧 (ホット)
1. SCSI rescan: `echo "- - -" > /sys/class/scsi_host/hostN/scan`
2. `mdadm /dev/md0 --add /dev/sdX` で再追加
3. リビルド完了確認
4. **kernel bug が発生しないことを確認** (raid10.c バグは別コード)

### Phase 2: LVM RAID1 テスト (pve9)

#### セットアップ
1. LVM PV/VG: `pvcreate /dev/sd{b,c,d} && vgcreate linstor_vg /dev/sd{b,c,d}`
2. LINSTOR ストレージプール + LvcreateOptions:
   ```
   linstor storage-pool set-property ... StorDriver/LvcreateOptions -- '--type raid1 -m 1'
   ```
3. テストリソース作成 → `lvs -a` で raid1 レイアウト確認
4. テストデータ書き込み + md5sum 記録

#### ディスク障害テスト (ホット)
1. `echo 1 > /sys/block/sdc/device/delete`
2. `lvs -o lv_attr` で partial ('p') フラグ確認
3. DRBD UpToDate + md5sum 確認

#### ディスク復旧 + ホットリビルド
1. SCSI rescan
2. `lvchange --refresh` でリビルド開始
3. **raid1.c でカーネルバグが発生しないことを確認** (raid10.c とは別の人格)
4. バグ発生時: `--type mirror -m 1` (dm-mirror) にフォールバック

### Phase 3: スケールアップ/ダウン + 同時障害テスト

成功したアプローチで:
1. 2ノード運用 → レプリカ追加 → DRBD sync
2. ノード障害 (電源断) + ディスク障害 (SCSI delete) 同時テスト
3. スケールダウン (レプリカ削除 → 電源断)

### Phase 4: レポート作成

前回 RAID5 実験との比較表を含むレポート。

## 検証基準

1. ホットディスク障害でデータ生存 (md5sum 一致)
2. ホットリビルドが kernel bug なしで完了
3. スケールアップ/ダウンが動作
4. ノード障害 + ディスク障害同時でデータ生存

## 変更対象

- PERC H710 VD 構成 (RAID-5 → 個別 RAID-0)
- pve8: mdadm RAID1 + LVM + LINSTOR SP
- pve9: LVM RAID1 + LINSTOR SP (LvcreateOptions)
- `report/` — 実験レポート
