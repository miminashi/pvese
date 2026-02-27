---
name: linstor-node-ops
description: "LINSTOR/DRBD ノードの離脱・復帰操作。障害シミュレーション、回復、正常離脱、再参加を行う。"
disable-model-invocation: true
argument-hint: "<subcommand: fail|recover|depart|rejoin> <node: server4|server5>"
---

# LINSTOR ノード操作スキル

LINSTOR/DRBD クラスタのノード離脱・復帰操作を行う。

| サブコマンド | 用途 |
|-------------|------|
| `fail <node>` | IPMI 電源断で障害シミュレーション |
| `recover <node>` | 障害ノードの電源オン + DRBD resync 待機 |
| `depart <node>` | LINSTOR から正常離脱 (リソース削除 → SP削除 → ノード削除) |
| `rejoin <node>` | 離脱済みノードのクラスタ再参加 (将来用プレースホルダー) |

`<node>` は `server4` または `server5`。設定値は `config/linstor.yml` から読み取る。

## 設定値の読み取り

```sh
YQ="${PROJECT_DIR}/bin/yq"
CONFIG="config/linstor.yml"

NODE1=$("$YQ" '.nodes[0].name' "$CONFIG")
NODE1_IP=$("$YQ" '.nodes[0].ip' "$CONFIG")
NODE1_BMC=$("$YQ" '.nodes[0].bmc_ip' "$CONFIG")  # server4.yml の bmc_ip
NODE2=$("$YQ" '.nodes[1].name' "$CONFIG")
NODE2_IP=$("$YQ" '.nodes[1].ip' "$CONFIG")
NODE2_BMC=$("$YQ" '.nodes[1].bmc_ip' "$CONFIG")  # server5.yml の bmc_ip

VG_NAME=$("$YQ" '.vg_name' "$CONFIG")
RG_NAME=$("$YQ" '.resource_group' "$CONFIG")
PLACE_COUNT=$("$YQ" '.place_count' "$CONFIG")
```

BMC IP はノードの設定ファイルからも取得可能:
```sh
BMC_IP=$(./bin/yq '.bmc_ip' config/server5.yml)
```

## 既知の失敗と対策

| ID | 失敗 | サブコマンド | 検出方法 | 対策 |
|----|------|------------|---------|------|
| N1 | Auto-eviction がリソースを自動退去 (~60分) | fail | `linstor node list` に "Auto-eviction at ..." | 電源断直後に無効化 |
| N2 | place-count 変更忘れで depart 失敗 | depart | リソース削除時に LINSTOR エラー | depart 開始前に `--place-count 1` に変更 |
| N3 | リソース削除順序違反 | depart | ストレージプールやノードの削除でエラー | リソース → SP → ノード の順で削除 |
| N4 | DRBD bitmap resync ポーリング見逃し | recover | 接続直後は `Inconsistent` だが数秒〜数十秒で完了 | 30秒間隔ポーリングで UpToDate を確認 |
| N5 | stale DRBD メタデータ残存 | rejoin | `/etc/drbd.d/linstor-resources.res` が残る | LINSTOR が自動管理するため手動削除不要 |

### N1: Auto-eviction 干渉

LINSTOR はノードオフライン検出後、デフォルト約60分で Auto-eviction を発動する。
障害シミュレーション中に発動すると、リソースが意図せず退去される。

```sh
# 電源断直後に無効化
ssh root@$CONTROLLER_IP "linstor node set-property $TARGET_NODE DrbdOptions/AutoEvictAllowEviction false"
```

### N2: place-count 変更忘れ

正常離脱前に place-count を 1 に下げないと、LINSTOR がレプリカ維持を要求してリソース削除が拒否される。

```sh
# depart 開始前に必須
ssh root@$CONTROLLER_IP "linstor resource-group modify $RG_NAME --place-count 1"
```

### N3: リソース削除順序

削除は必ず「リソース → ストレージプール → ノード」の順。逆順だと依存関係エラーになる。

### N4: DRBD bitmap resync

障害回復後の DRBD resync はビットマップベースで高速 (障害中の変更ブロックのみ)。
接続直後は `peer-disk:Inconsistent` だが、通常15秒程度で `UpToDate` になる。
30秒ポーリング間隔で取りこぼさないよう注意。

## サブコマンド: fail

IPMI 電源断で対象ノードの障害をシミュレーションする。

**pve-lock**: 必須

### 手順

1. 事前状態を記録:
   ```sh
   ssh root@$CONTROLLER_IP "drbdadm status"
   ssh root@$CONTROLLER_IP "linstor node list"
   ssh root@$CONTROLLER_IP "linstor resource list"
   ```

2. IPMI 電源オフ:
   ```sh
   ./pve-lock.sh run ./oplog.sh ipmitool -I lanplus -H $TARGET_BMC -U claude -P Claude123 chassis power off
   ```

3. 30秒待機後、確認:
   ```sh
   ssh root@$CONTROLLER_IP "drbdadm status"           # connection:Connecting
   ssh root@$CONTROLLER_IP "qm status $VM_ID"          # running (VM が残存ノード上の場合)
   ssh root@$CONTROLLER_IP "pvesm status"               # active
   ssh root@$CONTROLLER_IP "linstor node list"          # TARGET_NODE: OFFLINE
   ```

4. Auto-eviction キャンセル (★ N1 対策):
   ```sh
   ssh root@$CONTROLLER_IP "linstor node set-property $TARGET_NODE DrbdOptions/AutoEvictAllowEviction false"
   ```

5. データ整合性検証 (VM 内):
   ```sh
   sshpass -p "$VM_PASS" ssh $VM_USER@$VM_IP 'md5sum -c checksums.txt'
   ```

## サブコマンド: recover

障害ノードの電源をオンにし、DRBD resync 完了を待機する。

**pve-lock**: 必須 (電源オン操作)

### 手順

1. IPMI 電源オン:
   ```sh
   ./pve-lock.sh run ./oplog.sh ipmitool -I lanplus -H $TARGET_BMC -U claude -P Claude123 chassis power on
   ```

2. SSH 復帰待機 (30秒間隔ポーリング、最大5分):
   ```sh
   ssh -o ConnectTimeout=5 root@$TARGET_IP 'hostname'
   ```

3. DRBD resync 待機 (30秒間隔ポーリング):
   ```sh
   ssh root@$CONTROLLER_IP "drbdadm status"
   # peer-disk:Inconsistent → peer-disk:UpToDate を待機
   ```

4. 完了確認:
   ```sh
   ssh root@$CONTROLLER_IP "drbdadm status"            # UpToDate/UpToDate
   ssh root@$CONTROLLER_IP "linstor node list"          # 両ノード Online
   ssh root@$CONTROLLER_IP "linstor resource list"      # 両ノードにリソースあり
   ```

### 回復タイムライン (実測値)

| イベント | 経過時間 |
|---------|---------|
| 電源オン | 0分 |
| SSH 復帰 | ~2分21秒 |
| DRBD 再接続 | ~2分37秒 |
| Bitmap resync 完了 | ~2分52秒 |

ビットマップ resync は障害中の変更ブロックのみを同期するため、フル同期 (~96 MiB/s) と比べて大幅に高速。

## サブコマンド: depart

対象ノードを LINSTOR クラスタから正常に離脱させる。VM はダウンタイムなしで残存ノード上で稼働を継続する。

**pve-lock**: 必須

### 前提条件

- 対象ノードのリソースが UpToDate であること
- 残存ノードの LINSTOR コントローラが稼働中であること

### 手順

1. place-count を 1 に変更 (★ N2 対策):
   ```sh
   ./pve-lock.sh run ./oplog.sh ssh root@$CONTROLLER_IP "linstor resource-group modify $RG_NAME --place-count 1"
   ```

2. 対象ノードのリソースを全て削除 (★ N3 対策: リソースから先に削除):
   ```sh
   # リソース一覧取得
   ssh root@$CONTROLLER_IP "linstor -m resource list"
   # 各リソースを削除
   ./pve-lock.sh run ./oplog.sh ssh root@$CONTROLLER_IP "linstor resource delete $TARGET_NODE <resource-name>"
   ```

3. ストレージプール削除:
   ```sh
   ./pve-lock.sh run ./oplog.sh ssh root@$CONTROLLER_IP "linstor storage-pool delete $TARGET_NODE <pool-name>"
   ```

4. ノード削除:
   ```sh
   ./pve-lock.sh run ./oplog.sh ssh root@$CONTROLLER_IP "linstor node delete $TARGET_NODE"
   ```

5. 確認:
   ```sh
   ssh root@$CONTROLLER_IP "drbdadm status"            # peer なし, disk:UpToDate
   ssh root@$CONTROLLER_IP "linstor node list"          # 残存ノードのみ
   ssh root@$CONTROLLER_IP "linstor resource list"      # 残存ノードのみ
   ssh root@$CONTROLLER_IP "qm status $VM_ID"           # running
   ```

### 1ノード運用の成立条件

以下のパラメータが全て設定されていること:

| パラメータ | 値 | 効果 |
|-----------|-----|------|
| `quorum=off` | DRBD | ノード数に関係なく Primary 昇格可能 |
| `auto-promote=yes` | DRBD | I/O アクセス時に自動で Primary 昇格 |
| `two_node: 1` | PVE corosync | 1ノードでも quorate を維持 |

## サブコマンド: rejoin

離脱済みノードを LINSTOR クラスタに再参加させる。DRBD フル同期が発生するため、550 GiB で ~99分かかる。

**pve-lock**: 必須

### 前提条件

- 対象ノードが `linstor node delete` で離脱済みであること
- 対象ノードに SSH 接続可能であること
- 対象ノードの VG (`linstor_vg`) が存在すること (LV は空であること)

### 手順

1. **5号機の LVM 状態確認** (stale LV がある場合はクリーンアップ):
   ```sh
   ssh root@$TARGET_IP "vgs $VG_NAME"
   ssh root@$TARGET_IP "lvs $VG_NAME 2>/dev/null"
   # stale LV がある場合のみ:
   # ssh root@$TARGET_IP "lvremove -f $VG_NAME; vgremove -f $VG_NAME; pvremove /dev/sd{a,b,c,d}"
   # ssh root@$TARGET_IP "wipefs -af /dev/sd{a,b,c,d} && pvcreate /dev/sd{a,b,c,d} && vgcreate $VG_NAME /dev/sd{a,b,c,d}"
   ```

2. **LINSTOR ノード登録**:
   ```sh
   ./pve-lock.sh run ./oplog.sh ssh root@$CONTROLLER_IP "linstor node create $TARGET_NODE $TARGET_IP --node-type Satellite"
   ```

3. **IB インターフェース + PrefNic 設定**:
   ```sh
   ./pve-lock.sh run ./oplog.sh ssh root@$CONTROLLER_IP "linstor node interface create $TARGET_NODE ib0 $TARGET_IB_IP"
   ./pve-lock.sh run ./oplog.sh ssh root@$CONTROLLER_IP "linstor node set-property $TARGET_NODE PrefNic ib0"
   ```

4. **ストレージプール作成 + ストライプオプション**:
   ```sh
   ./pve-lock.sh run ./oplog.sh ssh root@$CONTROLLER_IP "linstor storage-pool create lvm $TARGET_NODE striped-pool $VG_NAME"
   ./pve-lock.sh run ./oplog.sh ssh root@$CONTROLLER_IP "linstor storage-pool set-property $TARGET_NODE striped-pool StorDriver/LvcreateOptions -- '-i4 -I64'"
   ```

5. **Auto-eviction 無効化** (★ N1 対策):
   ```sh
   ssh root@$CONTROLLER_IP "linstor node set-property $CONTROLLER_NODE DrbdOptions/AutoEvictAllowEviction false"
   ssh root@$CONTROLLER_IP "linstor node set-property $TARGET_NODE DrbdOptions/AutoEvictAllowEviction false"
   ```

6. **place-count 復元** (→ DRBD フル同期トリガー):
   ```sh
   ./pve-lock.sh run ./oplog.sh ssh root@$CONTROLLER_IP "linstor resource-group modify $RG_NAME --place-count $PLACE_COUNT"
   ```

7. **DRBD フル同期待機** (60秒ポーリング):
   ```sh
   # ~99分 (550 GiB, ~94 MiB/s)
   ssh root@$CONTROLLER_IP "drbdadm status"
   # peer-disk:Inconsistent → peer-disk:UpToDate を待機
   ```

8. **完了確認**:
   ```sh
   ssh root@$CONTROLLER_IP "drbdadm status"            # UpToDate/UpToDate
   ssh root@$CONTROLLER_IP "linstor node list"          # 両ノード Online
   ssh root@$CONTROLLER_IP "linstor resource list"      # 両ノードにリソースあり
   ```

### 実測値 (SATA HDD over IPoIB, 4x ストライプ)

| データ量 | 所要時間 | レート |
|---------|---------|--------|
| ~550 GiB | ~99分 | ~94 MiB/s |

2回実行して同一結果を確認済み。

### N5: stale DRBD メタデータ

`linstor node delete` 後も `/etc/drbd.d/linstor-resources.res` が残るが、内容は `include "/var/lib/linstor.d/*.res";` のみ。LINSTOR が satellite 起動時に自動管理するため、手動削除は不要。

## oplog

状態変更操作は `./oplog.sh` で記録する:

- fail: IPMI 電源オフ
- recover: IPMI 電源オン
- depart: place-count 変更、リソース削除、SP削除、ノード削除
- rejoin: ノード登録、IB設定、SP作成、place-count復元

読み取り専用操作 (drbdadm status, linstor node list, linstor resource list) は oplog 不要。

## pve-lock の使い方

全サブコマンドで状態変更操作に `./pve-lock.sh` を使用する:

```sh
./pve-lock.sh run <command...>     # 即座に実行（ロック中ならエラー）
./pve-lock.sh wait <command...>    # ロック待ち→実行
```

ロック中の場合は別の課題に着手し、ロック解放後に再開する。
