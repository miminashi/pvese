---
name: linstor-node-ops
description: "LINSTOR/DRBD ノードの離脱・復帰操作。障害シミュレーション、回復、正常離脱、再参加を行う。"
argument-hint: "<subcommand: fail|recover|depart|rejoin> <node: server4|server5|server6|server7|server8|server9>"
---

# LINSTOR ノード操作スキル

LINSTOR/DRBD クラスタのノード離脱・復帰操作を行う。

| サブコマンド | 用途 |
|-------------|------|
| `fail <node>` | IPMI/iDRAC 電源断で障害シミュレーション |
| `recover <node>` | 障害ノードの電源オン + DRBD resync 待機 |
| `depart <node>` | LINSTOR から正常離脱 (リソース削除 → SP削除 → ノード削除) |
| `rejoin <node>` | 離脱済みノードのクラスタ再参加 |

`<node>` は `server4`, `server5`, `server6`, `server7` のいずれか。設定値は `config/linstor.yml` と各サーバの `config/server<N>.yml` から読み取る。

## プラットフォーム分岐

| ノード | BMC タイプ | 電源操作 |
|--------|----------|---------|
| server4, server5, server6 | Supermicro IPMI | `ipmitool -I lanplus -H $BMC_IP -U claude -P Claude123 chassis power ...` |
| server7, server8, server9 | iDRAC7 | `ipmitool -I lanplus -H $BMC_IP -U claude -P Claude123 chassis power ...` (IPMI over LAN) |

## 設定値の読み取り

```sh
YQ="${PROJECT_DIR}/bin/yq"
CONFIG="config/linstor.yml"

# コントローラ情報
CONTROLLER_NODE=$("$YQ" '.controller_node' "$CONFIG")
CONTROLLER_IP=$("$YQ" '.controller_ip' "$CONFIG")

# ノード番号からサーバ設定ファイルを特定
# server4 → config/server4.yml, server7 → config/server7.yml
SERVER_CONFIG="config/server${NODE_NUM}.yml"
TARGET_NODE=$("$YQ" '.hostname' "$SERVER_CONFIG")
TARGET_IP=$("$YQ" '.static_ip' "$SERVER_CONFIG")
TARGET_BMC=$("$YQ" '.bmc_ip' "$SERVER_CONFIG")
BMC_USER=$("$YQ" '.bmc_user' "$SERVER_CONFIG")
BMC_PASS=$("$YQ" '.bmc_pass' "$SERVER_CONFIG")

TARGET_IB_IP=$("$YQ" ".nodes[] | select(.name == \"$TARGET_NODE\") | .ib_ip" "$CONFIG")

VG_NAME=$("$YQ" '.vg_name' "$CONFIG")
RG_NAME=$("$YQ" '.resource_group' "$CONFIG")
PLACE_COUNT=$("$YQ" '.place_count' "$CONFIG")
```

全ノードの BMC IP は各サーバの設定ファイルから取得する:
```sh
BMC_IP=$(./bin/yq '.bmc_ip' config/server5.yml)  # → 10.10.10.25
BMC_IP=$(./bin/yq '.bmc_ip' config/server7.yml)  # → 10.10.10.27 (iDRAC)
BMC_IP=$(./bin/yq '.bmc_ip' config/server8.yml)  # → 10.10.10.28 (iDRAC)
BMC_IP=$(./bin/yq '.bmc_ip' config/server9.yml)  # → 10.10.10.29 (iDRAC)
```

## 既知の失敗と対策

| ID | 失敗 | サブコマンド | 検出方法 | 対策 |
|----|------|------------|---------|------|
| N1 | Auto-eviction がリソースを自動退去 (~60分) | fail | `linstor node list` に "Auto-eviction at ..." | 電源断直後に無効化 |
| N2 | place-count 変更忘れで depart 失敗 | depart | リソース削除時に LINSTOR エラー | depart 開始前に `--place-count 1` に変更 |
| N3 | リソース削除順序違反 | depart | ストレージプールやノードの削除でエラー | リソース → SP → ノード の順で削除 |
| N4 | DRBD bitmap resync ポーリング見逃し | recover | 接続直後は `Inconsistent` だが数秒〜数十秒で完了 | 30秒間隔ポーリングで UpToDate を確認 |
| N5 | stale DRBD メタデータ残存 | rejoin | `/etc/drbd.d/linstor-resources.res` が残る | LINSTOR が自動管理するため手動削除不要 |
| N6 | minIoSize 不一致で rejoin 失敗 | rejoin | `incompatible minimum I/O size` エラー | VG 作成時に 512B PV を先頭に配置 |
| N7 | IPoIB インターフェースがリブート後に DOWN 状態 | recover | `ip link show <ib_iface>` で DOWN | 手動で `ip link set up` + `ip addr add` |
| N8 | SSH ホスト鍵がノードリブート後に変化 | recover | `REMOTE HOST IDENTIFICATION HAS CHANGED` | `ssh-keygen -R <target_ip> -f ssh/known_hosts` + `StrictHostKeyChecking=no` |
| N9 | DRBD 9 status に `/proc/drbd` (DRBD 8形式) を使用 | recover | 空出力またはタイムアウト | `drbdsetup status` または `drbdadm status` を使用 |
| N10 | node remove/re-add 後に cross-region パスが stale | rejoin | `Network interface 'default' does not exist` | パスを delete + recreate (詳細は linstor-migration スキル C3) |

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

### N6: minIoSize 不一致

LINSTOR は VG の最初の PV の physical block size を `StorDriver/internal/minIoSize` として使用する。
ノード間で minIoSize が異なると、DRBD リソース作成時に `incompatible minimum I/O size` エラーが発生する。

**原因**: 512e (512B) と 4Kn (4096B) のディスクが混在する環境で、VG 先頭の PV の block size がノード間で異なる。

**確認手順**:
```sh
# 各ディスクの physical block size を確認
ssh root@$TARGET_IP "blockdev --getpbsz /dev/sd{a,b,c,d}"

# LINSTOR の minIoSize を確認
ssh root@$CONTROLLER_IP "linstor storage-pool list-properties $TARGET_NODE striped-pool" | grep minIoSize
```

**回避策 1 (主)**: VG 作成時に 512B block size のディスクを先頭に配置する。

```sh
# 512B のディスクを特定 (例: sdb=512B)
ssh root@$TARGET_IP "blockdev --getpbsz /dev/sdb"   # → 512

# 512B ディスクを先頭にして VG を作成
ssh root@$TARGET_IP "vgcreate linstor_vg /dev/sdb /dev/sda /dev/sdc /dev/sdd"
```

512B を先頭に置く理由: minIoSize=512 は他ノードの minIoSize=512 と一致する。
4096B を先頭に置くと minIoSize=4096 になり、minIoSize=512 のノードとの互換性が失われる。

**回避策 2 (セーフティネット)**: `Linstor/Drbd/auto-block-size 512` を resource-group に設定する (LINSTOR >= 1.33.0)。

```sh
linstor resource-group set-property $RG_NAME Linstor/Drbd/auto-block-size 512
```

効果:
- DRBD リソース設定に `disk { block-size 512; }` が追加され、underlying device の physical block size を上書き
- **手動 `resource create`** で minIoSize 不一致でもリソース作成可能
- **auto-place** (`--place-count` 変更) は minIoSize 不一致ノードを除外するため、手動 `resource create` が必要

現環境では pve-rg に `auto-block-size=512` を常時設定済み。

### N7: IPoIB リブート後 DOWN

IPoIB は永続設定がない場合、リブート後に DOWN のまま（`ib_ipoib` モジュール未ロード）。
`ib-setup-remote.sh --persist` で設定と永続化を一括実行する:

```sh
# スクリプトを転送して実行 (connected mode, MTU 65520 推奨)
scp -F ssh/config scripts/ib-setup-remote.sh pve$N:/tmp/ib-setup-remote.sh
ssh -F ssh/config pve$N "sh /tmp/ib-setup-remote.sh --ip $TARGET_IB_IP/24 --mode connected --mtu 65520 --persist"
```

IB IP は `config/linstor.yml` の `ib_ip` を参照:
- Region A (4+5+6号機): 192.168.100.{1,2,3}/24, インターフェース ibp134s0
- Region B (7+8+9号機): 192.168.101.{7,8,9}/24, インターフェース ibp10s0

> **注**: 初回 `modprobe ib_ipoib` 時に udev リネームのタイミングで `ib0` として検出されることがある。失敗した場合は再実行すれば `ibp*` 名で検出される。

永続設定は `/etc/network/interfaces.d/ib0` に書き込まれる:
```
auto ibp10s0
iface ibp10s0 inet static
    address <IB_IP>/24
    mtu 65520
    pre-up modprobe ib_ipoib
    pre-up echo connected > /sys/class/net/ibp10s0/mode || true
```

### N8: SSH ホスト鍵変更

PVE ノードのリブートでは通常ホスト鍵は変わらない。
ただし OS 再インストールや初回接続時はホスト鍵が変わるため:
```sh
ssh-keygen -R $TARGET_IP -f ssh/known_hosts
ssh -o StrictHostKeyChecking=no root@$TARGET_IP hostname
```

### N9: DRBD 9 ステータスコマンド

DRBD 9 では `/proc/drbd` は空または形式が異なる。以下を使用:
```sh
# 全リソースのステータス
ssh root@$CONTROLLER_IP "drbdsetup status --verbose"
# 特定リソース
ssh root@$CONTROLLER_IP "drbdsetup status <resource> --verbose"
# drbdadm status も可 (ANSI カラーコード付き)
# ANSI カラーを除去する場合は TERM=dumb を設定
```

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

5. データ整合性検証 (VM 内、10.x 管理用 IP に直接 SSH):
   ```sh
   VM_MGMT_IP=$("$YQ" '.benchmark.vm_mgmt_ip' "$CONFIG")
   ssh ${VM_USER}@${VM_MGMT_IP} 'md5sum -c checksums.txt'
   ```

## サブコマンド: recover

障害ノードの電源をオンにし、DRBD resync 完了を待機する。

**pve-lock**: 必須 (電源オン操作)

### 手順

1. IPMI 電源オン:
   ```sh
   ./pve-lock.sh run ./oplog.sh ipmitool -I lanplus -H $TARGET_BMC -U claude -P Claude123 chassis power on
   ```

2. SSH 復帰待機 (★ N8: ホスト鍵クリア + 30秒間隔ポーリング、最大5分):
   ```sh
   ssh-keygen -R $TARGET_IP -f ssh/known_hosts
   ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 root@$TARGET_IP hostname
   ```

3. DRBD resync 待機 (★ N9: drbdsetup を使用、30秒間隔ポーリング):
   ```sh
   ssh root@$CONTROLLER_IP "drbdsetup status --verbose"
   # peer-disk:Inconsistent → peer-disk:UpToDate を待機
   ```

4. IPoIB 復旧確認 (★ N7: 全ノード IB 搭載):
   ```sh
   # IB インターフェースが UP か確認
   ssh root@$TARGET_IP "ip link show type ipoib"
   # DOWN の場合は手動起動 (インターフェース名はリージョンにより異なる)
   # Region A: ibp134s0, Region B: ibp10s0
   ssh root@$TARGET_IP "ip link set $IB_IFACE up"
   ssh root@$TARGET_IP "ip addr add $TARGET_IB_IP/24 dev $IB_IFACE"
   ```

5. 完了確認:
   ```sh
   ssh root@$CONTROLLER_IP "drbdsetup status --verbose"  # UpToDate/UpToDate
   ssh root@$CONTROLLER_IP "linstor node list"            # 両ノード Online
   ssh root@$CONTROLLER_IP "linstor resource list"        # 両ノードにリソースあり
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

離脱済みノードを LINSTOR クラスタに再参加させる。DRBD フル同期が発生する。

**pve-lock**: 必須

### 前提条件

- 対象ノードが `linstor node delete` で離脱済みであること
- 対象ノードに SSH 接続可能であること
- 対象ノードの ZFS プール (`linstor_zpool`) が存在すること

### 手順

1. **ZFS プール状態確認**:
   ```sh
   ssh root@$TARGET_IP "zpool status linstor_zpool"
   ssh root@$TARGET_IP "zpool list linstor_zpool"
   ```

   ZFS プールが存在しない場合は作成:
   ```sh
   # Region A (4-6号機): raidz1, /dev/sda-sdd
   ssh root@$TARGET_IP "zpool create -f linstor_zpool raidz1 /dev/sda /dev/sdb /dev/sdc /dev/sdd"
   # Region B (7-9号機): /dev/sdb-sde (sda は OS ディスク)
   ssh root@$TARGET_IP "zpool create -f linstor_zpool /dev/sdb /dev/sdc /dev/sdd /dev/sde"
   ```
   ```

   コントローラノードの minIoSize と一致していることを確認:
   ```sh
   ssh root@$CONTROLLER_IP "linstor storage-pool list-properties $CONTROLLER_NODE zfs-pool"
   ```

   > **注**: ZFS 環境では `auto-block-size=512` が resource-group に設定済みのため、minIoSize 不一致は自動解消される。

2. **LINSTOR ノード登録**:
   ```sh
   ./pve-lock.sh run ./oplog.sh ssh root@$CONTROLLER_IP "linstor node create $TARGET_NODE $TARGET_IP --node-type Satellite"
   ```

3. **IB インターフェース + PrefNic 設定**:
   ```sh
   # IB_IFACE は OS のデバイス名を使う (`ip link show type ipoib` で確認)
   # Region A (4+5+6号機): ibp134s0, Region B (7+8+9号機): ibp10s0
   ./pve-lock.sh run ./oplog.sh ssh root@$CONTROLLER_IP "linstor node interface create $TARGET_NODE $IB_IFACE $TARGET_IB_IP"
   ./pve-lock.sh run ./oplog.sh ssh root@$CONTROLLER_IP "linstor node set-property $TARGET_NODE PrefNic $IB_IFACE"
   ```

4. **ZFS ストレージプール作成**:
   ```sh
   ./pve-lock.sh run ./oplog.sh ssh root@$CONTROLLER_IP "linstor storage-pool create zfs $TARGET_NODE zfs-pool linstor_zpool"
   ```

5. **Auto-eviction 無効化** (★ N1 対策):
   ```sh
   ssh root@$CONTROLLER_IP "linstor node set-property $CONTROLLER_NODE DrbdOptions/AutoEvictAllowEviction false"
   ssh root@$CONTROLLER_IP "linstor node set-property $TARGET_NODE DrbdOptions/AutoEvictAllowEviction false"
   ```

6. **place-count 復元 → リソース配置** (→ DRBD フル同期トリガー):
   ```sh
   ./pve-lock.sh run ./oplog.sh ssh root@$CONTROLLER_IP "linstor resource-group modify $RG_NAME --place-count $PLACE_COUNT"
   ```

   auto-place が「Not enough available nodes」で失敗した場合 (★ N6 minIoSize 不一致時):
   手動でリソースを個別に作成する (`auto-block-size=512` が RG に設定済みであること):
   ```sh
   # リソース一覧を取得して各リソースを手動配置
   ssh root@$CONTROLLER_IP "linstor -m resource list"
   ./pve-lock.sh run ./oplog.sh ssh root@$CONTROLLER_IP "linstor resource create $TARGET_NODE <resource-name>"
   ```

7. **DRBD フル同期待機** (60秒ポーリング):
   ```sh
   # ~99分 (550 GiB, ~94 MiB/s)
   ssh root@$CONTROLLER_IP "drbdadm status"
   # peer-disk:Inconsistent → peer-disk:UpToDate を待機
   ```

8. **cross-region パスの再作成** (マルチリージョン構成の場合のみ):

   node delete → node create でノード UUID が変わるため、既存の cross-region パスが stale になる。
   `Network interface 'default' of node 'X' does not exist!` エラーが出た場合はパスを再作成する:
   ```sh
   # 対向リージョンの各ノードとのパスを delete + recreate
   ssh root@$CONTROLLER_IP "linstor node-connection path delete $TARGET_NODE $REMOTE_NODE cross-region"
   ssh root@$CONTROLLER_IP "linstor node-connection path create $TARGET_NODE $REMOTE_NODE cross-region default default"
   # Protocol A 再適用
   ./scripts/linstor-multiregion-setup.sh setup config/linstor.yml
   ```

   詳細は `linstor-migration` スキル (C3: stale パス) を参照。

9. **完了確認**:
   ```sh
   ssh root@$CONTROLLER_IP "drbdadm status"            # UpToDate/UpToDate
   ssh root@$CONTROLLER_IP "linstor node list"          # 両ノード Online
   ssh root@$CONTROLLER_IP "linstor resource list"      # 両ノードにリソースあり
   ```

### 実測値

**ZFS raidz1 (現環境)**:

| 操作 | 所要時間 | 備考 |
|------|---------|------|
| depart (リソース+SP+ノード削除) | ~10-19秒 | リソース有無で変動 |
| rejoin (ノード登録〜SP作成) | ~2-3分 | satellite 接続待ち含む |
| DRBD フル同期 (小データ) | ~30-54秒 | VM 1台分 |
| cross-region パス作成 | ~30秒 | 3本/ノード |
| multiregion setup | ~10秒 | Protocol A 設定 |
| **合計 (depart→rejoin完了)** | **~3-5分** | 小データ時 |

**旧 LVM striped (参考)**:

| データ量 | 所要時間 | レート |
|---------|---------|--------|
| ~550 GiB | ~99分 | ~94 MiB/s |

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
