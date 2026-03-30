# LINSTOR マルチリージョンマイグレーション 5回反復再現性テスト

- **実施日時**: 2026年3月20日 16:36 - 19:26 JST（2時間50分）
- **セッション**: c56e3190
- **テストデータチェックサム**: f6d83e12152c8768d688c6e6d1fc62f9 (512MiB)

## 前提・目的

6ノード構成（2リージョン）での LINSTOR マルチリージョンマイグレーションの再現性を検証する。ライブマイグレーション（リージョン内）とコールドマイグレーション（リージョン間）を5回反復し、全30回のチェックサム一致とデータ整合性を確認する。

- **背景**: LINSTOR/DRBD マルチリージョン運用基盤の安定性を定量的に評価する必要がある
- **目的**: 5回の反復テストにより、マイグレーション処理の再現性・信頼性を確認する
- **成功基準**: (1) 5回反復完了、(2) 全30チェックサム一致、(3) ライブマイグレーションでの稼働継続、(4) 既知問題の回避策が文書化されていること

## 環境情報

### リージョン構成

| リージョン | PVE クラスタ | ノード | ハードウェア | PVE ストレージ |
|-----------|-------------|--------|------------|---------------|
| Region A | pvese-cluster1 | 4号機 + 5号機 | Supermicro X11DPU, Xeon Skylake | linstor-storage |
| Region A | pvese-cluster2 | 6号機 | Supermicro X11DPU (DR ノード、ライブマイグレーション対象外) | linstor-storage |
| Region B | region-b | 7号機 + 8号機 + 9号機 | Dell R320, Xeon E5-2420v2 | linstor-storage-b |

### ネットワーク

| 経路 | インターフェース | プロトコル |
|------|----------------|-----------|
| リージョン間 (cross-region) | GbE (10.10.10.0/8) | DRBD Protocol A |
| Region A 内 (intra-region) | IPoIB (192.168.100.0/24) | DRBD Protocol C |
| Region B 内 (intra-region) | IPoIB (192.168.101.0/24) | DRBD Protocol C |

### ライブマイグレーション経路

- Region A: 4号機 ↔ 5号機
- Region B: 7号機 ↔ 8号機

### テスト VM

- VMID: 200 (bench-vm)
- RAM: 4GiB, CPU: 4 cores (kvm64), ディスク: 32GiB DRBD

## Phase 0a: スクリプト修正

テスト実行前に以下のスクリプト修正を実施した。

### 1. `get_region_nodes()` のパス修正（5ファイル）

`.regions."$1"[]` を `.regions."$1".nodes[]` に変更し、新しい設定構造に対応。

### 2. `linstor-migrate-cold.sh`: ストレージ名のパース修正

ハードコードされた `linstor-storage` を廃止し、`config/linstor.yml` の `pve_storage` フィールドからリージョンごとに読み取るように修正。また、`resource create` に `|| true` を追加し、非致命的な LINSTOR エラーを許容。

### 3. `linstor-migrate-live.sh`: ストレージ名のパース修正

同様にリージョンごとの `pve_storage` を使用するよう修正。

### 4. `config/linstor.yml`: リージョンごとの `pve_storage` 追加

- Region A: `linstor-storage`
- Region B: `linstor-storage-b`

## Iteration 1 で実施したインフラ修正

### 8号機・9号機: vmbr0/vmbr1 ブリッジ作成

ライブマイグレーションのターゲットノードに必要な vmbr0/vmbr1 が未作成だったため追加。

### クロスリージョンパス設定

Region A ↔ Region B の全ノードペアに対して `node-connection path create` を実行し、`default` インターフェースでの接続を明示的に定義。

### DRBD StandAlone リカバリ

`PrefNic=ib0` が IB アドレスにバインドされ、クロスリージョン接続が確立できなかった。クロスリージョンパスに `default` インターフェースを指定することで解決。

## テスト手順（各 Iteration のステップ）

各 Iteration は以下の4ステップで構成される。

| ステップ | 操作 | 内容 |
|---------|------|------|
| S1a | ライブマイグレーション | 4号機 → 5号機 |
| S1b | ライブマイグレーション | 5号機 → 4号機 (元に戻す) |
| S2 | コールドマイグレーション | Region A → Region B |
| S3a | ライブマイグレーション | 7号機 → 8号機 |
| S3b | ライブマイグレーション | 8号機 → 7号機 (元に戻す) |
| S4 | コールドマイグレーション | Region B → Region A |

各ステップ後に VM 内の 512MiB テストデータの MD5 チェックサムを検証。

## テスト結果

### Iteration 1（手動実行）

| ステップ | 所要時間 | ダウンタイム | チェックサム |
|---------|---------|------------|------------|
| S1 live 4→5 | 15s | 78ms | PASS |
| S1 live 5→4 | 14s | 49ms | PASS |
| S2 cold A→B | ~530s | - | PASS |
| S3 live 7→8 | 17s | 36ms | PASS |
| S3 live 8→7 | 17s | 43ms | PASS |
| S4 cold B→A | ~620s | - | PASS |

### Iterations 2-5（自動実行）

| Iteration | S1a (4→5) | S1b (5→4) | S2 (A→B) | S3a (7→8) | S3b (8→7) | S4 (B→A) |
|-----------|-----------|-----------|----------|-----------|-----------|----------|
| 2 | 21s PASS | 21s PASS | 735s PASS | 26s PASS | 25s PASS | 721s PASS |
| 3 | 21s PASS | 20s PASS | 746s PASS | 26s PASS | 25s PASS | 720s PASS |
| 4 | 21s PASS | 20s PASS | 747s PASS | 26s PASS | 25s PASS | 731s PASS |
| 5 | 21s PASS | 20s PASS | 756s PASS | 26s PASS | 26s PASS | 719s PASS |

**全30チェックサム: PASS (30/30)**

### ライブマイグレーション統計（PVE ログより）

| リージョン | 所要時間 | 転送量 | 平均速度 | ダウンタイム |
|-----------|---------|--------|---------|------------|
| Region A (4↔5) | ~14-15s | ~850 MiB | 514 MiB/s | 49-93ms |
| Region B (7↔8) | ~17s | ~830 MiB | 514 MiB/s | 35-43ms |

### コールドマイグレーション統計

| 方向 | ウォールタイム | 内訳 |
|------|-------------|------|
| A→B | 735-756s | DRBD 同期 (~320s, node8 レプリカ作成) + DR 同期 |
| B→A | 719-731s | DRBD 同期 (~300s, node5 レプリカ作成) + DR 同期 |

DRBD 同期レート: ~3.5%/10s = ~110 MiB/s（GbE 帯域制限）

## 発生した問題と対処

| 問題 | 状況 | 対処 |
|------|------|------|
| C8 (LV サイズ不一致) | 未発生 | 8号機の `-i3` ストライプによる PE アライメント問題は発生せず |
| DRBD StandAlone | Iteration 1 で発生 | 5ノードトポロジを3ノード (2 primary + 1 DR) に簡素化して解決 |
| PVE ストレージ名不一致 | `linstor-storage` vs `linstor-storage-b` | `config/linstor.yml` にリージョンごとの `pve_storage` を追加 |
| 8号機・9号機ブリッジ未作成 | ライブマイグレーション不可 | vmbr0/vmbr1 を作成 |

## 成功基準の評価

| 基準 | 結果 |
|------|------|
| 5回反復完了（回復不能エラーなし） | OK |
| 全30チェックサム一致 | OK (30/30 PASS) |
| ライブマイグレーション稼働継続性 | OK（全 uptime 値が連続、再起動なし） |
| 既知問題に文書化された回避策あり | OK |

## まとめ

6ノード2リージョン構成での LINSTOR マルチリージョンマイグレーションを5回反復し、全30回のデータ整合性チェックに合格した。ライブマイグレーションは Region A/B ともに安定しており、ダウンタイムは 100ms 未満。コールドマイグレーションは GbE 帯域制限により 12-13 分程度を要するが、再現性は高い。Iteration 1 で発見されたインフラ課題（ブリッジ未作成、クロスリージョンパス未設定、ストレージ名不一致）はすべて解決済みで、Iteration 2-5 は完全自動で成功した。
