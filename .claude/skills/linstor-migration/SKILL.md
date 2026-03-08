---
name: linstor-migration
description: "LINSTOR/DRBD マルチリージョン VM マイグレーション。ライブマイグレーション、コールドマイグレーション、リージョン廃止・追加を行う。"
argument-hint: "<subcommand: live-migrate|cold-migrate|decommission-region|add-region|setup-dr>"
---

# LINSTOR マイグレーションスキル

LINSTOR/DRBD マルチリージョン環境での VM マイグレーション操作を行う。

| サブコマンド | 用途 |
|-------------|------|
| `live-migrate <vmid> <target_node>` | リージョン内ライブマイグレーション (Protocol C, ゼロダウンタイム) |
| `cold-migrate <vmid> <source_region> <target_region>` | リージョン間コールドマイグレーション (VM 停止必要) |
| `decommission-region <region>` | リージョン廃止 (全 VM 移行 + ノード削除) |
| `add-region <region>` | リージョン追加 + DR レプリカ設定 |
| `setup-dr <vmid> <dr_node>` | DR レプリカの追加 (2+1 構成) |

## 前提条件

- LINSTOR マルチリージョン構成済み (`scripts/linstor-multiregion-setup.sh` 実行済み)
- 各ノードに `Aux/site` プロパティが設定済み
- リージョン内: Protocol C + allow-two-primaries=yes
- リージョン間: Protocol A + allow-two-primaries=no

## 設定値の読み取り

```sh
YQ="${PROJECT_DIR}/bin/yq"
CONFIG="config/linstor.yml"

CONTROLLER_IP=$("$YQ" '.controller_ip' "$CONFIG")
```

## トポロジー: 2+1 構成

```
Region A (Protocol C)          Region B (Protocol C)
  [Node 4] ←────────────→ [Node 6] ← Primary
  (DR)     Protocol A      [Node 7]
```

- リージョン内: 2レプリカ (Protocol C, allow-two-primaries=yes) → ライブマイグレーション可能
- リージョン間: 1レプリカ (Protocol A, allow-two-primaries=no) → DR 用、非同期レプリケーション

## サブコマンド: live-migrate

リージョン内のノード間で VM をゼロダウンタイムで移行する。

**pve-lock**: 必須

### 前提条件

- 移行元・移行先が同一リージョン内 (Protocol C + allow-two-primaries=yes)
- 両ノードに DRBD リソースが UpToDate で存在
- CPU タイプが `kvm64` (異種ハードウェア間の場合)

### 手順

1. 事前状態記録:
   ```sh
   ssh root@$SOURCE_IP "qm status $VMID"
   ssh root@$CONTROLLER_IP "drbdsetup status --verbose"
   ssh $VM_USER@$VM_MGMT_IP "uptime"
   ```

2. ライブマイグレーション実行:
   ```sh
   ./pve-lock.sh run ./oplog.sh ssh root@$SOURCE_IP "qm migrate $VMID $TARGET_NODE --online"
   ```

3. 事後検証:
   ```sh
   ssh root@$SOURCE_IP "qm status $VMID"           # running (移行先で)
   ssh $VM_USER@$VM_MGMT_IP "uptime"                 # 連続 (リブートなし)
   ssh $VM_USER@$VM_MGMT_IP "md5sum -c checksums.txt" # データ整合性
   ssh root@$CONTROLLER_IP "drbdsetup status --verbose" # Primary が移行先に
   ```

### 実測値

| 方向 | ダウンタイム (1回目) | ダウンタイム (2回目) | 備考 |
|------|-------------------|-------------------|------|
| 6号機 → 7号機 | 73ms / 911 MiB / 18秒 | 37ms / 834 MiB / 17秒 | 平均 55ms |
| 7号機 → 6号機 | 33ms / 349 MiB / 11秒 | 74ms / 844 MiB / 15秒 | 平均 53.5ms |

## サブコマンド: cold-migrate

リージョン間で VM を移行する (VM 停止が必要)。

**pve-lock**: 必須

### 手順

1. 移行先リージョンに2レプリカを確保:
   ```sh
   # DR レプリカが1つある場合、もう1つ追加
   ssh root@$CONTROLLER_IP "linstor resource create $TARGET_NODE2 $RESOURCE_NAME"
   # cross-region パスが必要な場合は作成
   ssh root@$CONTROLLER_IP "linstor node-connection path create $SOURCE_NODE $TARGET_NODE cross-region default default"
   # Protocol A 設定
   ./scripts/linstor-multiregion-setup.sh setup config/linstor.yml
   # DRBD 同期待ち (32GiB over 1GbE: ~6分)
   ```

2. VM 停止:
   ```sh
   ./pve-lock.sh run ./oplog.sh ssh root@$SOURCE_NODE_IP "qm stop $VMID"
   ```

3. 移行元リージョンのレプリカ削除:
   ```sh
   ssh root@$CONTROLLER_IP "linstor resource delete $SOURCE_NODE1 $RESOURCE_NAME"
   ssh root@$CONTROLLER_IP "linstor resource delete $SOURCE_NODE2 $RESOURCE_NAME"
   # cloudinit リソースも同様
   ```

4. VM config を移行先 PVE クラスタに再作成:
   ```sh
   # 移行元の VM config を削除 (qm destroy は LINSTOR リソースも消すので使わない)
   ssh root@$SOURCE_NODE_IP "rm /etc/pve/qemu-server/$VMID.conf"

   # 移行先で VM 再作成
   ssh root@$TARGET_NODE_IP "qm create $VMID --name $VM_NAME --memory $MEM --cores $CORES --cpu kvm64 --net0 virtio=$MAC0,bridge=vmbr1 --net1 virtio=$MAC1,bridge=vmbr0 --ostype l26 --scsihw virtio-scsi-single"

   # 既存 LINSTOR リソースをアタッチ (★核心: これが PVE クロスクラスタで動作する)
   ssh root@$TARGET_NODE_IP "qm set $VMID --scsi0 linstor-storage:${RESOURCE_NAME}_${VMID},discard=on,iothread=1,size=$DISK_SIZE"
   ssh root@$TARGET_NODE_IP "qm set $VMID --boot order=scsi0"
   ssh root@$TARGET_NODE_IP "qm set $VMID --ipconfig1 ip=$VM_MGMT_IP/$PREFIX,gw=$GW"
   ```

5. VM 起動 + 検証:
   ```sh
   ./pve-lock.sh run ./oplog.sh ssh root@$TARGET_NODE_IP "qm start $VMID"
   ssh $VM_USER@$VM_MGMT_IP "md5sum -c checksums.txt"  # データ整合性
   ```

6. DR レプリカの再設定 (移行元リージョンに):
   ```sh
   ssh root@$CONTROLLER_IP "linstor resource create $DR_NODE $RESOURCE_NAME"
   ./scripts/linstor-multiregion-setup.sh setup config/linstor.yml
   ```

### 重要な発見事項

- `qm set --scsi0 linstor-storage:<resource_name>` は **PVE クロスクラスタで動作する**
- vzdump/qmrestore は不要。既存 LINSTOR リソースを直接アタッチできる
- `qm destroy` は LINSTOR リソースも削除するため使用禁止。`rm /etc/pve/qemu-server/*.conf` を使う
- MAC アドレスを保持しないと VM のネットワーク設定が変わる

## サブコマンド: decommission-region

リージョンの全 VM を移行し、ノードを LINSTOR から削除する。

**pve-lock**: 必須

### 手順

1. 全 VM をコールドマイグレーション (cold-migrate サブコマンド参照)
2. ノードを LINSTOR から削除:
   ```sh
   ./scripts/linstor-multiregion-node.sh remove $NODE config/linstor.yml
   ```

## サブコマンド: add-region

LINSTOR にリージョンを追加し、DR レプリカを設定する。

**pve-lock**: 必須

### 手順

1. ノードを LINSTOR に登録:
   ```sh
   ssh root@$CONTROLLER_IP "linstor node create $NODE $NODE_IP --node-type Satellite"
   sleep 10  # satellite 接続待ち
   ```

2. ストレージプール作成:
   ```sh
   ssh root@$CONTROLLER_IP "linstor storage-pool create lvm $NODE striped-pool linstor_vg"
   ```

3. リージョンプロパティ + auto-eviction 無効化:
   ```sh
   ssh root@$CONTROLLER_IP "linstor node set-property $NODE Aux/site $REGION"
   ssh root@$CONTROLLER_IP "linstor node set-property $NODE DrbdOptions/AutoEvictAllowEviction false"
   ```

4. LvcreateOptions 設定:
   ```sh
   ssh root@$CONTROLLER_IP "linstor storage-pool set-property $NODE striped-pool StorDriver/LvcreateOptions -- '-i4 -I64'"
   ```

5. cross-region パス作成:
   ```sh
   # 既存リージョンの各ノードとパスを作成
   ssh root@$CONTROLLER_IP "linstor node-connection path create $EXISTING_NODE $NEW_NODE cross-region default default"
   ```

6. DR レプリカ追加 + Protocol A 設定:
   ```sh
   ssh root@$CONTROLLER_IP "linstor resource create $NODE $RESOURCE_NAME"
   ./scripts/linstor-multiregion-setup.sh setup config/linstor.yml
   ```

## サブコマンド: setup-dr

既存リソースに DR レプリカを追加し、2+1 構成にする。

**pve-lock**: 必須

### 手順

1. cross-region パスの確認・作成:
   ```sh
   ssh root@$CONTROLLER_IP "linstor node-connection path list $SOURCE_NODE $DR_NODE"
   # 未設定なら作成
   ssh root@$CONTROLLER_IP "linstor node-connection path create $SOURCE_NODE $DR_NODE cross-region default default"
   ```

2. DR レプリカ作成:
   ```sh
   ssh root@$CONTROLLER_IP "linstor resource create $DR_NODE $RESOURCE_NAME"
   ```

3. Protocol A 設定:
   ```sh
   ./scripts/linstor-multiregion-setup.sh setup config/linstor.yml
   ```

4. DRBD 同期待ち:
   ```sh
   # 32GiB over 1GbE: ~6分
   ssh root@$CONTROLLER_IP "linstor resource list -r $RESOURCE_NAME"
   ```

## 既知の失敗と対策

| ID | 失敗 | サブコマンド | 検出方法 | 対策 |
|----|------|------------|---------|------|
| M1 | `qm migrate --online` が LINSTOR ディスクで失敗 | live-migrate | エラー出力 | 両ノードに diskful リソースが存在するか `linstor resource list` で確認 |
| M2 | メモリ転送タイムアウト | live-migrate | タイムアウトエラー | `--migration_network` で 10.x を指定 |
| M3 | CPU タイプ `host` で異種ハードウェア間マイグレーション失敗 | live-migrate | `Failed to set special registers` | CPU タイプを `kvm64` に変更 |
| M4 | vendor snippet 未配置 | live-migrate | `volume 'local:snippets/...' does not exist` | 移行先ノードに snippet をコピー |
| M5 | DR レプリカが一時的に Outdated | live-migrate | `drbdsetup status` | Protocol A の非同期性により正常。自動復帰する |
| C1 | `qm set --scsi0 linstor-storage:X` がクロスクラスタで動作 | cold-migrate | - | 実証済み: vzdump 不要 |
| C2 | PrefNic=ib0 で DRBD がリージョン間接続を IB アドレスにバインド | cold-migrate/setup-dr | `Connecting` 状態が継続 | cross-region パスを `default` インターフェースで作成 |
| C3 | node remove/re-add 後にパスが stale | add-region | `Network interface 'default' does not exist` | パスを delete + recreate |
| C4 | `replicas-on-same "Aux/site"` が `Aux/Aux/site` に二重プレフィックス | - | `resource-group list-properties` | `--replicas-on-same site` (Aux/ なし) を使用 |
| C5 | cloudinit ディスクのアタッチ不要 | cold-migrate | - | 初回起動済みのため cloudinit スキップ可 |
| C6 | DRBD フルシンクがネットワーク帯域を飽和 | cold-migrate | SSH 遅延 | `c-max-rate` で帯域制限 |
| C7 | パス作成時の PeerClosingConnectionException | add-region | exit code 10 + エラー出力 | パスを delete + recreate (2回目の create で安定) |

### C2: PrefNic=ib0 と cross-region パス

Region A (4+5号機) は PrefNic=ib0 が設定されており、DRBD はデフォルトで IB アドレス (192.168.100.x) にバインドする。
Region B (6+7号機) は IB を持たないため、cross-region 接続は到達不能になる。

**解決策**: `node-connection path create` で cross-region ペアに `default` インターフェースを指定:
```sh
# Region A の各ノード ↔ Region B の各ノードにパスを作成
ssh root@$CONTROLLER_IP "linstor node-connection path create nodeA nodeB cross-region default default"
```

`default` は LINSTOR のデフォルトネットワークインターフェース (10.x) を使う。IB ではなく Ethernet で接続される。

### C3: node remove/re-add 後の stale パス

LINSTOR からノードを削除して再追加すると、ノードの UUID が変わる。既存のパスは古い UUID を参照しており、
`Network interface 'default' of node 'X' does not exist!` エラーが発生する。

**解決策**: パスを削除して再作成:
```sh
ssh root@$CONTROLLER_IP "linstor node-connection path delete nodeA nodeB cross-region"
ssh root@$CONTROLLER_IP "linstor node-connection path create nodeA nodeB cross-region default default"
```

### C7: パス作成時の PeerClosingConnectionException

ノード remove/re-add 直後に `node-connection path create` を実行すると、`PeerClosingConnectionException` が発生することがある。
パス自体は作成されるが、衛星ノードへの DRBD adjust が失敗し、後続のリソース作成で C3 エラーが発生する。

**発生条件**: ノード再登録直後のパス作成 (衛星ノードとの通信が不安定な場合)
**再現性**: 2回のテストで確認。発生するパスは一定ではない (条件依存)

**確定対策手順**:
```sh
# 1. path create を実行 (エラーが出る可能性あり)
ssh root@$CONTROLLER_IP "linstor node-connection path create nodeA nodeB cross-region default default"
# 2. path delete で一旦削除
ssh root@$CONTROLLER_IP "linstor node-connection path delete nodeA nodeB cross-region"
# 3. path create で再作成 (今度は成功)
ssh root@$CONTROLLER_IP "linstor node-connection path create nodeA nodeB cross-region default default"
```

## oplog

状態変更操作は `./oplog.sh` で記録する:
- live-migrate: qm migrate
- cold-migrate: qm stop, qm start, resource create/delete
- decommission-region: node remove
- add-region: node create, resource create

## pve-lock の使い方

全サブコマンドで状態変更操作に `./pve-lock.sh` を使用する:

```sh
./pve-lock.sh run <command...>     # 即座に実行（ロック中ならエラー）
./pve-lock.sh wait <command...>    # ロック待ち→実行
```

## 関連スクリプト

| スクリプト | 用途 |
|-----------|------|
| `scripts/linstor-multiregion-setup.sh setup` | Aux/site 設定 + リージョン間 Protocol A 設定 |
| `scripts/linstor-multiregion-node.sh add/remove` | ノードのリージョン追加/削除 |
| `scripts/linstor-multiregion-status.sh` | マルチリージョン状態表示 |
