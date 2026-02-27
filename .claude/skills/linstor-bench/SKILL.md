---
name: linstor-bench
description: "LINSTOR/DRBD ストレージベンチマーク。VM上でfioを実行し、thin/thick-stripe構成の性能を計測する。"
disable-model-invocation: true
argument-hint: "<storage_type: thin|thick-stripe>"
---

# LINSTOR ベンチマークスキル

LINSTOR/DRBD ストレージ上に VM を作成し、fio でベンチマークを実行する。
引数 `storage_type` で `thin` (LVM thin pool) または `thick-stripe` (LVM 4本ストライプ) を選択する。
両方を比較する場合は2回呼ぶ。

## 事前準備

1. LINSTOR/DRBD が両ノードにインストール済み (linstor-controller, linstor-satellite, drbd-dkms, drbd-utils, linstor-proxmox)
2. PVE クラスタが構築済み (`pvecm status` で Quorate)
3. LINSTOR ノードが登録済み (`linstor node list` で両ノード Online)
4. IB インターフェース (ib0) が登録済み + PrefNic=ib0 設定済み
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

# ノード情報
NODE1=$("$YQ" '.nodes[0].name' "$CONFIG")
NODE1_IP=$("$YQ" '.nodes[0].ip' "$CONFIG")
NODE2=$("$YQ" '.nodes[1].name' "$CONFIG")
NODE2_IP=$("$YQ" '.nodes[1].ip' "$CONFIG")
DISKS=$("$YQ" '.nodes[0].storage_disks[]' "$CONFIG")

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
| F4 | VM MAC アドレス不一致で IP 検出失敗 | Phase 4 | IP 検出タイムアウト | `qm config` から MAC を動的取得 |
| F5 | Thick LVM で DRBD 全領域同期 | Phase 4 | `peer-disk:Inconsistent` が長時間 | ポーリングで待機 (thin は ~30秒) |
| F6 | `linstor --output-format json` 不存在 | Phase 4 | `unrecognized arguments` エラー | `linstor -m resource list` を使う |
| F7 | citype デフォルト (configdrive2) が Debian に非対応 | Phase 3 | cloud-init 設定が VM に反映されない | `--citype nocloud` を初回起動前に設定 |
| F8 | LINSTOR Auto-eviction がノードオフライン時にリソースを自動退去 | Phase 4-5 | `linstor node list` で "Auto-eviction at ..." 表示 | テスト前に無効化 |

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

VM の MAC アドレスはハードコードせず、`qm config` から動的に取得する。

```sh
# qm config から MAC を取得
MAC=$(ssh root@$NODE1_IP "qm config $VM_ID" | grep '^net0' | grep -o 'virtio=[0-9A-Fa-f:]*' | cut -d= -f2)
# PVE ホストで ARP テーブルから IP を検出
ssh root@$NODE1_IP "nmap -sn 192.168.39.0/24 >/dev/null 2>&1; ip neigh | grep -i '$MAC' | awk '{print \$1}'"
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

> **注意**: cloud-init は初回起動時のみ実行される。すべての設定 (cicustom, citype, ciuser, cipassword, ipconfig0) を `qm start` 前に完了すること。

1. **VM 作成**:
   ```sh
   ssh root@$NODE1_IP "qm create $VM_ID --name $VM_NAME --memory $VM_MEMORY --cores $VM_CORES --cpu host --net0 virtio,bridge=$VM_BRIDGE --ostype l26 --scsihw virtio-scsi-single"
   ```

2. **ディスクインポート** (★ F2 対策: リソース名をパース):
   ```sh
   IMPORT_OUTPUT=$(ssh root@$NODE1_IP "qm importdisk $VM_ID $CLOUD_IMAGE linstor-storage" 2>&1)
   RESOURCE_NAME=$(echo "$IMPORT_OUTPUT" | grep -o 'pm-[0-9]*')
   ```
   - `RESOURCE_NAME` が空の場合は出力全体を確認しエラー対処

3. **ディスク接続** (パースしたリソース名を使用):
   ```sh
   ssh root@$NODE1_IP "qm set $VM_ID --scsi0 linstor-storage:${RESOURCE_NAME},discard=on,iothread=1"
   ```

4. **ブート順序 + cloudinit ドライブ**:
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

7. **cloud-init ユーザ・ネットワーク設定**:
   ```sh
   ssh root@$NODE1_IP "qm set $VM_ID --ciuser $VM_USER --cipassword $VM_PASS --ipconfig0 ip=dhcp"
   ```

8. **ディスクリサイズ**:
   ```sh
   ssh root@$NODE1_IP "qm resize $VM_ID scsi0 $VM_DISK_SIZE"
   ```

9. **VM 起動** (★ すべて設定完了後):
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

ポーリング間隔: 30秒 (`drbdadm status`)

```sh
# 同期状態のポーリング (30秒間隔)
ssh root@$NODE1_IP "drbdadm status"
# 出力例 (同期中): peer-disk:Inconsistent
# 出力例 (完了): peer-disk:UpToDate
```

UpToDate/UpToDate になるまでポーリングで待機する。

#### VM IP 検出 (★ F4)

1. `qm config` から MAC アドレスを動的取得:
   ```sh
   MAC=$(ssh root@$NODE1_IP "qm config $VM_ID" | grep '^net0' | grep -o 'virtio=[0-9A-Fa-f:]*' | cut -d= -f2)
   ```

2. PVE ホストで nmap + ARP テーブルから MAC→IP 変換:
   ```sh
   ssh root@$NODE1_IP "nmap -sn 192.168.39.0/24 >/dev/null 2>&1"
   VM_IP=$(ssh root@$NODE1_IP "ip neigh | grep -i '$MAC' | awk '{print \$1}'")
   ```

3. IP が取得できない場合は 30 秒待機して再試行 (最大 5 分)

#### SSH 接続テスト

```sh
sshpass -p "$VM_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 ${VM_USER}@${VM_IP} 'uname -a'
```

#### fio インストール

```sh
sshpass -p "$VM_PASS" ssh ${VM_USER}@${VM_IP} 'sudo apt-get update && sudo apt-get install -y fio'
```

> **注意 (F6)**: LINSTOR の JSON 出力は `linstor --output-format json` ではなく `linstor -m` (machine-readable) を使う。
> `--output-format` オプションは存在しない。

---

### Phase 5: ベンチマーク実行

**pve-lock**: 不要

7テストを順番に実行する。各テスト結果は JSON で `tmp/<session-id>/fio-results/` に保存する。

```sh
mkdir -p tmp/<session-id>/fio-results
```

各テストの実行:
```sh
sshpass -p "$VM_PASS" ssh ${VM_USER}@${VM_IP} "sudo fio \
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
