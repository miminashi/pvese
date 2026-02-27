# LINSTOR/DRBD thin vs thick-stripe ベンチマーク比較レポート

- **実施日時**: 2026年2月26日 12:29 - 13:08
- **セッション ID**: 88d64294

## 前提・目的

LINSTOR/DRBD ストレージの LVM thin provisioning と LVM thick (4本ストライプ) の
性能差を定量的に比較する。

- **背景**: LINSTOR は LVM thin と LVM (thick) の両方をバックエンドに使用できるが、
  thin provisioning のオーバーヘッドと thick のストライピング効果がどの程度性能に影響するか未検証
- **目的**: 同一ハードウェア・DRBD 構成で thin / thick-stripe を切り替え、fio による I/O ベンチマークを実行し性能を比較する
- **前提条件**: 2ノード PVE クラスタ、LINSTOR + DRBD over InfiniBand (ib0) が構築済み

## 参照レポート

- [report/2026-02-26_052044_linstor_drbd_benchmark.md](report/2026-02-26_052044_linstor_drbd_benchmark.md) — 前回 thick-stripe のみのベンチマーク
- [report/2026-02-26_084522_linstor_thin_vs_stripe_benchmark.md](report/2026-02-26_084522_linstor_thin_vs_stripe_benchmark.md) — thin vs stripe 初回試行

## 環境情報

### ハードウェア

| 項目 | 仕様 |
|------|------|
| サーバ | Supermicro X11DPU × 2台 (4号機, 5号機) |
| CPU | Intel Xeon (ホストパススルー) |
| ストレージディスク | /dev/sda, /dev/sdb, /dev/sdc, /dev/sdd (各ノード 4本, HDD) |
| ネットワーク | InfiniBand (ib0) — DRBD レプリケーション用 |
| VM ネットワーク | vmbr1 (192.168.39.0/24 DHCP) |

### ソフトウェア

| 項目 | バージョン |
|------|-----------|
| OS (ホスト) | Debian 13.3 (Trixie) + Proxmox VE 9.1.6 |
| カーネル | 6.17.9-1-pve |
| OS (VM) | Debian 13 (cloud image, カーネル 6.12.73) |
| DRBD | drbd-dkms + drbd-utils |
| LINSTOR | linstor-controller + linstor-satellite + linstor-proxmox |
| fio | 3.39 |

### DRBD 構成

| 項目 | 設定 |
|------|------|
| Protocol | C (同期レプリケーション) |
| Place count | 2 (両ノードにレプリカ) |
| Quorum | off (2ノード構成) |
| Auto-promote | yes |
| Transport | InfiniBand (ib0, PrefNic 設定) |

### ストレージ構成比較

| 項目 | thin | thick-stripe |
|------|------|-------------|
| VG | linstor_vg (4 PV) | linstor_vg (4 PV) |
| LVM 構成 | thin pool (95% FREE) | 通常 LV (ストライプ) |
| LINSTOR Pool | lvmthin | lvm |
| LvcreateOptions | (デフォルト) | `-i4 -I64` (4本ストライプ, 64KiB) |
| 容量 | ~1.73 TiB | ~1.82 TiB |
| DRBD 初期同期 | ~30秒 (使用済み領域のみ) | ~6分 (全領域) |

### VM 構成

| 項目 | 値 |
|------|-----|
| VM ID | 100 |
| vCPU | 4 (host passthrough) |
| メモリ | 4096 MiB |
| ディスク | 32 GiB (SCSI, virtio-scsi-single, iothread) |
| ブリッジ | vmbr1 |

## ベンチマーク結果

### fio テスト条件

- ioengine: libaio, direct=1, numjobs=1, time_based, runtime=60s
- Random テスト: size=1G
- Sequential テスト: size=4G
- Mixed R/W: rwmixread=70

### IOPS・スループット比較

| テスト | thin IOPS | thick IOPS | 差分 | thin BW | thick BW |
|--------|-----------|------------|------|---------|----------|
| Random Read 4K QD1 | 128 | 155 | +21% | 513 KiB/s | 619 KiB/s |
| Random Read 4K QD32 | 266 | 1,191 | +348% | 1.0 MiB/s | 4.7 MiB/s |
| Random Write 4K QD1 | 43 | 81 | +90% | 171 KiB/s | 324 KiB/s |
| Random Write 4K QD32 | 157 | 489 | +211% | 629 KiB/s | 1.9 MiB/s |
| Sequential Read 1M QD32 | 130 | 239 | +84% | 129.6 MiB/s | 238.7 MiB/s |
| Sequential Write 1M QD32 | 27 | 87 | +223% | 26.9 MiB/s | 86.9 MiB/s |
| Mixed R/W 4K QD32 (Read) | 158 | 636 | +302% | 632 KiB/s | 2.5 MiB/s |
| Mixed R/W 4K QD32 (Write) | 68 | 272 | +299% | 272 KiB/s | 1.1 MiB/s |

### レイテンシ比較

| テスト | thin Avg Lat | thick Avg Lat | thin p99 Lat | thick p99 Lat |
|--------|-------------|--------------|-------------|--------------|
| Random Read 4K QD1 | 7.75 ms | 6.43 ms | 12.52 ms | 14.61 ms |
| Random Read 4K QD32 | 120.25 ms | 26.84 ms | 658.51 ms | 187.70 ms |
| Random Write 4K QD1 | 23.35 ms | 12.26 ms | 66.85 ms | 32.37 ms |
| Random Write 4K QD32 | 203.32 ms | 65.35 ms | 784.33 ms | 187.70 ms |
| Sequential Read 1M QD32 | 246.85 ms | 134.02 ms | 505.41 ms | 1,434.45 ms |
| Sequential Write 1M QD32 | 1,183.52 ms | 367.37 ms | 2,164.26 ms | 775.95 ms |
| Mixed R/W 4K QD32 (Read) | 186.02 ms | 33.71 ms | 885.00 ms | 316.67 ms |
| Mixed R/W 4K QD32 (Write) | 37.56 ms | 38.75 ms | 700.45 ms | 149.95 ms |

## 分析

### IOPS

thick-stripe は全テストで thin を上回った。特に顕著な差は以下の通り:

- **Random Read 4K QD32**: thick は thin の **4.5倍** の IOPS
- **Mixed R/W 4K QD32 (Read)**: thick は thin の **4.0倍** の IOPS
- **Mixed R/W 4K QD32 (Write)**: thick は thin の **4.0倍** の IOPS
- **Sequential Write 1M QD32**: thick は thin の **3.2倍** の IOPS
- **Random Write 4K QD32**: thick は thin の **3.1倍** の IOPS
- **Random Write 4K QD1**: thick は thin の **1.9倍** の IOPS
- **Sequential Read 1M QD32**: thick は thin の **1.8倍** の IOPS
- **Random Read 4K QD1**: thick は thin の **1.2倍** の IOPS

### ストライピング効果

thick-stripe の LVM ストライピング (`-i4 -I64`) は 4本の物理ディスクに I/O を分散する。
これにより:

1. **ランダム I/O**: 複数ディスクが並列に seek できるため、特に QD32 のような高キュー深度で
   IOPS が大幅に向上 (randread QD32: thin 266 → thick 1,191、4.5倍)
2. **シーケンシャル I/O**: 4本のディスクからの帯域幅が合算され、read は 130→239 MiB/s (1.8倍)、
   write は 27→87 MiB/s (3.2倍) に改善
3. **レイテンシ**: ストライピングにより I/O が分散されるため、平均レイテンシが大幅に低減

### thin provisioning のオーバーヘッド

thin provisioning には以下のオーバーヘッドがある:

- **メタデータ管理**: thin pool のブロックマッピングテーブル更新
- **CoW (Copy-on-Write)**: 新規書き込み時の thin ブロック割り当て
- **ゼロ化**: thin pool のデフォルト設定でブロックのゼロ化が有効 (WARNING あり)
- **ストライプなし**: thin pool は単一 LV のため I/O が分散されない

これらの要因が組み合わさり、特に write 系ワークロードで大きな性能差が生じた。

### 容量効率の比較

thin provisioning と thick-stripe では物理ストレージの消費パターンが根本的に異なる。

| 項目 | thin | thick-stripe |
|------|------|-------------|
| 物理割り当てタイミング | データ書き込み時 (遅延割り当て) | LV 作成時 (即時割り当て) |
| 32GB VM の初期物理消費 | ~3GB (cloud image 分のみ) | 32GB (全領域を即座に確保) |
| オーバープロビジョニング | 可能 (仮想容量 > 物理容量) | 不可 (仮想容量 ≤ 物理容量) |
| 空き容量の返却 | discard/TRIM でブロック解放可能 | 解放されない (LV サイズ固定) |

**具体例** (本環境: 各ノード物理容量 ~1.82 TiB、DRBD place_count=2):

- **thick-stripe**: 32GB の VM を作成すると両ノードでそれぞれ 32GB を即座に消費する。
  物理容量 1.82 TiB に対して最大 ~58 台の 32GB VM を収容できる (1,862 GB ÷ 32 GB)。
  これが容量の上限であり、VM 内で実データが少なくても物理消費は変わらない
- **thin**: 同じ 32GB の VM でも、実データが 10GB なら物理消費は 10GB のみ。
  残りの 22GB は他の VM が使える。仮に各 VM の平均実使用量が 10GB なら、
  同じ物理容量に ~186 台を収容できる計算になる (オーバープロビジョニング)

ただし thin のオーバープロビジョニングにはリスクがある:
- 全 VM が一斉に書き込みを行うと thin pool の物理容量が枯渇する可能性がある
- 容量枯渇時は I/O エラーが発生し、VM がハングまたはデータ破損に至る
- 運用上は thin pool の使用率を監視し、閾値でアラートを上げる仕組みが必須

### DRBD 初期同期時間

| 構成 | 同期時間 | 理由 |
|------|---------|------|
| thin | ~30秒 | 使用済み領域 (cloud image ~3GB) のみ同期 |
| thick | ~6分 | 全 32GB 領域を同期 (ブロックデバイス全体) |

thick は初期同期に時間がかかるが、稼働後の性能は大幅に優れる。
thin の同期速度の優位性は、VM の迅速なプロビジョニングが必要な環境で有用。

### 結論

HDD ベースの LINSTOR/DRBD ストレージにおいて、thick-stripe (LVM 4本ストライプ) は
thin provisioning に対して全ワークロードで **1.2〜4.5倍** の性能向上を示した。

両構成の使い分け指針:

- **thick-stripe が適する場面**: I/O 性能が最優先、VM 台数が限定的、容量計画が明確
- **thin が適する場面**: 多数の VM を少ない物理容量で運用したい、VM のプロビジョニング速度が重要、
  容量監視の運用体制がある

## 再現方法

`linstor-bench` スキルを使用して再現可能:

```bash
# thin ベンチマーク
/linstor-bench thin

# thick-stripe ベンチマーク
/linstor-bench thick-stripe
```

スキル定義: `.claude/skills/linstor-bench/SKILL.md`
設定ファイル: `config/linstor.yml`
Preflight スクリプト: `scripts/linstor-bench-preflight.sh`

### 手動実行手順 (概要)

1. Phase 0: `scripts/linstor-bench-preflight.sh` で SMART チェック
2. Phase 1: 既存 VM/LINSTOR/LVM をクリーンアップ
3. Phase 2: VG 作成 → LINSTOR ストレージプール → リソースグループ → PVE ストレージ登録
4. Phase 3: `qm create` → `qm importdisk` → cloud-init 設定 → `qm start`
5. Phase 4: DRBD 同期完了待ち → VM IP 検出 → SSH → fio インストール
6. Phase 5: fio 7テスト実行 (各60秒)

詳細は SKILL.md の各フェーズを参照。
