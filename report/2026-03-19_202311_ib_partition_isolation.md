# InfiniBand パーティション分離 (Region A / Region B)

- **実施日時**: 2026年3月20日 05:23 JST
- **セッション**: 2490de2b

## 前提・目的

6台のサーバ (4-9号機) が 1台の Mellanox SX6036 IB スイッチに接続されており、全ノードが同一 IB ファブリックを共有している。Region A (4/5/6号機) と Region B (7/8/9号機) の IB トラフィックをファブリックレベルで分離したい。

- **背景**: LINSTOR/DRBD マルチリージョン構成で、リージョン内 DRBD はIPoIB、リージョン間は Ethernet を使用。IB レベルでリージョン間のトラフィック分離が望ましい
- **目的**: IB パーティション (Pkey) またはサブネット分離で Region A / B の IB トラフィックを分離
- **前提条件**: SX6036 (MLNX-OS 3.6.8012) が `ib partition` コマンドをサポートするかどうかが不明

## 環境情報

| ノード | IB ポート | IB I/F | IPoIB IP (変更前) | リンク状態 |
|--------|----------|--------|-------------------|-----------|
| 4号機 | IB1/23 | ibp134s0 | なし (state DOWN) | Active (40 Gbps QDR) |
| 5号機 | IB1/21 | ibp134s0 | 192.168.100.2/24 | Down (電源 OFF) |
| 6号機 | IB1/19 | ibp134s0 | 未設定 | Down (DAC ケーブル交換後も未確立) |
| 7号機 | IB1/7 | ibp10s0 | 192.168.100.7/24 | Active (40 Gbps QDR) |
| 8号機 | IB1/11 | ibp10s0 | 192.168.100.8/24 | Active (40 Gbps QDR) |
| 9号機 | IB1/9 | ibp10s0 | 192.168.100.9/24 | Active (40 Gbps QDR) |

- スイッチ: MSX6036F-1SFS, MLNX-OS 3.6.8012, 内蔵 SM active (OpenSM 4.8.1)
- 8号機の実際のポートは IB1/8 ではなく **IB1/11** であることを確認

### HCA GUID

| サーバ | IB デバイス | GUID |
|--------|-----------|------|
| 4号機 | ibp134s0 | e41d:2d03:00b4:db20 |
| 7号機 | mlx4_0 (ibp10s0) | ec0d:9a03:00e6:cc10 |
| 8号機 | mlx4_0 (ibp10s0) | ec0d:9a03:00de:bb40 |
| 9号機 | mlx4_0 (ibp10s0) | f452:1403:006b:7530 |

## Phase 1: 調査結果

### `ib partition` コマンドの対応確認

```
ssh pve4 python3 /tmp/sx6036-console.py show ib partition
→ % Unrecognized command "ib".
```

**MLNX-OS 3.6.8012 は `ib partition` コマンドを非サポート**。`show ib partition` が `Unrecognized command "ib"` でエラーとなった。

### 判定

ハードウェアレベルの Pkey パーティション分離は不可 → **Phase 2-ALT (サブネット分離) にフォールバック**

### その他の調査結果

- `create_child` sysfs パス: 4号機・7号機とも存在 (`/sys/class/net/<iface>/create_child`) → 子インターフェースは技術的に作成可能だが、スイッチ側でパーティションを設定できないため意味がない
- Pkey テーブル: 4号機に 128 エントリ (index 0-127) 存在、index 0 の値は `0xffff` (default full membership)
- 5号機: 電源 OFF (IPMI で確認)
- 6号機: BMC (Supermicro) に IPMI 接続不可

## Phase 2-ALT: サブネット分離

### 設計

Region B の IPoIB サブネットを変更:

| リージョン | サブネット | ノード |
|-----------|-----------|--------|
| Region A | 192.168.100.0/24 | 4号機 (.1), 5号機 (.2), 6号機 (.3) |
| Region B | **192.168.101.0/24** | 7号機 (.7), 8号機 (.8), 9号機 (.9) |

### 実施手順

各ノードで以下のスクリプトを実行:

```sh
# 7号機の例
ip addr del 192.168.100.7/24 dev ibp10s0
ip addr add 192.168.101.7/24 dev ibp10s0
sed -i "s|192.168.100.7|192.168.101.7|g" /etc/network/interfaces.d/ib0
```

3台を同時に変更。

### LINSTOR インターフェース更新

```sh
linstor node interface modify ayase-web-service-7 ibp10s0 --ip 192.168.101.7
linstor node interface modify ayase-web-service-8 ibp10s0 --ip 192.168.101.8
linstor node interface modify ayase-web-service-9 ibp10s0 --ip 192.168.101.9
```

全て SUCCESS。

## Phase 5: 検証結果

### リージョン内疎通 (Region B)

```
pve7 → 192.168.101.8: 0.219ms (OK)
pve7 → 192.168.101.9: 0.251ms (OK)
pve8 → 192.168.101.9: 2.51ms (OK)
```

### リージョン間分離

```
pve7 → 192.168.100.1: 100% packet loss (OK - 分離確認)
```

Region B から Region A の IPoIB サブネットに到達不可。

### DRBD 接続状態

IP 変更後、DRBD は自動的に新しい IP (192.168.101.x) で再接続:

```
pm-0b9b12c1:
  this_host ipv4 192.168.101.7:7000
  remote_host ipv4 192.168.101.8:7000
  → Connected, UpToDate

vm-100-cloudinit:
  this_host ipv4 192.168.101.7:7001
  remote_host ipv4 192.168.101.9:7001
  → Connected, UpToDate
```

### LINSTOR リソース状態

全リソースが UpToDate/Ok のまま、ダウンタイムなしで切り替え完了。

## Phase 6: 設定ファイル更新

| ファイル | 変更内容 |
|---------|---------|
| `config/linstor.yml` | Region B ノードの `ib_ip` を 192.168.101.x に変更、regions セクションに `ib_subnet` 追加 |
| `config/switch-sx6036.yml` | `ib_subnets` セクション (region-a/b サブネット) と `port_map` セクション追加 |
| `.claude/skills/ib-switch/SKILL.md` | パーティション/トラフィック分離セクション、ポートマップ、HCA GUID 追加 |
| `memory/sx6036.md` | ポート状態更新、サブネット分離設定、HCA GUID 追加 |

## まとめ

- **`ib partition` は MLNX-OS 3.6 で非サポート** — Pkey によるハードウェアレベル分離は不可
- **代替手段**: サブネット分離 (192.168.100.0/24 vs 192.168.101.0/24) で IP レベルの分離を実現
- Region B (7/8/9号機) の IPoIB を 192.168.101.0/24 に変更完了
- DRBD は自動的に新 IP で再接続し、ダウンタイムなし
- Region A (4号機のみオンライン、5号機電源 OFF、6号機 IB リンク未確立) は現状のまま 192.168.100.0/24

### 制約

- IP レベルの分離であり、IB ファブリックレベルの強制ではない (ルーティング追加で到達可能になりうる)
- 5号機・6号機が復帰した際に Region A の IPoIB セットアップが必要
