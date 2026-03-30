# LINSTOR セカンダリコントローラ実験 — Region B 自律運用テスト

- **実施日時**: 2026年3月30日 17:09 (JST)
- **所要時間**: 約20分

## 添付ファイル

- [実装プラン](attachment/2026-03-30_080923_linstor_secondary_controller_experiment/plan.md)

## 前提・目的

### 背景

LINSTOR コントローラは Region A の pve4 (10.10.10.204) 1台のみで稼働。Region B (pve7/8/9) はサテライトノードとして管理されている。Region A との通信が切れた場合、DRBD データプレーンは継続するが、LINSTOR 管理操作（VM 起動・マイグレーション・リソース操作）が不可能になる。

### 目的

Region B にセカンダリ（休眠）コントローラを配置し、ネットワーク分断時に Region B が自律的に VM 運用を継続できるか検証する。

### アプローチ選定

| 方式 | 判定 | 理由 |
|------|------|------|
| DRBD-Reactor HA (公式推奨) | 不適 | linstor_db の quorum が Region A 側に残るため、分断時に Region B でコントローラを昇格できない |
| 完全独立クラスタ | 過剰 | 既存スクリプト・マルチリージョン構成の大幅改修が必要 |
| **休眠コントローラ方式** | **採用** | 通常時は pve4 が全ノードを管理。pve7 に停止状態のコントローラ + DB スナップショットを配置し、分断時のみ起動 |

## 環境情報

| 項目 | Region A | Region B |
|------|----------|----------|
| ノード | pve4 (10.10.10.204), pve5 (205), pve6 (206) | pve7 (10.10.10.207), pve8 (208), pve9 (209) |
| LINSTOR コントローラ | pve4 (通常時) | pve7 (休眠、実験時のみ起動) |
| PVE クラスタ | 独立クラスタ | 独立クラスタ |
| IB サブネット | 192.168.100.0/24 | 192.168.101.0/24 |
| ストレージプール | ZFS (linstor_zpool) | ZFS (linstor_zpool) |
| PVE ストレージ | linstor-storage | linstor-storage-b |
| LINSTOR バージョン | 1.33.1 | 1.33.1 |
| OS | Debian 13.3 + PVE 9.1.6 | 同左 |

## 再現方法

### Phase 1: pve7 にコントローラをインストール

```bash
ssh pve7 "apt install -y linstor-controller"
ssh pve7 "systemctl disable linstor-controller"
ssh pve7 "systemctl stop linstor-controller"
# linstor-client も必要
ssh pve7 "apt install -y linstor-client"
```

### Phase 2: コントローラ DB スナップショットコピー

```bash
# pve4 コントローラ一時停止（DRBD データプレーンに影響なし）
ssh pve4 "systemctl stop linstor-controller"
# DB コピー (約 745KB、数秒で完了)
scp root@10.10.10.204:/var/lib/linstor/linstordb.mv.db root@10.10.10.207:/var/lib/linstor/
scp root@10.10.10.204:/var/lib/linstor/linstordb.trace.db root@10.10.10.207:/var/lib/linstor/
# pve4 コントローラ再起動
ssh pve4 "systemctl start linstor-controller"
```

### Phase 3: 動作確認（分断なし）

```bash
ssh pve4 "systemctl stop linstor-controller"
ssh pve7 "systemctl start linstor-controller"
sleep 15
ssh pve7 "linstor --controllers=10.10.10.207 node list"
# 確認後に元に戻す
ssh pve7 "systemctl stop linstor-controller"
ssh pve4 "systemctl start linstor-controller"
```

### Phase 4: ネットワーク分断

```bash
# Region B 各ノードで実行
for ip in 10.10.10.207 10.10.10.208 10.10.10.209; do
  ssh root@$ip "iptables -A INPUT -s 10.10.10.204 -j DROP"
  ssh root@$ip "iptables -A INPUT -s 10.10.10.205 -j DROP"
  ssh root@$ip "iptables -A INPUT -s 10.10.10.206 -j DROP"
  ssh root@$ip "iptables -A OUTPUT -d 10.10.10.204 -j DROP"
  ssh root@$ip "iptables -A OUTPUT -d 10.10.10.205 -j DROP"
  ssh root@$ip "iptables -A OUTPUT -d 10.10.10.206 -j DROP"
  ssh root@$ip "iptables -A INPUT -s 192.168.100.0/24 -j DROP"
  ssh root@$ip "iptables -A OUTPUT -d 192.168.100.0/24 -j DROP"
done
sleep 30
# PVE ストレージ設定をセカンダリコントローラに切替
ssh pve7 "sed -i 's/controller 10.10.10.204/controller 10.10.10.207/' /etc/pve/storage.cfg"
# セカンダリコントローラ起動
ssh pve7 "systemctl start linstor-controller"
```

### Phase 5: 分断復旧

```bash
ssh pve7 "systemctl stop linstor-controller"
ssh pve7 "sed -i 's/controller 10.10.10.207/controller 10.10.10.204/' /etc/pve/storage.cfg"
# iptables ルール削除（-D で個別削除）
for ip in 10.10.10.207 10.10.10.208 10.10.10.209; do
  ssh root@$ip "iptables -D INPUT -s 10.10.10.204 -j DROP"
  ssh root@$ip "iptables -D INPUT -s 10.10.10.205 -j DROP"
  ssh root@$ip "iptables -D INPUT -s 10.10.10.206 -j DROP"
  ssh root@$ip "iptables -D OUTPUT -d 10.10.10.204 -j DROP"
  ssh root@$ip "iptables -D OUTPUT -d 10.10.10.205 -j DROP"
  ssh root@$ip "iptables -D OUTPUT -d 10.10.10.206 -j DROP"
  ssh root@$ip "iptables -D INPUT -s 192.168.100.0/24 -j DROP"
  ssh root@$ip "iptables -D OUTPUT -d 192.168.100.0/24 -j DROP"
done
```

## 実験結果

### Phase 0: 事前状態

- 全 6 ノード Online (pve4: COMBINED, pve5-9: SATELLITE)
- リソース: pm-5b16a893 (Region A: pve4+pve5), pm-d8dccaf4 (Region B: pve7+pve9) — 全 UpToDate
- Region B に VM なし → テスト用 VM 200 を pve7 に作成（linstor-storage-b, 8GB, cloud image）
- 全ノードの iptables: デフォルト ACCEPT のみ（カスタムルールなし）

### Phase 1: コントローラインストール — 成功

- pve7 に `linstor-controller` 1.33.1 + `linstor-client` 1.27.1 をインストール
- `systemctl disable` で自動起動無効化

### Phase 2: DB スナップショットコピー — 成功

- DB サイズ: 745KB (linstordb.mv.db)
- pve4 コントローラ停止 → DB コピー → 再起動: 数秒で完了
- コピー後、全 6 ノード Online を確認

### Phase 3: 動作確認（分断なし） — 成功

pve7 のセカンダリコントローラが DB スナップショットから起動し、全 6 ノードを認識:

```
| ayase-web-service-4 | COMBINED  | 10.10.10.204:3366 | Online |
| ayase-web-service-5 | SATELLITE | 10.10.10.205:3366 | Online |
| ayase-web-service-6 | SATELLITE | 10.10.10.206:3366 | Online |
| ayase-web-service-7 | SATELLITE | 10.10.10.207:3366 | Online |
| ayase-web-service-8 | SATELLITE | 10.10.10.208:3366 | Online |
| ayase-web-service-9 | SATELLITE | 10.10.10.209:3366 | Online |
```

リソース情報もスナップショットから正確に復元された。

### Phase 4: ネットワーク分断 — 成功

iptables で Region A への通信を遮断後、セカンダリコントローラを起動:

```
| ayase-web-service-4 | COMBINED  | OFFLINE (Auto-eviction at Disabled)            |
| ayase-web-service-5 | SATELLITE | OFFLINE (Auto-eviction at Disabled)            |
| ayase-web-service-6 | SATELLITE | OFFLINE (Auto-eviction at 2026-05-29 07:59:20) |
| ayase-web-service-7 | SATELLITE | Online                                         |
| ayase-web-service-8 | SATELLITE | Online                                         |
| ayase-web-service-9 | SATELLITE | Online                                         |
```

- Region A ノード: OFFLINE（期待通り）
- Region B ノード: Online
- Region B リソース (pm-d8dccaf4): pve7 InUse/UpToDate, pve9 UpToDate
- テスト VM 200: 分断後も稼働継続

### Phase 5: 分断中の VM 操作テスト

#### 初回マイグレーション失敗と原因

最初のライブマイグレーション (pve7 → pve9) は失敗:

```
could not connect to any LINSTOR controller at /usr/share/perl5/PVE/Storage/Custom/LINSTORPlugin.pm line 260
```

**原因**: PVE の `/etc/pve/storage.cfg` で `linstor-storage-b` の `controller` が `10.10.10.204` (pve4) にハードコードされていた。PVE LINSTOR プラグインは LINSTOR サテライトとは別に独自にコントローラに接続するため、分断中は接続できない。

**対策**: `storage.cfg` の `controller` を `10.10.10.207` (pve7) に変更。`/etc/pve/` は PVE クラスタ共有ファイルなので 1 箇所の変更で全ノードに反映。

#### マイグレーション成功

storage.cfg 修正後、全テスト成功:

| テスト | 結果 | 詳細 |
|--------|------|------|
| ライブマイグレーション (pve7 → pve9) | **成功** | 13秒、ダウンタイム 18ms |
| VM 停止 (pve9) | **成功** | 即座に停止 |
| VM 起動 (pve9) | **成功** | auto-promote 正常動作 |
| ライブマイグレーション (pve9 → pve7) | **成功** | 11秒、ダウンタイム 27ms |

### Phase 6: 分断復旧 — 成功

1. pve7 のセカンダリコントローラを停止
2. `storage.cfg` の controller を `10.10.10.204` に復元
3. iptables ルールを `-D` で個別削除
4. 30秒後に全 6 ノード Online を確認
5. 全リソース UpToDate
6. DRBD split-brain: なし (`drbdsetup status` で正常な Primary/Secondary 状態)

## 成功基準の達成状況

| # | 基準 | 結果 |
|---|------|------|
| 1 | 分断中に Region B コントローラが Region B ノードを Online として認識する | **達成** |
| 2 | 分断中に Region B 内で VM のライブマイグレーションが成功する | **達成** (storage.cfg 変更後) |
| 3 | 分断中に VM の停止・再起動が成功する | **達成** |
| 4 | 復旧後に Region A コントローラが全 6 ノードを管理できる | **達成** |
| 5 | DRBD クロスリージョン接続が split-brain なしで再同期する | **達成** |

## 発見事項と課題

### 重要な発見: PVE ストレージプラグインの controller 設定

PVE LINSTOR プラグイン (`LINSTORPlugin.pm`) は、LINSTOR サテライトの接続先とは独立に、`/etc/pve/storage.cfg` の `controller` フィールドで指定されたコントローラに接続する。分断時にセカンダリコントローラを起動するだけでは不十分で、**`storage.cfg` の controller IP も切り替える必要がある**。

### 本番運用化に向けた課題

1. **`storage.cfg` の自動切替**: 分断検知時に `storage.cfg` の controller を自動で切り替えるスクリプトが必要
2. **DB スナップショットの定期更新**: cron 等で定期的に pve4 → pve7 に DB をコピーするか、LINSTOR の H2 バックアップ API を利用
3. **分断検知の自動化**: Region A コントローラへの疎通を監視し、N 回連続失敗でセカンダリコントローラを起動するウォッチドッグ
4. **復旧手順の自動化**: Region A が復帰した際に、セカンダリコントローラの停止 + storage.cfg の復元を自動化
5. **分断中に作成されたリソースの整合性**: 分断中に新規 VM/リソースを作成した場合、DB スナップショットとの不整合が発生する可能性がある。復旧時に DB マージが必要

### 運用手順まとめ（手動フェイルオーバー）

**Region A 障害時:**
1. `ssh pve7 "sed -i 's/controller 10.10.10.204/controller 10.10.10.207/' /etc/pve/storage.cfg"`
2. `ssh pve7 "systemctl start linstor-controller"`

**Region A 復帰時:**
1. `ssh pve7 "systemctl stop linstor-controller"`
2. `ssh pve7 "sed -i 's/controller 10.10.10.207/controller 10.10.10.204/' /etc/pve/storage.cfg"`

## 結論

休眠コントローラ方式により、Region B はネットワーク分断時に自律的に VM 運用（ライブマイグレーション、停止・起動）を継続できることが実証された。PVE ストレージプラグインの controller 設定の切替が必要という重要な制約が判明したが、`/etc/pve/storage.cfg` の1行の変更で対応可能。
