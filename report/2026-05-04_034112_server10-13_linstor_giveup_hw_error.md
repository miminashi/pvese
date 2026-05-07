# 10-13号機 LINSTOR セットアップ — データ HDD Hardware Error によりギブアップ

- **実施日時**: 2026年5月3日 23:47 〜 5月4日 03:41 JST (約 4 時間)
- **Issue**: #61
- **結果**: ⚠️ **ギブアップ** — データ HDD への書き込みが Hardware Error (Sense Key 0x4, vendor ASC=0x81) で全 8 本ブロックされ、ZFS pool 作成およびベンチマークが実行不能。PVE クラスタと LINSTOR クラスタは構築完了済み。

## 添付ファイル

- [実装プラン](attachment/2026-05-04_034112_server10-13_linstor_giveup_hw_error/plan.md)
- [pve12 sdb sg_format ログ](attachment/2026-05-04_034112_server10-13_linstor_giveup_hw_error/pve12_sg_format_sdb.log)
- [pve13 sdb sg_format ログ](attachment/2026-05-04_034112_server10-13_linstor_giveup_hw_error/pve13_sg_format_sdb.log)
- [pve12 dmesg HW error 抜粋](attachment/2026-05-04_034112_server10-13_linstor_giveup_hw_error/pve12_dmesg_hw_error.log)

## 前提・目的

10-13号機 (Supermicro X10DRT-P / Nutanix OEM Twin Server) にデータ HDD (Seagate DKS5x-J1R2SS 1.2 TB × 2) を装着完了したため、これら 4 台で独立した PVE クラスタ + LINSTOR クラスタを構築し fio ベンチマークが完走することを確認する。4-9号機との連携は将来計画。

- **背景**: ストレージ棚卸し ([2026-05-03 レポート](2026-05-03_224709_server10-13_storage_inventory.md)) で 10/11号機の sdb/sdc は 512B セクタで「即利用可」、12/13号機は 520B (T10-PI) で `sg_format` が必要と判定済み
- **目的**: 4 ノード LINSTOR クラスタ (ZFS stripe + DRBD place_count=2) を構築しベンチマーク完走
- **ユーザ指示**: 「先に 12/13 を sg_format してから 4 ノード全員参加」「完了したら/ギブアップしたらシャットダウン」

## 環境情報

| 項目 | 10号機 | 11号機 | 12号機 | 13号機 |
|------|--------|--------|--------|--------|
| ホスト | ayase-web-service-10 | -11 | -12 | -13 |
| 静的 IP | 10.10.10.210 | 10.10.10.211 | 10.10.10.212 | 10.10.10.213 |
| OS | Debian 13.3 + PVE 9.1.9 | 同左 | 同左 | 同左 |
| カーネル | 7.0.0-3-pve | 同左 | 同左 | 同左 |
| OEM モデル | NX-1065-G5 | NX-3060-G5 | NX-3060-G5 | NX-3060-G5 |
| データ HBA | Broadcom/LSI SAS3008 (`mpt3sas`) | 同左 | 同左 | 同左 |
| データ HDD | Seagate DKS5H-J1R2SS 1.2 TB ×2 | DKS5L/DKS5H ×2 | DKS5H ×2 | DKS5H ×2 |

ソフトウェア (構築完了分):

| パッケージ | バージョン | 状態 |
|-----------|-----------|------|
| drbd-dkms | 9.3.2-1 | 全 4 ノードで modprobe 済 |
| linstor-controller | 1.33.2-1 | pve10 で active |
| linstor-satellite | 1.33.2-1 | 全 4 ノードで active |
| linstor-client / linstor-proxmox | 1.33.2-1 | 全 4 ノードに導入 |
| zfsutils-linux | 2.4.1-pve1 | 全 4 ノード (PVE 標準) |

## 実施した作業 (完了分)

### Phase 1: PVE クラスタ構築 ✅

```
Cluster: pvese-cluster-c (新規)
Quorate: Yes (4/4 nodes, expected_votes=4, quorum=3)
Nodes: 10.10.10.210 (master) / 10.10.10.211 / 10.10.10.212 / 10.10.10.213
```

実施手順:
1. 全ノードに root SSH 鍵 (id_rsa) を相互配信、known_hosts 整備
2. `pvecm create pvese-cluster-c --link0 10.10.10.210` を pve10 で実行
3. `pvecm add 10.10.10.210 --link0 10.10.10.21X --use_ssh` を pve11/12/13 で順次実行

### Phase 2: LINSTOR + DRBD インストール ✅

LINBIT 公式リポジトリ (`http://packages.linbit.com/public/ proxmox-9 drbd-9`) を追加し、`drbd-dkms 9.3.2`, `linstor-satellite 1.33.2`, `linstor-client`, `linstor-proxmox`, `gcc`, `proxmox-headers-7.0.0-3-pve` を全 4 ノードに導入。pve10 のみ `linstor-controller` 追加。ZFS ARC を 4 GiB に制限 (`zfs_arc_max=4294967296`)。systemctl で satellite/controller 起動。

### Phase 4.1: LINSTOR ノード登録 ✅

```
+-----------------------------------------------------------------------+
| Node                 | NodeType  | Addresses                 | State  |
|=======================================================================|
| ayase-web-service-10 | COMBINED  | 10.10.10.210:3366 (PLAIN) | Online |
| ayase-web-service-11 | SATELLITE | 10.10.10.211:3366 (PLAIN) | Online |
| ayase-web-service-12 | SATELLITE | 10.10.10.212:3366 (PLAIN) | Online |
| ayase-web-service-13 | SATELLITE | 10.10.10.213:3366 (PLAIN) | Online |
+-----------------------------------------------------------------------+
```

各ノードで `Supported storage providers: [diskless, lvm, lvm_thin, zfs, zfs_thin, file, file_thin, ...]` を確認。`DfltDisklessStorPool` のみ自動登録、ZFS の物理プールは未作成。

### Phase 0: 12/13号機 sg_format ✅

```
sg_format --format --size=512 /dev/sdb (and /dev/sdc) を pve12/13 で並列 4 実行
開始: 2026-05-03 23:54
終了: 2026-05-04 03:26-03:27 (約 3h32m)
結果: 全 4 ディスクが 1.2 TB / 512B セクタで Linux 認識成功
```

事前: pve12/13 sdb/sdc は 520B (Nutanix T10-PI) で `lsblk` 上 0B 表示 → 不可
事後: 1200243695616 bytes (1144641.6 MiB, 1.20 TB) を Logical block 512B で認識

### Phase 5.0: 設定変更 ✅

`config/linstor.yml` の `benchmark.vm_mgmt_ip` を `10.10.10.210` から `10.10.10.250` に変更 (10号機本体 IP との衝突回避)。pve10 へ Debian 13 cloud image, vendor snippet (`/var/lib/vz/snippets/ssh-pwauth.yml`), Ed25519 公開鍵を配置済み。

## ⚠️ 失敗した作業 (ZFS pool 作成 / ベンチマーク)

### 症状

`zpool create linstor_zpool sdb sdc` が以下のエラーで失敗:

```
cannot label 'sdb': try using parted(8) and then provide a specific slice: -2
Error preparing/labeling disk.
```

直接 `dd if=/dev/zero of=/dev/sdb bs=1M count=10 oflag=direct` でも:

```
dd: error writing '/dev/sdb': Remote I/O error
```

カーネルログ (dmesg):

```
sd 0:0:1:0: [sdb] tag#1736 FAILED Result: hostbyte=DID_OK driverbyte=DRIVER_OK cmd_age=0s
sd 0:0:1:0: [sdb] tag#1736 Sense Key : Hardware Error [current]
sd 0:0:1:0: [sdb] tag#1736 <<vendor>>ASC=0x81 ASCQ=0x0
sd 0:0:1:0: [sdb] tag#1736 CDB: Write(10) 2a 00 00 00 00 00 00 04 00 00
critical target error, dev sdb, sector 0 op 0x1:(WRITE) flags 0xc800 phys_seg 128 prio class 2
```

### 影響範囲

| ノード | sdb | sdc | sg_format 実施 |
|-------|-----|-----|---------------|
| pve10 | NG (write fail) | NG | 未実施 (元から 512B) |
| pve11 | NG | NG | 未実施 (元から 512B) |
| pve12 | NG | NG | 実施完了 (520→512 B) |
| pve13 | NG | NG | 実施完了 (520→512 B) |

**全 8 ディスクで全く同じ症状** (ASC=0x81, Hardware Error)。読み出し (read) は 80 MB/s 程度で正常動作するが、**書き込み (write) のみ即時拒否**される。

### 原因切り分け (実施した検査)

切り分けに使用したコマンドと結果:

| 検査 | コマンド | 結果 |
|------|---------|------|
| SMART ヘルス | `smartctl -a` | **OK** (Grown defects 0, Reassigned 0) |
| 容量・セクタサイズ | `sg_readcap --long` | 1.20 TB / 512 B / **prot_en=0** (T10-PI 無効) |
| Mode page WP bit | `sg_modes --page=0x01` | **WP=0** (write protect 無効) |
| Persistent Reservation | `sg_persist --in --read-keys` | **NO registered keys** (無し) |
| SAS link state | `sg_logs --page=0x18` | "loss of dword synchronization" (発生後の二次症状か) |
| 読み出し | `dd if=/dev/sdc of=/dev/null bs=4k count=10` | **成功** (81.7 MB/s) |
| 書き込み (オフセット 0) | `dd if=/dev/zero of=/dev/sdc bs=512 count=1 oflag=direct` | **NG** (Remote I/O error) |
| 書き込み (オフセット 1M) | `dd if=/dev/zero of=/dev/sdb bs=512 count=1 seek=1000000 oflag=direct` | **NG** (Remote I/O error) |
| sg_start cycle | `sg_start --stop; sleep 5; sg_start --start` | 効果なし |
| sg_format (520B→512B) | `sg_format --format --size=512` (pve12/13 sdb/sdc) | フォーマット成功するが **書き込み不可は変わらず** |

OS ディスク (sda, Intel C610 sSATA 経由) への書き込みは正常に動作するため、HBA 全体の問題ではなく **LSI SAS3008 配下の Seagate DKS5x SAS HDD に固有の問題**。

### 推測される原因 (未確定)

`Sense Key 0x4 (Hardware Error)` + `vendor-specific ASC=0x81` の組み合わせは Seagate エンタープライズ SAS HDD で以下の状態を示すことがある:

1. **Nutanix Cluster Lock**: Nutanix CVM が出荷時にディスクへ書き込んだ "shared protection" モード — ノード離脱時に他ノードからの上書きを防ぐためのフラグ。SED/TCG ではなく、より低レベルの SCSI 拡張機能を使用している可能性
2. **NetApp/HUS-IBOD ドライブの書き込み禁止モード**: ドライブが特定のホストイニシエータ ID を期待していて、それ以外の書き込みを拒否
3. **ファームウェア (Rev 7FA9) 固有の保護**: Nutanix OEM 用カスタムファーム

**`sg_format` で初期化しても解除されない**ことが今回判明したのは大きな知見。

## 再現方法 (最小症状再現)

```sh
# 1. 任意の 10-13号機に SSH
ssh -F ssh/config pve12

# 2. 単一書き込みテスト (即時 Remote I/O error)
dd if=/dev/zero of=/dev/sdb bs=512 count=1 oflag=direct

# 3. 期待される dmesg
dmesg -T | grep -E "Hardware Error|ASC=0x81" | tail -5
```

## 構築済み資産 (シャットダウン後も保持)

- PVE クラスタ `pvese-cluster-c` (4 ノード Quorate)
- LINSTOR クラスタ (controller=pve10, satellite=pve10-13, 全 Online)
- DRBD 9.3.2 / LINSTOR 1.33.2 / ZFS 2.4.1 全ノード導入済
- LINBIT リポジトリ設定 (`/etc/apt/sources.list.d/linbit.list`)
- pve10 上に Debian cloud image (`/var/lib/vz/template/debian-cloud.qcow2`), cloud-init vendor snippet, Ed25519 公開鍵
- pve10-13 root 相互 SSH 鍵 (`/root/.ssh/authorized_keys`)
- `/tmp/install-linstor.sh`, `/tmp/sg-format.sh` 等のセットアップスクリプト

これらは次回セッションで Hardware Error の原因を解明できればそのまま流用可能。

## 次回セッションへの引き継ぎ事項

### 高優先度: ASC=0x81 Hardware Error の根本対策

仮説と検証アプローチ:

1. **Nutanix CVM 由来の保護クリア**:
   - `sg_write_buffer` で MicroCode/Configuration バッファに特定のクリア コマンド送信
   - SAS expander 経由でドライブに `LINK RESET` 送信
   - 検証: 1 ドライブで実験、ベンダーマニュアル要確認 (Seagate DKS5H-J1R2SS は OEM のため公開資料が少ない)

2. **HBA レベルでのリセット**:
   - `lsiutil` または `sas3ircu` で HBA 設定をリセット
   - HBA を IT モードに上書きフラッシュ (現在の状態を確認)

3. **オリジナル Nutanix CVM 環境での解放**:
   - 本ディスクは Nutanix AOS 環境で初期化されたため、AOS 上で `manage_ssd_release` 等のツールでリリースが必要な可能性
   - Nutanix のジャンキングオプション (`/opt/nutanix/cluster/bin/genesis stop` 後の disk_release) を試す価値あり

4. **物理的なジャンパーピン / DRV READY 信号**:
   - 一部 SAS HDD は背面ジャンパで Write Protect 設定可能。物理確認

### 中優先度: 設定の整備

- `config/linstor.yml` に region-c (10-13) の正式定義を追加 (現在は未追加)
- `ssh/config` に pve10-13 エイリアスは既にあり、`/root/.ssh/authorized_keys` 4-mesh も済

### 低優先度: ベンチマーク再開

ディスク問題が解決すれば以下で再開可能:

```sh
# 各ノードで ZFS pool 作成
zpool create linstor_zpool sdb sdc
zfs set compression=off linstor_zpool
zfs set atime=off linstor_zpool

# LINSTOR storage-pool / resource-group / PVE storage 作成
linstor storage-pool create zfs ayase-web-service-10 zfs-pool linstor_zpool   # ×4
linstor resource-group create pve-rg-c --place-count 2 --storage-pool zfs-pool
linstor volume-group create pve-rg-c
linstor resource-group drbd-options --protocol C --quorum off --auto-promote yes pve-rg-c
linstor resource-group set-property pve-rg-c Linstor/Drbd/auto-block-size 512
ssh pve10 "pvesm add drbd linstor-storage-c --resourcegroup pve-rg-c --content images,rootdir --controller 10.10.10.210"

# linstor-bench スキル Phase 0/3-6 を流用
```

## 訂正: ストレージインベントリの「即利用可」は read-only 検証のみ

[2026-05-03 ストレージ棚卸しレポート](2026-05-03_224709_server10-13_storage_inventory.md) で 10/11号機を「512B セクタで即利用可」と記載したが、実際には `lsblk` と `smartctl -i` (read-only) のみで判定しており **書き込み可能性は未検証**。次回以降、ディスクインベントリ時には `dd if=/dev/zero of=/dev/sdX bs=512 count=1 oflag=direct` 等の **書き込みテストを必ず実施する** ルールを memory に追加すべき。

## メトリクス

- セッション総時間: 約 4 時間 (準備〜ギブアップ判定〜レポート)
- sg_format 所要時間 (1.2 TB SAS HDD, 並列 2 本): **3h32m / ノード**
- 構築完了: PVE クラスタ作成、LINSTOR インストール、ノード登録
- 失敗: ZFS pool 作成、LINSTOR storage-pool 作成、ベンチマーク

## ギブアップ判断基準との照合

プランに定義されたギブアップ条件:

| 条件 | 該当 | 備考 |
|------|------|------|
| sg_format が 6 時間以上完了しない | △ | pve10/11 を含めると累計 6h+ になる見込み |
| PVE クラスタ join が再試行を含めて 3 回失敗 | × | 1 発成功 |
| LINSTOR satellite 接続が 3 回試行しても全ノード Online にならない | × | 全ノード Online |
| DRBD 同期が 2 時間以上 UpToDate にならない | - | DRBD リソース未作成 |
| fio ベンチマークが 3 テスト連続失敗 | - | bench 未実行 |
| **想定外: write blocked HW error** | ✓ | sg_format でも解決せず、深掘りに 4-7h+ 必要と推定 |

最後の項目が決定的: 4 時間の作業時間中に書き込み不可の根本対策が見つからず、ユーザ指示通りシャットダウンに移行。
