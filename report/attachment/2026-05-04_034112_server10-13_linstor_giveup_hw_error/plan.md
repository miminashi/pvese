# 10-13号機 LINSTOR セットアップ + ベンチマーク

## Context

10-13号機 (Supermicro X10DRT-P / Nutanix OEM) にデータ HDD (Seagate DKS5H-J1R2SS 1.2 TB × 2) を装着完了。OS と PVE は既に各ノードでスタンドアロン稼働している。これを使って 4 ノードの PVE クラスタ + LINSTOR クラスタを構築し、fio ベンチマークが完走することを確認する。

4-9号機との連携は将来計画。今回は **10-13号機だけで独立した PVE クラスタ + 独立した LINSTOR クラスタ** (controller も10号機内蔵) を組む。

### 主要前提と判断

| 項目 | 判断 | 理由 |
|------|------|------|
| データ HDD 対応 | **先に 12/13 を sg_format → 4 ノード全員参加** | ユーザ指示 |
| ストレージ | **ZFS** | Region A/B での実績 (raidz1 + LINSTOR ZFS プロバイダ) |
| ZFS トポロジ | **stripe (RAID0)** | sdb+sdc の 2 ディスクのみ。raidz1 は最低 3 必要。冗長化は DRBD で行う |
| PVE クラスタ | **新規クラスタ作成 (10号機 init, 11-13 join)** | ユーザ指示。4-9 とは別物 |
| place_count | **2** | ユーザ指示。Region A/B と同じ |
| DRBD transport | **TCP over Ethernet (10.10.10.0/8 vmbr0)** | 10-13 は IB 接続なし (別拠点) |
| LINSTOR controller | **10号機 (Combined: controller+satellite)** | クラスタ内蔵。4号機 controller には依存しない |
| ベンチマーク | linstor-bench スキルの **Phase 0 / 3-6 を流用**、Phase 1-2 は ZFS 用に手動 | スキルは thin/thick-stripe のみ対応で ZFS 不可 |

### 既知の衝突点 (要対応)

- `config/linstor.yml` の `benchmark.vm_mgmt_ip = 10.10.10.210` は **10号機本体の IP と衝突** する。bench VM を 10号機に立てるため必ず変更する (案: `10.10.10.250`)。

## 全体フロー

```
Phase 0 (BG): 12/13号機 sg_format ──┐
Phase 1: PVE クラスタ構築           ├ 並行可
Phase 2: LINSTOR + ZFS インストール ┘
                  ↓ (Phase 0 完了待ち)
Phase 3: ZFS pool 作成 (4ノード)
Phase 4: LINSTOR 登録 + storage-pool + RG + PVE storage
Phase 5: fio ベンチマーク (linstor-bench Phase 0,3-6 を流用)
Phase 6: レポート作成
```

---

## Phase 0: 12/13号機 sg_format (バックグラウンド)

12/13号機の sdb/sdc は Nutanix T10-PI 520B フォーマットで Linux からは 0B に見え利用不可。`sg_format` で 512B に再フォーマット (1.2 TB / 数時間/ディスク)。

参考: `memory/server10-13_data_disks.md`

```sh
ssh -F ssh/config root@10.10.10.212 "apt-get install -y sg3-utils"
ssh -F ssh/config root@10.10.10.213 "apt-get install -y sg3-utils"

# 各ノードで sdb, sdc を並列実行 (run_in_background=true)
ssh -F ssh/config root@10.10.10.212 "sg_format --format --size=512 /dev/sdb"
ssh -F ssh/config root@10.10.10.212 "sg_format --format --size=512 /dev/sdc"
ssh -F ssh/config root@10.10.10.213 "sg_format --format --size=512 /dev/sdb"
ssh -F ssh/config root@10.10.10.213 "sg_format --format --size=512 /dev/sdc"
```

完了確認: `lsblk -d -b /dev/sdb /dev/sdc` でサイズが 1.2 TB 程度と認識されること。

> 待機中に Phase 1, 2 を並行で進める。

---

## Phase 1: PVE クラスタ構築

`pve-lock.sh run` で排他制御を取りながら実行。

```sh
# 10号機: cluster init
./pve-lock.sh run ssh -F ssh/config root@10.10.10.210 \
  "pvecm create pvese-cluster-c --link0 10.10.10.210"

# 11/12/13号機: join (1 台ずつ順次)
./pve-lock.sh run ssh -F ssh/config root@10.10.10.211 \
  "pvecm add 10.10.10.210 --link0 10.10.10.211 --use_ssh"
./pve-lock.sh run ssh -F ssh/config root@10.10.10.212 \
  "pvecm add 10.10.10.210 --link0 10.10.10.212 --use_ssh"
./pve-lock.sh run ssh -F ssh/config root@10.10.10.213 \
  "pvecm add 10.10.10.210 --link0 10.10.10.213 --use_ssh"
```

検証: `pvecm status` で 4 ノード Quorate (expected = 4, total = 4)

参考: `report/2026-04-04_032859_phase5_pve_setup.md`

---

## Phase 2: LINSTOR + ZFS パッケージインストール

LINBIT リポジトリ追加とパッケージインストール (4 ノード共通)。詳細手順は過去レポートを踏襲:
- `report/2026-03-07_210011_linstor_4node_multiregion.md`
- `report/2026-04-04_034704_phase6_7_8_ipoib_pve_linstor.md`

```sh
# 各ノード共通パッケージ:
#   drbd-dkms drbd-utils linstor-satellite linstor-client linstor-proxmox zfsutils-linux
# 10号機のみ追加:
#   linstor-controller
```

ZFS ARC を 4 GiB に制限 (各ノード):

```sh
echo 'options zfs zfs_arc_max=4294967296' > /etc/modprobe.d/zfs-arc.conf
echo 4294967296 > /sys/module/zfs/parameters/zfs_arc_max
```

ZFS インストール後に linstor-satellite を再起動 (ZFS プロバイダ認識のため):

```sh
systemctl restart linstor-satellite
```

10号機で linstor-controller を起動:

```sh
systemctl enable --now linstor-controller
```

---

## Phase 3: ZFS pool 作成 (sg_format 完了後)

各ノード sdb + sdc の 2 ディスク stripe。**Phase 0 で 12/13 の sg_format が完了していること**を確認してから実行。

```sh
# 各ノード共通
ssh -F ssh/config root@10.10.10.21X \
  "zpool create linstor_zpool sdb sdc && \
   zfs set compression=off linstor_zpool && \
   zfs set atime=off linstor_zpool"
```

`pve-lock.sh run` で排他。

検証: `zpool status linstor_zpool` で ONLINE。容量は 2.4 TiB 程度。

---

## Phase 4: LINSTOR セットアップ

10号機 (controller) 上で全コマンドを実行。

### 4.1 ノード登録

```sh
linstor node create ayase-web-service-10 10.10.10.210 --node-type Combined
linstor node create ayase-web-service-11 10.10.10.211 --node-type Satellite
linstor node create ayase-web-service-12 10.10.10.212 --node-type Satellite
linstor node create ayase-web-service-13 10.10.10.213 --node-type Satellite
```

検証: `linstor node list` で全ノード Online

### 4.2 ZFS storage-pool

```sh
for n in 10 11 12 13; do
  linstor storage-pool create zfs ayase-web-service-${n} zfs-pool linstor_zpool
done
```

> ループは Bash パーミッションで弾かれるため、実装時は `tmp/<sid>/sp-create.sh` に書いて実行。

検証: `linstor storage-pool list`

### 4.3 リソースグループ + DRBD オプション

```sh
linstor resource-group create pve-rg-c --place-count 2 --storage-pool zfs-pool
linstor volume-group create pve-rg-c
linstor resource-group drbd-options --protocol C pve-rg-c
linstor resource-group drbd-options --quorum off pve-rg-c
linstor resource-group drbd-options --auto-promote yes pve-rg-c
linstor resource-group set-property pve-rg-c Linstor/Drbd/auto-block-size 512
```

`auto-block-size 512` は OS HDD と DATA HDD のセクタサイズ差に対する安全策 (linstor-node-ops スキル N6 参照)。

### 4.4 Auto-eviction 無効化 (テスト中の事故防止)

```sh
for n in 10 11 12 13; do
  linstor node set-property ayase-web-service-${n} DrbdOptions/AutoEvictAllowEviction false
done
```

### 4.5 PVE ストレージ追加

```sh
ssh -F ssh/config root@10.10.10.210 \
  "pvesm add drbd linstor-storage-c --resourcegroup pve-rg-c --content images,rootdir --controller 10.10.10.210"
```

検証: `pvesm status` で `linstor-storage-c` が active

---

## Phase 5: fio ベンチマーク

linstor-bench スキル (`.claude/skills/linstor-bench/SKILL.md`) の **Phase 0 と Phase 3-6 を流用**。Phase 1-2 は本計画で対応済みなのでスキップ。

### 5.0 設定変更

`config/linstor.yml` の以下を変更 (実装時の最初):

```yaml
benchmark:
  vm_mgmt_ip: 10.10.10.250   # 10号機 (10.10.10.210) との衝突回避
```

### 5.1 Phase 0 (preflight): SMART チェック

`scripts/linstor-bench-preflight.sh` を 4 ノード全部で `/dev/sdb /dev/sdc` に対して実行。

### 5.2 Phase 3-6: VM 作成 → fio → レポート

linstor-bench SKILL.md の Phase 3-6 を流用。読み替え点:

| 項目 | 値 |
|------|-----|
| NODE1 | ayase-web-service-10 (10.10.10.210) |
| NODE2 | ayase-web-service-11 (10.10.10.211) (place_count=2 で自動配置) |
| controller IP | 10.10.10.210 |
| pve_storage 名 | `linstor-storage-c` |
| resource group | `pve-rg-c` |
| VM_MGMT_IP | 10.10.10.250 (上記で変更) |

注意点 (SKILL.md の F1-F19):
- F2: importdisk 出力からリソース名 (`pm-XXXX`) をパース
- F3, F7, F17: vendor snippet + nocloud + Ed25519 鍵
- F11: DRBD 同期確認は `drbdsetup status --verbose`
- F18: DRBD 同期完了後に `qm resize`

DRBD 同期待機: `scripts/linstor-drbd-sync-wait.sh <resource_name>` を流用 (config 引数を渡せる)。

7 種の fio テスト (randread/write 4k qd1/qd32, seqread/write 1m qd32, mixed) を VM 内で実行。結果は `tmp/<sid>/fio-results/` に JSON 保存。

---

## Phase 6: レポート作成

`REPORT.md` フォーマットに従い `report/<timestamp>_server10-13_linstor_setup_bench.md` を作成。内容:

- 環境情報 (HW, SW バージョン)
- 構築手順 (ZFS stripe、4 ノードクラスタ、独立 controller)
- ベンチマーク結果 (7 テスト × IOPS/BW/レイテンシ)
- Region B (raidz1) との比較分析
- 発生した問題と対処

---

## Phase 7: シャットダウン (完了時 / ギブアップ時 共通)

ユーザ指示: **完了したらシャットダウン。途中でギブアップした場合もシャットダウン**。

10-13号機 4 台を OS シャットダウン。終了時/ギブアップ時の両方で必ず実行する。

```sh
# OS shutdown (各ノード並列)
for ip in 10.10.10.210 10.10.10.211 10.10.10.212 10.10.10.213; do
  ssh -F ssh/config root@${ip} "shutdown -h now" || true
done
```

> ループは Bash パーミッションで弾かれるため、実装時は `tmp/<sid>/shutdown.sh` に書いて `sh tmp/<sid>/shutdown.sh` で実行する。

OS シャットダウン後、BMC 経由で電源状態確認:

```sh
./scripts/bmc-power.sh status   # 各 BMC に対して
```

OS shutdown が応答しない場合のみ IPMI Power Off にフォールバック (最後の手段):

```sh
./oplog.sh ./pve-lock.sh run ./scripts/bmc-power.sh off
```

ベンチマーク VM (`bench-vm` VM ID 100) は Phase 5 終了時点で `qm stop 100` 済み (ベンチマーク完了後)。LINSTOR リソースは保持したままシャットダウンしてよい (次回起動時に DRBD が再接続する)。

---

### ギブアップ判断基準

以下のいずれかでギブアップ判定し、Phase 7 に進む:

- sg_format が **6時間** 以上完了しない
- PVE クラスタ join が再試行を含めて **3回失敗**
- LINSTOR satellite 接続が **3回試行しても全ノード Online にならない**
- DRBD 同期が **2時間** 以上 UpToDate にならない
- fio ベンチマークが **3 テスト連続失敗**
- ユーザが明示的に中断指示

ギブアップ時は現状を簡潔にレポート (`report/<timestamp>_server10-13_linstor_setup_giveup.md`) にまとめてから Phase 7 を実行。

---

## 検証 (完了条件)

| 項目 | 確認コマンド | 期待値 |
|------|-------------|--------|
| PVE クラスタ | `pvecm status` | Quorate, 4/4 nodes |
| LINSTOR ノード | `linstor node list` | 4 ノード Online |
| ZFS pool | `zpool list linstor_zpool` (各ノード) | ONLINE, ~2.4 TiB |
| storage-pool | `linstor storage-pool list` | 4 ノードに `zfs-pool` |
| PVE storage | `pvesm status` | `linstor-storage-c` active |
| bench VM | `qm status 100` | running |
| DRBD 同期 | `drbdsetup status --verbose` | UpToDate × 2 |
| fio | 7 テストの JSON が揃う | `tmp/<sid>/fio-results/*.json` × 7 |

---

## 修正対象ファイル

- `config/linstor.yml` — `benchmark.vm_mgmt_ip` を `10.10.10.250` に変更 (Phase 5.0)

新規作成は無し。10-13号機専用の `config/linstor-c.yml` 等は今回作らず、4-9 統合時に既存の linstor.yml を拡張する方針。

## 再利用する既存リソース

- `scripts/linstor-bench-preflight.sh` — SMART ヘルスチェック
- `scripts/linstor-drbd-sync-wait.sh` — DRBD 同期待機
- `.claude/skills/linstor-bench/SKILL.md` — Phase 3-6 の VM 作成・fio 実行手順
- `pve-lock.sh` / `oplog.sh` — 排他制御 + ログ記録
- `ssh/config` — pve10-13 のエイリアス (要確認、未定義なら追加)

## 参考レポート

- `report/2026-03-07_210011_linstor_4node_multiregion.md` — 4ノード初期構築
- `report/2026-03-30_025702_linstor_zfs_raidz1_benchmark.md` — ZFS + LINSTOR ZFS プロバイダ
- `report/2026-04-04_032859_phase5_pve_setup.md` — PVE クラスタ作成手順
- `report/2026-04-04_034704_phase6_7_8_ipoib_pve_linstor.md` — LINSTOR インストール手順
- `report/2026-05-03_224709_server10-13_storage_inventory.md` — ストレージ現状

## リスク・留意点

1. **sg_format の所要時間**: 12/13号機 sdb/sdc の 4 ディスクで数時間。Phase 0 を最初に並列起動して待機中に Phase 1-2 を進める
2. **ssh エイリアス未定義**: ssh/config に pve10-pve13 のエイリアスが無い場合は追加 (ssh/setup.sh または直接編集)
3. **bench VM の IP 衝突**: vm_mgmt_ip 変更を忘れると VM 起動と同時に 10号機本体と衝突
4. **linstor-bench スキルは ZFS 非対応**: Phase 1-2 (LVM/thin/thick-stripe) は skip。Phase 3-6 のみ実行
5. **既存 LINSTOR (4-9 controller=4号機) との混同**: 10号機に独立 controller を立てるため、各ノードの `/etc/linstor/linstor-client.conf` および satellite 接続先は 10.10.10.210 を指す。`linstor` コマンドを 4-9 controller に向けないよう注意
