# ZFS raidz1 + LINSTOR ZFS プロバイダ ベンチマーク (Region B: 7,8,9号機)

## Context

レポート `2026-03-30_012812` で ZFS + LINSTOR ZFS プロバイダが「未テストだが有望」と評価された。ZFS raidz1 は容量効率 75%、COW による write hole 解消、チェックサムによるサイレント破損検出を備え、LINSTOR とネイティブ統合できる。本タスクでは Region B (7,8,9号機) で ZFS raidz1 を構築し、fio ベンチマークを実行して LVM RAID1 / thick-stripe との性能比較を行う。

## 設計判断

| 項目 | 決定 | 理由 |
|------|------|------|
| ZFS トポロジ | **raidz1** | 容量効率 75%、write hole なし、レポート推奨 |
| ディスク使用 | **全利用可能ディスク** | ユーザ指示。7号機: 6本, 8/9号機: 5本 |
| LINSTOR プロバイダ | **zfs (thick)** | thin より単純、ベンチマーク結果が予測可能 |
| VM 配置 | **7号機 + 9号機** (place-count=2) | 前回 RAID1 ベンチと同条件 |
| ARC メモリ | **4 GiB** | 48 GiB RAM の ~8%。VM + PVE + DRBD に余裕 |
| ZFS 圧縮 | **off** | ベンチマークは生ディスク性能を計測 |

### ディスク構成 (VD 作成後)

| サーバ | データディスク | raidz1 容量 (概算) |
|--------|-------------|-------------------|
| 7号機 | 6本 (sdb-sdg) | ~4.09 TiB (83%) |
| 8号機 | 5本 (sdb-sdf) | ~3.27 TiB (80%) |
| 9号機 | 5本 (sdb-sdf) | ~3.27 TiB (80%) |

## 実行手順

### Phase 0: VD 作成 (8号機 Bay 3, 9号機 Bay 2)

交換済みディスクに RAID-0 VD を作成。要リブート。

1. **racadm createvd** — 8号機 Bay 3, 9号機 Bay 2 を並列で実行
   ```
   ssh -F ssh/config idrac8 racadm raid createvd:RAID.Integrated.1-1 -rl r0 -pdkey:Disk.Bay.3:...
   ssh -F ssh/config idrac9 racadm raid createvd:RAID.Integrated.1-1 -rl r0 -pdkey:Disk.Bay.2:...
   ```
2. **jobqueue create + pwrcycle** — 両サーバ並列リブート
3. **ジョブ完了待ち** — `racadm jobqueue view` でポーリング (~5分)
4. **VD 確認** — `racadm raid get vdisks` で VD5 が Online
5. **OS 上のデバイス確認** — `lsblk -d` で新ディスク (sdf) が見えること

### Phase 1: 既存 LINSTOR/LVM クリーンアップ

pve-lock 必要。LINSTOR コマンドはすべて Controller (pve4) で実行。

1. 既存 VM 100 があれば停止・破棄
2. LINSTOR リソース定義削除
3. PVE ストレージ `linstor-storage-b` 削除
4. リソースグループ `pve-rg-b` 削除
5. ストレージプール `striped-pool` を 3 ノードから削除
6. 各ノードで LVM 解体: `lvremove` → `vgremove` → `pvremove`
7. ディスク署名消去: `wipefs -af` (raidz1 用ディスクのみ)

### Phase 2: ZFS インストール・設定

1. **ZFS 確認**: `which zpool`, `modprobe zfs` — PVE 9 には通常含まれる
2. 未インストールなら `apt-get install -y zfsutils-linux`
3. **ARC 制限**: `/etc/modprobe.d/zfs-arc.conf` に `options zfs zfs_arc_max=4294967296`
4. 即時適用: `/sys/module/zfs/parameters/zfs_arc_max` に書き込み

### Phase 3: ZFS raidz1 プール作成

1. **zpool create** — 各ノードで全データディスクを使用
   - 7号機: `zpool create linstor_zpool raidz1 sdb sdc sdd sde sdf sdg`
   - 8号機: `zpool create linstor_zpool raidz1 sdb sdc sdd sde sdf`
   - 9号機: `zpool create linstor_zpool raidz1 sdb sdc sdd sde sdf`
2. **zpool status** で健全性確認
3. **ZFS プロパティ**: `compression=off`, `atime=off`

### Phase 4: LINSTOR ZFS ストレージプール + リソースグループ

1. `linstor storage-pool create zfs <node> zfs-pool linstor_zpool` × 3 ノード
2. `linstor resource-group create pve-rg-b --place-count 2 --storage-pool zfs-pool`
3. `linstor volume-group create pve-rg-b`
4. DRBD オプション: protocol C, quorum off, auto-promote yes
5. Auto-eviction 無効化 (7号機, 9号機)
6. `pvesm add drbd linstor-storage-b --resourcegroup pve-rg-b --content images --controller 10.10.10.204`

### Phase 5: ベンチマーク VM 作成

linstor-bench スキルの Phase 3 に準拠。7号機に VM 100 を作成。

1. cloud image import → linstor-storage-b
2. cloud-init 設定 (nocloud, Ed25519 鍵, dual NIC)
3. VM 起動 → DRBD 同期待ち (thick: ~数分)
4. SSH 接続確認 (10.10.10.210) → fio インストール

### Phase 6: fio ベンチマーク実行

7 テスト × 3 回 × 2 トランスポート (GbE / IPoIB)

| テスト | rw | bs | iodepth | size |
|--------|----|----|---------|------|
| randread-4k-qd1 | randread | 4k | 1 | 1G |
| randread-4k-qd32 | randread | 4k | 32 | 1G |
| randwrite-4k-qd1 | randwrite | 4k | 1 | 1G |
| randwrite-4k-qd32 | randwrite | 4k | 32 | 1G |
| seqread-1m-qd32 | read | 1m | 32 | 4G |
| seqwrite-1m-qd32 | write | 1m | 32 | 4G |
| mixed-rw-4k-qd32 | randrw 70/30 | 4k | 32 | 1G |

### Phase 7: 結果分析・レポート

3 構成の比較:
- ZFS raidz1 (今回)
- LVM RAID1 (2026-03-29)
- Thick-stripe (2026-03-19)

matplotlib でグラフ生成、レポート作成。

## Phase 7: レポート作成計画

### ファイル名

`report/<timestamp>_linstor_zfs_raidz1_benchmark.md`
- タイムスタンプは `date +%Y-%m-%d_%H%M%S` で取得

### 添付ファイル

```
report/attachment/<timestamp>_linstor_zfs_raidz1_benchmark/
  plan.md                  # このプランファイルのコピー
  iops_comparison.png      # IOPS 比較棒グラフ (matplotlib)
  throughput_comparison.png # スループット比較棒グラフ
```

### レポート構成

```markdown
# LINSTOR ZFS raidz1 ベンチマーク — Region B (7+8+9号機)

- **実施日時**: YYYY年M月D日 HH:MM (JST)

## 添付ファイル
- [実装プラン](attachment/.../plan.md)
- [IOPS 比較グラフ](attachment/.../iops_comparison.png)
- [スループット比較グラフ](attachment/.../throughput_comparison.png)

## 前提・目的
### 背景
- LVM RAID1 ベンチ (2026-03-29) が完了、ZFS raidz1 が未テスト
- write hole 解消 + チェックサム + 75% 容量効率が ZFS の優位性
### 目的
1. ZFS raidz1 + LINSTOR ZFS プロバイダでの fio 性能計測
2. LVM RAID1 / thick-stripe との定量比較
3. GbE vs IPoIB の差異確認
### 参照レポート
- 2026-03-29_090042 (LVM RAID1)
- 2026-03-19_173724 (thick-stripe Region B)
- 2026-03-30_012812 (冗長化選択肢調査)

## 環境情報
### ハードウェア
- 7号機: 6 data disks (Bay 2-7), raidz1
- 8号機: 5 data disks (Bay 2-6), raidz1 ← VD 新規作成含む
- 9号機: 5 data disks (Bay 2-6), raidz1 ← VD 新規作成含む
### ソフトウェア
- ZFS バージョン, DRBD 9.3.1, LINSTOR 1.33.1
### ZFS 構成
- zpool topology, ARC 設定, compression/atime 設定
### DRBD 構成
- Protocol C, place-count 2, quorum off
### ベンチマーク VM
- VM 100, 4 vCPU, 4 GiB RAM, 32 GiB disk

## ベンチマーク結果
### GbE (中央値, 3回)
テスト | IOPS | BW | min | max
### IPoIB (中央値, 3回)
テスト | IOPS | BW | min | max
### 過去データとの比較
ZFS raidz1 GbE | ZFS raidz1 IPoIB | LVM RAID1 GbE | LVM RAID1 IPoIB | Thick-stripe GbE

## 分析
1. GbE vs IPoIB の差異
2. ZFS raidz1 vs LVM RAID1: ランダム/シーケンシャル I/O 比較
3. ZFS raidz1 vs Thick-stripe: ストライプ幅の違い
4. ZFS COW オーバーヘッドの影響
5. ARC キャッシュの効果 (読み込みヒット率)

## 結論
- 性能特性のまとめ
- 推奨構成の判断材料

## 再現方法
- zpool create コマンド
- LINSTOR storage-pool/resource-group 設定
- fio コマンド例
```

## 検証方法

1. `zpool status linstor_zpool` — 各ノードで ONLINE, no errors
2. `linstor storage-pool list` — 3 ノードとも zfs-pool が Ok
3. `drbdsetup status --verbose` — 両ピアが UpToDate
4. fio JSON 出力から IOPS/BW/latency を抽出して比較

## 重要ファイル

- `config/linstor.yml` — ストレージプール設定 (ZFS 用に更新)
- `.claude/skills/linstor-bench/SKILL.md` — ベンチマーク手順・失敗パターン
- `.claude/skills/perc-raid/SKILL.md` — racadm VD 作成手順
- `report/2026-03-29_090042_linstor_lvm_raid1_benchmark.md` — 比較元データ
- `report/2026-03-30_012812_lvm_node_disk_redundancy_options.md` — ZFS 設計根拠
