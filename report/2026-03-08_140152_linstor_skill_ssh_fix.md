# LINSTOR SKILL.md SSH/ネットワーク修正レポート

- **実施日時**: 2026年3月8日 14:01 JST
- **関連Issue**: #33
- **前回レポート**: [linstor_skill_improvement](2026-03-08_083123_linstor_skill_improvement.md), [linstor_4node_multiregion](2026-03-07_210011_linstor_4node_multiregion.md)

## 前提・目的

LINSTOR スキルファイル (linstor-bench, linstor-node-ops) の SSH/ネットワーク関連の問題を修正し、3回のテストイテレーションで動作を検証する。

### 修正対象の問題

1. **VM SSH が 192.168.39.0/24 (DHCP) 経由** — DHCP アドレスは OS 再インストールで変動するため不安定。10.0.0.0/8 (static) 経由にすべき
2. **DHCP 遅延時に 192.168.39.0/24 で静的 IP を割り当て** — DHCP 衝突の危険。デュアル NIC で管理用を分離すべき
3. **IB IP のリテラルプレースホルダ** (`192.168.100.x`) — config から変数で読み取るべき
4. **sshpass 残存** — Ed25519 公開鍵認証に統一

### 解決方針

VM にデュアル NIC を構成し、SSH は 10.x 経由で直接接続:
- net0: vmbr1 (192.168.39.0/24, DHCP, インターネット用)
- net1: vmbr0 (10.0.0.0/8, static 10.10.10.210, SSH 管理用)

## 環境情報

| 項目 | 値 |
|------|-----|
| Region B ノード | 6号機 (10.10.10.206) + 7号機 (10.10.10.207) |
| LINSTOR コントローラ | 4号機 (10.10.10.204) |
| VM ID | 200 (bench-vm-b) |
| VM スペック | 4 vCPU, 4GB RAM, 32GB disk (LINSTOR thin) |
| VM OS | Debian cloud image (cloud-init) |
| VM 管理 IP | 10.10.10.210/8 (net1, vmbr0) |
| VM インターネット | DHCP (net0, vmbr1, 192.168.39.0/24) |
| DRBD | place-count=2 (6号機 + 7号機) |
| OS | Debian 13.3 + Proxmox VE 9.1.6 |

## 修正内容

### 1. config/linstor.yml

`benchmark:` セクションに管理用 NIC 設定を追加:
```yaml
vm_mgmt_bridge: vmbr0
vm_mgmt_ip: 10.10.10.210
vm_mgmt_prefix: 8
```

### 2. linstor-bench/SKILL.md

| 項目 | 修正前 | 修正後 |
|------|--------|--------|
| VM NIC | net0 のみ (vmbr1) | net0 (vmbr1) + net1 (vmbr0) |
| cloud-init | `--ipconfig0 ip=dhcp` | `--ipconfig0 ip=dhcp --ipconfig1 ip=$VM_MGMT_IP/$VM_MGMT_PREFIX` |
| SSH 接続先 | MAC検出 + nmap → 192.168.39.x | `$VM_MGMT_IP` (10.10.10.210) 直接 |
| SSH 認証 | sshpass (コメント行) | Ed25519 公開鍵 (ローカルマシンの鍵) |
| SSH 鍵設定 | PVE ホストの `/root/.ssh/id_ed25519.pub` | ローカルの `~/.ssh/id_ed25519.pub` を scp → `qm set --sshkeys` |
| ディスクリサイズ | Phase 3 (VM 作成時) | Phase 4 (DRBD sync 完了後) |
| ブリッジ検証 | なし | Phase 3 Step 0 で `ip -4 addr show vmbr0/vmbr1` |
| F2 grep | `grep -o 'pm-[a-z0-9_]*'` | `grep "successfully imported" \| grep -o "pm-[a-z0-9_]*"` |
| F4 (MAC検出) | 必須 | 「管理IP がconfig 設定済みの場合は不要」注記追加 |
| F12 (sshpass) | sshpass 使用 | 「公開鍵認証のため不要」に変更 |
| F15 (DHCP遅延) | 静的IP フォールバック | DHCP 最大5分待機 + 管理SSH は 10.x で DHCP 待ち不要 |

### 3. linstor-node-ops/SKILL.md

| 項目 | 修正前 | 修正後 |
|------|--------|--------|
| IB IP | `192.168.100.x` リテラル | `$TARGET_IB_IP` (config から読み取り) |
| fail step 5 | `sshpass -p "$VM_PASS" ssh $VM_USER@$VM_IP` | `ssh ${VM_USER}@${VM_MGMT_IP}` |

### 4. memory/linstor.md

デュアル NIC ルール、10.x SSH、DHCP 待機ルールを追記。

## テストイテレーション結果

### イテレーション 1

| ステップ | 結果 | 備考 |
|---------|------|------|
| VM 作成 | 修正要 | F2 grep バグ (pm-xxx と pm-xxx_200 の2行マッチ) |
| SSH 接続 | 修正要 | PVE ホスト鍵 → ローカルマシン鍵に変更が必要 |
| ディスクリサイズ | 修正要 | DRBD sync 前の resize 失敗 (F18) |
| VM 再作成 | 成功 | 上記3修正後に VM 破棄→再作成 |
| fio 7テスト | 全完了 | 10.x SSH 経由で正常動作 |
| server7 fail | 成功 | 電源断、auto-eviction キャンセル |
| server7 recover | 成功 | DRBD resync 完了 |

**発見・修正した問題:**
1. **F2 grep パターン**: `qm importdisk` の出力に `pm-xxx` (LINSTOR リソース名) と `pm-xxx_200` (PVE ボリューム名) の2行が含まれ、`grep -o 'pm-[a-z0-9_]*'` が両方マッチ → `grep "successfully imported"` で行を絞り込む修正を追加
2. **SSH 公開鍵の指定元**: SKILL.md は PVE ホストの `/root/.ssh/id_ed25519.pub` を参照していたが、SSH はローカルマシンから接続するため `~/.ssh/id_ed25519.pub` を scp で PVE ホストに転送して使用する手順に変更
3. **F18 リサイズタイミング**: `qm resize` を VM 作成直後に実行すると DRBD sync が完了していないため失敗。Phase 4 (DRBD sync 完了後) に移動

### イテレーション 2

| ステップ | 結果 |
|---------|------|
| VM 作成 | 成功 (1回で完了) |
| SSH 接続 (10.x) | 成功 |
| DRBD sync + resize | 成功 |
| cloud-init 待機 | 成功 |
| fio 7テスト | 全完了 |
| server7 fail | 成功 |
| server7 recover | 成功 |

問題なし。修正が正しく機能。

### イテレーション 3

| ステップ | 結果 |
|---------|------|
| VM 作成 | 成功 (1回で完了) |
| SSH 接続 (10.x) | 成功 |
| DRBD sync + resize | 成功 |
| cloud-init 待機 | 成功 |
| fio 7テスト | 全完了 |
| server7 fail | 成功 |
| server7 recover | 成功 (SSH 復帰: ~240秒) |

問題なし。3回連続で安定動作を確認。

## fio 性能結果 (イテレーション 2 vs 3)

| テスト | Iter 2 IOPS | Iter 3 IOPS | 差異 |
|--------|------------|------------|------|
| randread-4k-qd1 | 161 | 162 | +0.6% |
| randread-4k-qd32 | 1,255 | 1,261 | +0.5% |
| randwrite-4k-qd1 | 707 | 655 | -7.4% |
| randwrite-4k-qd32 | 634 | 607 | -4.3% |
| seqread-1m-qd32 | 221 (221 MB/s) | 209 (209 MB/s) | -5.4% |
| seqwrite-1m-qd32 | 112 (112 MB/s) | 112 (112 MB/s) | +0.0% |
| mixed-rw-4k-qd32 | R:603 / W:258 | R:606 / W:259 | +0.5% / +0.5% |

性能は安定しており、イテレーション間の差異は通常の変動範囲内 (< 10%)。

## 成功基準の達成状況

| 基準 | 結果 |
|------|------|
| VM 作成が1回で成功 | Iter 2, 3: 達成。Iter 1: 3バグ修正後に達成 |
| SSH が 10.x (vmbr0) 経由で直接接続 | 全3回達成 |
| 192.168.39.x への直接 SSH がゼロ | 達成 |
| 192.168.39.x への静的 IP 割り当てがゼロ | 達成 |
| DHCP 5分以内に完了 | 達成 (cloud-init status --wait で確認) |
| fio 全7テスト完了 | 全3回達成 |
| fail/recover が手順通り完了 | 全3回達成 |

## 再現方法

### VM 作成 (デュアル NIC)

```sh
NODE1_IP=10.10.10.206
VM_ID=200
VM_NAME=bench-vm-b

# ローカルの Ed25519 公開鍵を PVE ホストに転送
scp ~/.ssh/id_ed25519.pub root@$NODE1_IP:/tmp/local_ed25519.pub

# VM 作成 (デュアル NIC: net0=vmbr1 DHCP, net1=vmbr0 static 10.x)
ssh root@$NODE1_IP "qm create $VM_ID --name $VM_NAME --memory 4096 --cores 4 --cpu host \
  --net0 virtio,bridge=vmbr1 --net1 virtio,bridge=vmbr0 \
  --ostype l26 --scsihw virtio-scsi-single"

# ディスクインポート
ssh root@$NODE1_IP "qm importdisk $VM_ID /var/lib/vz/template/debian-cloud.qcow2 linstor-storage"
# grep "successfully imported" で LINSTOR リソース名を取得
ssh root@$NODE1_IP "qm set $VM_ID --scsi0 linstor-storage:<resource>,discard=on,iothread=1"
ssh root@$NODE1_IP "qm set $VM_ID --boot order=scsi0"
ssh root@$NODE1_IP "qm set $VM_ID --ide2 linstor-storage:cloudinit"
ssh root@$NODE1_IP "qm set $VM_ID --citype nocloud"
ssh root@$NODE1_IP "qm set $VM_ID --sshkeys /tmp/local_ed25519.pub"
ssh root@$NODE1_IP "qm set $VM_ID --ciuser debian --cipassword password \
  --ipconfig0 ip=dhcp --ipconfig1 ip=10.10.10.210/8"

# VM 起動 (resize は DRBD sync 完了後に行う)
ssh root@$NODE1_IP "qm start $VM_ID"

# DRBD sync 完了を待機
ssh root@$NODE1_IP "drbdsetup status --verbose"
# peer-disk:UpToDate を確認後にリサイズ
ssh root@$NODE1_IP "qm resize $VM_ID scsi0 32G"
```

### SSH 接続 + fio

```sh
# 10.x 管理 IP に直接 SSH (公開鍵認証)
ssh debian@10.10.10.210 'cloud-init status --wait'
ssh debian@10.10.10.210 'sudo apt-get update && sudo apt-get install -y fio'
ssh debian@10.10.10.210 'sudo fio --name=randread-4k-qd1 --ioengine=libaio --direct=1 ...'
```

## 修正したファイル

| ファイル | 変更内容 |
|---------|---------|
| `config/linstor.yml` | benchmark に vm_mgmt_bridge/ip/prefix 追加 |
| `.claude/skills/linstor-bench/SKILL.md` | デュアル NIC、10.x SSH、F2/F4/F12/F15/F18 修正 |
| `.claude/skills/linstor-node-ops/SKILL.md` | IB IP 変数化、sshpass → 公開鍵 SSH |
| `memory/linstor.md` | VM SSH/NIC ルール追記 |
