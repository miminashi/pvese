# LINSTOR/DRBD ノード離脱 — 運用継続実験レポート

- **実施日時**: 2026年2月27日 00:00〜00:53 (Phase 1〜4), Phase 0 は 2月26日 23:02〜00:35

## 前提・目的

LINSTOR/DRBD 2ノードクラスタから1ノードを離脱させた際に、残り1ノードで運用継続できるかを検証する。

- **背景**: 2ノード DRBD クラスタの耐障害性と運用柔軟性を評価する必要がある
- **目的**: 障害シミュレーション (電源断) と正常離脱 (linstor node delete) の2パターンで運用継続性を検証
- **前提条件**: quorum=off, auto-promote=yes, PVE two_node=1 の構成で、理論上は1ノード運用が可能

### 参考レポート

- [LINSTOR/DRBD ベンチマーク (thick-stripe)](report/2026-02-26_130844_linstor_thin_vs_thick_stripe_benchmark.md)

## 環境情報

### ハードウェア

| 項目 | 4号機 (ayase-web-service-4) | 5号機 (ayase-web-service-5) |
|------|---------------------------|---------------------------|
| マザーボード | Supermicro X11DPU | Supermicro X11DPU |
| BMC IP | 10.10.10.24 | 10.10.10.25 |
| 静的 IP | 10.10.10.204 | 10.10.10.205 |
| ストレージ | 4x SATA SSD (~466 GiB each) | 同左 |

### ソフトウェア

| 項目 | 値 |
|------|-----|
| OS | Debian 13.3 (Trixie) + Proxmox VE 9.1.6 |
| カーネル | 6.17.9-1-pve |
| DRBD | Protocol C, quorum=off, auto-promote=yes |
| LINSTOR コントローラ | 4号機 (COMBINED) |
| LINSTOR サテライト | 5号機 (SATELLITE) |

### LINSTOR/DRBD 構成

| 項目 | 値 |
|------|-----|
| ストレージプール | striped-pool (LVM thick, -i4 -I64) |
| 総容量 | ~1.82 TiB / ノード |
| PVE クラスタ | pvese-cluster (two_node: 1) |
| リソースグループ | pve-rg (place-count: 2) |
| リソース | pm-23282c6c (VM ディスク 550G), vm-100-cloudinit |

### テスト対象 VM

| 項目 | 値 |
|------|-----|
| VM ID | 100 (bench-vm) |
| ディスク | 550G (scsi0, DRBD 経由) |
| メモリ | 4 GiB |
| OS | Debian (cloud-init) |
| ネットワーク | vmbr1 (192.168.39.112, DHCP) |

## Phase 0: ストレージ 30% 充填

### 実施内容

1. VM ディスクを 32G → 550G にリサイズ (`qm resize 100 scsi0 550G`)
2. DRBD フル同期を待機 (~518 GiB)
3. VM 内でファイルシステム拡張 + 10 GiB 検証データ作成

### DRBD 同期性能

| 項目 | 値 |
|------|-----|
| 同期データ量 | ~518 GiB |
| 所要時間 | 92分 (23:03 → 00:35) |
| 平均同期レート | ~96 MiB/s |

### Phase 0 完了時のストレージ状態

**PVE ストレージ**:

| Name | Type | Status | Total | Used | Available | % |
|------|------|--------|-------|------|-----------|---|
| linstor-storage | drbd | active | 1,953,529,856 KiB | 576,864,256 KiB | 1,376,665,600 KiB | 29.53% |

**物理ディスク使用状況 (両ノード同一)**:

| PV | PSize | PFree | Used | PE | Alloc |
|----|-------|-------|------|----|-------|
| /dev/sda | 465.76g | 328.22g | 137.54g | 119234 | 35209 |
| /dev/sdb | 465.76g | 328.22g | 137.54g | 119234 | 35209 |
| /dev/sdc | 465.76g | 328.22g | 137.54g | 119234 | 35209 |
| /dev/sdd | 465.76g | 328.22g | 137.54g | 119234 | 35209 |

**検証データ**:
- ファイル: `/home/debian/verify-10g.bin` (10 GiB, urandom)
- MD5: `f7cf7d8470ca057a8c1184ec55fb7d8f`

## Phase 1: テスト A — 障害シミュレーション (5号機電源断)

### 実施手順

1. 事前状態を記録 (DRBD: UpToDate/UpToDate, VM: running, checksums: OK)
2. IPMI で5号機を電源オフ: `ipmitool ... chassis power off`
3. 30秒待機後、確認項目を実行

### 結果

| # | 確認項目 | コマンド | 期待結果 | 実測結果 | 判定 |
|---|---------|---------|---------|---------|------|
| A1 | DRBD 状態 | `drbdadm status` | peer 切断 | `connection:Connecting` | PASS |
| A2 | VM ステータス | `qm status 100` | running | `running` | PASS |
| A3 | 既存データ読み取り | `md5sum -c checksums.txt` | OK | OK | PASS |
| A4 | 新規データ書き込み | `dd ... + md5sum` | 成功 | 1G 書き込み成功 (297 MB/s) | PASS |
| A5 | PVE ストレージ | `pvesm status` | active | `active` | PASS |
| A6 | LINSTOR ノード | `linstor node list` | 5号機: OFFLINE | `OFFLINE (Auto-eviction at ...)` | PASS |

### 備考

- LINSTOR Auto-eviction が有効であり、5号機オフライン検出後にタイマーが開始された
- `linstor node set-property ayase-web-service-5 DrbdOptions/AutoEvictAllowEviction false` でキャンセルした
- VM は電源断中もダウンタイムなしで I/O を継続できた
- Phase 1 で書き込んだデータ: `newfile-phase1.bin` MD5: `8ce131adb3c127da6c12aa78633d27c9`

## Phase 2: 障害回復

### 実施手順

1. IPMI で5号機を電源オン: `ipmitool ... chassis power on`
2. SSH 復帰を待機
3. DRBD bitmap resync を待機
4. UpToDate/UpToDate を確認

### 回復タイムライン

| イベント | 時刻 | 経過 |
|---------|------|------|
| 電源オン | 00:43:31 | 0分 |
| SSH 復帰 | 00:45:52 | ~2分21秒 |
| DRBD 再接続 | 00:46:08 | ~2分37秒 |
| DRBD resync 完了 | 00:46:23 | ~2分52秒 |

### DRBD Bitmap Resync

- 再同期開始時: `done:86.35` (障害中の変更ブロックのみが dirty)
- 完了まで: 約15秒
- ビットマップベースのため、変更ブロックのみの差分同期で高速に完了

### 回復後の検証

- DRBD: UpToDate/UpToDate
- LINSTOR: 両ノード Online
- データ整合性: checksums.txt OK, newfile-phase1.bin MD5 一致

## Phase 3: テスト B — 正常離脱 (linstor node delete)

### 実施手順

1. `linstor resource-group modify pve-rg --place-count 1`
2. `linstor resource delete ayase-web-service-5 pm-23282c6c`
3. `linstor resource delete ayase-web-service-5 vm-100-cloudinit`
4. `linstor storage-pool delete ayase-web-service-5 striped-pool`
5. `linstor node delete ayase-web-service-5`

### 結果

| # | 確認項目 | コマンド | 期待結果 | 実測結果 | 判定 |
|---|---------|---------|---------|---------|------|
| B1 | DRBD 状態 | `drbdadm status` | UpToDate (peer なし) | `disk:UpToDate` (peer 記載なし) | PASS |
| B2 | VM ステータス | `qm status 100` | running | `running` | PASS |
| B3 | 既存データ読み取り | `md5sum -c checksums.txt` | OK | OK + Phase1 データも一致 | PASS |
| B4 | 新規データ書き込み | `dd ... + md5sum` | 成功 | 1G 書き込み成功 (310 MB/s) | PASS |
| B5 | PVE ストレージ | `pvesm status` | active | `active` | PASS |
| B6 | LINSTOR ノード | `linstor node list` | 4号機のみ | 4号機のみ | PASS |
| B7 | LINSTOR リソース | `linstor resource list` | 4号機のみ | 4号機のみに2リソース | PASS |

### 備考

- 正常離脱は全ステップがエラーなく完了した
- リソース削除 → ストレージプール削除 → ノード削除の順序で実行
- VM はダウンタイムなしで稼働継続
- Phase 3 で書き込んだデータ: `newfile-phase3.bin` MD5: `1b32e920a08db4803bf0fafaca5e80aa`

## 分析

### 1ノード運用の成立条件

以下の構成パラメータが1ノード運用を可能にしている:

| パラメータ | 値 | 効果 |
|-----------|-----|------|
| `quorum=off` | DRBD | ノード数に関係なく Primary 昇格可能 |
| `auto-promote=yes` | DRBD | I/O アクセス時に自動で Primary 昇格 |
| `two_node: 1` | PVE corosync | 1ノードでも quorate を維持 |
| LINSTOR コントローラ | 4号機上 | 5号機離脱後も管理可能 |

### ダウンタイム

| テスト | VM ダウンタイム | ストレージ中断 |
|--------|---------------|--------------|
| テスト A (障害) | 0秒 | 0秒 |
| テスト B (正常離脱) | 0秒 | 0秒 |

### 書き込み性能

| 状態 | dd 書き込み速度 (1G) |
|------|---------------------|
| 2ノード通常 | 未計測 (Phase 0 で大量書き込みは DRBD 同期と並行) |
| 障害中 (1ノード) | 297 MB/s |
| 正常離脱後 (1ノード) | 310 MB/s |

1ノード運用時はネットワークレプリケーションのオーバーヘッドがないため、書き込み性能が向上する傾向がある。

### DRBD Bitmap Resync の効果

フル同期 (~518 GiB) が92分かかるのに対し、障害中の変更ブロックのみのビットマップ同期は約15秒で完了した。これは DRBD のアクティビティログとビットマップ機能による効率的な差分同期の証左である。

### LINSTOR Auto-eviction のデフォルトタイムアウト

ノードオフライン検出から約60分後に Auto-eviction が発動する (デフォルト設定)。Phase 1 では電源断 (00:43頃) に対し `Auto-eviction at 2026-02-27 01:42:26` と表示された。Auto-eviction が発動するとリソースの自動退去とデータ再配置が発生するため、計画的メンテナンスや短時間障害では不要な再配置を防ぐために事前にタイムアウトの延長または無効化が必要。

### 制約事項

- 1ノード運用中はディスク故障 = データ全損 (レプリカなし)
- Auto-eviction が有効な場合 (デフォルト ~60分)、LINSTOR が自動的にリソースを退去させる可能性があるため、計画的な障害テスト時は事前に無効化が必要
- PVE クラスタメンバーシップは変更していない (LINSTOR のみ離脱)
- Phase 3 完了後、5号機の LINSTOR リソースは削除済み。元に戻すにはノード再追加 + フル DRBD 同期が必要

## 再現方法

### 前提

- LINSTOR/DRBD 2ノードクラスタが構成済み (thick-stripe)
- VM がLINSTOR ストレージ上で稼働中

### テスト A (障害シミュレーション)

```bash
# 1. 事前状態確認
ssh root@10.10.10.204 "drbdadm status"
ssh root@10.10.10.204 "qm status 100"

# 2. 5号機電源オフ
ipmitool -I lanplus -H 10.10.10.25 -U claude -P Claude123 chassis power off

# 3. 30秒後に確認
ssh root@10.10.10.204 "drbdadm status"           # connection:Connecting
ssh root@10.10.10.204 "qm status 100"             # running
ssh root@10.10.10.204 "pvesm status"               # active
ssh root@10.10.10.204 "linstor node list"          # 5号機: OFFLINE

# 4. Auto-eviction キャンセル (必要に応じて)
ssh root@10.10.10.204 "linstor node set-property ayase-web-service-5 DrbdOptions/AutoEvictAllowEviction false"

# 5. VM 内でデータ検証
# (PVE ホスト経由) sshpass -p 'password' ssh debian@<VM_IP> 'md5sum -c checksums.txt'

# 6. 復旧
ipmitool -I lanplus -H 10.10.10.25 -U claude -P Claude123 chassis power on
# SSH 復帰 + DRBD UpToDate/UpToDate を待機
```

### テスト B (正常離脱)

```bash
# 1. place-count 変更
ssh root@10.10.10.204 "linstor resource-group modify pve-rg --place-count 1"

# 2. リソース削除
ssh root@10.10.10.204 "linstor resource delete ayase-web-service-5 <resource-name>"
# 全リソースに対して繰り返す

# 3. ストレージプール削除
ssh root@10.10.10.204 "linstor storage-pool delete ayase-web-service-5 striped-pool"

# 4. ノード削除
ssh root@10.10.10.204 "linstor node delete ayase-web-service-5"

# 5. 確認
ssh root@10.10.10.204 "drbdadm status"            # peer なし
ssh root@10.10.10.204 "linstor node list"          # 4号機のみ
ssh root@10.10.10.204 "linstor resource list"      # 4号機のみ
```
