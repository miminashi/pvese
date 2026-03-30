# LINSTOR マルチリージョン運用マニュアル

## 1. アーキテクチャ概要

### リージョン構成図

```
Region A                              Region B
┌───────────────────────┐             ┌───────────────────────┐
│ PVE Cluster           │             │ PVE Cluster           │
│ ┌────┐┌────┐┌────┐ │ Protocol A  │ ┌────┐┌────┐┌────┐ │
│ │ A1 ││ A2 ││ A3 │─│─────────────│─│ B1 ││ B2 ││ B3 │ │
│ └────┘└────┘└────┘ │  (async)    │ └────┘└────┘└────┘ │
│   Protocol C (sync)   │  no 2pri    │   Protocol C (sync)   │
│   allow-2pri: yes     │             │   allow-2pri: yes     │
│   Aux/site=region-a   │             │   Aux/site=region-b   │
└───────────────────────┘             └───────────────────────┘
         ↕                                      ↕
  ライブマイグレーション可              ライブマイグレーション可
         ↔ ─ ─ ─ ─ ─ フェイルオーバーのみ ─ ─ ─ ─ ─ ↔
```

### リージョン内 vs リージョン間の設定差分

| 項目 | リージョン内 | リージョン間 |
|------|------------|------------|
| Protocol | C (同期) | A (非同期) |
| allow-two-primaries | yes | **no** |
| ライブマイグレーション | 可 | **不可** |
| フェイルオーバー | 可 | 可 (手動) |
| 設定レベル | resource-group (デフォルト) | resource-connection (オーバーライド) |
| Corosync | 同一クラスタ (< 5ms RTT) | 独立クラスタ or 不要 |

### 前提条件・制約

- **allow-two-primaries と Protocol の排他制約**: DRBD カーネルモジュールは `allow-two-primaries yes` と Protocol A/B の共存を許可しない (error 139)。Protocol A/B を使う接続では必ず `allow-two-primaries no` を設定する
- **`--protocol` と `--allow-two-primaries` は同時に設定する**: 片方だけ変更すると DRBD カーネルが拒否する
- **LINSTOR 設定の優先順位**: `resource-connection > node-connection > resource-definition > resource-group > controller`
- **DRBD 9.x / LINSTOR 1.33+ が必要**: per-connection protocol 設定には DRBD 9 の機能が必要

### 2+1 トポロジー

推奨構成: リージョン内 2 レプリカ + リージョン間 1 DR レプリカ。

```
Region A (Protocol C)          Region B (Protocol C)
  [Node A1] ←────────────→ [Node B1] ← Primary
  (DR)      Protocol A      [Node B2]
```

- リージョン内: 2 レプリカ (Protocol C, allow-two-primaries=yes) → ライブマイグレーション可能
- リージョン間: 1 DR レプリカ (Protocol A, allow-two-primaries=no) → 非同期レプリケーション
- `replicas-on-same` は `site` を使用 (LINSTOR が自動で `Aux/` プレフィックスを付加するため `Aux/site` ではなく `site`)
- `auto-block-size=512` を設定し、minIoSize 不一致によるリソース作成失敗を防止

設定コマンド:

```sh
linstor resource-group modify pve-rg --replicas-on-same site
linstor resource-group set-property pve-rg Linstor/Drbd/auto-block-size 512
```

## 2. 初期セットアップ

### 2.1 config/linstor.yml にリージョン情報を定義

```yaml
regions:
  region-a:
    - node-a1
    - node-a2
  region-b:
    - node-b1
    - node-b2
```

### 2.2 セットアップスクリプトの実行

```sh
./scripts/linstor-multiregion-setup.sh setup config/linstor.yml
```

このスクリプトは以下を実行する:

1. 各ノードに `Aux/site` プロパティを設定
2. 異なるリージョン間のノードペアに対して、各リソースの resource-connection に `--protocol A --allow-two-primaries no` を設定

### 2.3 手動で設定する場合

```sh
# Aux/site プロパティの設定
linstor node set-property <node> Aux/site <region-name>

# リージョン間 Protocol A の設定 (各リソース×リージョン間ノードペアに対して)
linstor resource-connection drbd-peer-options <nodeA> <nodeB> <resource> \
  --protocol A --allow-two-primaries no
```

### 2.4 設定確認

```sh
./scripts/linstor-multiregion-status.sh config/linstor.yml
```

## 3. 状態確認

### 3.1 ステータス一覧表示

```sh
./scripts/linstor-multiregion-status.sh [config/linstor.yml]
```

表示内容:
- 全ノードの Aux/site プロパティ (config との整合性チェック付き)
- 各リソースの per-connection protocol 設定 (intra-region / INTER-REGION 表示)
- DRBD 同期状態 (linstor resource list)
- DRBD 接続詳細 (drbdsetup status)

### 3.2 個別確認コマンド

リージョン/サイト割り当ての確認:

```sh
linstor node list-properties <node> | grep Aux/site
```

per-connection Protocol の確認:

```sh
linstor resource-connection list-properties <nodeA> <nodeB> <resource>
```

DRBD 同期状態の確認:

```sh
drbdsetup status --verbose --statistics
```

out-of-sync 量の確認:

```sh
drbdsetup status --statistics | grep out-of-sync
```

### 3.3 DRBD 同期待ち

スクリプトで全レプリカの UpToDate を待機:

```sh
./scripts/linstor-drbd-sync-wait.sh <resource_name> [config/linstor.yml] [--timeout 600]
```

10 秒間隔でポーリングし、全レプリカが UpToDate になったら終了。タイムアウト (デフォルト 600 秒) で異常終了。

## 4. リージョン内ライブマイグレーション

### 4.1 前提条件の確認

ライブマイグレーション前に以下を確認する:

1. **Protocol C であること**: リージョン内接続のデフォルト
2. **allow-two-primaries yes であること**: resource-group レベルで設定済み
3. **両ノードが UpToDate であること**:
   ```sh
   linstor resource list
   ```
4. **CPU タイプが `kvm64` であること** (異種ハードウェア間の場合):
   ```sh
   qm config <vmid> | grep cpu
   ```

### 4.2 スクリプトでの実行

```sh
./pve-lock.sh run ./oplog.sh ./scripts/linstor-migrate-live.sh <vmid> <target_node>
```

スクリプトは以下を自動実行する:
1. ソース/ターゲットが同一リージョンであることを検証
2. ターゲットノードにリソースが UpToDate で存在することを検証
3. VM が running であることを検証
4. `qm migrate <vmid> <target_node> --online` を実行
5. 事後検証 (VM 状態、DRBD 状態)

### 4.3 手動での手順

```sh
# VM のライブマイグレーション
qm migrate <vmid> <target-node> --online
```

### 4.4 確認項目

- マイグレーション中、一時的にデュアルプライマリ状態になる (正常)
- マイグレーション完了後、移行元が Secondary に降格する (auto-promote)
- DRBD 状態が両ノードで UpToDate であること
- DR レプリカは一時的に Outdated になることがある (Protocol A の非同期性。自動復帰する)

### 4.5 実測値

| 方向 | ダウンタイム (1回目) | ダウンタイム (2回目) | 備考 |
|------|-------------------|-------------------|------|
| 6号機 → 7号機 | 73ms / 911 MiB / 18秒 | 37ms / 834 MiB / 17秒 | 平均 55ms |
| 7号機 → 6号機 | 33ms / 349 MiB / 11秒 | 74ms / 844 MiB / 15秒 | 平均 53.5ms |

- テスト環境: VM 200 (4GiB RAM, 32GiB DRBD disk, kvm64 CPU)
- ダウンタイムは方向・VM のメモリ dirty pages により変動。平均値は同等レンジ
- 転送量は 349-911 MiB の範囲で変動
- **注記**: 上記は旧リージョン構成 (Region B: 6+7号機) 時の実測値

## 5. リージョン間フェイルオーバー

### 5.1 計画的フェイルオーバー (メンテナンス時)

メンテナンスウィンドウで元リージョンの VM を DR サイトに移行する手順:

1. **DRBD 同期完了を確認**:
   ```sh
   drbdsetup status --statistics | grep out-of-sync
   ```
   out-of-sync が 0 であることを確認。

2. **元リージョンで VM を停止**:
   ```sh
   qm stop <vmid>
   ```

3. **DR サイトで VM を起動**:
   ```sh
   qm start <vmid>
   ```
   `auto-promote yes` により、DRBD デバイスを open した時点で自動的に Primary に昇格する。

4. **状態確認**:
   ```sh
   linstor resource list
   drbdsetup status
   ```

### 5.2 障害時フェイルオーバー

元リージョンが応答不能になった場合:

1. **障害を確認**:
   ```sh
   # 元リージョンのノードに接続不可
   linstor resource list
   ```
   障害ノードのリソースが `Unknown` や `Connecting` になる。

2. **DR サイトで VM を起動**:
   ```sh
   qm start <vmid>
   ```
   `quorum=off` の場合、単独ノードでも Primary 昇格が可能。

3. **注意**: Protocol A (非同期) のため、障害発生時点で未同期のデータが失われる可能性がある (RPO > 0)。

### 5.3 フェイルバック

元リージョンが復旧した後、VM を戻す手順:

1. **元リージョンのノード復旧を確認**:
   ```sh
   linstor node list
   linstor resource list
   ```
   復旧ノードのリソースが `SyncTarget` → `UpToDate` に遷移するのを待つ。

2. **DRBD 再同期完了を待機**:
   ```sh
   drbdsetup status --statistics | grep out-of-sync
   ```
   out-of-sync が 0 になるまで待機。

3. **DR サイトで VM を停止**:
   ```sh
   qm stop <vmid>
   ```

4. **元リージョンで VM を起動**:
   ```sh
   qm start <vmid>
   ```

5. **状態確認**:
   ```sh
   linstor resource list
   ```

## 6. ノード追加・削除

### 6.1 リージョンへのノード追加

前提: ノードが LINSTOR に登録済み (IB インターフェース、ストレージプール設定済み)。
未登録の場合は先に LINSTOR ノード作成を行う。

```sh
./scripts/linstor-multiregion-node.sh add <node> <region> config/linstor.yml
```

スクリプトの処理:
1. `Aux/site` プロパティを設定
2. 異なるリージョンのノードとの間で、各リソースに Protocol A + allow-two-primaries no を設定

追加後の確認:

```sh
./scripts/linstor-multiregion-status.sh config/linstor.yml
```

### 6.2 リージョンからのノード削除

```sh
./scripts/linstor-multiregion-node.sh remove <node> config/linstor.yml
```

スクリプトの処理:
1. リージョン間の resource-connection オーバーライドを Protocol C に復元後クリア
2. ノードのリソースを全て削除
3. ストレージプールを削除
4. `Aux/site` プロパティを削除
5. LINSTOR ノードを削除

**注意**: place-count の変更 (必要に応じて `linstor resource-group modify <rg> --place-count N`) はスクリプトの責務外。事前に手動で調整すること。

## 7. トラブルシューティング

### 7.1 "Protocol C required" エラー (error 139)

```
Failure: (139) Protocol C required
```

**原因**: `allow-two-primaries yes` が設定された状態で Protocol A/B を設定しようとした。

**対処**:
```sh
# --protocol と --allow-two-primaries を同時に設定する
linstor resource-connection drbd-peer-options <nodeA> <nodeB> <resource> \
  --protocol A --allow-two-primaries no
```

`--protocol` のみの設定は常に失敗する。必ず両方を同時に変更すること。

### 7.2 スプリットブレイン

リージョン間で両方のノードが Primary になった場合 (障害時フェイルオーバー後に元リージョンも復帰した場合等)、スプリットブレインが発生する可能性がある。

**検知**:
```sh
drbdsetup status
# StandAlone 状態や SplitBrain 警告を確認
```

**対処**:
1. データが新しい方のノードを特定
2. 古い方のノードで:
   ```sh
   drbdadm disconnect <resource>
   drbdadm secondary <resource>
   drbdadm connect --discard-my-data <resource>
   ```
3. 新しい方のノードで:
   ```sh
   drbdadm disconnect <resource>
   drbdadm connect <resource>
   ```

**注意**: スプリットブレイン解消は破壊的操作。必ずバックアップを確認してから実行すること。

### 7.3 リージョン間同期遅延

Protocol A では非同期レプリケーションのため、同期遅延が発生する。

**確認**:
```sh
drbdsetup status --statistics | grep -E '(out-of-sync|send)'
```

**大量の out-of-sync が継続する場合の原因と対処**:

| 原因 | 対処 |
|------|------|
| ネットワーク帯域不足 | WAN 帯域の拡張、DRBD の c-max-rate 調整 |
| 書き込み量過多 | ワークロード調整、DR 側ディスク性能確認 |
| ネットワーク断 | `drbdsetup status` で接続状態を確認、ルーティング確認 |

### 7.4 障害パターン一覧

#### ライブマイグレーション

| ID | 障害 | 検出方法 | 対策 |
|----|------|---------|------|
| M1 | LINSTOR ディスクで `qm migrate --online` 失敗 | エラー出力 | 両ノードに diskful リソースが UpToDate で存在するか確認 |
| M2 | メモリ転送タイムアウト | タイムアウトエラー | `--migration_network` で専用ネットワークを指定 |
| M3 | CPU タイプ `host` で異種ハードウェア間失敗 | `Failed to set special registers` | CPU タイプを `kvm64` に変更 |
| M4 | vendor snippet 未配置 | `volume 'local:snippets/...' does not exist` | 移行先ノードに snippet をコピー |
| M5 | DR レプリカが一時的に Outdated | `drbdsetup status` | Protocol A の非同期性により正常。自動復帰する |

#### コールドマイグレーション

| ID | 障害 | 検出方法 | 対策 |
|----|------|---------|------|
| C1 | `qm set --scsi0` がクロスクラスタで動作 (発見) | - | 実証済み: vzdump 不要 |
| C2 | PrefNic=ib0 で cross-region 接続不能 | `Connecting` 状態が継続 | cross-region パスを `default` インターフェースで作成 |
| C3 | node remove/re-add 後に stale パス | `Network interface 'default' does not exist` | パスを delete + recreate |
| C4 | `replicas-on-same "Aux/site"` が二重プレフィックス | `resource-group list-properties` | `--replicas-on-same site` (Aux/ なし) を使用 |
| C5 | cloudinit ディスクのアタッチ不要 | - | 初回起動済みのため cloudinit スキップ可 |
| C6 | DRBD フルシンクがネットワーク帯域を飽和 | SSH 遅延 | `c-max-rate` で帯域制限 |
| C7 | パス作成時の PeerClosingConnectionException | exit code 10 + エラー出力 | パスを create → delete → recreate (2回目で安定) |
| C8 | ストライプ/非ストライプ間の LV サイズ不一致 | `The peer's disk size is too small!` + StandAlone | リソース削除 → 手動 LV 作成 (正しい PE 数) → 再作成 |

### 7.5 C2: PrefNic=ib0 と cross-region パス

Region A (4+5+6号機) は PrefNic=ib0 が設定されており、DRBD はデフォルトで IB アドレス (192.168.100.x) にバインドする。
Region B (7+8+9号機) も IB を持つが、cross-region 接続はデフォルトインターフェース経由で行う。

**解決策**: `node-connection path create` で cross-region ペアに `default` インターフェースを指定:
```sh
# Region A の各ノード ↔ Region B の各ノードにパスを作成
linstor node-connection path create nodeA nodeB cross-region default default
```

`default` は LINSTOR のデフォルトネットワークインターフェース (10.x) を使う。IB ではなく Ethernet で接続される。

### 7.6 C3: node remove/re-add 後の stale パス

LINSTOR からノードを削除して再追加すると、ノードの UUID が変わる。既存のパスは古い UUID を参照しており、
`Network interface 'default' of node 'X' does not exist!` エラーが発生する。

**再現性**: 2回のテストで 100% 再現。

**解決策**: パスを削除して再作成:
```sh
linstor node-connection path delete nodeA nodeB cross-region
linstor node-connection path create nodeA nodeB cross-region default default
```

### 7.7 C7: パス作成時の PeerClosingConnectionException

ノード remove/re-add 直後に `node-connection path create` を実行すると、`PeerClosingConnectionException` が発生することがある。
パス自体は作成されるが、衛星ノードへの DRBD adjust が失敗し、後続のリソース作成で C3 エラーが発生する。

**発生条件**: ノード再登録直後のパス作成 (衛星ノードとの通信が不安定な場合)
**再現性**: 2回のテストで確認。発生するパスは一定ではない (条件依存)

**確定対策手順**:
```sh
# 1. path create を実行 (エラーが出る可能性あり)
linstor node-connection path create nodeA nodeB cross-region default default
# 2. path delete で一旦削除
linstor node-connection path delete nodeA nodeB cross-region
# 3. path create で再作成 (今度は成功)
linstor node-connection path create nodeA nodeB cross-region default default
```

### 7.8 C8: ストライプ/非ストライプ間の LV サイズ不一致

ストライプ構成のノードから非ストライプ構成のノードにリソースを作成すると、LVM PE アライメントの違いにより LV サイズが数 MB 異なり、DRBD が接続を拒否する:

```
drbd pm-39c4600d: The peer's disk size is too small! (67110832 < 67127216 sectors)
```

接続は StandAlone 状態に入り、`drbdadm adjust` では復旧できない。

**原因**: ストライプ構成では PE 数がストライプ数の倍数に切り上げられるため、同じボリューム定義サイズ (32 GiB) でもストライプ側が 2 PE (8MB) 大きくなる。

**対策**:
```sh
# 1. リソースを削除
linstor resource delete <node> <resource>
# 2. 正しいサイズで LV を手動作成 (ソースノードの PE 数に合わせる)
ssh root@<node_ip> "lvcreate -n <resource>_00000 -l <pe_count> linstor_vg"
# 3. リソースを再作成 (既存 LV を使用)
linstor resource create <node> <resource>
```

PE 数の確認方法:
```sh
ssh root@<source_ip> "lvs --noheadings -o lv_name,seg_pe_ranges linstor_vg/<resource>_00000"
```

### 7.9 M3: CPU タイプ host での異種ハードウェア間マイグレーション

CPU タイプ `host` では、異なる CPU 世代間 (例: Skylake ↔ Sandy Bridge) でライブマイグレーションが失敗する:

```
kvm: Putting registers after init: Failed to set special registers: Invalid argument
```

**対策**: CPU タイプを `kvm64` に変更:
```sh
qm set <vmid> --cpu kvm64
```

### 7.10 M4: vendor snippet 未配置

VM config に `startup: ...` 等で snippet を参照している場合、移行先ノードに同じ snippet がないとエラーになる。

**対策**: 移行先ノードの `/var/lib/vz/snippets/` に事前コピー。

### 7.10 C6: DRBD フルシンクの帯域飽和

32GiB のフルシンクは 1GbE 経由で約 6 分かかり、その間ネットワーク帯域を飽和させる。SSH 等の操作が遅延する。

**対策**: 帯域制限を設定:
```sh
linstor resource-connection drbd-peer-options <nodeA> <nodeB> <resource> --c-max-rate 50M
```

## 8. コールドマイグレーション (リージョン間)

### 8.1 概要

リージョン間の VM 移行は、Protocol A (非同期) + allow-two-primaries=no のため、ライブマイグレーションは不可。VM を停止してコールドマイグレーションを行う。

核心的発見事項: **`qm set --scsi0 linstor-storage:<resource_name>` は PVE クロスクラスタで動作する。** vzdump/qmrestore は不要。

### 8.2 スクリプトでの実行

```sh
./pve-lock.sh run ./oplog.sh ./scripts/linstor-migrate-cold.sh <vmid> <source_region> <target_region>
```

### 8.3 手動での手順

1. **ターゲットリージョンに 2 レプリカを確保**:
   ```sh
   # DR レプリカが 1 つある場合、もう 1 つ追加
   linstor resource create <target_node2> <resource>
   # cross-region パスが必要な場合は作成
   linstor node-connection path create <source_node> <target_node> cross-region default default
   # Protocol A 設定
   ./scripts/linstor-multiregion-setup.sh setup config/linstor.yml
   # DRBD 同期待ち
   ./scripts/linstor-drbd-sync-wait.sh <resource> config/linstor.yml
   ```

2. **VM 設定をキャプチャ**:
   ```sh
   qm config <vmid>
   ```
   name, memory, cores, cpu, MAC アドレス, disk size, ipconfig 等を控える。

3. **VM を停止**:
   ```sh
   qm stop <vmid>
   ```

4. **ソースリージョンのレプリカを削除**:
   ```sh
   linstor resource delete <source_node1> <resource>
   linstor resource delete <source_node2> <resource>
   ```

5. **ソースの VM config を削除** (`qm destroy` は LINSTOR リソースも消すので使わない):
   ```sh
   rm /etc/pve/qemu-server/<vmid>.conf
   ```

6. **ターゲットで VM を再作成**:
   ```sh
   qm create <vmid> --name <name> --memory <mem> --cores <cores> --cpu kvm64 \
     --net0 virtio=<MAC0>,bridge=vmbr1 --net1 virtio=<MAC1>,bridge=vmbr0 \
     --ostype l26 --scsihw virtio-scsi-single
   ```

7. **既存 LINSTOR リソースをアタッチ**:
   ```sh
   qm set <vmid> --scsi0 linstor-storage:<resource_name>_<vmid>,discard=on,iothread=1,size=<size>
   qm set <vmid> --boot order=scsi0
   qm set <vmid> --ipconfig1 ip=<vm_mgmt_ip>/<prefix>,gw=<gw>
   ```

8. **VM を起動しデータ整合性を検証**:
   ```sh
   qm start <vmid>
   ssh <user>@<vm_ip> "md5sum -c checksums.txt"
   ```

### 8.4 重要な注意事項

- `qm destroy` は LINSTOR リソースも削除するため **使用禁止**。`rm /etc/pve/qemu-server/*.conf` を使う
- MAC アドレスを保持しないと VM のネットワーク設定が変わる
- cloudinit ディスクは初回起動済みならアタッチ不要
- リソース名の形式: `<linstor_resource>_<vmid>` (例: `pm-39c4600d_200`)

## 9. リージョン廃止

リージョンの全 VM を移行し、ノードを LINSTOR から削除する。

### 9.1 手順

1. **全 VM をコールドマイグレーション** (Section 8 参照)
2. **place-count を調整** (必要に応じて):
   ```sh
   linstor resource-group modify pve-rg --place-count <N>
   ```
3. **各ノードを LINSTOR から削除**:
   ```sh
   ./scripts/linstor-multiregion-node.sh remove <node> config/linstor.yml
   ```

### 9.2 注意事項

- 全 VM の移行が完了してからノード削除を行うこと
- ノード削除順序: 先にリソースのないノードから削除すると安全

## 10. リージョン追加

廃止したリージョンの再追加、または新規リージョンの追加手順。

### 10.1 手順

1. **ノードを LINSTOR に登録**:
   ```sh
   linstor node create <node> <node_ip> --node-type Satellite
   sleep 10  # satellite 接続待ち
   ```

2. **ストレージプール作成**:
   ```sh
   linstor storage-pool create lvm <node> striped-pool linstor_vg
   ```

3. **リージョンプロパティ + auto-eviction 無効化**:
   ```sh
   linstor node set-property <node> Aux/site <region>
   linstor node set-property <node> DrbdOptions/AutoEvictAllowEviction false
   ```

4. **LvcreateOptions 設定**:
   ```sh
   linstor storage-pool set-property <node> striped-pool StorDriver/LvcreateOptions -- '-i4 -I64'
   ```

5. **cross-region パス作成** (create-delete-recreate パターンで stale 対策):
   ```sh
   # 各既存リージョンのノードとパスを作成
   linstor node-connection path create <existing_node> <new_node> cross-region default default
   linstor node-connection path delete <existing_node> <new_node> cross-region
   linstor node-connection path create <existing_node> <new_node> cross-region default default
   ```

6. **DR レプリカ追加 + Protocol A 設定**:
   ```sh
   linstor resource create <node> <resource>
   ./scripts/linstor-multiregion-setup.sh setup config/linstor.yml
   ```

### 10.2 注意事項

- node remove/re-add 後はパスが stale になる (C3)。必ず create-delete-recreate パターンを使用
- PeerClosingConnectionException (C7) が発生する可能性がある。delete-recreate で解消

## 11. DR レプリカセットアップ

既存リソースに DR レプリカを追加し、2+1 構成にする。

### 11.1 手順

1. **cross-region パスの確認・作成**:
   ```sh
   linstor node-connection path list <source_node> <dr_node>
   # 未設定なら作成
   linstor node-connection path create <source_node> <dr_node> cross-region default default
   ```

2. **DR レプリカ作成**:
   ```sh
   linstor resource create <dr_node> <resource>
   ```

3. **Protocol A 設定**:
   ```sh
   ./scripts/linstor-multiregion-setup.sh setup config/linstor.yml
   ```

4. **DRBD 同期待ち**:
   ```sh
   ./scripts/linstor-drbd-sync-wait.sh <resource> config/linstor.yml
   ```
   32GiB over 1GbE: 約 6 分。

## 12. 性能データ

### 12.1 ライブマイグレーション

| 方向 | テスト | ダウンタイム | 転送量 | 所要時間 |
|------|--------|------------|--------|---------|
| 6→7 | 1回目 | 73ms | 911 MiB | 18秒 |
| 7→6 | 1回目 | 33ms | 349 MiB | 11秒 |
| 6→7 | 2回目 | 37ms | 834 MiB | 17秒 |
| 7→6 | 2回目 | 74ms | 844 MiB | 15秒 |

環境: VM 200 (4GiB RAM, 32GiB DRBD disk, kvm64 CPU), 1GbE

**注記**: 旧リージョン構成 (Region B: 6+7号機) 時の実測値。

### 12.2 DRBD 同期時間

| 経路 | データ量 | 所要時間 | 備考 |
|------|---------|---------|------|
| 1GbE (cross-region) | 32 GiB | ~6分 | Ethernet |
| IPoIB (intra-region) | 32 GiB | ~5.7分 (推定) | InfiniBand |
| IPoIB (intra-region) | 550 GiB | ~99分 | 実測 (~94 MiB/s) |

### 12.3 コールドマイグレーション

| フェーズ | 所要時間 | 備考 |
|---------|---------|------|
| DRBD 同期 (32GiB, 1GbE) | ~6分 | 律速要因 |
| VM 停止 + config 移行 + 起動 | ~1分 | 操作時間 |
| DR レプリカ再同期 (32GiB) | ~6分 | バックグラウンド可 |

## 参考資料

- [LINSTOR マルチリージョン per-connection protocol 実験レポート](../report/2026-03-01_051957_linstor_multi_region_protocol_experiment.md)
- [DRBD Protocol 比較レポート](../report/2026-02-27_074430_drbd_protocol_comparison.md)
- [LINSTOR マイグレーションテスト (1回目)](../report/2026-03-09_010540_linstor_migration_test.md)
- [LINSTOR マイグレーション再現性テスト (2回目)](../report/2026-03-09_035515_linstor_migration_retest.md)
- [LINSTOR マルチリージョンマイグレーション チュートリアル](linstor-multiregion-tutorial.md)
- [LINBIT DRBD Users Guide — Protocol](https://linbit.com/drbd-user-guide/drbd-guide-9_0-en/#s-replication-protocols)
- [LINBIT LINSTOR Users Guide — Resource Connections](https://linbit.com/linstor-user-guide/linstor-guide-1_0-en/)
