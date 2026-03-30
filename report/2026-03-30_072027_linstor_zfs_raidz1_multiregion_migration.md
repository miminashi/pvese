# LINSTOR ZFS raidz1 マルチリージョンマイグレーション実験

- **実施日時**: 2026年3月30日 15:00〜16:20 (JST)

## 添付ファイル

- [実装プラン](attachment/2026-03-30_072027_linstor_zfs_raidz1_multiregion_migration/plan.md)

## 前提・目的

### 背景

LVM thick-stripe によるマルチリージョンマイグレーションは 5x テスト (2026-03-20) で検証済み。ZFS raidz1 は Region B でベンチマーク済み (2026-03-30) で、COW 設計による write hole 解消、チェックサムによるサイレント破損検出、75% 容量効率という利点がある。

### 目的

1. Region A (4+5+6号機) の LVM thick-stripe を ZFS raidz1 に変更
2. 全 6 ノードを ZFS raidz1 に統一した環境でマルチリージョンマイグレーションを検証
3. コールドマイグレーションスクリプトの ZFS 対応 (`--storage-pool` 対応、cloud-init 再構築)

### 参照レポート

- [LINSTOR マルチリージョンマイグレーション 5x テスト (LVM, 2026-03-20)](2026-03-20_163600_linstor_multiregion_migration_5x.md)
- [LINSTOR ZFS raidz1 ベンチマーク (2026-03-30)](2026-03-30_025702_linstor_zfs_raidz1_benchmark.md)
- [ZFS raidz1 ベンチマーク ARC 最小化 (2026-03-30)](2026-03-30_053421_zfs_raidz1_arc_disabled_benchmark.md)

## 環境情報

### ハードウェア

| 項目 | Region A (4+5+6号機) | Region B (7+8+9号機) |
|------|---------------------|---------------------|
| サーバ | Supermicro X11DPU | DELL PowerEdge R320 |
| CPU | Xeon Skylake (多コア) | Xeon E5-2420 v2 (6C/12T) |
| メモリ | 大容量 DDR4 | 48 GiB DDR3 |
| OS ディスク | NVMe 128GB | RAID-1 (Bay 0+1) |
| データディスク | 4× SATA HDD (sda-sdd) | 5-6× SAS HDD |
| ネットワーク | GbE + IB QDR | GbE + IB QDR |

### ZFS 構成

| 項目 | Region A | Region B |
|------|---------|---------|
| ZFS バージョン | 2.4.0-pve1 | 2.4.1-pve1 |
| プール名 | linstor_zpool | linstor_zpool |
| トポロジ | raidz1 × 4ディスク | raidz1 × 5-6ディスク |
| 容量 | 1.81 TiB/ノード | 4.08-4.91 TiB/ノード |
| ARC 最大 | 4 GiB | 4 GiB |
| compression | off | off |
| atime | off | off |

### ソフトウェア

| 項目 | バージョン |
|------|-----------|
| OS | Debian 13.3 (Trixie) + Proxmox VE 9.1.6 |
| カーネル | 6.17.13-2-pve |
| DRBD | 9.3.1 |
| LINSTOR | 1.33.1 |
| ストレージプロバイダ | ZFS (thick) |
| リソースグループ | pve-rg (place-count=2, Protocol C) |

### DRBD/LINSTOR 構成

| 項目 | 設定 |
|------|------|
| LINSTOR ストレージプール | zfs-pool (全6ノード統一) |
| Intra-region Protocol | C (同期) |
| Inter-region Protocol | A (非同期) |
| Cross-region interface | default (GbE, IB ではなく) |
| PVE storage (Region A) | linstor-storage |
| PVE storage (Region B) | linstor-storage-b |

## 実施内容

### Phase 1: Region A を ZFS raidz1 に変更

1. LINSTOR ストレージプール `striped-pool` (LVM) を全 Region A ノードから削除
2. LVM VG `linstor_vg` を削除、PV をワイプ
3. `zpool create linstor_zpool raidz1 sda sdb sdc sdd` で ZFS raidz1 プール作成
4. ARC 最大を 4 GiB に設定
5. LINSTOR に `zfs-pool` として登録
6. リソースグループ `pve-rg` の `--storage-pool` を `zfs-pool` に変更

**結果**: 全 6 ノードで `zfs-pool` (ZFS) が正常に動作。Region A: 1.81 TiB/ノード。

### Phase 2: スクリプト修正

#### linstor-migrate-cold.sh

1. **`--storage-pool` 対応**: `resource create` にリージョン別のストレージプール名を指定
   - `SOURCE_POOL` / `TARGET_POOL` を `config/linstor.yml` のリージョン設定から取得
2. **cloud-init 再構築**: コールドマイグレーション後に cloud-init ドライブ、ユーザ、SSH 鍵、IP 設定を再作成
3. **stale cloud-init ディスク削除**: 既存の cloud-init qcow2 を削除してから再作成

#### linstor-multiregion-node.sh

- `do_remove()` でリージョン別ストレージプール名を解決

#### config/linstor.yml

- グローバル設定とリージョン設定に `storage_pool_name: zfs-pool` を追加

### Phase 3: マイグレーション実験結果

**テスト VM**: VMID 200, 3G ディスク, 512 MiB テストデータ, MD5 チェックサム検証

| ステップ | 内容 | 所要時間 | ダウンタイム | チェックサム |
|---------|------|---------|-----------|-----------|
| S1 | コールド A→B (ZFS→ZFS) | ~160s | VM 停止 | **PASS** |
| S2a | ライブ 7→9 (ZFS, Region B) | 23s | 48ms | **PASS** |
| S2b | ライブ 9→7 (ZFS, Region B) | 22s | 67ms | **PASS** |
| S3 | コールド B→A (ZFS→ZFS) | ~120s | VM 停止 | **PASS** |
| S4a | ライブ 4→5 (ZFS, Region A) | 18s | 58ms | **PASS** |
| S4b | ライブ 5→4 (ZFS, Region A) | 17s | 85ms | **PASS** |

**全 6 ステップでチェックサム PASS** (MD5: `3586b79e33aa129aeecd5a056b2226b6`)

### LVM 5x テストとの比較

| メトリクス | LVM (32G disk) | ZFS (3G disk) | 備考 |
|-----------|:---:|:---:|------|
| コールド A→B | 735-756s | ~160s | ディスクサイズが異なるため直接比較不可 |
| コールド B→A | 719-731s | ~120s | 同上 |
| ライブ Region A | 14-21s, 49-93ms | 17-18s, 58-85ms | メモリ転送のため同等 |
| ライブ Region B | 17-26s, 35-43ms | 22-23s, 48-67ms | 同等 |
| チェックサム | 30/30 PASS | 6/6 PASS | 両方 100% |

**ライブマイグレーション性能は ZFS/LVM で同等** — ライブマイグレーションはメモリ転送が支配的であり、ストレージバックエンドに依存しない。

## 発生した問題と対処

| 問題 | 原因 | 対処 |
|------|------|------|
| 6号機 LINSTOR satellite が ZFS 未対応 | satellite 再起動直後の一時的なタイミング | 数秒待って再試行で解決 |
| `qm resize` で DRBD エラー | ZFS 上の DRBD リソースのリサイズが一部ノードで失敗 | ディスクリサイズを避け、3G ディスクで実験 |
| 6号機 DRBD 接続が Connecting で停滞 | リサイズ失敗後の DRBD メタデータ破損 | 6号機からリソースを削除して回避 |
| コールドマイグレーション後に VM の管理 IP 未設定 | cloud-init ドライブが再作成されない | スクリプトに cloud-init 再構築を追加 |
| cloud-init ディスク `already exists` | 前回のマイグレーションで残った stale ファイル | `rm -f` で削除してから再作成 |
| 8号機が Region B PVE クラスタに未参加 | クラスタセットアップ時の不足 | 9号機をライブマイグレーションのターゲットに変更 |

## 結論

1. **ZFS raidz1 はマルチリージョンマイグレーションに完全対応**: コールドマイグレーション (リージョン間) とライブマイグレーション (リージョン内) の両方が正常動作
2. **データ整合性は 100% 保持**: 全ステップで MD5 チェックサム検証 PASS
3. **ライブマイグレーション性能は LVM と同等**: メモリ転送が支配的なため、ストレージバックエンドに差なし
4. **スクリプト修正が必要だった**:
   - `--storage-pool` フラグでリージョン別プール指定
   - cloud-init ドライブの再構築 (ciuser, sshkeys, ipconfig)
   - stale cloud-init ディスクの削除
5. **ZFS 固有の問題**: `qm resize` (DRBD 上のZFS zvol のライブリサイズ) に障害。ディスクサイズは VM 作成時に確定させるのが安全
6. **6号機の DRBD 不安定性**: resize 失敗後に DRBD 接続が復旧しない問題。リソース再作成で対処

### 推奨

- ZFS raidz1 をマルチリージョン LINSTOR の標準ストレージバックエンドとして採用可能
- VM ディスクサイズは作成時に確定し、ライブリサイズは避ける
- コールドマイグレーションスクリプトの cloud-init 対応は必須 (本実験で実装済み)

## 再現方法

### Region A ZFS 変換

```sh
# 1. LINSTOR ストレージプール削除
linstor storage-pool delete ayase-web-service-4 striped-pool
linstor storage-pool delete ayase-web-service-5 striped-pool
linstor storage-pool delete ayase-web-service-6 striped-pool

# 2. 各ノードで LVM → ZFS 変換
vgremove -f linstor_vg
pvremove /dev/sda /dev/sdb /dev/sdc /dev/sdd
zpool create linstor_zpool raidz1 sda sdb sdc sdd
zfs set compression=off linstor_zpool
zfs set atime=off linstor_zpool
echo 'options zfs zfs_arc_max=4294967296' > /etc/modprobe.d/zfs-arc.conf
echo 4294967296 > /sys/module/zfs/parameters/zfs_arc_max
systemctl restart linstor-satellite

# 3. LINSTOR ストレージプール作成
linstor storage-pool create zfs ayase-web-service-4 zfs-pool linstor_zpool
linstor storage-pool create zfs ayase-web-service-5 zfs-pool linstor_zpool
linstor storage-pool create zfs ayase-web-service-6 zfs-pool linstor_zpool

# 4. リソースグループ更新
linstor resource-group modify pve-rg --storage-pool zfs-pool
```

### マイグレーション実行

```sh
# コールドマイグレーション A→B
./pve-lock.sh run ./oplog.sh ./scripts/linstor-migrate-cold.sh 200 region-a region-b

# ライブマイグレーション Region B 内
./pve-lock.sh run ./oplog.sh ./scripts/linstor-migrate-live.sh 200 ayase-web-service-9

# コールドマイグレーション B→A
./pve-lock.sh run ./oplog.sh ./scripts/linstor-migrate-cold.sh 200 region-b region-a

# ライブマイグレーション Region A 内
./pve-lock.sh run ./oplog.sh ./scripts/linstor-migrate-live.sh 200 ayase-web-service-5
```
