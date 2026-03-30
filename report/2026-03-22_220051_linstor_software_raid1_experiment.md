# LINSTOR ソフトウェア RAID1 耐障害性実験レポート

- **実施日時**: 2026年3月23日 04:00〜10:40 (JST)
- **所要時間**: 約6.5時間 (mdadm sync 待ち + LVM RAID1 同時障害テスト追加含む)
- **対象サーバ**: 8号機 (pve8, mdadm RAID1), 9号機 (pve9, LVM RAID1)

## 添付ファイル

- [実装プラン](attachment/2026-03-22_220051_linstor_software_raid1_experiment/plan.md)

## 前提・目的

### 背景

前回実験 (report/2026-03-22_120534) で PERC H710 ハードウェア RAID5 による耐障害性を実証したが、racadm 経由のディスク操作は毎回再起動が必要で運用性が低い。また、過去の LVM RAID10 実験 (report/2026-02-27_203200) では kernel bug (raid10.c:3454) が発見され、ホットリビルドが不可能だった。

### 目的

1. **再起動なし**でディスク障害検知・復旧可能なソフトウェア RAID 方式を検証
2. mdadm RAID1 と LVM RAID1 (`--type raid1`) の2方式を比較
3. raid10.c kernel bug が raid1 人格にも影響するか確認
4. ノード障害 + ディスク障害の同時耐性を実証

### 参照レポート

- [LINSTOR RAID5 実験](2026-03-22_120534_linstor_raid5_resilience_experiment.md) — HW RAID5 ベースライン
- [LVM RAID10 実験](2026-02-27_203200_linstor_lvm_raid10_disk_failure_experiment.md) — kernel bug 発見

## 環境情報

### ハードウェア

| 項目 | pve8 | pve9 |
|------|------|------|
| サーバ | DELL PowerEdge R320 | DELL PowerEdge R320 |
| PERC | H710 Mini (FW 21.3.0-0009) | H710 Mini (FW 21.3.0-0009) |
| OS VD | VD0: RAID-1 (Bay 0+1) | VD0: RAID-1 (Bay 0+1) |
| Data VD | VD1-3: 個別 RAID-0 (Bay 2,4,5) | VD1-3: 個別 RAID-0 (Bay 3,4,5) |
| データディスク | sdb, sdc, sdd (各 837.8 GiB) | sdb, sdc, sdd (各 837.8 GiB) |

### ソフトウェア

- OS: Debian 13.3 (Trixie) + Proxmox VE 9.1.6
- カーネル: 6.17.13-2-pve
- mdadm: 4.4-11
- LINSTOR Controller: pve4 (10.10.10.204)

## 実験結果

### アプローチ A: mdadm RAID1 (pve8)

#### セットアップ

```
mdadm --create /dev/md0 --level=1 --raid-devices=2 --spare-devices=1 /dev/sdb /dev/sdc /dev/sdd
```

- ミラー: sdb + sdc (2ディスク)
- ホットスペア: sdd
- 容量: 837.62 GiB (1ディスク分)
- 初期 sync 時間: **約85分** (837 GiB @ 170 MB/s)

#### ディスク障害テスト

| ステップ | 操作 | 結果 |
|---------|------|------|
| 1 | `echo 1 > /sys/block/sdc/device/delete` | sdc が faulty、アレイ [U_] |
| 2 | ホットスペア自動起動 | sdd が自動リビルド開始 |
| 3 | DRBD 状態 | **UpToDate** |
| 4 | md5sum 検証 | `0a0cc90e60430e6bd9d7ed66c75b387d` — **完全一致** |
| 5 | 再起動 | **不要** |

#### 重要な発見: リビルド中の脆弱性

リビルド進行中 (28%) に追加のディスク障害テストを行ったところ、**I/O エラーが発生**。mdadm RAID1 のリビルド中はミラーメンバーが1つしかないため、そのメンバーが障害するとデータ全損する。

**教訓**: 障害テストは必ず**リビルド完了後の正常状態**で実施すること。

### アプローチ B: LVM RAID1 (pve9)

#### セットアップ

```
pvcreate /dev/sdb /dev/sdc /dev/sdd
vgcreate linstor_vg /dev/sdb /dev/sdc /dev/sdd
linstor storage-pool set-property ... StorDriver/LvcreateOptions -- '--type raid1 -m 1'
```

- LINSTOR が自動的に LVM RAID1 LV を作成 (rimage_0 on sdb, rimage_1 on sdc)
- 容量: 837.62 GiB (1ディスク分、3PV 中 2PV 使用)

#### ディスク障害テスト

| ステップ | 操作 | 結果 |
|---------|------|------|
| 1 | `echo 1 > /sys/block/sdc/device/delete` | LV に `p` (partial) フラグ |
| 2 | DRBD 状態 | **UpToDate** |
| 3 | md5sum 検証 | `2ede211840101e919e55e46d020ae420` — **完全一致** |
| 4 | 再起動 | **不要** |

#### ホットリビルドテスト (kernel bug 検証)

| ステップ | 操作 | 結果 |
|---------|------|------|
| 1 | SCSI rescan | ディスクが sde として再認識 |
| 2 | `pvscan --cache` | LVM が PV を検出、partial 解消 |
| 3 | `lvchange --refresh` | リビルド開始 (recover 0%) |
| 4 | **kernel bug** | **発生せず** (raid1.c は raid10.c とは別コード) |
| 5 | md5sum 検証 | **完全一致** |

### ノード障害 + ディスク障害同時テスト (pve8, mdadm RAID1)

| ステップ | 操作 | 結果 |
|---------|------|------|
| 1 | 2ノード運用 (pve8 + pve9) | 両方 UpToDate |
| 2 | pve9 電源断 (ノード障害) | pve8 Connecting (pve9) |
| 3 | pve8 sdd SCSI 削除 (ディスク障害) | mdadm [_U]、sde でサービス継続 |
| 4 | ホットスペア scc が自動リビルド開始 | recovery 0.2% |
| 5 | DRBD 状態 | **UpToDate** |
| 6 | md5sum 検証 | `08f4fa7ad05cde4cf66e5706785169e8` — **完全一致** |
| 7 | 再起動 | **不要** |

### ノード障害 + ディスク障害同時テスト (pve9, LVM RAID1)

| ステップ | 操作 | 結果 |
|---------|------|------|
| 1 | 2ノード運用 (pve8 + pve9, test-lvmraid1-v2) | 両方 UpToDate |
| 2 | pve8 電源断 (ノード障害) | pve9 Connecting (pve8) |
| 3 | pve9 sdb SCSI 削除 (ディスク障害) | LV に `p` (partial) フラグ、rimage_1 で継続 |
| 4 | DRBD 状態 | **UpToDate** |
| 5 | md5sum 検証 | `a72c9938ad94cff4ea14d43f01075427` — **完全一致** |
| 6 | 再起動 | **不要** |

## 方式比較

### mdadm RAID1 vs LVM RAID1 vs HW RAID5

| 項目 | mdadm RAID1 | LVM RAID1 | HW RAID5 (前回) |
|------|-------------|-----------|----------------|
| カーネルモジュール | md/raid1.c | dm-raid/raid1.c | PERC H710 FW |
| raid10.c bug 影響 | なし | なし | なし |
| ホットディスク障害 | SCSI delete で即検知 | SCSI delete で即検知 | racadm + **再起動必要** |
| ホットリビルド | `mdadm --add` | `lvchange --refresh` | racadm + **再起動必要** |
| ホットスペア | 自動起動 | なし (手動 refresh) | なし |
| LINSTOR 統合 | 手動 (mdadm 層が別) | **透過的** (LvcreateOptions) | 透過的 (単一 VD) |
| 容量 (3ディスク) | 838 GiB + spare | 838 GiB (3rd PV 予備) | 1.63 TiB (RAID5) |
| 初期 sync | ~85分 (837 GiB) | 不要 (COW) | 不要 (HW) |
| 起動時の自動構成 | mdadm.conf 必要 | LVM が自動管理 | PERC FW が管理 |
| 同時障害耐性 | **実証済み** | **実証済み** | **実証済み** |

### 推奨

**LVM RAID1** が最も実用的:
- LINSTOR と透過的に統合 (LvcreateOptions のみ)
- ホットディスク障害・リビルドが動作
- kernel bug (raid10.c) の影響なし
- mdadm 層が不要 (構成がシンプル)
- 起動時の自動構成が LVM に任せられる
- **ノード障害 + ディスク障害の同時耐性を実証済み**

**mdadm RAID1** はホットスペアの自動起動が利点だが、別レイヤーの管理が必要。同時障害耐性も実証済みだが、LINSTOR 統合の面で LVM RAID1 に劣る。

**HW RAID5** は容量効率が最も高い (1.63 TiB vs 838 GiB) が、全ディスク操作に再起動が必要で運用性が低い。

## 運用上の注意

1. **SCSI rescan 後のデバイス名変動**: sdc → sde のように変わる。LVM/mdadm は UUID で管理するため実害はないが、スクリプトでデバイス名をハードコードしないこと
2. **リビルド中の脆弱性**: RAID1 リビルド中はミラーメンバーが1つ。追加障害でデータ全損。リビルド完了まで追加操作は避ける
3. **mdadm 初期 sync**: 837 GiB で約85分。この間もデータ読み書きは可能だが性能低下あり
4. **Bay 3 (server 8)**: STOR062 エラーで VD 作成不可。ディスクに問題がある可能性

## 再現方法

### mdadm RAID1 セットアップ

```sh
# PERC RAID-0 VD が個別に作成済みであること
apt-get install -y mdadm
mdadm --create /dev/md0 --level=1 --raid-devices=2 --spare-devices=1 /dev/sdb /dev/sdc /dev/sdd --run
mdadm --detail --scan >> /etc/mdadm/mdadm.conf
update-initramfs -u
pvcreate /dev/md0
vgcreate linstor_vg /dev/md0
linstor storage-pool create lvm <node> striped-pool linstor_vg
```

### LVM RAID1 セットアップ

```sh
pvcreate /dev/sdb /dev/sdc /dev/sdd
vgcreate linstor_vg /dev/sdb /dev/sdc /dev/sdd
linstor storage-pool create lvm <node> striped-pool linstor_vg
linstor storage-pool set-property <node> striped-pool StorDriver/LvcreateOptions -- '--type raid1 -m 1'
```

### ディスク障害シミュレーション

```sh
# 障害
echo 1 > /sys/block/sdc/device/delete
# 復旧 (SCSI rescan)
echo "- - -" > /sys/class/scsi_host/host0/scan
# LVM RAID1 リビルド
pvscan --cache
lvchange --refresh linstor_vg/<lv_name>
```
