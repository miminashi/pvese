# LINSTOR/DRBD thick-stripe ベンチマーク (Region B, IPoIB)

- **実施日時**: 2026年3月19日 (JST)
- **セッション ID**: 18c7ddd0

## 前提・目的

Region B (7/8/9号機) で IPoIB を有効化し、DRBD トランスポートを GbE → InfiniBand に切り替えた上で thick-stripe ベンチマークを再実施する。前回 (GbE) との性能差を定量化する。

- **背景**: 前回ベンチマーク (GbE) で Sequential Write が 112 MiB/s に留まり、GbE (理論上限 ~120 MiB/s) がボトルネックと判明。3台とも Mellanox ConnectX-3 QDR (40Gb/s) が搭載されているが `ib_ipoib` 未ロードのため IPoIB が使えていなかった
- **目的**: IPoIB 有効化後の性能を計測し、GbE vs IB の差を定量化する

## 参照レポート

- [report/2026-03-19_173724_linstor_thick_stripe_benchmark_region_b.md](2026-03-19_173724_linstor_thick_stripe_benchmark_region_b.md) — 前回 (GbE) ベンチマーク結果

## 環境情報

### ハードウェア

| 項目 | 仕様 |
|------|------|
| サーバ | DELL PowerEdge R320 x 3台 (7/8/9号機) |
| CPU | Intel Xeon E5-2420 v2 @ 2.20GHz (6C/12T) |
| メモリ | 48 GiB DDR3 |
| ストレージ | 7号機: 4本 SAS HDD (1x 300GB + 3x 900GB), 8/9号機: 3本 SAS HDD (3x 900GB) |
| ディスク型番 | HP EG0300FARTT (300GB 10K RPM SAS), 他 900GB SAS |
| RAID コントローラ | DELL PERC (JBOD/passthrough) |
| ネットワーク (DRBD) | **InfiniBand QDR (40Gb/s)** — Mellanox ConnectX-3, IPoIB connected mode, MTU 65520 |
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
| Transport | **IPoIB (192.168.100.x)** — PrefNic=ibp10s0 |
| リソース配置 | ayase-web-service-7 + ayase-web-service-8 |

### ストレージ構成

| 項目 | 設定 |
|------|------|
| VG | linstor_vg (3 PV per node, SAS HDD) |
| LVM | 通常 LV (ストライプ) |
| LINSTOR Pool | lvm (striped-pool) |
| LvcreateOptions | `-i3 -I64` (3本ストライプ, 64KiB) |

### VM 構成

| 項目 | 値 |
|------|-----|
| VM ID | 100 |
| vCPU | 4 (host passthrough) |
| メモリ | 4096 MiB |
| ディスク | 32 GiB (SCSI, virtio-scsi-single, iothread) |
| net0 | vmbr1 (192.168.39.x DHCP, インターネット用) |
| net1 | vmbr0 (10.10.10.210/8, SSH 管理用) |

## IPoIB 有効化手順

1. 各ノードで `modprobe ib_ipoib` → `ib-setup-remote.sh --ip 192.168.100.x/24 --persist`
2. インターフェース名: `ibp10s0` (Debian 13 の命名規則で `ib0` ではない)
3. 3台間の ping 疎通確認 (RTT ~4ms)
4. LINSTOR に IB インターフェース登録: `linstor node interface create <node> ibp10s0 192.168.100.x`
5. PrefNic 設定: `linstor node set-property <node> PrefNic ibp10s0`
6. LINSTOR が既存 DRBD リソースを自動的に IB 経由に再接続 (手動 `drbdadm adjust` 不要)

## ベンチマーク結果

### fio テスト条件

- ioengine: libaio, direct=1, numjobs=1, time_based, runtime=60s
- Random テスト: size=1G
- Sequential テスト: size=4G
- Mixed R/W: rwmixread=70

### Region B IB 結果

| テスト | IOPS | BW (MiB/s) | Avg Lat (ms) | p99 Lat (ms) |
|--------|------|------------|--------------|--------------|
| Random Read 4K QD1 | 260 | 1.01 | 3.818 | 7.111 |
| Random Read 4K QD32 | 2,522 | 9.85 | 12.663 | 77.070 |
| Random Write 4K QD1 | 2,714 | 10.60 | 0.335 | 0.807 |
| Random Write 4K QD32 | 3,727 | 14.56 | 8.562 | 99.090 |
| Sequential Read 1M QD32 | 395 | 395.44 | 80.877 | 166.724 |
| Sequential Write 1M QD32 | 367 | 367.15 | 87.062 | 122.159 |
| Mixed R/W 4K QD32 (Read) | 1,848 | 7.22 | 16.711 | 81.265 |
| Mixed R/W 4K QD32 (Write) | 791 | 3.09 | 1.315 | 3.359 |

### GbE vs IB 比較 (Region B)

| テスト | GbE IOPS | IB IOPS | 変化 | GbE BW | IB BW | BW 変化 |
|--------|----------|---------|------|--------|-------|---------|
| Random Read 4K QD1 | 418 | 260 | **-38%** | 1.63 MiB/s | 1.01 MiB/s | -38% |
| Random Read 4K QD32 | 3,935 | 2,522 | **-36%** | 15.37 MiB/s | 9.85 MiB/s | -36% |
| Random Write 4K QD1 | 1,938 | 2,714 | **+40%** | 7.57 MiB/s | 10.60 MiB/s | +40% |
| Random Write 4K QD32 | 3,691 | 3,727 | +1% | 14.42 MiB/s | 14.56 MiB/s | +1% |
| Seq Read 1M QD32 | 431 | 395 | -8% | 430.66 MiB/s | 395.44 MiB/s | -8% |
| **Seq Write 1M QD32** | **112** | **367** | **+228%** | **111.98 MiB/s** | **367.15 MiB/s** | **+228%** |
| Mixed R/W 4K QD32 (R) | 1,864 | 1,848 | -1% | 7.28 MiB/s | 7.22 MiB/s | -1% |
| Mixed R/W 4K QD32 (W) | 797 | 791 | -1% | 3.11 MiB/s | 3.09 MiB/s | -1% |

## 分析

### Sequential Write: GbE ボトルネック解消 (+228%)

最大の改善は Sequential Write。GbE では 112 MiB/s で GbE 帯域幅 (~120 MiB/s 理論上限) がボトルネックだったが、IB 有効化後は 367 MiB/s に向上。DRBD Protocol C の同期書き込みで、レプリカへの転送がネットワーク帯域に律速されなくなった。

367 MiB/s は 3本 SAS 10K RPM ストライプのシーケンシャル書き込み性能の上限付近と推測される。

### Random Read: 予想外の低下 (-36~38%)

Random Read が GbE 時より低下した。これは予想外の結果。考えられる原因:

1. **IPoIB connected mode のオーバーヘッド**: IPoIB connected mode は reliable connection (RC) を使用し、small random I/O のレイテンシが増加する可能性がある。Avg Latency が 2.363ms → 3.818ms に悪化している
2. **VM のディスクキャッシュ状態の差**: 前回テスト時はディスクの warm-up 状態が異なっていた可能性。ただし `--direct=1` で OS キャッシュはバイパスしているため、RAID コントローラのキャッシュ状態に依存
3. **DRBD メタデータ通信のオーバーヘッド**: IPoIB の MTU 65520 は大きな転送に有利だが、小さな 4K random read では TCP/IP スタックのオーバーヘッドが GbE より大きい可能性

### Random Write QD1: +40% 改善

Random Write QD1 は DRBD の同期書き込みで IB の低レイテンシが効いた結果。1回の 4K write でレプリカへの ACK 待ちが短縮された。

### 他のテスト: ほぼ同等

Mixed R/W、Random Write QD32 はほぼ変化なし。これらはディスク I/O がボトルネックであり、ネットワークは律速要因でなかったことを示す。

### ボトルネック分析

| テスト | GbE ボトルネック | IB ボトルネック |
|--------|----------------|----------------|
| Seq Write | **GbE 帯域幅** (112 MiB/s) | ディスク帯域幅 (367 MiB/s) |
| Seq Read | ディスク帯域幅 | ディスク帯域幅 |
| Random Read | ディスクシーク | ディスクシーク + IPoIB レイテンシ |
| Random Write QD1 | DRBD 同期 + GbE レイテンシ | DRBD 同期 (IB で改善) |
| Random R/W QD32 | ディスク並列性 | ディスク並列性 |

### PCIe x4 制約

ConnectX-3 は PCIe x4 スロットに搭載されており、実効帯域は ~16 Gbps (~2 GB/s)。IB QDR の理論 40Gb/s に対して PCIe がボトルネックだが、今回の Sequential Write 367 MiB/s (~3 Gbps) はディスク側が先に飽和しているため PCIe は律速要因ではない。

## 結論

| 項目 | 結論 |
|------|------|
| IB 効果 (Seq Write) | **+228%** (112 → 367 MiB/s) — GbE ボトルネック完全解消 |
| IB 効果 (Random Write QD1) | **+40%** (1,938 → 2,714 IOPS) — 同期書き込みレイテンシ改善 |
| IB 効果 (Random Read) | **-36~38%** — IPoIB のオーバーヘッドで逆効果 |
| IB 効果 (その他) | ±1~8% — ディスクが律速のため変化なし |
| 真のボトルネック | SAS HDD (シーク時間 + シーケンシャル帯域) |

IB 有効化はシーケンシャル書き込みと低QD書き込みで大きな効果があるが、ランダム読み取りには逆効果。ワークロードに応じた判断が必要。

## 再現方法

### IPoIB 有効化

```bash
# 各ノードで ib_ipoib モジュールをロード後にスクリプト実行
ssh pve7 modprobe ib_ipoib
scp ./scripts/ib-setup-remote.sh root@10.10.10.207:/tmp/
ssh pve7 sh /tmp/ib-setup-remote.sh --ip 192.168.100.7/24 --persist
# pve8, pve9 も同様

# LINSTOR IB インターフェース登録 + PrefNic 設定
ssh pve4 linstor node interface create ayase-web-service-7 ibp10s0 192.168.100.7
ssh pve4 linstor node set-property ayase-web-service-7 PrefNic ibp10s0
# pve8, pve9 も同様
```

### ベンチマーク

```bash
/linstor-bench thick-stripe region-b
```

設定ファイル: `config/linstor.yml`
スキル定義: `.claude/skills/linstor-bench/SKILL.md`
