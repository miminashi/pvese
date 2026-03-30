# 5/6号機起動 + IB パーティション再調査・IPoIB セットアップ

- **実施日時**: 2026年3月20日 05:30 (JST)

## 前提・目的

- 5号機は電源 OFF、6号機も電源 OFF の状態
- 前回セッションで Region B (7/8/9号機) の IPoIB を 192.168.101.0/24 に設定済み
- 前回の `show ib partition` テストは operator mode (`>`) で実行しており不正確だった
- 目的: 5/6号機を起動し IPoIB をセットアップ、enable mode で IB パーティションの正確な対応状況を確認する

## 環境情報

| サーバ | BMC IP | 静的 IP | IB ポート | 状態 (作業前) |
|--------|--------|---------|----------|--------------|
| 4号機 | 10.10.10.24 | 10.10.10.204 | IB1/23 | ON, IB DOWN, IPoIB なし |
| 5号機 | 10.10.10.25 | 10.10.10.205 | IB1/21 | OFF |
| 6号機 | 10.10.10.26 | 10.10.10.206 | IB1/19 | OFF |
| 7号機 | 10.10.10.27 | 10.10.10.207 | IB1/7 | ON, 192.168.101.7 |
| 8号機 | 10.10.10.28 | 10.10.10.208 | IB1/11 | ON, 192.168.101.8 |
| 9号機 | 10.10.10.29 | 10.10.10.209 | IB1/9 | ON, 192.168.101.9 |

- IB スイッチ: Mellanox SX6036, MLNX-OS 3.6.8012, 内蔵 SM active

## 実施結果

### Phase 1: 5/6号機起動

- BMC 電源投入: 両方成功
- POST: 正常完了 (POST 92 スタックなし)
- SSH 接続: 両方 OK

### Phase 2: IB パーティションコマンド調査 (enable mode)

#### `show ib partition` (enable mode)

```
Default:
  PKey : 0x7FFF
  ipoib: yes
  members:
    GUID='ALL' member='full'
```

**結果**: enable mode で正常動作。Default パーティション (PKey 0x7FFF) が存在。

#### `ib partition` (configure mode)

| コマンド | 結果 |
|---------|------|
| `ib partition region-a pkey 0x0001` | 成功 |
| `ib partition region-a ipoib` | 成功 |
| `ib partition region-a member ALL type full` | 成功 |
| `ib partition region-a member e41d:2d03:00b4:db21 type full` | **失敗** — `% Invalid port GUID` |
| `ib partition region-a member e41d2d0300b4db21 type full` | **失敗** — `% Invalid port GUID` |
| `ib partition region-a member 0xe41d2d0300b4db21 type full` | **失敗** — `% Invalid port GUID` |
| `ib partition region-a member IB1/23 type full` | **失敗** — `% Invalid port GUID` |

**結論**: MLNX-OS 3.6.8012 は `ib partition member` で `ALL` キーワードのみ受け付け、個別 GUID によるメンバー制限は非サポート。ハードウェアレベルの Pkey パーティション分離は不可。

### Phase 3: Region A IPoIB セットアップ

```sh
scp -F ssh/config scripts/ib-setup-remote.sh pveN:/tmp/ib-setup-remote.sh
ssh -F ssh/config pveN sh /tmp/ib-setup-remote.sh --ip 192.168.100.X/24 --persist
```

| サーバ | IP | IB デバイス | 結果 |
|--------|-----|-----------|------|
| 4号機 | 192.168.100.1/24 | ibp134s0 | 成功 |
| 5号機 | 192.168.100.2/24 | ibp134s0 | 成功 |
| 6号機 | 192.168.100.3/24 | ibp134s0 (mlx4_0) | 成功 (2回目で成功 — 初回は modprobe 後のインターフェース生成が間に合わず) |

#### 6号機の注意点

- IB デバイス名: sysfs は `mlx4_0`、ネットワークインターフェース名は `ibp134s0` (modprobe ib_ipoib 後に作成)
- 初回の `ib-setup-remote.sh` 実行時は「No IPoIB interface found」エラー。modprobe 後のインターフェース生成にラグがあった

#### LINSTOR ノードインターフェース

- 4号機・5号機: `ib0` インターフェース登録済み
- 6号機: 新規登録 `linstor node interface create ayase-web-service-6 ib0 192.168.100.3`

### Phase 4: スイッチパーティション

個別 GUID メンバー指定が非サポートのため、テストパーティションをクリーンアップ:
```
no ib partition region-a
no ib partition region-b
write memory
```

### Phase 5: 検証

#### リージョン内疎通

| テスト | 結果 | RTT |
|--------|------|-----|
| 4→5 (192.168.100.1→.2) | OK | 0.2 ms |
| 4→6 (192.168.100.1→.3) | OK | 0.2 ms |
| 7→8 (192.168.101.7→.8) | OK | 0.1 ms |
| 7→9 (192.168.101.7→.9) | OK | 0.1 ms |

#### リージョン間分離

| テスト | 結果 |
|--------|------|
| 4→7 (192.168.100.1→192.168.101.7) | **100% packet loss** — 分離成功 |

#### DRBD 状態

- pm-39c4600d: Connected, UpToDate (4号機↔6号機)

#### IB ポート状態 (全6台 Active)

| ポート | サーバ | 状態 |
|--------|--------|------|
| IB1/7 | 7号機 | Active 40 Gbps QDR |
| IB1/9 | 9号機 | Active 40 Gbps QDR |
| IB1/11 | 8号機 | Active 40 Gbps QDR |
| IB1/19 | 6号機 | Active 40 Gbps QDR |
| IB1/21 | 5号機 | Active 40 Gbps QDR |
| IB1/23 | 4号機 | Active 40 Gbps QDR |

#### LINSTOR ノード状態

全6ノード Online。

### 副次的な修正

- `scripts/sx6036-console.py`: `terminal width 256` を追加 (シリアルコンソールの行折り返し防止)

## HCA GUID 一覧

| サーバ | IB デバイス | Node GUID | Port GUID (port 1) |
|--------|-----------|-----------|---------------------|
| 4号機 | ibp134s0 | e41d:2d03:00b4:db20 | e41d:2d03:00b4:db21 |
| 5号機 | ibp134s0 | e41d:2d03:007a:5c60 | e41d:2d03:007a:5c61 |
| 6号機 | ibp134s0 (mlx4_0) | e41d:2d03:00b4:ded0 | e41d:2d03:00b4:ded1 |
| 7号機 | ibp10s0 (mlx4_0) | ec0d:9a03:00e6:cc10 | ec0d:9a03:00e6:cc11 |
| 8号機 | ibp10s0 (mlx4_0) | ec0d:9a03:00de:bb40 | ec0d:9a03:00de:bb41 |
| 9号機 | ibp10s0 (mlx4_0) | f452:1403:006b:7530 | f452:1403:006b:7531 |

## 最終構成

| リージョン | サブネット | ノード | 分離方式 |
|-----------|-----------|--------|---------|
| Region A | 192.168.100.0/24 | 4号機 (.1), 5号機 (.2), 6号機 (.3) | IP サブネット分離 |
| Region B | 192.168.101.0/24 | 7号機 (.7), 8号機 (.8), 9号機 (.9) | IP サブネット分離 |

## 参考レポート

- [IB パーティション分離調査 (前回)](2026-03-19_202311_ib_partition_isolation.md)
- [Region B IB ベンチマーク](2026-03-19_182643_ib_benchmark_region_b.md)
