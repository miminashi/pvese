# LINSTOR/DRBD thick-stripe ベンチマーク (Region B, スキル改善検証)

- **実施日時**: 2026年3月19日 19:15 - 19:32 (JST)
- **セッション ID**: 828c18c6

## 前提・目的

前回のセッションで IB 有効化の知見 (K1-K6) を linstor-bench / linstor-node-ops / linstor-migration スキルに反映した。
今回はスキルの手順に従って Region B thick-stripe ベンチマークを再実施し、更新されたスキルが問題なく機能するかを検証する。

- **背景**: 前回の IB ベンチマークでは手順の修正が多数発生。PrefNic 名 (`ib0` → `ibp10s0`)、DRBD 接続確認コマンドなどの知見をスキルに反映済み
- **目的**: (1) スキルの手順どおりに Phase 0〜6 が完了するか検証、(2) DRBD が IB (192.168.100.x) 経由で接続されることを確認、(3) 前回 IB 結果との比較
- **前提条件**: IB 設定済み (ibp10s0, PrefNic 登録済み)、LINSTOR controller (4号機) 稼働中

## 参照レポート

- [report/2026-03-19_182643_ib_benchmark_region_b.md](2026-03-19_182643_ib_benchmark_region_b.md) — 前回 IB ベンチマーク結果
- [report/2026-03-19_173724_linstor_thick_stripe_benchmark_region_b.md](2026-03-19_173724_linstor_thick_stripe_benchmark_region_b.md) — GbE ベンチマーク結果

## スキル改善の検証結果

| # | 検証項目 | 結果 | 詳細 |
|---|---------|------|------|
| V1 | PrefNic が `ibp10s0` で登録済み | OK | `linstor node interface list` で 7号機・8号機とも `ibp10s0` (192.168.100.x) を確認 |
| V2 | DRBD が IB (192.168.100.x) 経由で接続 | OK | `drbdsetup show pm-0b9b12c1` で 192.168.100.7:7000 ↔ 192.168.100.8:7000 を確認 |
| V3 | スキルの IB 記述が `ibp*` | OK | スキルに従って実行し問題なし |
| V4 | `ib-setup-remote.sh` の modprobe 順序 | - | IB 既設定済みのため直接検証せず |

**結論**: スキルの手順に従い Phase 0〜6 すべて問題なく完了。手順の逸脱・修正は不要だった。

## 環境情報

### ハードウェア

| 項目 | 仕様 |
|------|------|
| サーバ | DELL PowerEdge R320 x 2台 (7/8号機) |
| CPU | Intel Xeon E5-2420 v2 @ 2.20GHz (6C/12T) |
| メモリ | 48 GiB DDR3 |
| ストレージ | 7号機: 3本 SAS HDD (900GB x3, sdb/sdd/sde), 8号機: 3本 SAS HDD (900GB x3, sdb/sdc/sdd) |
| RAID コントローラ | DELL PERC (JBOD/passthrough) |
| ネットワーク (DRBD) | InfiniBand QDR (40Gb/s) — Mellanox ConnectX-3, IPoIB connected mode, MTU 65520 |
| IB PCIe 制約 | PCIe x4 (実効 ~16 Gbps) |

### ソフトウェア

| 項目 | バージョン |
|------|-----------|
| OS (ホスト) | Debian 13.3 (Trixie) + Proxmox VE 9.1.6 |
| カーネル | 6.17.13-2-pve |
| OS (VM) | Debian 13 (cloud image, カーネル 6.12.73) |
| DRBD | 9.3.1 (drbd-dkms + drbd-utils) |
| LINSTOR | Controller 1.33.1 (4号機), linstor-satellite + linstor-proxmox |
| fio | 3.39 |

### DRBD 構成

| 項目 | 設定 |
|------|------|
| Protocol | C (同期レプリケーション) |
| Place count | 2 (2ノードにレプリカ) |
| Quorum | off |
| Auto-promote | yes |
| Transport | IPoIB (192.168.100.7 ↔ 192.168.100.8) — PrefNic=ibp10s0 |
| リソース配置 | ayase-web-service-7 + ayase-web-service-8 |

### ストレージ構成

| 項目 | 設定 |
|------|------|
| VG | linstor_vg (3 PV per node, SAS HDD) |
| LVM | 通常 LV (ストライプ) |
| LINSTOR Pool | lvm (striped-pool) |
| LvcreateOptions | `-i3 -I64` (3本ストライプ, 64KiB) |
| 容量 | 7号機: 2.45 TiB, 8号機: 2.45 TiB |

### VM 構成

| 項目 | 値 |
|------|-----|
| VM ID | 100 |
| vCPU | 4 (host passthrough) |
| メモリ | 4096 MiB |
| ディスク | 32 GiB (SCSI, virtio-scsi-single, iothread) |
| net0 | vmbr1 (192.168.39.x DHCP, インターネット用) |
| net1 | vmbr0 (10.10.10.210/8, SSH 管理用) |

## ベンチマーク結果

### fio テスト条件

- ioengine: libaio, direct=1, numjobs=1, time_based, runtime=60s
- Random テスト: size=1G
- Sequential テスト: size=4G
- Mixed R/W: rwmixread=70

### 今回の結果 (IB, スキル検証)

| テスト | IOPS | BW (MiB/s) | Avg Lat (ms) | p99 Lat (ms) |
|--------|------|------------|--------------|--------------|
| Random Read 4K QD1 | 383 | 1.50 | 2.584 | 13.566 |
| Random Read 4K QD32 | 3,134 | 12.24 | 10.186 | 104.333 |
| Random Write 4K QD1 | 3,861 | 15.08 | 0.229 | 0.659 |
| Random Write 4K QD32 | 4,566 | 17.84 | 6.976 | 27.394 |
| Sequential Read 1M QD32 | 553 | 552.85 | 57.842 | 126.353 |
| Sequential Write 1M QD32 | 534 | 534.08 | 59.829 | 92.799 |
| Mixed R/W 4K QD32 (Read) | 1,576 | 6.16 | 19.637 | 101.188 |
| Mixed R/W 4K QD32 (Write) | 673 | 2.63 | 1.477 | 0.561 |

### 3回比較 (GbE → 前回IB → 今回IB)

| テスト | GbE IOPS | 前回IB IOPS | 今回IB IOPS | GbE→今回IB | 前回IB→今回IB |
|--------|----------|-------------|-------------|-----------|--------------|
| Random Read 4K QD1 | 418 | 260 | 383 | -8% | **+47%** |
| Random Read 4K QD32 | 3,935 | 2,522 | 3,134 | -20% | **+24%** |
| Random Write 4K QD1 | 1,938 | 2,714 | 3,861 | **+99%** | **+42%** |
| Random Write 4K QD32 | 3,691 | 3,727 | 4,566 | **+24%** | **+23%** |
| Seq Read 1M QD32 | 431 | 395 | 553 | **+28%** | **+40%** |
| Seq Write 1M QD32 | 112 | 367 | 534 | **+377%** | **+46%** |
| Mixed R/W 4K QD32 (R) | 1,864 | 1,848 | 1,576 | -15% | -15% |
| Mixed R/W 4K QD32 (W) | 797 | 791 | 673 | -16% | -15% |

## 分析

### 前回 IB vs 今回 IB: 大幅改善

今回の結果は前回 IB ベンチマークと比較して、ほぼ全テストで大幅に改善した (Mixed を除く)。特にシーケンシャル系は +40〜46% の向上。

考えられる原因:
1. **LVM/VG の再構成**: 前回は既存 VG の上にストレージプールを再作成した可能性があり、LVM メタデータやディスク上のレイアウトが最適でなかった。今回は wipefs → pvcreate → vgcreate をクリーンに実行
2. **DRBD リソースの完全再作成**: 前回は PrefNic 変更後に既存リソースが再接続された状態。今回はリソース自体を新規作成し、IB で初期同期→UpToDate まで完了後にベンチマーク実施
3. **HDD の状態**: ベンチマーク間でのディスクの温度・キャッシュ状態の差

### Sequential Write: GbE → +377%

GbE 時代の 112 MiB/s から 534 MiB/s へ。GbE ボトルネック (理論上限 ~120 MiB/s) が完全に解消され、3本 SAS HDD ストライプの書き込み性能を引き出せている。

### Sequential Read: +28% (vs GbE)

GbE ではネットワークボトルネックにはなっていなかったが、今回は 553 MiB/s と GbE 時 (431 MiB/s) より改善。DRBD の read-balancing やキャッシュ効果の可能性。

### Random Write QD1: +99% (vs GbE)

DRBD Protocol C の同期書き込みにおいて、IB の低レイテンシが効果的。Avg Latency が 0.478ms → 0.229ms に半減。

### Mixed R/W: -15% (vs GbE, 前回IB)

Mixed テストのみ一貫して低下。原因は不明だが、DRBD の IPoIB 経由での小ブロック mixed workload に何らかのオーバーヘッドがある可能性。

### ボトルネック分析

| テスト | ボトルネック |
|--------|------------|
| Seq Write | ディスク帯域幅 (534 MiB/s ≈ 3x SAS HDD 上限付近) |
| Seq Read | ディスク帯域幅 (553 MiB/s) |
| Random Read | ディスクシーク (HDD 物理制約) |
| Random Write QD1 | DRBD 同期レイテンシ (IB で改善) |
| Random Write QD32 | ディスク I/O 並列度 |

## 再現方法

1. config/linstor.yml に region-b ノード構成を設定
2. Phase 0: `linstor-bench-preflight.sh` を scp + 実行 (SMART チェック)
3. Phase 1: 既存 VM/LINSTOR リソース/LVM をクリーンアップ
4. Phase 2: VG 作成 (7号機 sdb/sdd/sde, 8号機 sdb/sdc/sdd) → LINSTOR ストレージプール → LvcreateOptions `-i3 -I64` → リソースグループ pve-rg-b → PVE ストレージ
5. Phase 3: VM 作成 (デュアル NIC, cloud-init, Ed25519 SSH 鍵)
6. Phase 4: DRBD UpToDate 待ち → ディスクリサイズ → SSH + fio インストール
7. Phase 5: fio 7テスト (randread/randwrite QD1/QD32, seqread/seqwrite 1M QD32, mixed 4K QD32)
8. Phase 6: Python で結果抽出 + レポート生成

全操作はスキル `linstor-bench` の Phase 0〜6 に準拠。
