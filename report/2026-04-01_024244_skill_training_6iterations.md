# スキルトレーニング (6/10 イテレーション実施) レポート

- **実施日時**: 2026年4月1日 10:09 JST (開始) - 11:42 JST (完了)
- **所要時間**: 約93分
- **対象**: 4-9号機、14スキル

## 添付ファイル

- [実装プラン](attachment/2026-04-01_024244_skill_training_6iterations/plan.md)

## 前提・目的

全14スキルを4-9号機で繰り返し実行し、スキル定義・スクリプトの品質を向上させる。各イテレーションで発見された問題を修正し、次のイテレーションで検証する。当初10回計画だったが、Region B のインフラ問題 (ブリッジ未作成) により6回で中間停止。

## 環境情報

| 項目 | Region A (4-6号機) | Region B (7-9号機) |
|------|-------------------|-------------------|
| ハードウェア | Supermicro X11DPU | Dell PowerEdge R320 |
| OS | Debian 13 + PVE 9.1.6 | Debian 13 + PVE 9.1.6 |
| カーネル | 6.17.13-2-pve | 6.17.13-2-pve |
| LINSTOR | 1.33.1 (Controller+Satellite) | 1.33.1 (Satellite) |
| DRBD | 9.3.1 | 9.3.1 |
| ストレージ | ZFS (linstor_zpool, ~1.8TiB/node) | ZFS (linstor_zpool, 3.2-4.9TiB/node) |
| IB | ibp134s0, 192.168.100.x/24 | ibp10s0, 192.168.101.x/24 |

## サマリ

| Iteration | 内容 | 発見問題 | 修正 | 所要時間 |
|-----------|------|---------|------|---------|
| 1 | 全スキル status/read-only | #35 Region B LINSTOR未構成 | - | ~15分 |
| 2 | dell-fw-download, tftp, live migration | #36 TFTP local test, #37 Dell GEO redirect | スキル修正 | ~20分 |
| 3 | BIOS enter/exit, IB switch, fail/recover | #38 IPoIB auto-start | - | ~15分 |
| 4 | fio bench (119K IOPS), PERC status | - | - | ~15分 |
| 5 | Region B PVEクラスタ + LINSTOR setup | #39 os-setup missing deps | #35 解消 | ~20分 |
| 6 | Region B IB/cross-region + cold migrate | #40 vmbr0/vmbr1 未作成 | - | ~15分 |
| 7-10 | スキップ (Region B ブリッジ問題) | - | - | - |

## 発見・修正した問題の一覧

| # | Issue | 問題 | 発見Iter | 状態 |
|---|-------|------|---------|------|
| 1 | #35 | Region B LINSTOR/DRBD 未セットアップ | 1 | **完了** (Iter 5で解消) |
| 2 | #36 | Docker TFTP ローカル UDP テスト応答なし | 2 | Open (環境依存) |
| 3 | #37 | dell-fw-download GEO IP リダイレクト | 2 | Open (スキル修正済み、未検証) |
| 4 | #38 | IPoIB リブート後に自動起動しない | 3 | Open (rdma-core 起動順序) |
| 5 | #39 | os-setup: LINBIT GPG鍵/gcc/headers 未インストール | 5 | Open |
| 6 | #40 | Region B: vmbr0/vmbr1 ブリッジ未作成 | 6 | Open (Iter 7-10 ブロッカー) |

## Iteration 1: 全スキル status/read-only

全14スキルの読み取り専用操作を実行しベースラインを確立した。

- **playwright**: OK (v1.58.0)
- **idrac7**: OK (全3台 FW 2.65.65.65, IPMI LAN enabled, jobqueue全完了)
- **perc-raid**: OK (全VD Online)
- **bios-setup**: OK (KVM screenshot 4-6号機正常)
- **ib-switch**: OK (6ポート Active QDR 40Gbps, MLNX-OS 3.6.8012)
- **linstor-bench**: OK (SMART PASSED)
- **linstor-migration**: OK (pm-5b16a893 UpToDate)
- **linstor-node-ops**: OK (Region A 3ノード Online)
- **os-setup**: OK (phase state files確認)

## Iteration 2: ローカルスキル + ライブマイグレーション

- **dell-fw-download**: 失敗 — GEO IP で日本語ページにリダイレクトされダウンロードボタンなし。スキルに locale/cookie 対策を追記
- **tftp-server**: Docker コンテナ起動OK、ローカル UDP テストタイムアウト。スキルに制限事項追記
- **linstor-bench**: VM 9900 作成成功、Ed25519 鍵+known_hostsクリアが必要 (F13/F17)
- **linstor-migration (live)**: pve4→pve5 成功。14秒、409.8 MiB/s、ダウンタイム 63ms
- 6号機 IPoIB DOWN → ib-setup-remote.sh --persist で修正

## Iteration 3: BIOS/PERC操作 + fail/recover

- **bios-setup**: 5号機で BIOS 進入成功 (Delete 連打 60回)。全7タブ screenshot 取得。保存せず終了
- **ib-switch**: enable-cmd show running-config 取得成功
- **linstor-node-ops (fail)**: 6号機電源断 → LINSTOR OFFLINE 検出 (30秒以内)
- **linstor-node-ops (recover)**: 6号機電源ON → SSH復帰 → LINSTOR Online
- IPoIB がリブート後に DOWN (#38)

## Iteration 4: fio ベンチマーク + PERC status

- **linstor-bench**: fio random read 4K = **119,491 IOPS**, 467 MB/s (ZFS over DRBD, Region A)
- **perc-raid**: racadm で全 VD Online 確認
- cloud-init status --wait の重要性を確認

## Iteration 5: Region B PVEクラスタ + LINSTOR セットアップ

Region B (7-9号機) を一からセットアップ:
1. PVE クラスタ作成 (pvese-cluster2, `--fingerprint` オプションが必須)
2. LINSTOR/DRBD パッケージインストール (proxmox-9 リポジトリ、GPG鍵コピー、enterprise.sources 削除、gcc + pve-headers インストールが必要)
3. ZFS pool 作成 (linstor_zpool)
4. LINSTOR ストレージプール登録、Aux/site、auto-eviction 無効化

**待ち時間最適化**: DRBD dkms ビルド (5-10分/台) を3台並行実行。インターネット接続設定 (DHCP + 192.168.39.1 ゲートウェイ) が前提条件として必要だった。

## Iteration 6: リージョン間操作 + コールドマイグレーション

1. Region B IPoIB セットアップ (ibp10s0, 192.168.101.x)
2. LINSTOR IB interface + PrefNic 登録
3. Cross-region パス 9ペア作成
4. Protocol A 設定 (linstor-multiregion-setup.sh)
5. DRBD レプリカ作成 (Region B に2ノード) → 同期完了 (3 GiB, ~2分)
6. VM 停止 → Region A レプリカ削除 → Region B で VM 再作成
7. **vmbr1 未作成で VM 起動失敗** (#40)

## 待ち時間最適化の成果

- DRBD dkms ビルドを3台並行で実行 (各5-10分 → 実質10分)
- SSH 起動待ちをバックグラウンドで実行し、他スキル操作を並行
- BIOS 操作中に他サーバのステータス確認を並行
- DRBD 同期待ち中に IB switch 操作を実行

## 結論・今後の課題

### 成果
- 14スキル中12スキルの動作を確認 (dell-fw-download/tftp-server は部分的)
- Region B のLINSTOR マルチリージョン構成を完了
- 6つのインフラ問題を発見し、2つの修正をスキルにコミット

### 残課題 (次回セッション向け)
1. **Issue #40**: Region B ブリッジ (vmbr0/vmbr1) 作成 → pve-setup-remote.sh の実行が必要
2. **Issue #38**: IPoIB リブート後の自動起動 → rdma-core/ib_ipoib モジュール起動順序の調査
3. **Issue #39**: os-setup スキルに LINBIT GPG鍵、gcc、pve-headers の自動インストールを追加
4. **Iteration 7-10**: Region B ブリッジ修正後に再開 (コントローラ障害、os-setup フル実行等)
