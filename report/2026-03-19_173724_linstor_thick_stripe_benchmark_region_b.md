# LINSTOR/DRBD thick-stripe ベンチマーク (Region B)

- **実施日時**: 2026年3月19日 16:58 - 17:37 (JST)
- **セッション ID**: 50074b8a

## 前提・目的

Region B (7/8/9号機, DELL PowerEdge R320) で LINSTOR/DRBD thick-stripe ストレージの性能を計測する。

- **背景**: Region A (4/5/6号機, Supermicro X11DPU) で thick-stripe ベンチマーク済み。Region B は異なるハードウェア (DELL R320, SAS 10K RPM HDD, GbE Ethernet) のため性能特性が異なる可能性がある
- **目的**: Region B の thick-stripe 性能を定量的に計測し、Region A との比較を行う
- **前提条件**: 3ノード PVE クラスタ (Region B) + LINSTOR controller (4号機) が構築済み

## 参照レポート

- [report/2026-02-26_130844_linstor_thin_vs_thick_stripe_benchmark.md](2026-02-26_130844_linstor_thin_vs_thick_stripe_benchmark.md) -- Region A の thin vs thick-stripe 比較ベンチマーク

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
| ネットワーク | GbE Ethernet (10.10.10.0/8) -- DRBD レプリケーション用 |

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
| Transport | GbE Ethernet (10.10.10.x) |
| リソース配置 | ayase-web-service-7 + ayase-web-service-8 |

### ストレージ構成

| 項目 | 設定 |
|------|------|
| VG | linstor_vg (3 PV per node, SAS HDD) |
| LVM | 通常 LV (ストライプ) |
| LINSTOR Pool | lvm (striped-pool) |
| LvcreateOptions | `-i3 -I64` (3本ストライプ, 64KiB) |
| 容量 | 7号機: 2.73 TiB, 8/9号機: 2.45 TiB |
| DRBD 初期同期 (32G) | 約3分 (GbE Ethernet) |

**注**: 7号機は 4本の PV があるが、ディスクサイズの不均一 (300GB + 900GB x 3) により DRBD のペアノード (8号機, 3本 900GB) と LV サイズ不一致が発生するため、全ノード `-i3` に統一した。

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

### Region B 結果

| テスト | IOPS | BW (MiB/s) | Avg Lat (ms) | p99 Lat (ms) |
|--------|------|------------|--------------|--------------|
| Random Read 4K QD1 | 418 | 1.63 | 2.363 | 6.980 |
| Random Read 4K QD32 | 3,935 | 15.37 | 8.111 | 67.633 |
| Random Write 4K QD1 | 1,938 | 7.57 | 0.478 | 0.782 |
| Random Write 4K QD32 | 3,691 | 14.42 | 8.636 | 90.702 |
| Sequential Read 1M QD32 | 431 | 430.66 | 74.262 | 119.013 |
| Sequential Write 1M QD32 | 112 | 111.98 | 285.192 | 509.608 |
| Mixed R/W 4K QD32 (Read) | 1,864 | 7.28 | 16.518 | 84.410 |
| Mixed R/W 4K QD32 (Write) | 797 | 3.11 | 1.433 | 1.335 |

### Region A vs Region B 比較

| テスト | Region A IOPS | Region B IOPS | 倍率 | Region A BW | Region B BW |
|--------|---------------|---------------|------|-------------|-------------|
| Random Read 4K QD1 | 155 | 418 | **2.7x** | 619 KiB/s | 1.63 MiB/s |
| Random Read 4K QD32 | 1,191 | 3,935 | **3.3x** | 4.7 MiB/s | 15.37 MiB/s |
| Random Write 4K QD1 | 81 | 1,938 | **23.9x** | 324 KiB/s | 7.57 MiB/s |
| Random Write 4K QD32 | 489 | 3,691 | **7.5x** | 1.9 MiB/s | 14.42 MiB/s |
| Seq Read 1M QD32 | 239 | 431 | **1.8x** | 238.7 MiB/s | 430.66 MiB/s |
| Seq Write 1M QD32 | 87 | 112 | **1.3x** | 86.9 MiB/s | 111.98 MiB/s |
| Mixed R/W 4K QD32 (R) | 636 | 1,864 | **2.9x** | 2.5 MiB/s | 7.28 MiB/s |
| Mixed R/W 4K QD32 (W) | 272 | 797 | **2.9x** | 1.1 MiB/s | 3.11 MiB/s |

## 分析

### Region B が Region A を大幅に上回った要因

Region B (DELL R320) は全テストで Region A (Supermicro X11DPU) を上回った。特にランダムライト QD1 は **23.9倍** の差。考えられる要因:

1. **SAS 10K RPM vs SATA 7.2K RPM**: Region B は SAS 10,025 RPM ディスクを使用しており、回転速度が約1.4倍高い。ランダム I/O はシーク時間に依存するため、回転速度の差が顕著に出る

2. **RAID コントローラのライトバックキャッシュ**: DELL PERC コントローラにはバッテリバックアップ付きキャッシュ (BBU) があり、ライトバックキャッシュが有効になっている可能性が高い。これはランダムライト性能を劇的に向上させる (QD1 で 81 -> 1,938 IOPS)

3. **ストライプ本数 3 vs 4**: Region B は 3本ストライプだが、SAS HDD の高い個別性能で十分に補っている

4. **シーケンシャル読み取り 430 MiB/s**: GbE (理論上限 ~120 MiB/s) を大幅に超えているが、これはローカルディスクからの読み取り (Primary ノード) で DRBD レプリケーションの制約を受けないため

5. **シーケンシャル書き込み 112 MiB/s**: GbE 帯域幅の上限付近。DRBD Protocol C (同期書き込み) でレプリカへの書き込み完了を待つため、GbE がボトルネックになっている

### ボトルネック分析

| テスト | ボトルネック |
|--------|------------|
| Seq Write | GbE 帯域幅 (~120 MiB/s 理論上限、実測 112 MiB/s) |
| Seq Read | ディスク帯域幅 (3本 SAS ストライプ: 430 MiB/s) |
| Random Read QD1 | ディスクシーク時間 (10K RPM SAS) |
| Random Write QD1 | RAID コントローラキャッシュ (BBU ライトバック) |
| Random R/W QD32 | ディスク並列性 (3本ストライプ + コントローラキュー) |

### DRBD 初期同期

32G thick ディスクの初期同期は約3分で完了。Region A (IPoIB) では約9分かかっていたが、Region B では GbE にもかかわらず短時間で完了した。同期レートの差はデータ量とディスク速度に依存する。

### Region A とのネットワークの違い

| 項目 | Region A | Region B |
|------|----------|----------|
| DRBD 通信 | IPoIB (InfiniBand) | GbE Ethernet |
| 理論帯域幅 | ~6 Gbps (FDR10) | ~1 Gbps |
| Seq Write 結果 | 86.9 MiB/s | 111.98 MiB/s |

Region A は IPoIB で高帯域にもかかわらず Seq Write が低い。これはディスク側 (SATA 7.2K RPM) がボトルネックであり、ネットワークの速度差がそのまま性能に反映されないことを示す。

## 再現方法

### 使用スキル

```bash
/linstor-bench thick-stripe region-b
```

### 手動実行手順

1. Phase 0: `scripts/linstor-bench-preflight.sh` で SMART チェック (7/8/9号機)
2. Phase 1: 既存リソースが無い場合はスキップ
3. Phase 2: ストレージプール (striped-pool) + リソースグループ (pve-rg-b) 作成
   - **注意**: 全ノード `-i3 -I64` に統一する (ディスク本数の不均一対策)
   - vmbr0/vmbr1 ブリッジが無い場合は作成する (7号機は初期状態でブリッジ無し)
4. Phase 3: `qm create` -> `qm importdisk` -> cloud-init 設定 -> `qm start`
   - Ed25519 公開鍵を使用 (F17: Debian 13 OpenSSH 10.0 は RSA 非対応)
   - デュアル NIC: net0=vmbr1 (DHCP), net1=vmbr0 (10.10.10.210/8)
5. Phase 4: DRBD 同期完了待ち (~3分) -> SSH (10.10.10.210) -> fio インストール
6. Phase 5: fio 7テスト実行 (各60秒、合計約7分)

### 発見した追加知見

- **LvcreateOptions とノード間 LV サイズ不一致**: `-i4` (4本ストライプ) と `-i3` (3本ストライプ) を混在させると、同じ要求サイズでも LV の実サイズがエクステントアライメントの違いにより異なる。DRBD は "The peer's disk size is too small!" エラーで接続を拒否する。リソースグループ内で配置される可能性のある全ノードのストライプ数を統一する必要がある
- **DELL R320 にはデフォルトで PVE ブリッジが設定されていない**: OS インストール後に vmbr0/vmbr1 を手動作成する必要がある (`ifreload -a` で動的適用可能)

設定ファイル: `config/linstor.yml`
Preflight スクリプト: `scripts/linstor-bench-preflight.sh`
スキル定義: `.claude/skills/linstor-bench/SKILL.md`
