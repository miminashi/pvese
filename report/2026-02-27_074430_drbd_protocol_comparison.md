# DRBD レプリケーション Protocol 比較レポート

- **実施日時**: 2026年2月27日 07:44
- **セッション ID**: aee62582

## 前提・目的

pvese 環境では DRBD Protocol C（同期レプリケーション）を採用し、IPoIB (40 Gbps InfiniBand) 上で 2 ノード間のデータ同期を行っている。DRBD には Protocol A（非同期）、Protocol B（半同期）、Protocol C（同期）の 3 種類のレプリケーションモードが存在するが、これらの特徴や選定基準が文書化されていない。

- **背景**: 既存ベンチマークで Protocol C の性能特性は把握済みだが、Protocol A/B との比較検討が未実施
- **目的**: 3 つの Protocol を体系的に整理し、ネットワーク特性やワークロードに応じた選定ガイドラインを提供する
- **前提条件**: DRBD 9.x / LINSTOR 環境を対象とする

## 参照レポート

- [report/2026-02-26_052044_linstor_drbd_benchmark.md](2026-02-26_052044_linstor_drbd_benchmark.md) — LINSTOR/DRBD 構築 + VM ベンチマーク (Protocol C, thin pool)
- [report/2026-02-26_130844_linstor_thin_vs_thick_stripe_benchmark.md](2026-02-26_130844_linstor_thin_vs_thick_stripe_benchmark.md) — thin vs thick-stripe ベンチマーク比較 (Protocol C)

## 環境情報

| 項目 | 詳細 |
|------|------|
| **Server 4** | 10.10.10.204 / IB: 192.168.100.1 (Supermicro X11DPU) |
| **Server 5** | 10.10.10.205 / IB: 192.168.100.2 (Supermicro X11DPU) |
| **OS** | Debian 13.3 (Trixie) + Proxmox VE 9.1.6 |
| **カーネル** | 6.17.9-1-pve |
| **DRBD** | 9.3.0 (drbd-dkms 9.3.0-1, drbd-utils 9.33.0-1) |
| **LINSTOR** | Controller/Satellite 1.33.1-1 |
| **IB** | Mellanox ConnectX-3 QDR 40 Gbps (IPoIB Connected Mode) |
| **ストレージ** | 各ノード 4 x 500GB SATA HDD, LVM thick stripe (`-i4 -I64`) |
| **DRBD 設定** | Protocol C, quorum=off, auto-promote=yes, PrefNic=ib0 |
| **設定ファイル** | `config/linstor.yml` |

## DRBD Protocol 概要

DRBD は書き込み操作の完了条件（アプリケーションに ACK を返すタイミング）によって 3 つのレプリケーションモードを提供する。

| 項目 | Protocol A (非同期) | Protocol B (半同期) | Protocol C (同期) |
|------|-------------------|-------------------|-------------------|
| **書き込み完了条件** | ローカルディスク書き込み完了 + TCP 送信バッファへの投入 | ローカルディスク書き込み完了 + リモートノードの受信確認 (メモリ) | ローカルディスク書き込み完了 + リモートディスク書き込み完了 |
| **データ安全性** | 低（フェイルオーバー時にデータ損失の可能性） | 中（両ノード同時電源断でのみ損失の可能性） | 高（単一ノード障害でデータ損失なし） |
| **書き込みレイテンシ** | 最低（ネットワーク遅延の影響なし） | 低（ネットワーク RTT の半分が加算） | 最高（ネットワーク RTT + リモートディスク I/O が加算） |
| **スループット** | Protocol 間で大差なし | Protocol 間で大差なし | Protocol 間で大差なし |
| **主な用途** | 遠距離レプリケーション (DR) | 低レイテンシ要件 + 一定のデータ保護 | 一般的な HA 構成（最も広く使用） |

> **注**: LINBIT 公式ドキュメントによれば、スループットはレプリケーション Protocol の選択にほぼ依存しない。影響を受けるのは **データ保護レベル** と **レイテンシ** である。

## 各 Protocol の詳細解説

### Protocol A（非同期レプリケーション）

```
アプリ → [Write] → ローカルディスク書き込み
                  → TCP 送信バッファへ投入 → ACK をアプリに返す
                                           → (バックグラウンドで) リモートへ送信
```

**書き込み完了条件**: ローカルディスクへの書き込みが完了し、レプリケーションパケットがローカルの TCP 送信バッファに配置された時点で完了とみなす。

**データ損失リスク**:
- 強制フェイルオーバー時に、TCP 送信バッファに残っていた未送信データが失われる可能性がある
- スタンバイノードのデータは整合性を保つが、最新の更新が欠落する
- 書き込みスパイクが発生すると TCP 送信バッファが急速に埋まり、バッファ溢れによるデータ損失リスクが増大する

**ユースケース**:
- **遠距離 DR (Disaster Recovery)**: WAN 経由のレプリケーションでネットワーク遅延が大きい場合
- **DRBD Proxy との併用**: 帯域制限のある WAN リンクでバッファリングを行う構成
- **性能最優先のワークロード**: データ損失を許容できるバッチ処理やキャッシュ用途

### Protocol B（半同期 / メモリ同期レプリケーション）

```
アプリ → [Write] → ローカルディスク書き込み
                  → レプリケーションパケット送信
                  → リモートノードがメモリで受信確認 → ACK をアプリに返す
                                                    → (バックグラウンドで) リモートディスク書き込み
```

**書き込み完了条件**: ローカルディスクへの書き込みが完了し、リモートノードがレプリケーションパケットをメモリ上で受信したことを確認した時点で完了とみなす。

**データ損失リスク**:
- 通常のフェイルオーバー（片方のノード障害）ではデータ損失なし
- **両ノードが同時に電源断** し、かつプライマリのストレージが不可逆的に破壊された場合のみ損失の可能性
- リモートノードのメモリにはデータが到達しているが、ディスクに永続化される前に電源断が起きるシナリオ

**ユースケース**:
- **中距離レプリケーション**: 数 ms 〜 十数 ms の RTT があり Protocol C のレイテンシが許容できない場合
- **データ保護と性能のバランス**: Protocol A よりも安全、Protocol C よりも低レイテンシ
- **UPS で保護された環境**: 両ノード同時電源断のリスクが低い場合

### Protocol C（同期レプリケーション）

```
アプリ → [Write] → ローカルディスク書き込み
                  → レプリケーションパケット送信
                  → リモートディスク書き込み完了確認 → ACK をアプリに返す
```

**書き込み完了条件**: ローカルとリモートの**両方のディスク**への書き込みが確認された時点で完了とみなす。

**データ損失リスク**:
- 単一ノード障害ではデータ損失なし（書き込み完了 = 両ノードでディスクに永続化済み）
- 両ノードのストレージが同時に物理的に破壊される場合のみ損失の可能性（事実上ゼロ）

**ユースケース**:
- **DRBD で最も広く使用されるプロトコル**
- **一般的な HA (High Availability) 構成**: データ損失ゼロが要件の本番環境
- **低レイテンシネットワーク**: LAN / InfiniBand / RDMA など RTT が小さい環境

## 性能比較

### ネットワーク遅延とレイテンシの関係

Protocol C では、ネットワーク RTT とリモートディスク I/O 時間が書き込みレイテンシに直接加算される。以下は LINBIT ブログ記事の実測データ（4K ブロック、Protocol C、NVMe ストレージ）を基にした影響分析である。

| 追加ネットワーク遅延 | IOPS | 平均書き込みレイテンシ | ベースライン比 |
|---------------------|------|---------------------|--------------|
| 0 ms | 3,015 | 10.59 ms | 100% |
| 2 ms | 2,716 | 11.76 ms | 90% |
| 5 ms | 2,569 | 12.44 ms | 85% |
| 10 ms | 1,953 | 16.36 ms | 65% |
| 20 ms | 1,226 | 26.06 ms | 41% |

> 出典: [The Impact of Network Latency on Write Performance When Using DRBD (LINBIT Blog)](https://linbit.com/blog/the-impact-of-network-latency-on-write-performance-when-using-drbd/)

**Protocol 別のレイテンシモデル**:

| Protocol | 書き込みレイテンシの構成要素 |
|----------|--------------------------|
| A | `T_local_disk` |
| B | `T_local_disk + T_network_RTT` |
| C | `T_local_disk + T_network_RTT + T_remote_disk` |

- `T_local_disk`: ローカルディスクの書き込み時間
- `T_network_RTT`: ネットワーク往復遅延
- `T_remote_disk`: リモートディスクの書き込み時間

Protocol A はネットワーク遅延の影響を受けないが、Protocol B/C では RTT が直接レイテンシに加算される。Protocol C はさらにリモートディスクの I/O 時間も加算されるため、HDD 環境ではその影響が顕著になる。

### pvese 環境の実測値 (Protocol C, IPoIB, thick-stripe)

既存ベンチマーク（[thin vs thick-stripe レポート](2026-02-26_130844_linstor_thin_vs_thick_stripe_benchmark.md)）からの引用:

| テスト | IOPS | 平均レイテンシ | p99 レイテンシ |
|--------|------|--------------|--------------|
| Random Read 4K QD1 | 155 | 6.43 ms | 14.61 ms |
| Random Read 4K QD32 | 1,191 | 26.84 ms | 187.70 ms |
| Random Write 4K QD1 | 81 | 12.26 ms | 32.37 ms |
| Random Write 4K QD32 | 489 | 65.35 ms | 187.70 ms |
| Seq Read 1M QD32 | 239 | 134.02 ms | 1,434.45 ms |
| Seq Write 1M QD32 | 87 | 367.37 ms | 775.95 ms |

IPoIB の RTT は 0.1 ms 以下であるため、Protocol C でもネットワーク遅延の影響は無視できるレベルである。ボトルネックは SATA HDD のメカニカル I/O に集中している。

## Protocol と DRBD/LINSTOR 設定の関係

### Quorum との組み合わせ

| Protocol | Quorum 使用 | 備考 |
|----------|------------|------|
| A | 技術的には設定可能だが非推奨 | 非同期のため、quorum 判定時にリモートに未到達のデータが存在しうる。Quorum の「データが過半数のノードに到達している」前提が崩れる |
| B | 条件付きで可能 | メモリ受信は確認されるが、ディスク永続化前の障害でデータ不整合のリスクあり |
| C | **推奨** | 書き込み完了 = 全レプリカで永続化済みのため、quorum との整合性が最も高い |

pvese 環境では 2 ノード構成のため `quorum=off` としているが、将来 3 ノード以上に拡張して quorum を有効にする場合は Protocol C が事実上の必須要件となる。

### LINSTOR での Protocol 変更コマンド

#### リソースグループ単位（推奨: 新規リソースに適用）

```bash
# Protocol を変更
linstor resource-group drbd-options --protocol A pve-rg
linstor resource-group drbd-options --protocol B pve-rg
linstor resource-group drbd-options --protocol C pve-rg
```

リソースグループの変更は、**変更後に新規作成されるリソース**にのみ適用される。既存リソースには影響しない。

#### リソース定義単位（既存リソースに適用）

```bash
# 特定リソースの Protocol を変更
linstor resource-definition drbd-options --protocol A <resource-name>
```

#### 接続単位（特定ノード間のみ変更）

```bash
# 特定の接続に対して Protocol を変更
linstor resource-connection drbd-options --protocol A <resource-name> <node-a> <node-b>
```

### オンライン変更の可否

DRBD 9.x では `drbdadm adjust` コマンドにより、稼働中のリソースに対して設定変更を適用できる。LINSTOR 経由で Protocol を変更した場合も、LINSTOR が内部的に `drbdsetup net-options` を呼び出して接続中のリソースに変更を反映する。

**オンライン変更の手順**:
1. LINSTOR でリソース定義の Protocol を変更
2. LINSTOR が自動的に DRBD カーネルモジュールに設定を反映
3. I/O を停止する必要はない（ただし変更適用中に一時的なレイテンシ変動の可能性あり）

**注意点**:
- Protocol C → A への変更は、データ安全性の低下を意味する。運用手順上の承認プロセスを設けることを推奨
- 接続が切断状態（StandAlone）のときは、再接続時に新しい Protocol が使用される

## ネットワーク特性別の選定ガイドライン

### 推奨 Protocol マトリクス

| ネットワーク | RTT | 帯域幅 | 推奨 Protocol | 理由 |
|-------------|-----|--------|-------------|------|
| **InfiniBand RDMA** | < 0.01 ms | 40+ Gbps | **C** | RTT が無視できるため、同期レプリケーションのペナルティがほぼゼロ |
| **IPoIB** | < 0.1 ms | 10-40 Gbps | **C** | 上記とほぼ同等。pvese 環境はこの構成 |
| **10 GbE LAN** | 0.1-0.5 ms | 10 Gbps | **C** | LAN 内であれば Protocol C のレイテンシ増加は許容範囲 |
| **1 GbE LAN** | 0.2-1 ms | 1 Gbps | **C** (帯域に注意) | 帯域がボトルネックになる可能性。書き込みスループットが 1 Gbps を超える場合は B を検討 |
| **WAN (同一都市)** | 1-5 ms | 可変 | **B** or **C** | RTT 5 ms 以下なら C でも実用的。レイテンシ要件次第で B |
| **WAN (遠距離)** | 10-100 ms | 可変 | **A** | Protocol C では RTT がそのまま書き込みレイテンシに加算され実用的でない |
| **WAN + DRBD Proxy** | 50+ ms | 低帯域 | **A** | DRBD Proxy のバッファリングと組み合わせて DR 構成 |

### 選定フローチャート

```
ネットワーク RTT は?
│
├─ < 1 ms (LAN / IB)
│   │
│   └─ データ損失ゼロが要件?
│       ├─ Yes → Protocol C ★
│       └─ No  → Protocol C (性能差が小さいため C を推奨)
│
├─ 1-10 ms (Metro WAN)
│   │
│   └─ 書き込みレイテンシの要件は?
│       ├─ 厳しい (< 5 ms) → Protocol A or B
│       └─ 許容可能       → Protocol C
│
└─ > 10 ms (遠距離 WAN)
    │
    └─ DRBD Proxy を使用?
        ├─ Yes → Protocol A + DRBD Proxy
        └─ No  → Protocol A
```

## pvese 環境への考察

### 現在の Protocol C 選定が妥当である理由

1. **IPoIB の超低遅延**: IPoIB の RTT は 0.1 ms 以下であり、Protocol C の同期レプリケーションによるレイテンシ増加は事実上無視できる。Protocol A/B に変更しても書き込みレイテンシの改善はごくわずかである

2. **HDD がボトルネック**: 既存ベンチマークが示す通り、書き込みレイテンシの大部分は SATA HDD のメカニカル I/O (seek + rotation) に起因する。ネットワーク遅延は全体の 1% 以下であり、Protocol を変更してもボトルネックは解消されない

3. **データ安全性の最大化**: 2 ノード構成では片方のノードが障害を起こした場合にデータが残るノードは 1 台のみ。Protocol C であれば、障害発生前のすべての書き込みが残存ノードに保証される

4. **quorum=off との整合性**: pvese 環境は 2 ノード構成のため quorum=off としているが、Protocol C はこの構成でも最大限のデータ保護を提供する。将来ノードを追加して quorum を有効にする場合も Protocol C であればそのまま移行可能

### Protocol A/B に変更した場合のメリット・デメリット

| 項目 | Protocol A に変更 | Protocol B に変更 |
|------|-----------------|-----------------|
| **書き込みレイテンシ改善** | ごくわずか (IPoIB RTT ≈ 0.1 ms の削減) | ごくわずか (リモートディスク I/O 時間の削減のみ) |
| **IOPS 改善** | HDD がボトルネックのため効果は限定的 | 同左 |
| **データ損失リスク** | フェイルオーバー時に直近の書き込みが失われる可能性 | 両ノード同時電源断でのみ損失の可能性 |
| **運用複雑性** | DR 向け構成としての監視・アラートが必要 | Protocol C と大差なし |
| **総合判断** | **非推奨** — メリットがほぼなくリスクのみ増加 | **非推奨** — 同左 |

### RDMA トランスポートとの組み合わせの展望

pvese 環境には `drbd_transport_rdma.ko` モジュールがビルド済みである。現在の IPoIB (TCP over InfiniBand) から RDMA トランスポートに変更した場合の影響を以下に整理する。

| 項目 | IPoIB (TCP) | RDMA |
|------|-------------|------|
| **RTT** | < 0.1 ms | < 0.01 ms (カーネルバイパス) |
| **CPU オーバーヘッド** | TCP/IP スタック処理あり | ゼロコピー、カーネルバイパス |
| **Protocol C レイテンシ** | `T_local_disk + ~0.1 ms + T_remote_disk` | `T_local_disk + ~0.01 ms + T_remote_disk` |
| **効果** | — | RTT 削減は ~0.09 ms。HDD 環境では効果は限定的 |

RDMA の真の効果は **NVMe SSD 環境** で発揮される。ディスク I/O が 0.01-0.1 ms レベルまで高速化された場合、ネットワーク RTT の 0.09 ms 削減が性能全体に対する有意な改善となる。HDD 環境（ディスク I/O ≈ 5-15 ms）では RDMA の効果は相対的に小さい。

## まとめ

- DRBD の 3 つの Protocol は **データ安全性とレイテンシのトレードオフ** を提供する
- **スループット** は Protocol 選択にほぼ依存しない
- **pvese 環境 (IPoIB, SATA HDD, 2 ノード) では Protocol C が最適解**:
  - IPoIB の超低遅延により Protocol C のペナルティが無視可能
  - SATA HDD がボトルネックのため Protocol 変更による性能改善は限定的
  - 2 ノード構成でのデータ保護を最大化
- Protocol A/B は **WAN レプリケーション** や **レイテンシ要件が極めて厳しい環境** で検討する
- 将来 NVMe SSD + RDMA に移行した場合も、Protocol C + RDMA の組み合わせが推奨される

## 参考資料

- [DRBD User's Guide 9.0 (LINBIT)](https://linbit.com/drbd-user-guide/drbd-guide-9_0-en/) — Protocol A/B/C の公式定義
- [The Impact of Network Latency on Write Performance When Using DRBD (LINBIT Blog)](https://linbit.com/blog/the-impact-of-network-latency-on-write-performance-when-using-drbd/) — Protocol C のネットワーク遅延別ベンチマーク
- [DRBD Quorum Implementation Updates (LINBIT Blog)](https://linbit.com/blog/drbd-quorum-implementation-updates/) — Quorum 機能の実装詳細
- [drbdsetup(8) man page](https://manpages.debian.org/testing/drbd-utils/drbdsetup-9.0.8.en.html) — DRBD 設定コマンドリファレンス
- [LINSTOR Quorum Policies and Virtualization Environments (LINBIT KB)](https://kb.linbit.com/linstor/linstor-quorum-policies-and-vm-environments/) — LINSTOR における Quorum ポリシー
