# LINSTOR ディスク個別 Storage Pool 構成によるディスク冗長性 — 調査レポート

- **実施日時**: 2026年3月28日 09:06 JST
- **種別**: 調査レポート（デスクリサーチ）

## 添付ファイル

- [調査プラン](attachment/2026-03-28_000658_linstor_per_disk_pool_investigation/plan.md)

## 前提・目的

### 背景

本プロジェクトでは LINSTOR/DRBD によるマルチリージョン VM 運用基盤を構築しており、各ノードに 4 本の SATA HDD を搭載している。これまでディスク冗長性は LVM RAID（RAID10, RAID1）や HW RAID5 で確保してきたが、いずれも LINSTOR 以外の管理レイヤー（dm-raid, mdadm, PERC H710）が介在する。

### 調査の問い

> ディスクごとに個別の LINSTOR storage pool を登録し、DRBD のレプリケーション機能だけで同一ノード内のディスク冗長性を確保できるか？

目的は、HW RAID・mdraid・LVM RAID 等の追加レイヤーを排除し、LINSTOR/DRBD の単一管理レイヤーでディスク障害耐性を実現すること。

### 想定構成

```
sda → linstor_vg_a → pool-a
sdb → linstor_vg_b → pool-b
sdc → linstor_vg_c → pool-c
sdd → linstor_vg_d → pool-d

resource group: place-count=2, 同一ノード内の異なる pool に 2 レプリカを配置
```

## 調査結果

### 1. DRBD の設計制約: 同一ノード内レプリカは不可

**結論: DRBD は同一ホスト上に同一リソースの複数レプリカを配置できない。**

DRBD はノード間ネットワーク越しレプリケーション専用として設計されている。

- DRBD リソースは各ノードで単一のブロックデバイス (`/dev/drbdX`) として公開される
- `drbd_connection` データ構造は `peer_node_id` と `transport`（TCP/IP または RDMA）を前提とする
- 同一ホスト上の異なるディスクに対して DRBD レプリケーション関係を構成する機能は存在しない
- DRBD User Guide (9.0) でも、同一ホスト内ミラーリングのユースケースは記載されていない

つまり、想定構成の「同一ノード内の異なる pool に 2 レプリカ」は DRBD レベルで技術的に成立しない。

### 2. LINSTOR 複数 Storage Pool: 作成は可能だが目的は別

LINSTOR で同一ノードに複数の storage pool を作成すること自体は可能。

```sh
linstor storage-pool create lvm node-1 pool-a linstor_vg_a
linstor storage-pool create lvm node-1 pool-b linstor_vg_b
```

しかし、これは以下の用途を想定した機能であり、同一ノード内レプリカ配置ではない:

| 用途 | 説明 |
|------|------|
| 性能ティアリング | NVMe pool と HDD pool を同一ノードに共存 |
| 容量分離 | VM 用途別に pool を分ける |
| ノード間分散 | `replicas-on-different` で異なるノードの異なる pool タイプに配置 |

`replicas-on-same` / `replicas-on-different` はノードの **Aux プロパティ** に基づく配置制約であり、同一ノード内の pool 間分散を制御する機能ではない。

### 3. 関連する LINSTOR GitHub Issue

| Issue | 内容 | 関連性 |
|-------|------|--------|
| [LINBIT/linstor-server#88](https://github.com/LINBIT/linstor-server/issues/88) | `replicas-on-different` が機能せず同一 Aux 値ノードに両レプリカ配置 | 配置制約のバグ |
| [LINBIT/linstor-server#236](https://github.com/LINBIT/linstor-server/issues/236) | ノード障害時にレプリカ数が自動復帰しない | auto-eviction の制約 |
| [LINBIT/linstor-server#150](https://github.com/LINBIT/linstor-server/issues/150) | レプリカ作成時に重複 node-id(0) 割当 | 同一ノード内配置時の問題 |
| [piraeusdatastore/linstor-csi#195](https://github.com/piraeusdatastore/linstor-csi/issues/195) | 同一ノード内配置時に「利用可能なノードが不足」エラー | CSI 経由での制約 |

Issue #195 は特に示唆的で、LINSTOR が同一ノードへの複数レプリカ配置を意図的にブロックしていることを示している。

### 4. `allowMixStorPoolWithRecentEnoughDrbdTest` について

LINSTOR のテストコードに同一ノード内の異なる storage pool にリソースを配置するテストが存在するが、これは **異なるリソース** を異なる pool に配置するテストであり、**同一リソースの複数レプリカ** を同一ノード内に配置するものではない。

## これまでの RAID 構成実験の振り返り

ディスク冗長性の確保を目的に、これまで以下の構成を実験してきた。

### LVM RAID10 (2026-02-27)

- 構成: 4 ディスク → `--type raid10 -i2 -m1`（2 ストライプ × 2 ミラー）
- 容量: ~910 GiB (50% 減)
- **問題**: `lvchange --refresh` でカーネルバグ (`raid10.c:3454`) 発生。ホットリビルド不可
- 参照: [LVM RAID10 実験レポート](2026-02-27_203200_linstor_lvm_raid10_disk_failure_experiment.md)

### HW RAID5 (2026-03-22)

- 構成: PERC H710 RAID-5（3 本 + 1 パリティ）
- 容量: 1.63 TiB
- **問題**: RAID 再構成に再起動が必要、racadm ジョブ管理が煩雑、OS 消失リスク
- 参照: [RAID5 耐障害性実験レポート](2026-03-22_120534_linstor_raid5_resilience_experiment.md)

### Software RAID1 — mdadm vs LVM RAID1 (2026-03-22)

- 構成 (mdadm): sdb+sdc ミラー、sdd ホットスペア
- 構成 (LVM RAID1): `--type raid1 -m1` で LINSTOR 透過管理
- 容量: ~838 GiB
- **LVM RAID1 が最も実用的**と結論。LINSTOR と透過的に統合、ホットリビルド動作確認済み
- **問題**: DRBD が LVM RAID デグレードを検知しない（UpToDate のまま）
- 参照: [ソフトウェア RAID1 実験レポート](2026-03-22_220051_linstor_software_raid1_experiment.md)

### 共通の運用課題 (2026-02-28)

- SCSI 再スキャンでデバイス名変動 (sdd → sde)
- Physical block size 不一致による LINSTOR minIoSize 問題
- DRBD が LVM RAID デグレードを透過的に扱い監視の盲点になる
- 参照: [LVM RAID 運用上の懸念事項レポート](2026-02-28_010338_linstor_lvm_raid_operational_concerns.md)

## 代替アプローチの比較

| 方式 | ディスク冗長 | ノード冗長 | 追加レイヤー | 容量効率 | LINSTOR 統合 | 運用性 |
|------|:-:|:-:|:-:|:-:|:-:|:-:|
| **DRBD のみ (per-disk pool)** | **不可** | — | なし | — | — | — |
| LVM RAID1 | ○ | ○ | dm-raid | 50% | 透過的 | 高 |
| mdadm RAID1 | ○ | ○ | mdadm | 50% | 手動管理 | 中 |
| HW RAID5 | ○ | ○ | PERC H710 | 67% | 透過的 | 低 |
| LVM RAID10 | ○ | ○ | dm-raid | 50% | 透過的 | 低 (バグ) |
| ストライプ (冗長なし) | **なし** | ○ | なし | 100% | 透過的 | 高 |

## 結論

1. **ディスクごとに個別 pool を作り、DRBD レプリケーションだけでディスク冗長性を確保する構成は実現不可能**。DRBD は同一ノード上に同一リソースの複数レプリカを持つことを設計上サポートしていない

2. **LINSTOR 以外の管理レイヤーを完全に排除したい場合**、ディスク冗長性は諦め、ノード間レプリケーション（place-count=2 以上）でノード障害耐性のみ確保する構成が唯一の選択肢となる。この場合、単一ディスク障害でノード全体のデータが失われるリスクを許容する必要がある

3. **ディスク冗長性が必要な場合**、何らかの追加レイヤーが不可避。これまでの実験から **LVM RAID1 が最も実用的**:
   - LINSTOR の `LvcreateOptions` で透過的に管理でき、別途の管理ツール操作が不要
   - ホットリビルドが動作する（RAID10 のカーネルバグとは異なる）
   - ノード障害 + ディスク障害の同時耐性を実証済み
   - 欠点: DRBD が LVM RAID デグレードを検知しないため、LVM 層の監視が別途必要
