# SX6036 スイッチ経由 InfiniBand ベンチマークレポート

- **実施日時**: 2026年2月25日 20:17 - 20:37

## 前提・目的

SX6036 InfiniBand スイッチ経由での IB 通信を確立し、RDMA ネイティブおよび IPoIB の性能を計測する。以前の直結テスト結果と比較し、スイッチ経由のオーバーヘッドを評価する。

- **背景**: 4号機・5号機の ConnectX-3 HCA が DAC ケーブルで SX6036 に物理接続済み（IB1/21, IB1/23）だが、Subnet Manager 未稼働・IB ユーザスペースパッケージ未インストールで通信不可
- **目的**: スイッチ SM 有効化 → opensm フォールバック → パッケージインストール → IPoIB 設定 → RDMA/IPoIB ベンチマーク実施
- **前提条件**: 両サーバの mlx4_core/ib カーネルモジュールはロード済み
- **参考**: 直結テスト結果（RDMA ~30 Gbps, IPoIB Connected ~16 Gbps）

## 環境情報

| 項目 | Server 4 | Server 5 |
|------|----------|----------|
| ホスト名 | ayase-web-service-4 | ayase-web-service-5 |
| 静的 IP | 10.10.10.204 | 10.10.10.205 |
| IPoIB IP | 192.168.100.1/24 | 192.168.100.2/24 |
| HCA | ConnectX-3 MT4099 (mlx4_0) | 同左 |
| FW | 2.40.5030 | 2.40.5030 |
| Port GUID | 0xe41d2d0300b4db21 | 0xe41d2d03007a5c61 |
| IPoIB インターフェース | ibp134s0 | ibp134s0 |
| OS | Debian 13.3 + PVE 9.1.6 | 同左 |
| カーネル | 6.17.9-1-pve | 同左 |

| 項目 | 値 |
|------|-----|
| スイッチ | Mellanox SX6036 (MSX6036F-1SFS) |
| MLNX-OS | 3.6.8008 |
| ポート | IB1/21 (server 5), IB1/23 (server 4) |
| リンク速度 | 40 Gbps QDR (4X × 10 Gbps) |
| Subnet Manager | opensm 3.3.23 on server 4 |
| パッケージ | rdma-core 56.1-1, infiniband-diags 56.1-1, perftest 25.01.0, iperf3 3.18-2 |

## セットアップ手順

### 1. スイッチ SM 有効化（失敗 → opensm フォールバック）

スイッチ内蔵 SM を `ib sm` で有効化したが、`show ib sm routing-info` が "Connection to SM unavailable" を返し、server 5 のポートが Initialize のまま Active に遷移しなかった。

フォールバックとしてスイッチ SM を `no ib sm` で無効化し、server 4 に opensm をインストール:

```sh
ssh root@10.10.10.204 'apt-get install -y opensm'
ssh root@10.10.10.204 'systemctl restart opensm'
```

opensm 起動後、両サーバのポートが Active になった。

### 2. パッケージインストール

```sh
ssh root@10.10.10.204 'apt-get install -y rdma-core infiniband-diags perftest iperf3'
ssh root@10.10.10.205 'apt-get install -y rdma-core infiniband-diags perftest iperf3'
```

### 3. IPoIB 設定

`scripts/ib-setup-remote.sh` を使用:

```sh
scp ./scripts/ib-setup-remote.sh root@10.10.10.204:/tmp/
ssh root@10.10.10.204 '/tmp/ib-setup-remote.sh --ip 192.168.100.1/24 --persist'
ssh root@10.10.10.205 '/tmp/ib-setup-remote.sh --ip 192.168.100.2/24 --persist'
```

設定内容: Connected Mode, MTU 65520, `/etc/network/interfaces.d/ib0` に永続設定。

## ファブリックトポロジ

```
Server 5 (lid=1) ──[IB1/21]── SX6036 (lid=3) ──[IB1/23]── Server 4 (lid=4, SM)
```

`iblinkinfo` 出力（Active ポートのみ）:

```
CA: ayase-web-service-5:  lid 1 port 1 ==( 4X 10.0 Gbps Active/LinkUp)==> lid 3 port 21 "SX6036"
CA: ayase-web-service-4:  lid 4 port 1 ==( 4X 10.0 Gbps Active/LinkUp)==> lid 3 port 23 "SX6036"
```

## RDMA ベンチマーク結果

perftest ツール使用。server 4 でサーバ起動、server 5 からクライアント接続。

| テスト | パラメータ | 結果 | 単位 |
|--------|-----------|------|------|
| ib_write_bw | --size=65536 --duration=10 | 3,671.51 | MiB/s (30.6 Gbps) |
| ib_read_bw | --size=65536 --duration=10 | 3,667.19 | MiB/s (30.6 Gbps) |
| ib_write_lat | --size=2 --duration=5 | 1.21 | usec |
| ib_read_lat | --size=2 --duration=5 | 2.05 | usec |

再現コマンド例:

```sh
# Server 4 (サーバ側)
ssh root@10.10.10.204 'ib_write_bw --size=65536 --duration=10'
# Server 5 (クライアント側)
ssh root@10.10.10.205 'ib_write_bw --size=65536 --duration=10 192.168.100.1'
```

## IPoIB ベンチマーク結果

iperf3 使用。server 5 でサーバ (`iperf3 -s -D -1`)、server 4 からクライアント接続。

| # | テスト条件 | Bitrate | Retr | 備考 |
|---|-----------|---------|------|------|
| A | Connected, MTU 65520, TCP 1stream | **19.1 Gbps** | 0 | |
| B | Connected, MTU 65520, TCP 4stream | **18.7 Gbps** | 4180 | 帯域飽和、並列化で改善なし |
| C | Datagram, MTU 2044, TCP 1stream | **8.10 Gbps** | 24940 | 小 MTU + retransmit 多発 |
| D | Connected, MTU 65520, UDP unlimited | **12.4 Gbps** (rx) | - | sender 54.6 Gbps, 77% loss |
| E | Connected, MTU 65520, TCP reverse | **23.9 Gbps** | 0 | Server 5 → Server 4 方向 |

再現コマンド例:

```sh
# Server 5 (サーバ)
ssh root@10.10.10.205 'iperf3 -s -D -1'
# Test A
ssh root@10.10.10.204 'iperf3 -c 192.168.100.2 -t 30'
# Test B
ssh root@10.10.10.204 'iperf3 -c 192.168.100.2 -t 30 -P 4'
# Test C (datagram mode に切替後)
ssh root@10.10.10.204 'iperf3 -c 192.168.100.2 -t 30'
# Test D
ssh root@10.10.10.204 'iperf3 -c 192.168.100.2 -t 30 -u -b 0'
# Test E
ssh root@10.10.10.204 'iperf3 -c 192.168.100.2 -t 30 --reverse'
```

## 直結 vs スイッチ経由 比較

| 測定項目 | 直結 | スイッチ経由 | 差分 |
|---------|------|------------|------|
| RDMA Write BW | ~30 Gbps | 30.6 Gbps | +2% |
| RDMA Read BW | ~30 Gbps | 30.6 Gbps | +2% |
| RDMA Write Lat | N/A | 1.21 usec | - |
| RDMA Read Lat | N/A | 2.05 usec | - |
| IPoIB TCP Connected (1 stream) | ~16 Gbps | 19.1 Gbps | +19% |
| IPoIB TCP Connected (reverse) | N/A | 23.9 Gbps | - |

**主な知見**:

1. **RDMA 性能はスイッチ経由でもほぼ同等** — 30.6 Gbps で直結時と変わらない。SX6036 のカットスルースイッチングにより、追加レイテンシは最小限
2. **IPoIB TCP は直結時より向上** — 19.1 Gbps vs ~16 Gbps。SM が opensm に変更されたことやパッケージバージョンの違いが影響している可能性
3. **方向による非対称性** — Server 4→5 が 19.1 Gbps、Server 5→4 が 23.9 Gbps。opensm が Server 4 で動作しているため、SM ホストからの送信は CPU 負荷で若干不利
4. **Datagram Mode は Connected の 42% の性能** — MTU 2044 の小パケットと大量 retransmit が原因。Connected Mode + 大 MTU が推奨
5. **UDP は受信側でパケットロス多発** — 送信側は 54.6 Gbps で送信するが、リンク帯域超過で 77% がドロップ。実効 12.4 Gbps

## 永続化設定

| 項目 | ファイル | 内容 |
|------|---------|------|
| IPoIB | `/etc/network/interfaces.d/ib0` | auto ibp134s0, connected mode, MTU 65520 |
| opensm | systemd enabled | `opensm.service` (server 4 のみ) |
| SX6036 SM | `no ib sm` (write memory) | スイッチ SM 無効 |
