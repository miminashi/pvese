# LINSTOR セカンダリコントローラ実験 — Region B 自律運用テスト

## Context

現在 LINSTOR コントローラは Region A の pve4 (10.10.10.204) 1台のみで稼働しており、Region B (pve7/8/9) はすべてサテライトノード。Region A との通信が切れると、Region B では DRBD データプレーンは継続するが、LINSTOR 管理操作（VM 起動・マイグレーション等）が不可能になる。

Region B にセカンダリコントローラを配置し、ネットワーク分断時に Region B が自律運用を継続できるか実験する。

## アプローチ選定

| 方式 | 判定 | 理由 |
|------|------|------|
| DRBD-Reactor HA (公式推奨) | **不適** | linstor_db の quorum が Region A 側に残るため、分断時に Region B でコントローラを昇格できない |
| 完全独立クラスタ (リージョン別) | **過剰** | 既存スクリプト・マルチリージョン構成を大幅改修する必要あり |
| **休眠コントローラ方式** | **採用** | 通常時は pve4 が全ノードを管理。pve7 に停止状態のコントローラ+DB スナップショットを配置し、分断時に起動して Region B のみ管理 |

## 実験手順

### Phase 0: 事前確認

1. pve4 で `linstor node list`, `linstor resource list` を実行し現状を記録
2. `./scripts/linstor-multiregion-status.sh config/linstor.yml` でフルステータス取得
3. pve7 に `linstor-controller` パッケージがインストール済みか確認
4. Region B でテスト用 VM が稼働中か確認（なければ作成を検討）
5. 各ノードの既存 iptables ルールを `iptables-save` で保存

### Phase 1: pve7 にコントローラをインストール

1. `ssh pve7 "apt install -y linstor-controller"` でインストール
2. `ssh pve7 "systemctl disable linstor-controller"` で自動起動を無効化
3. `ssh pve7 "systemctl stop linstor-controller"` で停止を確認

### Phase 2: コントローラ DB のスナップショットコピー

1. pve4 のコントローラを一時停止: `ssh pve4 "systemctl stop linstor-controller"`
   - DRBD データプレーンは継続するため VM への影響なし（停止は数秒）
2. DB を pve4 → pve7 にコピー（scp 経由、pve4 上で実行）
3. pve4 のコントローラを即座に再起動: `ssh pve4 "systemctl start linstor-controller"`
4. `linstor node list` で全ノード Online を確認

### Phase 3: Region B コントローラの動作確認（分断なし）

1. pve4 コントローラを停止（2台同時稼働を防止）
2. pve7 コントローラを起動
3. `linstor --controllers=10.10.10.207 node list` で確認
   - Region B ノード (pve7/8/9): Online
   - Region A ノード (pve4/5/6): OFFLINE（期待通り）
4. pve7 コントローラを停止
5. pve4 コントローラを再起動
6. 全ノード Online を確認

### Phase 4: ネットワーク分断シミュレーション

1. Region B 各ノード (pve7/8/9) で iptables により Region A (10.10.10.204-206, 192.168.100.0/24) への通信を遮断
2. 30-60 秒待機（DRBD クロスリージョン接続が切断されるのを確認）
3. pve7 でセカンダリコントローラを起動
4. 確認項目:
   - `linstor --controllers=10.10.10.207 node list` — Region B ノードが Online
   - `linstor --controllers=10.10.10.207 resource list` — Region B リソースが UpToDate
   - テスト VM が稼働継続していること

### Phase 5: 分断中の VM 操作テスト

1. Region B 内でテスト VM のライブマイグレーション（例: pve7 → pve8）
2. VM の停止・起動テスト（auto-promote が Region B コントローラ経由で動作するか）
3. 各操作の成功/失敗を記録

### Phase 6: 分断復旧

1. pve7 のセカンダリコントローラを停止
2. Region B 各ノードの iptables ルールを削除（`iptables -D` で個別削除）
3. 30-60 秒待機（DRBD クロスリージョン再接続）
4. pve4 で `linstor node list` — 全 6 ノード Online を確認
5. `./scripts/linstor-multiregion-status.sh config/linstor.yml` でフルステータス確認
6. DRBD split-brain チェック（`drbdsetup status` で StandAlone がないか）
7. DR レプリカの再同期完了を待機

### Phase 7: クリーンアップ

1. pve7 の linstor-controller を disable のまま維持（再実験用）または `apt remove`
2. `/etc/linstor/linstor-client.conf` を元に戻す（変更した場合）
3. 実験結果をレポートに記録

## リスクと対策

| リスク | 対策 |
|--------|------|
| 2台のコントローラ同時稼働 → サテライト混乱 | Phase 3: 必ず片方を停止してから起動。Phase 4: iptables で物理的に通信不可 |
| DB スナップショットが古い | Phase 2 で実験直前にスナップショット取得 |
| 復旧時の DRBD split-brain | Protocol A + allow-two-primaries=no により双方 Primary は発生しない。念のため Phase 6 で確認 |
| PVE クラスタ quorum | Region A/B は独立 PVE クラスタのため影響なし |
| iptables flush で既存ルール消失 | Phase 0 で `iptables-save` 保存、Phase 6 では `-D` で個別削除 |

## 成功基準

1. 分断中に Region B コントローラが起動し、Region B ノードを Online として認識する
2. 分断中に Region B 内で VM のライブマイグレーションが成功する
3. 分断中に VM の停止・再起動が成功する
4. 復旧後に Region A コントローラが全 6 ノードを管理できる
5. DRBD クロスリージョン接続が split-brain なしで再同期する

## 主要ファイル

- `config/linstor.yml` — コントローラ IP 等の設定
- `scripts/linstor-multiregion-status.sh` — ステータス確認
- `scripts/linstor-migrate-live.sh` — ライブマイグレーション
- `docs/linstor-multiregion-ops.md` — 運用マニュアル（split-brain 解決手順含む）

## 検証方法

各 Phase 完了時に以下を記録:
- `linstor node list` / `linstor resource list` の出力
- `drbdsetup status` の出力（特にクロスリージョン接続状態）
- VM のアクセス可否
- エラーメッセージがあれば全文記録

## レポート

実験完了後に `report/` にレポートを作成する。REPORT.md のフォーマットに従い、以下を含める:

- **ファイル名**: `report/YYYY-MM-DD_HHMMSS_linstor_secondary_controller_experiment.md`
- **内容**:
  1. 実験目的（Region B 自律運用の検証）
  2. 事前状態（各ノードの LINSTOR/DRBD ステータス）
  3. 各 Phase の実行結果（コマンド出力、成功/失敗、所要時間）
  4. 分断中の VM 操作テスト結果
  5. 復旧後の状態確認結果（split-brain の有無、再同期状況）
  6. 成功基準の達成状況
  7. 課題・改善点（本番運用化に向けた考察）
- **添付**: 主要なコマンド出力は `report/attachment/` に保存
