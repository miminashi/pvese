# LINSTOR LVM RAID10 ディスク障害実験レポート

- **実施日時**: 2026年2月27日 17:00〜20:30
- **所要時間**: 約3.5時間
- **Issue**: #26

## 前提・目的

### 背景

現在の LINSTOR 構成は LVM ストライプ (`-i4 -I64`, RAID0) で、ディスク冗長性がない。2ノード運用時は DRBD がノード間レプリケーションを提供するが、1ノードに縮退した場合はディスク1本の障害でデータ全損になる。

### 目的

1. LINSTOR の `StorDriver/LvcreateOptions` で LVM RAID10 (`--type raid10 -i 2 -m 1`) を使用し、1ノード内でのディスク冗長性を実現する
2. SCSI デバイス削除によるディスク障害エミュレーションで耐障害性を検証する
3. 障害中のデータ読み書き可用性を確認する
4. ディスク復旧後の RAID リビルド動作を確認する

### 前提条件

- 2ノード LINSTOR/DRBD クラスタが稼働中
- 各ノードに 4本の SATA HDD (sda〜sdd)
- OS ディスクは NVMe (SATA デバイスの動的削除に影響なし)

## 環境情報

### ハードウェア

| 項目 | 4号機 (ayase-web-service-4) |
|------|---------------------------|
| マザーボード | Supermicro X11DPU |
| OS ディスク | SK hynix NVMe 119.2G |
| sda | ST3500418AS 465.8G (phy: 512B) |
| sdb | SAMSUNG HD502HJ 465.8G (phy: 512B) |
| sdc | ST500DM002 465.8G (phy: 4096B) |
| sdd | WDC WD5000AAKS 465.8G (phy: 512B) |

### ソフトウェア

- OS: Debian 13.3 (Trixie)
- カーネル: 6.17.9-1-pve
- Proxmox VE: 9.1.6
- LINSTOR Controller: 1.33.1
- DRBD: dm-raid v1.15.1, LVM segtypes raid10

### SCSI ホスト番号マッピング

| デバイス | SCSI パス | ホスト番号 |
|---------|-----------|-----------|
| sda | ata7/host6 | host6 |
| sdb | ata8/host7 | host7 |
| sdc | ata9/host8 | host8 |
| sdd | ata10/host9 | host9 |

## RAID10 構成

### LVM RAID10 レイアウト

```
lvcreate --type raid10 -i 2 -m 1
```

- 4ディスク: 2ストライプ × 2ミラー
- rimage_0 (sda) + rimage_1 (sdb) → ストライプ1ミラーペア
- rimage_2 (sdc) + rimage_3 (sdd) → ストライプ2ミラーペア

各 rimage は独立した LV として管理され、rmeta (メタデータ) も各ディスクに配置。

### LINSTOR 設定

```sh
linstor storage-pool create lvm ayase-web-service-4 raid10-pool linstor_vg
linstor storage-pool set-property ayase-web-service-4 raid10-pool StorDriver/LvcreateOptions -- '--type raid10 -i 2 -m 1'
linstor resource-group create pve-rg --place-count 1 --storage-pool raid10-pool
linstor resource-group drbd-options --quorum off pve-rg
linstor resource-group drbd-options --auto-promote yes pve-rg
```

## 実験結果

### ディスク障害エミュレーション (Phase 4)

**障害方法**: SCSI デバイスの動的削除

```sh
echo 1 > /sys/block/sdd/device/delete
```

**結果**:
- sdd が即座に消失
- カーネルログ: `md/raid10:mdX: Disk failure on dm-9, disabling device. Operation continuing on 3 devices.`
- LVM: rimage_3 と rmeta_3 が `[unknown]` に、LV attr に `p` (partial) フラグ
- DRBD: UpToDate のまま (LVM RAID のデグレードは DRBD レベルでは透過的)
- **VM は中断なく稼働を継続**

### 障害中のデータ可用性 (Phase 5)

| 検証項目 | 結果 |
|---------|------|
| 既存データ読み取り (md5sum -c) | OK |
| 新規データ書き込み (512M) | OK (33.3 MB/s) |
| 書き込み後チェックサム | OK |
| DRBD ステータス | UpToDate |

### 書き込み性能比較

| 状態 | 書き込み速度 (dd urandom 512M oflag=direct) |
|------|------|
| RAID10 正常 | 32.6 MB/s |
| RAID10 デグレード (1ディスク障害) | 33.3 MB/s |
| RAID10 リビルド後 | 33.2 MB/s |

デグレード状態でも性能低下はほぼなし。`dd if=/dev/urandom` の CPU 律速のため、ストレージ性能差が見えにくい可能性あり。

### ディスク復旧 + RAID リビルド (Phase 6)

**復旧方法**: SCSI バスリスキャン

```sh
echo "- - -" > /sys/class/scsi_host/host9/scan
```

**問題発生**: ディスクが `/dev/sde` として再認識 (SCSI 再スキャンの一般的動作)。LVM は PV UUID でディスクを認識するため、デバイス名の変更は透過的に処理された。

**カーネルバグ発見**:

```
kernel BUG at drivers/md/raid10.c:3454!
CPU: 14 UID: 0 PID: 592548 Comm: mdX_resync
Tainted: P OE 6.17.9-1-pve #1
RIP: 0010:raid10_sync_request+0x1299/0x2380 [raid10]
```

- `lvchange --refresh` で RAID リビルドを開始した直後に発生
- リカバリスレッド (`mdX_resync`) がクラッシュ
- リビルドが 6.25% で停止
- lvconvert --repair も D state (uninterruptible sleep) でハング
- **データアクセスは正常に継続** (リビルドだけが停止)

**回復方法**: サーバを IPMI リセットで再起動

- 再起動後、RAID リビルドが自動再開
- 再起動後のリビルドではカーネルバグは再発せず
- 32G LV のリビルド: 約3分で完了 (9.38% → 100%)

### LINSTOR minIoSize 不一致問題 (Phase 8)

5号機 rejoin 時に `incompatible minimum I/O size` エラーが発生。

**原因**:
- 4号機: sda=512B, sdb=512B, sdc=4096B, sdd=512B → LINSTOR minIoSize=512
- 5号機: sda=4096B, sdb=512B, sdc=4096B, sdd=4096B → LINSTOR minIoSize=4096

LINSTOR は VG の最初の PV の physical block size を minIoSize として使用。4号機は sda(512B)が先頭、5号機は sda(4096B)が先頭のため不一致。

**回避策**: 5号機の VG を sdb (512B) を先頭にして再作成

```sh
vgcreate linstor_vg /dev/sdb /dev/sda /dev/sdc /dev/sdd
```

これにより LINSTOR の minIoSize が 512 になり、リソース作成が成功。

## 発見事項のまとめ

### 成功点

1. **LVM RAID10 + DRBD は機能する**: LINSTOR の `StorDriver/LvcreateOptions` で RAID10 を指定可能
2. **障害耐性が実証された**: 1ディスク障害中もデータ読み書き可能、VM は中断なし
3. **DRBD は透過的**: LVM RAID のデグレードは DRBD レベルでは見えない (UpToDate のまま)
4. **性能低下なし**: デグレード状態でも書き込み性能はほぼ同等

### 問題点

1. **カーネルバグ (6.17.9-1-pve)**: `raid10.c:3454` で BUG — ホットリビルド時にリカバリスレッドがクラッシュ。コールドリビルド (再起動後) では発生せず
2. **SCSI 再スキャンでデバイス名が変わる**: `/dev/sdd` が `/dev/sde` になるケースあり。LVM は PV UUID で対応するが、スクリプトはデバイス名に依存しないよう注意
3. **LINSTOR minIoSize チェック**: 異なる physical block size のディスクを持つノード間で VG の PV 順序により minIoSize が異なると rejoin が失敗する
4. **RAID10 は容量50%減**: 4ディスク 1.82 TiB → 有効容量 ~910 GiB

### 推奨事項

- **本番環境では LVM RAID10 は使用しない**: カーネルバグのリスクがある。DRBD 2ノードレプリケーションで十分
- **1ノード縮退運用時のみ検討**: 計画的メンテナンスでノードを一時的に1台にする場合、残存ノードに RAID10 を使えば冗長性を維持可能
- **カーネルバージョンに注意**: 6.17.9-1-pve の dm-raid raid10 リカバリにバグあり。アップデートで修正される可能性

## 再現方法

### ディスク障害エミュレーション

```sh
readlink -f /sys/block/sdd/device     # SCSI パス確認 → hostN
echo 1 > /sys/block/sdd/device/delete  # ディスク「故障」
```

### ディスク復帰

```sh
echo "- - -" > /sys/class/scsi_host/hostN/scan  # hostN は上記で確認した番号
```

### RAID リビルド

```sh
lvchange --refresh linstor_vg/<lv_name>  # リビルドトリガー
lvs -a -o name,raid_sync_action,copy_percent linstor_vg  # 進捗確認
```

## 参考レポート

- 過去のベンチマークレポート (LINSTOR thick-stripe 構成)
