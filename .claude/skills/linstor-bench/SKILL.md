---
name: linstor-bench
description: "LINSTOR/DRBD ストレージベンチマーク。VM上でfioを実行し、thin/thick-stripe構成の性能を計測する。"
argument-hint: "<storage_type: thin|thick-stripe> [region: region-a|region-b]"
---

# LINSTOR ベンチマークスキル

LINSTOR/DRBD ストレージ上に VM を作成し、fio でベンチマークを実行する。
引数 `storage_type` で `thin` (LVM thin pool) または `thick-stripe` (LVM 4本ストライプ) を選択する。
オプションで `region` を指定して特定リージョンでベンチマークを実行する。

## マルチリージョン構成

| リージョン | ノード | DRBD通信 | 特徴 |
|-----------|--------|---------|------|
| region-a | 4号機 + 5号機 | IPoIB 192.168.100.x | InfiniBand 高速通信 |
| region-b | 6号機 + 7号機 | Ethernet 10.10.10.x | 1GbE 通信 |

`region` 指定時は、そのリージョンの最初のノードに VM を配置し、同リージョン内の2ノードで DRBD レプリケーションを行う。
`config/linstor.yml` の `regions` セクションからノード構成を読み取る。

## 事前準備

1. LINSTOR/DRBD が全ノードにインストール済み (linstor-controller, linstor-satellite, drbd-dkms, drbd-utils, linstor-proxmox)
2. PVE クラスタが構築済み (`pvecm status` で Quorate)
3. LINSTOR ノードが登録済み (`linstor node list` で全ノード Online)
4. IB インターフェース (ib0) が登録済み + PrefNic=ib0 設定済み (Region A のみ)
5. Debian cloud image が PVE ホスト上にダウンロード済み (パスは `config/linstor.yml` の `benchmark.cloud_image`)
6. vendor snippet (`ssh-pwauth.yml`) が PVE ホスト上に作成済み (後述)
7. `config/linstor.yml` の `benchmark:` セクションが設定済み

## スクリプト一覧

| スクリプト | 用途 |
|-----------|------|
| `./scripts/linstor-bench-preflight.sh` | ディスク SMART ヘルスチェック (SCP で PVE ノードに転送して実行) |

## 設定値の読み取り

```sh
YQ="${PROJECT_DIR}/bin/yq"
CONFIG="config/linstor.yml"

# リージョン指定時のノード選択
# region-a: nodes[0]=4号機, nodes[1]=5号機
# region-b: nodes[2]=6号機, nodes[3]=7号機
# リージョン未指定時はデフォルトで region-a (nodes[0], nodes[1])
REGION="${2:-region-a}"  # 第2引数

if [ "$REGION" = "region-b" ]; then
    NODE1=$("$YQ" '.regions.region-b[0]' "$CONFIG")
    NODE2=$("$YQ" '.regions.region-b[1]' "$CONFIG")
else
    NODE1=$("$YQ" '.regions.region-a[0]' "$CONFIG")
    NODE2=$("$YQ" '.regions.region-a[1]' "$CONFIG")
fi

# ノード名からIPを取得
NODE1_IP=$("$YQ" ".nodes[] | select(.name == \"$NODE1\") | .ip" "$CONFIG")
NODE2_IP=$("$YQ" ".nodes[] | select(.name == \"$NODE2\") | .ip" "$CONFIG")
DISKS=$("$YQ" ".nodes[] | select(.name == \"$NODE1\") | .storage_disks[]" "$CONFIG")

# ストレージ
VG_NAME=$("$YQ" '.vg_name' "$CONFIG")
RG_NAME=$("$YQ" '.resource_group' "$CONFIG")
PLACE_COUNT=$("$YQ" '.place_count' "$CONFIG")

# ベンチマーク
VM_ID=$("$YQ" '.benchmark.vm_id' "$CONFIG")
VM_NAME=$("$YQ" '.benchmark.vm_name' "$CONFIG")
VM_CORES=$("$YQ" '.benchmark.vm_cores' "$CONFIG")
VM_MEMORY=$("$YQ" '.benchmark.vm_memory' "$CONFIG")
VM_DISK_SIZE=$("$YQ" '.benchmark.vm_disk_size' "$CONFIG")
VM_BRIDGE=$("$YQ" '.benchmark.vm_bridge' "$CONFIG")
VM_MGMT_BRIDGE=$("$YQ" '.benchmark.vm_mgmt_bridge' "$CONFIG")
VM_MGMT_IP=$("$YQ" '.benchmark.vm_mgmt_ip' "$CONFIG")
VM_MGMT_PREFIX=$("$YQ" '.benchmark.vm_mgmt_prefix' "$CONFIG")
VM_USER=$("$YQ" '.benchmark.vm_user' "$CONFIG")
VM_PASS=$("$YQ" '.benchmark.vm_password' "$CONFIG")
CLOUD_IMAGE=$("$YQ" '.benchmark.cloud_image' "$CONFIG")
FIO_RUNTIME=$("$YQ" '.benchmark.fio_runtime' "$CONFIG")
FIO_SIZE=$("$YQ" '.benchmark.fio_size' "$CONFIG")
FIO_SEQ_SIZE=$("$YQ" '.benchmark.fio_seq_size' "$CONFIG")
```

## 既知の失敗と対策

前回のベンチマーク実行で発生した失敗パターン。各フェーズでこの対策を適用する。

| ID | 失敗 | フェーズ | 検出方法 | 対策 |
|----|------|---------|---------|------|
| F1 | ディスク不良セクタ | Phase 0 | SMART Current_Pending_Sector > 0 | ゼロ書きで強制再割り当て |
| F2 | LINSTOR リソース名が `vm-100-disk-0` ではなく `pm-XXXX` | Phase 3 | `qm importdisk` 出力に `pm-XXXX` と表示 | importdisk 出力をパースしてリソース名を取得 |
| F3 | cloud-init SSH パスワード認証無効 | Phase 3 | `Permission denied (publickey)` | vendor snippet `ssh_pwauth: true` + `--cicustom` |
| F4 | VM MAC アドレス不一致で IP 検出失敗 | Phase 4 | IP 検出タイムアウト | 管理用 IP (10.x) が config で設定済みのため不要。DHCP のみの場合は `qm config` から MAC を動的取得 |
| F5 | Thick LVM で DRBD 全領域同期 | Phase 4 | `peer-disk:Inconsistent` が長時間 | ポーリングで待機 (thin は ~30秒) |
| F6 | `linstor --output-format json` 不存在 | Phase 4 | `unrecognized arguments` エラー | `linstor -m resource list` を使う |
| F7 | citype デフォルト (configdrive2) が Debian に非対応 | Phase 3 | cloud-init 設定が VM に反映されない | `--citype nocloud` を初回起動前に設定 |
| F8 | LINSTOR Auto-eviction がノードオフライン時にリソースを自動退去 | Phase 4-5 | `linstor node list` で "Auto-eviction at ..." 表示 | テスト前に無効化 |
| F9 | fio JSON 出力ディレクトリが未作成 | Phase 5 | `No such file or directory` | ローカルの `mkdir -p` を先頭に追加 |
| F10 | `--boot order=scsi0` をディスクインポート前に設定 | Phase 3 | `device 'scsi0' does not exist` | importdisk → scsi0 接続の**後**に boot order を設定 |
| F11 | DRBD 9 の同期確認に `/proc/drbd` (DRBD 8形式) を使用 | Phase 4 | タイムアウトまたは空出力 | `drbdsetup status <res> --verbose` を使用 |
| F12 | sshpass が非コントローラ PVE ホストに未インストール | Phase 4 | `sshpass: command not found` | 公開鍵認証 + 10.x 直接 SSH を使用するため sshpass 不要 |
| F13 | VM 再作成後に SSH known_hosts のホスト鍵が不一致 | Phase 4 | `REMOTE HOST IDENTIFICATION HAS CHANGED` | `ssh-keygen -R <vm_ip>` で事前クリア |
| F14 | Satellite ノードで `linstor` コマンドが localhost controller に接続不可 | Phase 4 | `Connection refused` | 全 linstor コマンドは Controller ノード (4号機) で実行 |
| F15 | cloud-init DHCP でアドレス取得失敗 → SSH 不能 | Phase 3 | IP 検出タイムアウト | DHCP 取得を最大5分待機。管理用 SSH は ipconfig1 の static 10.x で行うため DHCP 完了前でもアクセス可能 |
| F16 | vendor snippet ssh_pwauth=true でもパスワード認証不可 | Phase 3-4 | `Permission denied (publickey)` | SSH 公開鍵認証を優先: `qm set --sshkeys <pubkey_file>` |
| F17 | Debian 13 (OpenSSH 10.0) で RSA 鍵が無効化 | Phase 3-4 | `Permission denied (publickey)` | **Ed25519 鍵** (`id_ed25519.pub`) を使用すること |
| F18 | DRBD non-UpToDate 中に `qm resize` が失敗 | Phase 3 | LINSTOR API 500 エラー | DRBD 同期完了後に resize する。resize 後に VM 内で `growpart` + `resize2fs` も必要 |

### F1: ディスク不良セクタ

SMART の `Current_Pending_Sector` が 0 より大きいディスクには不良セクタがあり、I/O エラーの原因になる。
ゼロ書きで該当セクタに書き込むと、ディスクが代替セクタに再割り当てを行う。

```sh
# 不良セクタの強制再割り当て (対象ディスクに対して実行)
ssh root@<node_ip> 'dd if=/dev/zero of=/dev/sdX bs=1M count=100 oflag=direct'
ssh root@<node_ip> 'dd if=/dev/zero of=/dev/sdX bs=1M count=100 oflag=direct seek=$(($(blockdev --getsize64 /dev/sdX)/1048576 - 100))'
# 再チェック
ssh root@<node_ip> 'smartctl -A /dev/sdX | grep -E "Current_Pending|Reallocated|Offline_Uncorrectable"'
```

### F2: LINSTOR リソース名

`qm importdisk` が LINSTOR ストレージにディスクをインポートすると、リソース名が `pm-XXXX` (ランダム) になる。
`vm-100-disk-0` のような標準名にはならないため、importdisk の出力からリソース名をパースする必要がある。

```sh
# importdisk 実行結果の例:
# unused0: successfully imported disk 'linstor-storage:pm-bfea68ea_100'
# → パースして 'pm-bfea68ea_100' を取得し、qm set --scsi0 に使用
# 注意: リソース名は pm-<hex>_<vmid> 形式。[0-9]* ではなく [a-z0-9_]+ でマッチすること
IMPORT_OUTPUT=$(ssh root@$NODE1_IP "qm importdisk $VM_ID $CLOUD_IMAGE linstor-storage" 2>&1)
RESOURCE_NAME=$(echo "$IMPORT_OUTPUT" | grep -o "linstor-storage:pm-[a-z0-9_]*" | sed 's/linstor-storage://')
ssh root@$NODE1_IP "qm set $VM_ID --scsi0 linstor-storage:$RESOURCE_NAME,discard=on,iothread=1"
```

### F3: cloud-init SSH パスワード認証

Debian cloud image はデフォルトで SSH パスワード認証が無効。`--cipassword` を設定しても SSH できない。
vendor snippet で `ssh_pwauth: true` を設定する必要がある。

```sh
# vendor snippet を PVE ホストに作成 (snippets ディレクトリが必要)
ssh root@$NODE1_IP 'mkdir -p /var/lib/vz/snippets'
ssh root@$NODE1_IP 'printf "#cloud-config\nssh_pwauth: true\n" > /var/lib/vz/snippets/ssh-pwauth.yml'
# VM に適用
ssh root@$NODE1_IP "qm set $VM_ID --cicustom 'vendor=local:snippets/ssh-pwauth.yml'"
```

### F4: VM MAC アドレスの動的取得

> **注**: 管理用 IP (10.x) が config で設定済み (`vm_mgmt_ip`) の場合、MAC アドレス検出・nmap スキャン・ARP 参照は不要。
> `VM_IP=$VM_MGMT_IP` で直接 SSH 接続できる。

以下は DHCP のみの構成で IP 検出が必要な場合の参考手順:
```sh
MAC=$(ssh root@$NODE1_IP "qm config $VM_ID" | grep '^net0' | grep -o 'virtio=[0-9A-Fa-f:]*' | cut -d= -f2)
ssh root@$NODE1_IP "ip neigh | grep -i '$MAC' | awk '{print \$1}'"
```

### F7: citype nocloud

Debian の cloud-init は `nocloud` データソースを使う。PVE のデフォルト `configdrive2` では設定が反映されない。

```sh
ssh root@$NODE1_IP "qm set $VM_ID --citype nocloud"
```

### F8: LINSTOR Auto-eviction

ノードがオフラインになると LINSTOR は約60分後に Auto-eviction を発動し、リソースを自動退去させる。
ベンチマーク中にノード障害やリブートが発生すると、意図しないリソース再配置が起きる。

検出:
```sh
ssh root@$NODE1_IP "linstor node list"
# "Auto-eviction at 2026-XX-XX XX:XX:XX" が表示される
```

対策 (テスト前に各ノードで無効化):
```sh
ssh root@$NODE1_IP "linstor node set-property $NODE1 DrbdOptions/AutoEvictAllowEviction false"
ssh root@$NODE1_IP "linstor node set-property $NODE2 DrbdOptions/AutoEvictAllowEviction false"
```

テスト終了後に再有効化:
```sh
ssh root@$NODE1_IP "linstor node set-property $NODE1 DrbdOptions/AutoEvictAllowEviction"
ssh root@$NODE1_IP "linstor node set-property $NODE2 DrbdOptions/AutoEvictAllowEviction"
```

### F9: fio 出力ディレクトリ未作成

fio の JSON 出力を SSH 経由で stdout リダイレクトする場合、出力先ディレクトリはローカルホスト側 (Claude Code 実行マシン) に必要。
```sh
# Phase 5 の先頭で実行
mkdir -p tmp/<session-id>/fio-results/
```

### F10: boot order 設定の順序

`qm importdisk` → `qm set --scsi0` → `qm set --boot order=scsi0` の順で実行すること。
importdisk 前や scsi0 接続前に boot order を設定すると、scsi0 デバイスが存在しないためエラーになる。

### F11: DRBD 9 の同期確認

DRBD 9 では `/proc/drbd` は空または DRBD 8 と形式が異なる。同期状態の確認には以下を使用:
```sh
# 推奨: 全リソースのステータス
ssh root@$CONTROLLER_IP "drbdsetup status --verbose"
# 特定リソース
ssh root@$CONTROLLER_IP "drbdsetup status <resource> --verbose"
# peer-disk で UpToDate を確認
# drbdadm status も使用可能 (ANSI カラーコード付き)
```

### F12: sshpass 未インストール

公開鍵認証 + 10.x 管理用 IP への直接 SSH を使用するため、sshpass は不要。
VM への SSH は `ssh ${VM_USER}@${VM_MGMT_IP}` で直接接続する。

### F13: SSH known_hosts ホスト鍵不一致

VM を再作成すると SSH ホスト鍵が変わるため、known_hosts に古い鍵が残っているとエラーになる。
```sh
# VM の IP に対してホスト鍵をクリア
ssh-keygen -R <vm_ip>
# PVE ホスト側でも同様
ssh root@$NODE1_IP "ssh-keygen -R <vm_ip>"
```

### F14: Satellite ノードでの linstor コマンド

Satellite ノードには linstor-controller が動いていないため、`linstor` コマンドがデフォルトの localhost:3370 に接続しようとして失敗する。全 linstor コマンドは Controller ノード (4号機) 経由で実行すること。

### F15-F16: SSH 接続の推奨方法

VM にはデュアル NIC を構成し、SSH は **10.x 管理用 IP に直接接続**する:
- `net0`: vmbr1 (192.168.39.0/24, DHCP, インターネット用)
- `net1`: vmbr0 (10.0.0.0/8, static, SSH 管理用)

> **注意 (F17)**: Debian 13 cloud image (OpenSSH 10.0) は **RSA 鍵が無効化**されている。
> `/root/.ssh/id_rsa.pub` ではなく **Ed25519 鍵** (`/root/.ssh/id_ed25519.pub`) を使うこと。

1. **ローカルマシン** (Claude Code ホスト) の Ed25519 公開鍵を `qm set --sshkeys` で設定:
   ```sh
   scp ~/.ssh/id_ed25519.pub root@$NODE1_IP:/tmp/local_ed25519.pub
   ssh root@$NODE1_IP "qm set $VM_ID --sshkeys /tmp/local_ed25519.pub"
   ```
   - **注意**: PVE ホストの鍵ではなくローカルの鍵を使うこと (SSH はローカルから直接 10.x に接続)
2. `ssh -o StrictHostKeyChecking=no debian@$VM_MGMT_IP` で**ローカルから直接接続** (10.x 経由、sshpass 不要)
3. DHCP は最大5分かかることがあるが、SSH は static 10.x なので DHCP 完了を待つ必要はない
4. fio インストール (apt) にはインターネットが必要なので、cloud-init 完了を待つ:
   ```sh
   ssh ${VM_USER}@${VM_MGMT_IP} 'cloud-init status --wait'
   ```

> **注意**: 192.168.39.0/24 に静的 IP を割り当てないこと (DHCP 衝突の危険)。

## fio テスト定義

全7テスト。各テストは `--runtime=$FIO_RUNTIME` (デフォルト 60秒) で実行。

| # | テスト名 | rw | bs | iodepth | size |
|---|---------|-----|-----|---------|------|
| 1 | randread-4k-qd1 | randread | 4k | 1 | $FIO_SIZE |
| 2 | randread-4k-qd32 | randread | 4k | 32 | $FIO_SIZE |
| 3 | randwrite-4k-qd1 | randwrite | 4k | 1 | $FIO_SIZE |
| 4 | randwrite-4k-qd32 | randwrite | 4k | 32 | $FIO_SIZE |
| 5 | seqread-1m-qd32 | read | 1m | 32 | $FIO_SEQ_SIZE |
| 6 | seqwrite-1m-qd32 | write | 1m | 32 | $FIO_SEQ_SIZE |
| 7 | mixed-rw-4k-qd32 | randrw (70/30) | 4k | 32 | $FIO_SIZE |

共通オプション: `--ioengine=libaio --direct=1 --numjobs=1 --time_based --group_reporting --output-format=json`

## フェーズ実行

---

### Phase 0: Pre-flight — ディスクヘルスチェック

**pve-lock**: 不要

各ノードの各ストレージディスクの SMART をチェックし、不良セクタを検出する。

1. preflight スクリプトを各ノードに転送:
   ```sh
   scp ./scripts/linstor-bench-preflight.sh root@$NODE1_IP:/tmp/
   scp ./scripts/linstor-bench-preflight.sh root@$NODE2_IP:/tmp/
   ```

2. 各ノードで実行:
   ```sh
   ssh root@$NODE1_IP 'sh /tmp/linstor-bench-preflight.sh /dev/sda /dev/sdb /dev/sdc /dev/sdd'
   ssh root@$NODE2_IP 'sh /tmp/linstor-bench-preflight.sh /dev/sda /dev/sdb /dev/sdc /dev/sdd'
   ```

3. 不良セクタ検出時 (exit 1):
   - 対策 F1 のゼロ書き手順でセクタを強制再割り当て
   - 再割り当て後に再実行して `Current_Pending_Sector = 0` を確認

---

### Phase 1: クリーンアップ

**pve-lock**: 必須

既存の VM、LINSTOR リソース、ストレージプール、LVM を解体する。
存在しないリソースの削除はエラーになるので、各ステップで存在確認してからスキップまたは削除する。

削除順序: VM → LINSTOR リソース → リソースグループ → ストレージプール → PVE ストレージ → LVM

1. **VM 停止・削除** (存在する場合):
   ```sh
   ssh root@$NODE1_IP "qm status $VM_ID" 2>/dev/null && \
     ssh root@$NODE1_IP "qm stop $VM_ID" && \
     ssh root@$NODE1_IP "qm destroy $VM_ID --purge"
   ```

2. **LINSTOR リソース削除** (存在する場合):
   ```sh
   # リソース定義一覧を確認
   ssh root@$NODE1_IP "linstor resource-definition list"
   # 各リソース定義を削除 (--async でタイムアウト回避)
   ssh root@$NODE1_IP "linstor resource-definition delete <resource-name>"
   ```

3. **PVE ストレージ削除**:
   ```sh
   ssh root@$NODE1_IP "pvesm status" | grep linstor-storage && \
     ssh root@$NODE1_IP "pvesm remove linstor-storage"
   ```

4. **リソースグループ削除**:
   ```sh
   ssh root@$NODE1_IP "linstor volume-group delete $RG_NAME 0" 2>/dev/null
   ssh root@$NODE1_IP "linstor resource-group delete $RG_NAME" 2>/dev/null
   ```

5. **ストレージプール削除**:
   ```sh
   ssh root@$NODE1_IP "linstor storage-pool delete $NODE1 <pool-name>"
   ssh root@$NODE1_IP "linstor storage-pool delete $NODE2 <pool-name>"
   ```

6. **各ノードで LVM 解体**:
   ```sh
   ssh root@$NODE1_IP "vgs $VG_NAME" 2>/dev/null && \
     ssh root@$NODE1_IP "lvremove -f $VG_NAME 2>/dev/null; vgremove -f $VG_NAME; pvremove /dev/sda /dev/sdb /dev/sdc /dev/sdd"
   ssh root@$NODE2_IP "vgs $VG_NAME" 2>/dev/null && \
     ssh root@$NODE2_IP "lvremove -f $VG_NAME 2>/dev/null; vgremove -f $VG_NAME; pvremove /dev/sda /dev/sdb /dev/sdc /dev/sdd"
   ```

7. 検証:
   ```sh
   ssh root@$NODE1_IP "linstor storage-pool list"
   ssh root@$NODE1_IP "linstor resource-definition list"
   ssh root@$NODE1_IP "pvesm status"
   ```

---

### Phase 2: ストレージ構成

**pve-lock**: 必須

引数 `storage_type` に応じてストレージを構成する。

#### 共通: VG 作成

各ノードで VG を作成する:

```sh
ssh root@$NODE1_IP "wipefs -af /dev/sda /dev/sdb /dev/sdc /dev/sdd && pvcreate /dev/sda /dev/sdb /dev/sdc /dev/sdd && vgcreate $VG_NAME /dev/sda /dev/sdb /dev/sdc /dev/sdd"
ssh root@$NODE2_IP "wipefs -af /dev/sda /dev/sdb /dev/sdc /dev/sdd && pvcreate /dev/sda /dev/sdb /dev/sdc /dev/sdd && vgcreate $VG_NAME /dev/sda /dev/sdb /dev/sdc /dev/sdd"
```

#### storage_type=thin の場合

```sh
# Thin pool 作成 (各ノード)
ssh root@$NODE1_IP "lvcreate -l 95%FREE -T ${VG_NAME}/thinpool"
ssh root@$NODE2_IP "lvcreate -l 95%FREE -T ${VG_NAME}/thinpool"

# LINSTOR ストレージプール (lvmthin)
POOL_NAME="thinpool"
ssh root@$NODE1_IP "linstor storage-pool create lvmthin $NODE1 $POOL_NAME ${VG_NAME}/thinpool"
ssh root@$NODE1_IP "linstor storage-pool create lvmthin $NODE2 $POOL_NAME ${VG_NAME}/thinpool"
```

#### storage_type=thick-stripe の場合

```sh
# LINSTOR ストレージプール (lvm)
POOL_NAME="striped-pool"
ssh root@$NODE1_IP "linstor storage-pool create lvm $NODE1 $POOL_NAME $VG_NAME"
ssh root@$NODE1_IP "linstor storage-pool create lvm $NODE2 $POOL_NAME $VG_NAME"

# ストライピングオプション設定 (-i4: 4本, -I64: 64KiB)
ssh root@$NODE1_IP "linstor storage-pool set-property $NODE1 $POOL_NAME StorDriver/LvcreateOptions -- '-i4 -I64'"
ssh root@$NODE1_IP "linstor storage-pool set-property $NODE2 $POOL_NAME StorDriver/LvcreateOptions -- '-i4 -I64'"
```

#### 共通: リソースグループ + DRBD オプション + PVE ストレージ

```sh
# リソースグループ
ssh root@$NODE1_IP "linstor resource-group create $RG_NAME --place-count $PLACE_COUNT --storage-pool $POOL_NAME"
ssh root@$NODE1_IP "linstor volume-group create $RG_NAME"

# DRBD オプション
ssh root@$NODE1_IP "linstor resource-group drbd-options --protocol C $RG_NAME"
ssh root@$NODE1_IP "linstor resource-group drbd-options --quorum off $RG_NAME"
ssh root@$NODE1_IP "linstor resource-group drbd-options --auto-promote yes $RG_NAME"

# PVE ストレージ
ssh root@$NODE1_IP "pvesm add drbd linstor-storage --resourcegroup $RG_NAME --content images,rootdir --controller $NODE1_IP"
```

#### 検証

```sh
ssh root@$NODE1_IP "linstor storage-pool list"
ssh root@$NODE1_IP "pvesm status"
```

---

### Phase 3: VM 作成

**pve-lock**: 必須

> **注意**: cloud-init は初回起動時のみ実行される。すべての設定 (cicustom, citype, ciuser, cipassword, ipconfig0, ipconfig1) を `qm start` 前に完了すること。

0. **ブリッジ検証** (★ 7号機 NIC 逆順対策):
   ```sh
   # vmbr0 が 10.x (管理)、vmbr1 が 192.168.39.x (DHCP) であることを確認
   ssh root@$NODE1_IP "ip -4 addr show vmbr0"   # → 10.10.10.x が表示されるべき
   ssh root@$NODE1_IP "ip -4 addr show vmbr1"   # → 192.168.39.x が表示されるべき
   # 逆の場合は VM_BRIDGE と VM_MGMT_BRIDGE を入れ替える
   ```

1. **VM 作成** (★ デュアル NIC: net0=インターネット用, net1=管理用):
   ```sh
   ssh root@$NODE1_IP "qm create $VM_ID --name $VM_NAME --memory $VM_MEMORY --cores $VM_CORES --cpu host --net0 virtio,bridge=$VM_BRIDGE --net1 virtio,bridge=$VM_MGMT_BRIDGE --ostype l26 --scsihw virtio-scsi-single"
   ```

2. **ディスクインポート** (★ F2 対策: リソース名をパース):
   ```sh
   IMPORT_OUTPUT=$(ssh root@$NODE1_IP "qm importdisk $VM_ID $CLOUD_IMAGE linstor-storage" 2>&1)
   RESOURCE_NAME=$(echo "$IMPORT_OUTPUT" | grep "successfully imported" | grep -o 'pm-[a-z0-9_]*')
   ```
   - `RESOURCE_NAME` が空の場合は出力全体を確認しエラー対処
   - **注意**: grep は `successfully imported` 行のみ対象にすること。`pm-<hex>` と `pm-<hex>_<vmid>` の両方にマッチするため、正しい行から抽出しないと誤ったリソース名になる

3. **ディスク接続** (パースしたリソース名を使用):
   ```sh
   ssh root@$NODE1_IP "qm set $VM_ID --scsi0 linstor-storage:${RESOURCE_NAME},discard=on,iothread=1"
   ```

4. **ブート順序 + cloudinit ドライブ** (★ F10: scsi0 接続後に設定すること):
   ```sh
   ssh root@$NODE1_IP "qm set $VM_ID --boot order=scsi0"
   ssh root@$NODE1_IP "qm set $VM_ID --ide2 linstor-storage:cloudinit"
   ```

5. **vendor snippet 作成・適用** (★ F3 対策):
   ```sh
   ssh root@$NODE1_IP 'mkdir -p /var/lib/vz/snippets'
   ssh root@$NODE1_IP 'printf "#cloud-config\nssh_pwauth: true\n" > /var/lib/vz/snippets/ssh-pwauth.yml'
   ssh root@$NODE1_IP "qm set $VM_ID --cicustom 'vendor=local:snippets/ssh-pwauth.yml'"
   ```

6. **citype 設定** (★ F7 対策):
   ```sh
   ssh root@$NODE1_IP "qm set $VM_ID --citype nocloud"
   ```

7. **SSH 公開鍵設定** (★ F16/F17 対策: Ed25519 公開鍵認証を使用):
   ```sh
   # ローカルマシン (Claude Code ホスト) の Ed25519 公開鍵を PVE ホストにコピー
   scp ~/.ssh/id_ed25519.pub root@$NODE1_IP:/tmp/local_ed25519.pub
   ssh root@$NODE1_IP "qm set $VM_ID --sshkeys /tmp/local_ed25519.pub"
   ```
   - **注意**: PVE ホストの鍵ではなく、ローカルマシンの公開鍵を設定すること。SSH はローカルから 10.x 経由で直接接続するため

8. **cloud-init ユーザ・ネットワーク設定** (★ デュアル NIC: DHCP + 管理用 static):
   ```sh
   ssh root@$NODE1_IP "qm set $VM_ID --ciuser $VM_USER --cipassword $VM_PASS --ipconfig0 ip=dhcp --ipconfig1 ip=$VM_MGMT_IP/$VM_MGMT_PREFIX"
   ```
   - `ipconfig0`: vmbr1 (DHCP, インターネット用)
   - `ipconfig1`: vmbr0 (static 10.x, SSH 管理用, ゲートウェイ不要)

9. **VM 起動** (★ resize は DRBD 同期完了後に行うため先に起動):
    ```sh
    ssh root@$NODE1_IP "qm start $VM_ID"
    ```

---

### Phase 4: 同期待ち + SSH 接続

**pve-lock**: 不要

#### DRBD 同期待ち (★ F5)

thick-stripe の場合、全領域の DRBD 初期同期が発生する。thin の場合は使用済み領域のみで ~30秒。

実測同期レート (SATA HDD over IPoIB):

| ディスクサイズ | 所要時間 | レート |
|--------------|---------|--------|
| 32G | ~9分 | — |
| 518 GiB | ~92分 | ~96 MiB/s |

ポーリング間隔: 30秒 (`drbdsetup status`)

```sh
# 同期状態のポーリング (30秒間隔) (★ F11: drbdsetup を使用、/proc/drbd は DRBD 9 で空)
ssh root@$CONTROLLER_IP "drbdsetup status --verbose"
# 出力例 (同期中): peer-disk:Inconsistent
# 出力例 (完了): peer-disk:UpToDate
# ★ F14: linstor/DRBD コマンドは Controller ノード (4号機) で実行すること
```

UpToDate/UpToDate になるまでポーリングで待機する。

#### ディスクリサイズ (★ F18: DRBD 同期完了後に実行)

```sh
ssh root@$NODE1_IP "qm resize $VM_ID scsi0 $VM_DISK_SIZE"
# VM 内でパーティション + ファイルシステム拡張
ssh ${VM_USER}@${VM_MGMT_IP} "sudo growpart /dev/sda 1"
ssh ${VM_USER}@${VM_MGMT_IP} "sudo resize2fs /dev/sda1"
```

#### VM 管理 IP

VM の管理用 IP は config から既知 (10.x static)。MAC アドレス検出・nmap スキャン・ARP テーブル参照は不要。

```sh
VM_IP=$VM_MGMT_IP
```

> **注**: F4 (MAC アドレス不一致) は管理用 IP が config で設定済みのため不要。
> DHCP の 192.168.39.x IP はインターネット通信専用で、SSH 接続には使用しない。

#### SSH 接続テスト (★ F13)

```sh
# ★ F13: VM 再作成時はホスト鍵をクリア
ssh-keygen -R $VM_IP

# 10.x 管理用 IP に直接 SSH (公開鍵認証、Phase 3 で --sshkeys 設定済み)
ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 ${VM_USER}@${VM_IP} 'uname -a'
```

#### cloud-init 完了待ち + fio インストール

DHCP (vmbr1) は最大5分かかる場合がある。SSH は 10.x (static) 経由なので DHCP 完了前でもアクセス可能。
ただし fio インストール (apt) にはインターネットが必要なので、cloud-init 完了を待つ。

```sh
ssh ${VM_USER}@${VM_IP} 'cloud-init status --wait'
ssh ${VM_USER}@${VM_IP} 'sudo apt-get update && sudo apt-get install -y fio'
```

> **注意 (F6)**: LINSTOR の JSON 出力は `linstor --output-format json` ではなく `linstor -m` (machine-readable) を使う。
> `--output-format` オプションは存在しない。

---

### Phase 5: ベンチマーク実行

**pve-lock**: 不要

7テストを順番に実行する。各テスト結果は JSON で `tmp/<session-id>/fio-results/` に保存する。

```sh
# ★ F9: 出力ディレクトリをローカル側に事前作成
mkdir -p tmp/<session-id>/fio-results
```

各テストの実行 (10.x 管理 IP に公開鍵認証で SSH 接続):
```sh
ssh ${VM_USER}@${VM_IP} "sudo fio \
  --name=<test-name> \
  --ioengine=libaio --direct=1 \
  --rw=<rw-pattern> --bs=<block-size> \
  --iodepth=<queue-depth> --numjobs=1 \
  --size=<size> \
  --runtime=$FIO_RUNTIME --time_based \
  --group_reporting --output-format=json" \
  > tmp/<session-id>/fio-results/<test-name>.json
```

テスト一覧 (fio テスト定義セクション参照):
1. `randread-4k-qd1`: `--rw=randread --bs=4k --iodepth=1 --size=$FIO_SIZE`
2. `randread-4k-qd32`: `--rw=randread --bs=4k --iodepth=32 --size=$FIO_SIZE`
3. `randwrite-4k-qd1`: `--rw=randwrite --bs=4k --iodepth=1 --size=$FIO_SIZE`
4. `randwrite-4k-qd32`: `--rw=randwrite --bs=4k --iodepth=32 --size=$FIO_SIZE`
5. `seqread-1m-qd32`: `--rw=read --bs=1m --iodepth=32 --size=$FIO_SEQ_SIZE`
6. `seqwrite-1m-qd32`: `--rw=write --bs=1m --iodepth=32 --size=$FIO_SEQ_SIZE`
7. `mixed-rw-4k-qd32`: `--rw=randrw --rwmixread=70 --bs=4k --iodepth=32 --size=$FIO_SIZE`

---

### Phase 6: 結果抽出 + レポート

**pve-lock**: 不要

1. fio JSON から主要メトリクスを抽出:
   - IOPS (read/write)
   - BW (KiB/s or MiB/s)
   - Avg Latency (ms)
   - p99 Latency (ms)

2. Python スクリプトで JSON をパース:
   ```sh
   # tmp/<session-id>/extract-fio.py を作成して実行
   python3 tmp/<session-id>/extract-fio.py tmp/<session-id>/fio-results/
   ```

   fio JSON の構造:
   ```
   jobs[0].read.iops, jobs[0].read.bw (KiB/s), jobs[0].read.clat_ns.mean (ns), jobs[0].read.clat_ns.percentile["99.000000"] (ns)
   jobs[0].write.iops, jobs[0].write.bw (KiB/s), jobs[0].write.clat_ns.mean (ns), jobs[0].write.clat_ns.percentile["99.000000"] (ns)
   ```

3. `report/` にレポート生成 (REPORT.md フォーマット準拠):
   - 環境情報 (ハードウェア、ソフトウェア、DRBD 構成)
   - ストレージ構成 (thin or thick-stripe)
   - ベンチマーク結果テーブル (IOPS, スループット, レイテンシ)
   - 分析 (ボトルネック、前回結果との比較 (あれば))
   - 再現方法

---

## oplog

状態変更操作は `./oplog.sh` で記録する:

- Phase 1 (クリーンアップ): VM 削除、LINSTOR リソース削除、LVM 解体
- Phase 2 (ストレージ構成): VG 作成、ストレージプール作成
- Phase 3 (VM 作成): qm create, qm importdisk, qm start

読み取り専用操作 (linstor storage-pool list, drbdadm status, fio 実行) は oplog 不要。

## pve-lock の使い方

Phase 1〜3 では状態変更操作に `./pve-lock.sh` を使用する:

```sh
./pve-lock.sh run <command...>     # 即座に実行（ロック中ならエラー）
./pve-lock.sh wait <command...>    # ロック待ち→実行
```

ロック中の場合は別の課題に着手し、ロック解放後に再開する。
