# LINSTOR/DRBD ノード離脱・復帰 完全サイクル実験レポート

- **実施日時**: 2026年2月27日 06:15〜11:10 (約5時間)

## 前提・目的

LINSTOR/DRBD 2ノードクラスタでノードの離脱・復帰の完全サイクル (REJOIN → FAIL → RECOVER → DEPART → REJOIN) を実行し、データ整合性とサービス継続性を検証する。

- **背景**: 前回実験 (障害シミュレーション + 正常離脱) で得た知見をスキルに反映済み。本実験でスキル修正内容の正しさを検証する
- **目的**: (1) 離脱済みノードの復帰手順 (rejoin) を確立する、(2) 障害 → 回復 → 離脱 → 再参加の完全サイクルでデータ整合性を検証する、(3) 各操作段階での書き込み性能を計測する
- **前提条件**: 前回実験で5号機は LINSTOR から離脱済み (node delete 実行済み)。4号機のみで VM 100 が稼働中

### 参考レポート

- [LINSTOR/DRBD ノード離脱 — 運用継続実験](report/2026-02-27_005307_linstor_node_departure_experiment.md) — 前回実験
- [LINSTOR/DRBD ベンチマーク (thick-stripe)](report/2026-02-26_130844_linstor_thin_vs_thick_stripe_benchmark.md) — 初回ノード構成

### 直前のスキル修正一覧 (本実験で検証する対象)

| 修正 | ファイル | 内容 |
|------|---------|------|
| F5 実測データ追記 | `.claude/skills/linstor-bench/SKILL.md` | 518 GiB / 92分 (~96 MiB/s) の同期レート |
| F8 新規追加 | `.claude/skills/linstor-bench/SKILL.md` | Auto-eviction 干渉パターンと対策 |
| linstor-node-ops 新規スキル | `.claude/skills/linstor-node-ops/SKILL.md` | fail/recover/depart/rejoin の4サブコマンド + 失敗パターン N1-N4 |
| メモリ更新 | `memory/linstor.md` | 同期性能、Auto-eviction、1ノード運用条件、回復タイムライン |

## 環境情報

### ハードウェア

| 項目 | 4号機 (ayase-web-service-4) | 5号機 (ayase-web-service-5) |
|------|---------------------------|---------------------------|
| マザーボード | Supermicro X11DPU | Supermicro X11DPU |
| BMC IP | 10.10.10.24 | 10.10.10.25 |
| 静的 IP | 10.10.10.204 | 10.10.10.205 |
| IB IP | 192.168.100.1 | 192.168.100.2 |
| ストレージ | 4x SATA SSD (~466 GiB each) | 同左 |

### ソフトウェア

| 項目 | 値 |
|------|-----|
| OS | Debian 13.3 (Trixie) + Proxmox VE 9.1.6 |
| カーネル | 6.17.9-1-pve |
| DRBD | 9.3.0, Protocol C, quorum=off, auto-promote=yes |
| LINSTOR | 1.33.1 |
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

## 実験フェーズと結果

### Phase 0: 事前確認 + ベースライン計測

**目的**: 1ノード状態のベースラインを記録

| # | 確認項目 | 結果 | 判定 |
|---|---------|------|------|
| 0-1 | LINSTOR ノード | 4号機のみ Online | OK |
| 0-2 | DRBD 状態 | UpToDate (peer なし) | OK |
| 0-3 | VM 100 | running | OK |
| 0-4 | データ整合性 (verify-10g.bin) | MD5: f7cf7d8470ca057a8c1184ec55fb7d8f 一致 | OK |
| 0-5 | 5号機 SSH | 接続成功 | OK |
| 0-6 | 5号機 LVM VG | linstor_vg あり、LV=0 (クリーン) | OK |
| 0-7 | IB 接続 | ping 192.168.100.2 成功 | OK |
| 0-8 | SMART | 全8ディスク (両ノード) 不良セクタなし | OK |
| 0-9 | dd 書き込み (1ノード) | 56.6 MB/s | 記録 |

### Phase 1: 5号機 REJOIN (1回目)

**目的**: 離脱済みノードの復帰手順を検証

| ステップ | コマンド | 結果 | スキル検証 |
|---------|---------|------|-----------|
| stale DRBD .res 確認 | ls /etc/drbd.d/*.res | linstor-resources.res あり (include ファイルのみ、削除不要) | N5 候補: stale .res ファイルは LINSTOR 管理の include であり、実害なし |
| ノード登録 | linstor node create | SUCCESS | — |
| IB インターフェース | linstor node interface create + PrefNic | SUCCESS | — |
| SP 作成 | linstor storage-pool create lvm + LvcreateOptions | SUCCESS | — |
| Auto-eviction 無効化 | 両ノードで DrbdOptions/AutoEvictAllowEviction false | SUCCESS | F8/N1 対策適用 |
| place-count 復元 | linstor resource-group modify --place-count 2 | SUCCESS、両リソース自動配置 | — |
| DRBD フル同期 | 06:19 → ~07:58 | ~99分、~94 MiB/s | F5 実測値と一致 |

### Phase 2: 復帰後検証

| # | 確認項目 | 結果 | 判定 |
|---|---------|------|------|
| 2-1 | DRBD | UpToDate/UpToDate | PASS |
| 2-2 | データ整合性 | checksums.txt 全OK | PASS |
| 2-3 | dd 書き込み (2ノード) | 28.6 MB/s | 記録 |

### Phase 3: 5号機 FAIL (電源断)

**電源断時刻**: 08:12:02

| # | 確認項目 | 期待結果 | 実測結果 | 判定 | スキル検証 |
|---|---------|---------|---------|------|-----------|
| 3-1 | DRBD 状態 | peer 切断 | connection:Connecting | PASS | — |
| 3-2 | VM ステータス | running | running | PASS | — |
| 3-3 | PVE ストレージ | active | active | PASS | — |
| 3-4 | LINSTOR 5号機 | OFFLINE | OFFLINE | PASS | — |
| 3-5 | データ整合性 | checksums OK | OK | PASS | — |
| 3-6 | Auto-eviction | 表示なし | 表示なし (事前に無効化済み) | PASS | N1 対策が有効 |

### Phase 4: 障害中データ書き込み

| # | 確認項目 | 結果 | 判定 |
|---|---------|------|------|
| 4-1 | dd 書き込み (1ノード障害中) | 55.8 MB/s | 記録 |
| 4-2 | checksums 更新 | write-phase4-fail.bin 追加 | OK |

### Phase 5: 5号機 RECOVER (電源オン)

**電源オン時刻**: 08:20:51

### 回復タイムライン

| イベント | 時刻 | 経過 |
|---------|------|------|
| 電源オン | 08:20:51 | 0分 |
| SSH 復帰 | ~08:22:42 | ~1分51秒 |
| DRBD 再接続 + resync 完了 | ~08:23:13 | ~2分22秒 |

前回実験 (2分52秒) と同程度。bitmap resync は Phase 4 の 1 GiB 変更分のみで即完了。

### Phase 6: 回復後検証

| # | 確認項目 | 結果 | 判定 |
|---|---------|------|------|
| 6-1 | DRBD | UpToDate/UpToDate | PASS |
| 6-2 | LINSTOR | 両ノード Online | PASS |
| 6-3 | データ整合性 | checksums.txt 全OK (Phase 4 データ含む) | PASS |
| 6-4 | dd 書き込み (2ノード回復後) | 29.0 MB/s | 記録 |

### Phase 7: 5号機 DEPART (正常離脱)

| ステップ | コマンド | 結果 | スキル検証 |
|---------|---------|------|-----------|
| place-count 変更 | --place-count 1 | SUCCESS | N2 対策適用 |
| リソース削除 | pm-23282c6c, vm-100-cloudinit | SUCCESS | N3 順序厳守 |
| SP 削除 | striped-pool | SUCCESS | N3 順序厳守 |
| ノード削除 | ayase-web-service-5 | SUCCESS | — |

全ステップエラーなし。前回実験と同一結果。

### Phase 8: 離脱後検証

| # | 確認項目 | 結果 | 判定 |
|---|---------|------|------|
| 8-1 | DRBD | UpToDate (peer なし) | PASS |
| 8-2 | LINSTOR | 4号機のみ | PASS |
| 8-3 | データ整合性 | checksums.txt 全OK | PASS |
| 8-4 | dd 書き込み (1ノード離脱後) | 55.8 MB/s | 記録 |

### Phase 9: 5号機 REJOIN (2回目)

Phase 1 と同一手順で実行。再現性確認。

| ステップ | 結果 | Phase 1 との差異 |
|---------|------|-----------------|
| VG 状態 | LV=0 (クリーン) | 同一 |
| stale DRBD .res | linstor-resources.res のみ | 同一 |
| ノード登録〜SP作成 | 全 SUCCESS | 同一 |
| DRBD フル同期 | 09:00 → 10:38 (~99分) | Phase 1 と同一所要時間 |

### Phase 10: 最終検証

| # | 確認項目 | 結果 | 判定 |
|---|---------|------|------|
| 10-1 | Auto-eviction 再有効化 | 両ノードで property 削除成功 | OK |
| 10-2 | DRBD | UpToDate/UpToDate | PASS |
| 10-3 | LINSTOR | 両ノード Online | PASS |
| 10-4 | データ整合性 | checksums.txt 全6ファイル OK | PASS |
| 10-5 | dd 書き込み (2ノード最終) | 29.0 MB/s | 記録 |

## 書き込み性能サマリ

`dd if=/dev/urandom of=... bs=1M count=1024 oflag=direct` で統一計測。

| 状態 | Phase | ノード数 | dd 速度 (MB/s) |
|------|-------|---------|---------------|
| 実験前 (1ノード) | 0 | 1 | 56.6 |
| 復帰後 (2ノード) | 2 | 2 | 28.6 |
| 障害中 (1ノード) | 4 | 1 | 55.8 |
| 回復後 (2ノード) | 6 | 2 | 29.0 |
| 離脱後 (1ノード) | 8 | 1 | 55.8 |
| 再復帰後 (2ノード) | 10 | 2 | 29.0 |

**分析**:
- 1ノード時は一貫して ~56 MB/s (urandom 生成速度がボトルネック)
- 2ノード時は一貫して ~29 MB/s (DRBD レプリケーションのオーバーヘッドで約半減)
- 各状態遷移で性能が安定しており、離脱・復帰による性能劣化は認められない

## DRBD フル同期性能

| 回 | 開始 | 完了 | 所要時間 | レート | データ量 |
|----|------|------|---------|--------|---------|
| 1回目 (Phase 1) | 06:19 | ~07:58 | ~99分 | ~94 MiB/s | ~550 GiB |
| 2回目 (Phase 9) | 09:00 | 10:38 | ~99分 | ~94 MiB/s | ~550 GiB |

2回とも同一所要時間。スキルに記録済みの ~96 MiB/s (518 GiB / 92分) と整合する。ディスク使用量が Phase 0 の 30% から増加しているため (追加テストデータ)、同期データ量が増えた分だけ時間が延びている。

## 回復タイムライン比較

| イベント | 今回 (Phase 5) | 前回実験 |
|---------|---------------|---------|
| 電源オン → SSH 復帰 | ~1分51秒 | ~2分21秒 |
| 電源オン → DRBD resync 完了 | ~2分22秒 | ~2分52秒 |

若干高速だが、同一オーダー。

## スキル検証結果

| スキル/パターン | 対象 Phase | 検証結果 | 備考 |
|---------------|-----------|---------|------|
| F5 (フル同期レート) | 1, 9 | PASS | ~94 MiB/s で ~96 MiB/s の記載と整合 |
| F8 (Auto-eviction 干渉) | 1, 3 | PASS | 事前無効化で Auto-eviction 未発動 |
| N1 (Auto-eviction) | 3 | PASS | Phase 1 で事前無効化、Phase 3 で発動なし |
| N2 (place-count 変更忘れ) | 7 | PASS | depart 前に --place-count 1 を実行 |
| N3 (リソース削除順序) | 7 | PASS | リソース → SP → ノード の順で実行 |
| N4 (bitmap resync ポーリング) | 5 | PASS | 30秒ポーリングで UpToDate を検出 |

### 新規発見: N5 (stale DRBD メタデータ)

5号機の `/etc/drbd.d/linstor-resources.res` に stale ファイルが残存していた。内容は `include "/var/lib/linstor.d/*.res";` のみで、LINSTOR が satellite 起動時に自動管理する include ファイル。`/var/lib/linstor.d/` 内にリソース定義がなければ実害なし。

**結論**: LINSTOR の node delete 後も `/etc/drbd.d/linstor-resources.res` は残るが、rejoin 時に LINSTOR が自動的に上書きするため、手動削除は不要。

## 分析

### rejoin 手順の確立

離脱済みノードの復帰手順が確立された:

1. LVM VG の確認 (stale LV がある場合は wipefs → pvcreate → vgcreate)
2. `linstor node create` (Satellite)
3. `linstor node interface create` (IB) + `PrefNic` 設定
4. `linstor storage-pool create` + `LvcreateOptions` (ストライプ)
5. `linstor node set-property DrbdOptions/AutoEvictAllowEviction false` (N1 対策)
6. `linstor resource-group modify --place-count 2`
7. DRBD フル同期待機 (~99分 / 550 GiB)

2回実行して同一結果を得たことで、手順の再現性が確認された。

### ダウンタイム

| 操作 | VM ダウンタイム | ストレージ中断 |
|------|---------------|--------------|
| REJOIN (復帰) | 0秒 | 0秒 |
| FAIL (障害) | 0秒 | 0秒 |
| RECOVER (回復) | 0秒 | 0秒 |
| DEPART (離脱) | 0秒 | 0秒 |

全フェーズでダウンタイムなし。VM は全操作を通じて稼働を継続した。

### データ整合性

全11フェーズ (Phase 0〜10) を通じて checksums.txt の検証に失敗はなし。障害中に書き込んだデータも回復後に正常に読み取れた。最終的に6ファイル (10 GiB 検証ファイル + 5x 1 GiB テストファイル) 全て MD5 一致。

### 制約事項

- DRBD フル同期に ~99分かかるため、rejoin のダウンタイムはゼロだが、完全冗長化まで待機が必要
- rejoin 中は VM の I/O 性能が 2ノード時の水準 (~29 MB/s) まで低下する (同期トラフィックとの帯域共有)
- Auto-eviction は実験中無効化が必須。再有効化を忘れると、次の障害時にリソース退去が発生しない

## 再現方法

### 前提

- LINSTOR/DRBD 2ノードクラスタが構成済み (thick-stripe)
- VM が LINSTOR ストレージ上で稼働中
- 一方のノードが `linstor node delete` で離脱済み

### REJOIN (復帰)

```bash
NODE="ayase-web-service-5"
NODE_IP="10.10.10.205"
CTRL_IP="10.10.10.204"
VG="linstor_vg"

ssh root@$NODE_IP "vgs $VG"
ssh root@$CTRL_IP "linstor node create $NODE $NODE_IP --node-type Satellite"
ssh root@$CTRL_IP "linstor node interface create $NODE ib0 192.168.100.2"
ssh root@$CTRL_IP "linstor node set-property $NODE PrefNic ib0"
ssh root@$CTRL_IP "linstor storage-pool create lvm $NODE striped-pool $VG"
ssh root@$CTRL_IP "linstor storage-pool set-property $NODE striped-pool StorDriver/LvcreateOptions -- '-i4 -I64'"
ssh root@$CTRL_IP "linstor node set-property ayase-web-service-4 DrbdOptions/AutoEvictAllowEviction false"
ssh root@$CTRL_IP "linstor node set-property $NODE DrbdOptions/AutoEvictAllowEviction false"
ssh root@$CTRL_IP "linstor resource-group modify pve-rg --place-count 2"
# DRBD フル同期待機 (~99分 / 550 GiB)
ssh root@$CTRL_IP "drbdadm status"  # peer-disk:UpToDate を待機
# Auto-eviction 再有効化
ssh root@$CTRL_IP "linstor node set-property ayase-web-service-4 DrbdOptions/AutoEvictAllowEviction"
ssh root@$CTRL_IP "linstor node set-property $NODE DrbdOptions/AutoEvictAllowEviction"
```

### DEPART (正常離脱)

```bash
ssh root@$CTRL_IP "linstor resource-group modify pve-rg --place-count 1"
ssh root@$CTRL_IP "linstor resource delete $NODE pm-23282c6c"
ssh root@$CTRL_IP "linstor resource delete $NODE vm-100-cloudinit"
ssh root@$CTRL_IP "linstor storage-pool delete $NODE striped-pool"
ssh root@$CTRL_IP "linstor node delete $NODE"
```

### FAIL + RECOVER

```bash
BMC_IP="10.10.10.25"
ipmitool -I lanplus -H $BMC_IP -U claude -P Claude123 chassis power off
# 30秒待機後に確認
ipmitool -I lanplus -H $BMC_IP -U claude -P Claude123 chassis power on
# SSH 復帰 + DRBD UpToDate/UpToDate を待機 (~2-3分)
```
