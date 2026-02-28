# LINSTOR LVM RAID 運用上の懸念事項レポート

- **実施日時**: 2026年2月28日 01:03
- **Issue**: #26 (実験), #27 (スキル改善)

## 前提・目的

### 背景

2026-02-27 実施の LINSTOR LVM RAID10 ディスク障害実験 (Issue #26) において、ディスク交換時の physical block size 不一致、カーネルバグ、SCSI デバイス名変動など、実運用時に問題となりうる複数の懸念事項が発見された。

### 目的

実験で得られた知見を整理し、ディスク交換・RAID リビルド・ノード rejoin 等の日常運用シナリオにおける影響を分析する。運用手順に組み込むべき対処方針をまとめる。

### 前提条件

- 2ノード LINSTOR/DRBD クラスタ (Proxmox VE 9.1.6)
- 各ノードに 4本の SATA HDD、異なる physical block size が混在
- LVM RAID10 (`--type raid10 -i 2 -m 1`) の使用を想定

## 環境情報

### ハードウェア

| 項目 | 4号機 (ayase-web-service-4) | 5号機 (ayase-web-service-5) |
|------|---------------------------|---------------------------|
| マザーボード | Supermicro X11DPU | Supermicro X11DPU |
| OS ディスク | SK hynix NVMe 119.2G | SK hynix NVMe 119.2G |
| sda | ST3500418AS 465.8G (**phy: 512B**) | (**phy: 4096B**) |
| sdb | SAMSUNG HD502HJ 465.8G (**phy: 512B**) | (**phy: 512B**) |
| sdc | ST500DM002 465.8G (**phy: 4096B**) | (**phy: 4096B**) |
| sdd | WDC WD5000AAKS 465.8G (**phy: 512B**) | (**phy: 4096B**) |

### ソフトウェア

- OS: Debian 13.3 (Trixie)
- カーネル: 6.17.9-1-pve
- Proxmox VE: 9.1.6
- LINSTOR Controller: 1.33.1
- LVM: dm-raid v1.15.1, segtypes raid10

## 懸念事項

### 3.1 ディスク交換時の physical block size 不一致

#### 問題

LINSTOR は VG の最初の PV の physical block size を `StorDriver/internal/minIoSize` として使用する。ノード間で minIoSize が異なると、DRBD リソース作成時に `incompatible minimum I/O size` エラーが発生し、rejoin が失敗する。

#### 実例

| ノード | VG 先頭 PV | physical block size | LINSTOR minIoSize |
|--------|-----------|--------------------|--------------------|
| 4号機 | sda | 512B | 512 |
| 5号機 | sda | 4096B | 4096 |

4号機は sda (512B) が VG の先頭 PV のため minIoSize=512、5号機は sda (4096B) が先頭のため minIoSize=4096 となり、不一致が発生。

#### 影響範囲

- ノード rejoin 時のリソース自動配置
- 手動リソース作成
- ディスク交換後の VG 再構成

#### 重要な制約

physical block size はドライブのファームウェアで固定されており、変更できない。現代の環境では 512e (512B logical / 4096B physical) と 4Kn (4096B/4096B) のディスクが混在することが一般的であり、交換用ディスクの block size が元のディスクと一致する保証はない。

#### 回避策

VG 作成時に 512B block size のディスクを先頭に配置する:

```sh
# 各ディスクの physical block size を確認
blockdev --getpbsz /dev/sd{a,b,c,d}

# 512B のディスクを先頭にして VG を作成
vgcreate linstor_vg /dev/sdb /dev/sda /dev/sdc /dev/sdd
```

512B を先頭に置く理由: minIoSize=512 は minIoSize=4096 のノードと互換性がある（4096 は 512 の倍数）が、逆は成り立たない場合がある。

#### 推奨

- ディスク交換前に `blockdev --getpbsz` で交換ディスクの block size を確認する
- VG 再作成時は必ず 512B block size のディスクを先頭に配置する
- 両ノードの minIoSize を `linstor storage-pool list-properties <node> <pool>` で定期的に確認する

### 3.2 カーネル dm-raid raid10 ホットリビルドバグ

#### 問題

`lvchange --refresh` による RAID10 のホットリビルド (稼働中のリビルド) 時に、カーネルバグが発生する:

```
kernel BUG at drivers/md/raid10.c:3454!
CPU: 14 UID: 0 PID: 592548 Comm: mdX_resync
Tainted: P OE 6.17.9-1-pve #1
RIP: 0010:raid10_sync_request+0x1299/0x2380 [raid10]
```

#### 影響

- リカバリスレッド (`mdX_resync`) がクラッシュ
- リビルドが途中 (実測 6.25%) で停止
- `lvconvert --repair` も D state (uninterruptible sleep) でハング
- **データへの影響はなし** — データ読み書きは正常に継続

#### 再現条件

- カーネル: 6.17.9-1-pve
- 操作: SCSI デバイス削除 → 復帰 → `lvchange --refresh` でホットリビルド
- コールドリビルド (再起動後の自動リビルド) では再現しない

#### 回復方法

```sh
# サーバを IPMI リセットで再起動
ipmitool -I lanplus -H $BMC_IP -U claude -P Claude123 chassis power reset

# 再起動後、RAID リビルドが自動的に再開される
# 進捗確認:
lvs -a -o name,raid_sync_action,copy_percent linstor_vg
```

再起動後のリビルド所要時間: 32G LV で約3分 (9.38% → 100%)。

#### 推奨

- **LVM RAID10 のホットリビルドは避ける** — ディスク復旧後は計画停止 → 再起動 → コールドリビルドを推奨
- カーネルアップデートで修正される可能性があるため、PVE カーネルのリリースノートを継続的に確認する
- ホットリビルドが必要な場合は、事前にデータの冗長コピーがあることを確認する

### 3.3 SCSI 再スキャン時のデバイス名変動

#### 問題

SCSI バスリスキャンでディスクを復帰させた際、元のデバイス名とは異なるデバイス名で再認識されることがある:

```sh
# sdd を削除
echo 1 > /sys/block/sdd/device/delete

# 復帰 — sdd ではなく sde として認識される
echo "- - -" > /sys/class/scsi_host/host9/scan
# kernel: scsi 9:0:0:0: Direct-Access ATA WDC WD5000AAKS
# kernel: sd 9:0:0:0: [sde] ...
```

#### LVM への影響

**影響なし**。LVM は PV UUID でディスクを管理するため、デバイス名の変更は透過的に処理される。`vgscan` や `pvscan` で自動的に新しいデバイス名が認識される。

#### 運用スクリプトへの影響

デバイス名 (`/dev/sdX`) をハードコードしたスクリプトは破綻する。例:

- SCSI ホスト番号の特定 (`/sys/block/sdX/device` パス)
- 障害エミュレーション用のデバイス削除コマンド
- パーティション操作スクリプト

#### 推奨

- デバイス名ではなく `/dev/disk/by-id/` パスまたは PV UUID を使用する
- スクリプトで SCSI ホスト番号が必要な場合は、実行時に動的に解決する:
  ```sh
  # 安定したパス
  ls -l /dev/disk/by-id/ | grep sdX
  # PV UUID
  pvs -o pv_name,pv_uuid
  ```

### 3.4 DRBD の LVM RAID デグレード透過性 (監視の盲点)

#### 問題

LVM RAID がデグレード (1ディスク障害) しても、DRBD は `UpToDate` ステータスのまま変化しない。DRBD 監視だけでは LVM RAID レイヤの障害を検知できない。

#### 実例

```
# ディスク障害発生後
# DRBD ステータス — 障害を検知できない:
drbdadm status
# → disk:UpToDate peer-disk:UpToDate

# LVM ステータス — ここにのみ情報が出る:
lvs -o lv_name,lv_attr
# → lv_attr の5文字目が 'p' (partial) → デグレード
```

#### 影響

DRBD 監視だけに依存している場合、以下のシナリオでデータ喪失リスクがある:

1. LVM RAID デグレード (1ディスク障害) — DRBD は UpToDate のまま
2. さらに同じミラーペアの残りディスクが障害 — LVM RAID が完全に破損
3. DRBD レベルでは「突然のディスク障害」として検知される

#### 推奨

LVM RAID 使用時は以下の監視を追加する:

```sh
# LV の partial フラグを監視 (5文字目が 'p' ならデグレード)
lvs -o lv_attr --noheadings linstor_vg | grep -c 'p'

# md デバイスの状態を監視
cat /proc/mdstat | grep -E '\[.*_.*\]'   # '_' はデグレードを示す
```

### 3.5 RAID10 の容量・性能トレードオフ

#### 容量への影響

| 構成 | ディスク数 | 生容量 | 有効容量 | 容量減 |
|------|-----------|--------|----------|--------|
| Stripe (RAID0) | 4 x 465.8G | 1.82 TiB | 1.82 TiB | 0% |
| RAID10 | 4 x 465.8G | 1.82 TiB | ~910 GiB | 50% |

#### 性能への影響

| 状態 | 書き込み速度 (dd urandom 512M oflag=direct) |
|------|------|
| RAID10 正常 | 32.6 MB/s |
| RAID10 デグレード | 33.3 MB/s |
| RAID10 リビルド後 | 33.2 MB/s |

`dd if=/dev/urandom` は CPU での乱数生成がボトルネックとなるため、ストレージ性能差が見えにくい。fio による詳細なベンチマーク比較は未実施。

#### 推奨

- 常時 RAID10 は容量 50% 減が大きく、2ノード DRBD レプリケーションがある通常運用では過剰
- **1ノード縮退時のみ RAID10 に動的切り替え**が現実的:
  1. 計画メンテナンスで1ノードを離脱
  2. 残存ノードで `StorDriver/LvcreateOptions` を RAID10 に変更
  3. メンテナンス完了後、ノード復帰時に stripe に戻す

## 運用シナリオ別の対処方針

| シナリオ | 対処 | 参照 |
|---------|------|------|
| 同一 block size のディスクに交換 | VG に PV として追加し、RAID リビルド | §3.1 |
| 異なる block size のディスクに交換 | VG の PV 順序に注意して再構成 (512B ディスクを先頭に) | §3.1 |
| 1ノード縮退中のディスク障害 | RAID10 ならデグレード継続可能、stripe ならデータ喪失 | §3.5 |
| ホットリビルド失敗 (カーネルバグ) | サーバ再起動 → コールドリビルドで回復 | §3.2 |
| ノード rejoin 時の minIoSize 不一致 | VG 再作成で 512B PV を先頭に配置 | §3.1 |
| SCSI 再スキャン後のデバイス名変動 | LVM は PV UUID で対応、スクリプトは by-id パスを使用 | §3.3 |
| LVM RAID デグレードの検知 | `lvs -o lv_attr` の partial フラグまたは `/proc/mdstat` を監視 | §3.4 |

## 推奨事項まとめ

1. **VG 作成時は 512B block size のディスクを先頭に配置する** — minIoSize 不一致によるリソース作成失敗を防止
2. **LVM RAID10 のホットリビルドは避ける** — カーネルバグ (6.17.9-1-pve) のリスクあり。計画停止→コールドリビルドを推奨
3. **デバイス名をハードコードしない** — SCSI 再スキャンで変動するため `/dev/disk/by-id/` や PV UUID を使用
4. **LVM RAID 使用時は DRBD 監視に加えて LVM 監視も実施する** — DRBD は RAID デグレードを検知しない
5. **RAID10 は1ノード縮退時のみ使用を検討する** — 通常運用では容量 50% 減が許容しがたい

Issue #27 にて linstor-node-ops スキルの rejoin 手順に minIoSize 回避策を追記済み。

## 参考レポート

- [LINSTOR LVM RAID10 ディスク障害実験レポート](2026-02-27_203200_linstor_lvm_raid10_disk_failure_experiment.md) — 本レポートの元となった実験結果
