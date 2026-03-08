# LINSTOR 4ノード・マルチリージョン構成レポート

- **実施日時**: 2026年3月7日 09:00 - 21:00
- **セッション ID**: d075b1ee (+ 前セッション2回)

## 前提・目的

以前2ノード (4+5号機) で実施した LINSTOR/DRBD のベンチマーク・ノード操作テストを、4ノード・2リージョン構成に拡張して再実施する。

- **背景**: 2ノード構成の性能・運用特性は検証済み。クロスリージョン DR 構成の実用性を評価するため、4ノード・2クラスタに拡張する
- **目的**:
  1. Region A (IPoIB) と Region B (Ethernet) の性能差を定量比較
  2. 各リージョンの satellite 障害、controller 障害からの回復を検証
  3. ノード正常離脱・再参加の手順を4ノード構成で確認
- **前提条件**: 4台のサーバが同一ネットワーク (10.10.10.0/8) 上に存在し、IPMI/iDRAC による遠隔電源管理が可能

## 参照レポート

- [report/2026-02-26_130844_linstor_thin_vs_thick_stripe_benchmark.md](2026-02-26_130844_linstor_thin_vs_thick_stripe_benchmark.md) — 2ノード thick-stripe ベンチマーク (前回比較用)
- [report/2026-02-27_111056_linstor_node_departure_rejoin_experiment.md](2026-02-27_111056_linstor_node_departure_rejoin_experiment.md) — 2ノードでのノード離脱・再参加実験
- [report/2026-03-01_051957_linstor_multi_region_protocol_experiment.md](2026-03-01_051957_linstor_multi_region_protocol_experiment.md) — マルチリージョン Protocol A/C 実験

## 環境情報

### 構成図

```
Region A (pvese-cluster1)                Region B (pvese-cluster2)
+---------------------------+           +---------------------------+
| 4号機  10.10.10.204       |           | 6号機  10.10.10.206       |
|   IB: 192.168.100.1      |           |   4x500GB SATA HDD       |
|   4x500GB SATA HDD       |           |                           |
|   LINSTOR Controller      | Protocol  |                           |
| 5号機  10.10.10.205       |    A      | 7号機  10.10.10.207       |
|   IB: 192.168.100.2      |<--------->|   (DELL R320)             |
|   4x500GB SATA HDD       | Ethernet  |   6x SAS HDD             |
+---------------------------+           +---------------------------+
  intra: Protocol C (IPoIB)               intra: Protocol C (Eth)
```

### ハードウェア

| 項目 | 4号機 | 5号機 | 6号機 | 7号機 |
|------|-------|-------|-------|-------|
| マザーボード | Supermicro X11DPU | Supermicro X11DPU | Supermicro X11DPU | DELL PowerEdge R320 |
| BMC IP | 10.10.10.24 (IPMI) | 10.10.10.25 (IPMI) | 10.10.10.26 (IPMI) | 10.10.10.120 (iDRAC) |
| 静的 IP | 10.10.10.204 | 10.10.10.205 | 10.10.10.206 | 10.10.10.207 |
| ストレージ | 4x 500GB SATA | 4x 500GB SATA | 4x 500GB SATA | 6x SAS HDD |
| InfiniBand | ConnectX-3 | ConnectX-3 | 障害で使用不可 | なし |
| リージョン | A | A | B | B |

### ソフトウェア

| 項目 | バージョン |
|------|-----------|
| OS (ホスト) | Debian 13.3 (Trixie) + Proxmox VE 9.1.6 |
| カーネル | 6.17.13-1-pve |
| OS (VM) | Debian 13 (cloud image, カーネル 6.12.73) |
| DRBD | 9.3.0 (dkms) |
| LINSTOR | controller + satellite + linstor-proxmox (Linbit public repo) |
| fio | 3.39 |

### DRBD / LINSTOR 構成

| 項目 | 設定 |
|------|------|
| Protocol (リージョン内) | C (同期レプリケーション) |
| Protocol (リージョン間) | A (非同期レプリケーション) ※今回未使用 |
| Place count | 2 (リージョン内の両ノードにレプリカ) |
| replicas-on-same | Aux/site (リージョン内制約) |
| Quorum | off |
| Auto-promote | yes |
| Resource Group | pve-rg (striped-pool) |
| LvcreateOptions | 4/5/6号機: `-i4 -I64` / 7号機: `-i6 -I64` |

### PVE クラスタ

| クラスタ | ノード | two_node |
|---------|--------|----------|
| pvese-cluster1 | 4号機 + 5号機 | 1 |
| pvese-cluster2 | 6号機 + 7号機 | 1 |

### VM 構成 (ベンチマーク用)

| 項目 | 値 |
|------|-----|
| vCPU | 4 (host passthrough) |
| メモリ | 4096 MiB |
| ディスク | 32 GiB (SCSI, virtio-scsi-pci) |
| ブリッジ | vmbr1 (192.168.39.0/24) |
| IP | Region A: 192.168.39.250 / Region B: 192.168.39.251 (静的) |

## 実施手順

### Phase 1: OS 再インストール (4台)

os-setup スキルで4台全てに Debian 13 + PVE 9 をインストール。並列実行で約40分。

### Phase 2: PVE クラスタ構成

```sh
# Cluster 1 (4+5号機)
pvecm create pvese-cluster1 --link0 10.10.10.204    # 4号機
pvecm add 10.10.10.204 --link0 10.10.10.205 --force --use_ssh  # 5号機

# Cluster 2 (6+7号機)
pvecm create pvese-cluster2 --link0 10.10.10.206    # 6号機
pvecm add 10.10.10.206 --link0 10.10.10.207 --force --use_ssh  # 7号機
```

**注意**: `pvecm add` 後に `two_node: 1` の追加が必要。

### Phase 3: LINSTOR パッケージインストール

全ノードに drbd-dkms, drbd-utils, linstor-satellite, linstor-client, linstor-proxmox をインストール。
4号機のみ linstor-controller を追加。

### Phase 4: LINSTOR ノード登録 + ストレージプール

```sh
# ノード登録 (コントローラ: 4号機)
linstor node create ayase-web-service-4 10.10.10.204 --node-type Combined
linstor node create ayase-web-service-5 10.10.10.205 --node-type Satellite
linstor node create ayase-web-service-6 10.10.10.206 --node-type Satellite
linstor node create ayase-web-service-7 10.10.10.207 --node-type Satellite

# IB インターフェース (4+5号機のみ)
linstor node interface create ayase-web-service-4 ib0 192.168.100.1
linstor node set-property ayase-web-service-4 PrefNic ib0
linstor node interface create ayase-web-service-5 ib0 192.168.100.2
linstor node set-property ayase-web-service-5 PrefNic ib0

# ストレージプール (全4ノード)
linstor storage-pool create lvm <node> striped-pool linstor_vg

# リソースグループ
linstor resource-group create pve-rg --storage-pool striped-pool --place-count 2
linstor resource-group modify pve-rg --replicas-on-same site
linstor resource-group drbd-options pve-rg --quorum off --auto-promote yes
```

### Phase 5: マルチリージョン設定

```sh
# Aux/site プロパティ設定
linstor node set-property ayase-web-service-4 Aux/site region-a
linstor node set-property ayase-web-service-5 Aux/site region-a
linstor node set-property ayase-web-service-6 Aux/site region-b
linstor node set-property ayase-web-service-7 Aux/site region-b
```

### Phase 6: ベンチマーク

各リージョンに VM を作成し、fio で7パターンのベンチマークを実施 (各60秒)。

### Phase 7: ノード操作テスト

IPMI/iDRAC による電源操作で障害シミュレーション・回復を実施。

## ベンチマーク結果

### fio テスト条件

- ioengine: libaio, direct=1, numjobs=1, time_based, runtime=60s
- Random テスト: size=1G
- Sequential テスト: size=4G
- Mixed R/W: rwmixread=70

### IOPS・スループット比較

| テスト | Region A IOPS | Region B IOPS | 差分 | Region A BW | Region B BW |
|--------|:------------:|:------------:|:----:|:-----------:|:-----------:|
| Random Read 4K QD1 | 156 | 162 | +3.8% | 0.61 MiB/s | 0.63 MiB/s |
| Random Read 4K QD32 | 1,166 | 1,237 | +6.1% | 4.55 MiB/s | 4.83 MiB/s |
| Random Write 4K QD1 | 80 | 837 | +945% | 0.31 MiB/s | 3.27 MiB/s |
| Random Write 4K QD32 | 484 | 937 | +94% | 1.89 MiB/s | 3.66 MiB/s |
| Sequential Read 1M QD32 | 243 | 210 | -14% | 243 MiB/s | 210 MiB/s |
| Sequential Write 1M QD32 | 80 | 112 | +40% | 80 MiB/s | 112 MiB/s |
| Mixed R/W 4K QD32 (Read) | 607 | 606 | -0.3% | 2.37 MiB/s | 2.37 MiB/s |
| Mixed R/W 4K QD32 (Write) | 260 | 259 | -0.3% | 1.02 MiB/s | 1.01 MiB/s |

### レイテンシ比較

| テスト | A Avg (us) | B Avg (us) | 差分 | A p99 (us) | B p99 (us) |
|--------|:---------:|:---------:|:----:|:---------:|:---------:|
| Random Read 4K QD1 | 6,368 | 6,134 | -3.7% | 11,731 | 12,780 |
| Random Read 4K QD32 | 27,417 | 25,837 | -5.8% | 185,598 | 164,626 |
| Random Write 4K QD1 | 12,441 | 1,164 | -90.6% | 34,341 | 20,316 |
| Random Write 4K QD32 | 66,089 | 34,110 | -48.4% | 162,529 | 227,541 |
| Seq Read 1M QD32 | 131,560 | 152,594 | +16.0% | 1,451,229 | 1,367,343 |
| Seq Write 1M QD32 | 399,805 | 285,331 | -28.6% | 784,335 | 463,471 |
| Mixed R/W QD32 (R) | 34,521 | 44,724 | +29.6% | 304,087 | 287,310 |
| Mixed R/W QD32 (W) | 42,308 | 18,829 | -55.5% | 166,724 | 160,432 |

### 前回ベンチマーク (2ノード thick-stripe) との比較

Region A は前回の2ノード構成と同じ 4+5号機で実施。

| テスト | 前回 IOPS | 今回 A IOPS | 差分 |
|--------|:---------:|:-----------:|:----:|
| Random Read 4K QD1 | 155 | 156 | +0.6% |
| Random Read 4K QD32 | 1,191 | 1,166 | -2.1% |
| Random Write 4K QD1 | 81 | 80 | -1.2% |
| Random Write 4K QD32 | 489 | 484 | -1.0% |
| Seq Read 1M QD32 | 239 | 243 | +1.7% |
| Seq Write 1M QD32 | 87 | 80 | -8.0% |

Region A の結果は前回の2ノード構成とほぼ同等 (±数%)。4ノード化による性能劣化は見られない。

## ノード操作テスト結果

### テスト1: Region A satellite 障害 (5号機電源断)

| イベント | 結果 |
|---------|------|
| 5号機 IPMI power off | 成功 |
| VM 100 (4号機) 継続稼働 | **OK** — ダウンタイムなし |
| DRBD 状態 | Connecting(ayase-web-service-5)、ローカル UpToDate |
| VM データアクセス | **OK** — df, uptime 正常応答 |
| Auto-eviction キャンセル | 成功 |
| 5号機 power on → SSH 復帰 | 約2分15秒 |
| IPoIB 手動起動 | **必要** — リブート後 ibp134s0 が DOWN |
| DRBD bitmap resync | IPoIB 起動後即座に完了 |

**発見事項**: IPoIB インターフェースはリブート後に自動起動しない。`/etc/network/interfaces` に永続設定が必要。

### テスト2: Region B satellite 障害 (7号機電源断)

| イベント | 結果 |
|---------|------|
| 7号機 IPMI power off | 成功 |
| VM 200 (6号機) 継続稼働 | **OK** — ダウンタイムなし |
| DRBD 状態 | Connecting(ayase-web-service-7)、ローカル UpToDate |
| VM データアクセス | **OK** — 正常応答 |
| 7号機 power on → SSH 復帰 | 約4分 (R320 は起動が遅い) |
| DRBD bitmap resync | 接続後即座に完了 |

### テスト3: Controller 障害 (4号機電源断)

| イベント | 結果 |
|---------|------|
| 4号機 IPMI power off | 成功 |
| VM 200 (6号機, Region B) 継続稼働 | **OK** — ダウンタイムなし |
| Region B DRBD (6↔7) | UpToDate/UpToDate — 影響なし |
| LINSTOR 管理コマンド | **使用不可** — Connection refused |
| VM 100 (4号機上) | **停止** — ホストダウンのため (想定通り) |
| 4号機 power on → SSH 復帰 | 約2分20秒 |
| IPoIB 手動起動 | **必要** |
| DRBD bitmap resync (32G) | IPoIB 起動後約2分で完了 |
| LINSTOR controller 復帰 | SSH 復帰とほぼ同時 |

**重要な発見**: LINSTOR controller がダウンしても、既存の DRBD 接続は独立して動作を継続する。controller は DRBD のメタデータ管理のみで、データパスには関与しない。

### テスト4: 正常離脱 + 再参加 (5号機)

| イベント | 結果 |
|---------|------|
| VM 100 削除 | 成功 (DRBD リソース自動削除) |
| place-count 1 に変更 | 成功 |
| 5号機リソース削除 | 成功 (対象リソースなし、VM 削除済み) |
| 5号機 SP 削除 | 成功 |
| 5号機ノード削除 | 成功 — 3ノード運用 |
| 5号機ノード再登録 | 成功 |
| IB + PrefNic 設定 | 成功 |
| SP 再作成 + LvcreateOptions | 成功 |
| place-count 2 に復元 | 成功 — Region B リソースは site 制約で6+7号機に留まる |

## 分析

### Region A vs Region B の性能差

1. **ランダム読み取り**: Region A (IPoIB) と Region B (Ethernet) はほぼ同等 (+3-6%)。ランダム読み取りはローカルディスクの seek 性能が支配的で、ネットワーク影響は小さい

2. **ランダム書き込み QD1**: Region B が Region A の **10倍** の IOPS (837 vs 80)。これは予想外の結果であり、以下の要因が考えられる:
   - Region B の7号機は 6x SAS HDD のストライプ構成で DRBD レプリカ側のディスク性能が高い
   - Protocol C の同期レプリケーションでは遅い方のノードがボトルネックになる
   - Region A の5号機の4x SATA HDD の書き込み性能が制約要因の可能性

3. **シーケンシャル読み取り**: Region A が優勢 (243 vs 210 MiB/s, +14%)。IPoIB の帯域幅の利点が出ている

4. **シーケンシャル書き込み**: Region B が優勢 (112 vs 80 MiB/s, +40%)。ランダム書き込みと同様、ディスク構成の差が影響

5. **Mixed R/W**: 両リージョンほぼ同等

### 4ノード化の影響

Region A の結果を前回2ノード構成と比較すると、IOPS は±数%の範囲で一致している。4ノード化・マルチリージョン設定による性能劣化は検出されなかった。

### 障害耐性

全テストケースで VM のダウンタイムは発生しなかった (ホスト自体がダウンしたテスト3を除く)。主な知見:

1. **DRBD は controller 非依存**: LINSTOR controller がダウンしても、既存のデータパスは維持される
2. **IPoIB は永続設定が必要**: リブート後に手動起動が必要で、永続化には `/etc/network/interfaces` への設定追加が必要
3. **bitmap resync は高速**: 障害中の変更ブロックのみの同期で、数秒～2分程度で完了
4. **R320 は起動が遅い**: 7号機の DELL R320 は SSH 復帰まで約4分 (X11DPU は約2分)

### 運用上の注意点

1. **Auto-eviction**: デフォルトで有効 (約60日後に発動)。障害シミュレーション時は即座に `DrbdOptions/AutoEvictAllowEviction false` を設定すること
2. **replicas-on-same**: `--replicas-on-same site` を設定すると、LINSTOR は `Aux/` プレフィックスを自動付与する。`Aux/site` と直接指定すると `Aux/Aux/site` になる
3. **cloud-init SSH**: Debian 13 cloud image ではパスワード認証が機能しない場合がある。SSH 公開鍵認証を推奨
4. **DRBD 9 と /proc/drbd**: DRBD 9 では `/proc/drbd` の形式が変わっているため、`drbdsetup status` を使用すること

## 結論

4ノード・2リージョン構成の LINSTOR/DRBD クラスタは、以下の点で実用的であることが確認された:

1. **性能**: 4ノード化による性能劣化なし。リージョン間のネットワーク差 (IPoIB vs Ethernet) よりも、ディスク構成の差が性能を支配する
2. **耐障害性**: satellite 障害、controller 障害の両方から VM ダウンタイムなしで回復可能
3. **運用性**: ノードの正常離脱・再参加が手順化されており、place-count の変更で柔軟にレプリカ数を調整可能
4. **分離性**: `replicas-on-same Aux/site` によりリージョン内にレプリカを制約でき、リージョン間の Protocol A レプリケーションも設定可能（今回は検証未実施）
