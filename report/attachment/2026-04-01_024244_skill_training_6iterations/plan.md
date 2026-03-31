# スキルトレーニング計画 (10 イテレーション)

## Context

全14スキルを4-9号機で繰り返し実行し、スキル定義・スクリプトの品質を向上させる。各イテレーションで発見された問題を修正し、次のイテレーションで検証する。段階的に複雑度を上げ、最終的にはos-setup含む全操作を実行する。

### 改善目標
1. **スキルの正確性**: スキル定義の誤り・不足を発見し修正
2. **待ち時間の最適化**: DRBD resync、OS インストール、電源ON/OFF 等の待ち時間中に並行作業を実行してスループットを最大化
3. **エラーハンドリング**: 障害時のリカバリ手順の検証と改善

### 待ち時間最適化戦略
- **DRBD resync 待ち (数分〜99分)**: resync 中に他スキルの status 確認やローカルスキル (dell-fw-download, tftp) を実行
- **OS インストール待ち (30-60分)**: SOL 監視をバックグラウンドで実行し、別サーバの操作を並行実施
- **電源 ON 後の起動待ち (2-5分)**: ssh-wait.sh をバックグラウンドで実行し、他の status チェックを並行実施
- **PERC ジョブ完了待ち (再起動必要)**: 再起動中に他サーバの操作を実行
- **Bash(run_in_background=true)** を活用し、長時間待ちの操作を非同期化

## 対象スキル一覧

| # | スキル | 対象 | 主な操作 |
|---|--------|------|----------|
| 1 | playwright | ローカル | セットアップ確認 |
| 2 | dell-fw-download | ローカル | FWダウンロード+BIN展開 |
| 3 | tftp-server | ローカル | Docker TFTP起動/停止 |
| 4 | idrac7 | 7-9号機 | getsysinfo/getconfig/jobqueue |
| 5 | idrac7-fw-update | 7-9号機 | FWバージョン確認 (既に最新) |
| 6 | perc-raid | 7-9号機 | RAID status/VD作成削除 |
| 7 | bios-setup | 4-6号機 | screenshot/enter/verify |
| 8 | ib-switch | 4号機経由 | status/ports/show/enable-cmd |
| 9 | linstor-bench | 両リージョン | preflight/fioベンチマーク |
| 10 | linstor-migration (live) | リージョン内 | ライブマイグレーション |
| 11 | linstor-migration (cold) | リージョン間 | コールドマイグレーション |
| 12 | linstor-migration (region) | 両リージョン | リージョン廃止/追加 |
| 13 | linstor-node-ops | 両リージョン | fail/recover/depart/rejoin |
| 14 | os-setup | 両リージョン | OS再インストール+PVEセットアップ |

## イテレーション計画

### Iteration 1: 全スキル status/read-only (45-60分)

全スキルの読み取り専用操作を実行し、ベースラインを確立する。

1. **playwright**: import確認、バージョン表示
2. **idrac7**: 7-9号機で getsysinfo, getconfig (cfgIpmiLan), jobqueue view
3. **idrac7-fw-update**: バージョン確認 (2.65.65.65)
4. **perc-raid**: 7-9号機で racadm raid get vdisks/pdisks
5. **bios-setup**: 4-6号機で KVM screenshot (BIOS に入らない)
6. **ib-switch**: status, ports
7. **linstor-bench**: preflight (SMARTチェック)
8. **linstor-migration**: linstor-multiregion-status.sh, resource list
9. **linstor-node-ops**: node list, drbdsetup status
10. **os-setup**: phase status確認
11. **dell-fw-download**: スキップ (iteration 2から)
12. **tftp-server**: スキップ (iteration 2から)

### Iteration 2: ローカルスキル + ライブマイグレーション (60-90分)

1. **dell-fw-download**: FW BINダウンロード + firmimg.d7 抽出
2. **tftp-server**: Docker起動 → UDPテスト → 停止
3. **playwright**: ダウンロードスクリプト動作確認 (dell-fw-downloadで検証済み)
4. **linstor-bench**: テストVM (VMID 9900) 作成、短時間fio (runtime=10s)
5. **linstor-migration (live)**: Region A内でVM 9900をライブマイグレーション
6. 残りのスキル: iteration 1と同じstatus確認
7. テストVM削除

### Iteration 3: BIOS/PERC操作 + fail/recover (90-120分)

1. **bios-setup**: 5号機でBIOS進入 → 全タブscreenshot → 保存せず終了
2. **perc-raid**: 8号機でVNC screenshot (PERC状態確認)
3. **linstor-node-ops (fail+recover)**: 6号機を電源断 → 復旧 → DRBD resync待ち
4. **ib-switch**: enable-cmd show running-config
5. 残りのスキル: status確認 + iteration 2のローカルスキル再実行

### Iteration 4: コールドマイグレーション + PERC VD操作 (120-150分)

1. テストVM 9900 作成 (Region A)
2. **linstor-bench**: フルfioベンチマーク (runtime=60s)
3. **linstor-migration (cold)**: VM 9900 を Region A → Region B へコールドマイグレーション
4. **perc-raid**: 8号機で非OSディスクにRAID-0 VD作成 → racadm確認 → VD削除
5. **linstor-migration (live)**: Region B内でVM 9900をライブマイグレーション
6. テストVM削除

### Iteration 5: ノード離脱/復帰 + DR設定 (150-180分)

1. テストVM 9900 作成 (Region A)
2. **linstor-migration (cold)**: VM 9900 を Region B へコールドマイグレーション
3. **linstor-migration (region)**: setup-dr で Region A に DR レプリカ追加
4. **linstor-node-ops (depart+rejoin)**: 9号機を正常離脱 → 再参加 → フルresync
5. **bios-setup**: 4号機でBIOS設定値verify (Boot Order等)
6. テストVM削除

### Iteration 6: リージョン廃止/追加 (180-240分)

1. テストVM 9900 作成 (Region A)
2. **linstor-migration (cold)**: VM 9900 を Region B へ移動
3. **linstor-migration (region)**: Region A 廃止 (全リソースをBへ移動)
4. **linstor-migration (region)**: Region A 再追加 + DR レプリカ設定
5. **linstor-migration (cold)**: VM 9900 を Region A へ戻す
6. 全スキル status 再確認
7. テストVM削除

### Iteration 7: コントローラノード障害テスト (120-150分)

1. **linstor-node-ops (fail+recover)**: 4号機 (LINSTORコントローラ) を電源断
2. Region B で linstor 操作がエラーになることを確認
3. 4号機復旧 → DRBD resync → コントローラ復帰確認
4. **bios-setup**: 6号機でBIOS設定変更 (安全な設定のみ) + 保存
5. **linstor-migration (live)**: テストVMでライブマイグレーション検証
6. **ib-switch**: 全showコマンドバリアント実行

### Iteration 8: os-setup 部分実行 + PERC VNC操作 (120-180分)

1. **os-setup**: 9号機で Phase 1-3 のみ (ISOダウンロード+preseed生成+リマスタ) — インストール開始せず
2. **perc-raid**: 8号機でVNC経由のVD作成 (racadmではなくVNC UI操作)
3. **dell-fw-download + tftp-server**: フルワークフロー (DL → 展開 → TFTP配信確認)
4. **bios-setup**: 5号機で設定変更+保存+再起動確認
5. 全スキル status 再確認

### Iteration 9: os-setup フル実行 (Region B) (180-300分)

1. **linstor-node-ops (depart)**: 9号機をLINSTORから正常離脱
2. **os-setup**: 9号機でフルOS再インストール (preseed → Debian → PVE)
3. **perc-raid**: 9号機のRAID構成確認 (os-setup後)
4. **idrac7**: 9号機の設定確認
5. **linstor-node-ops (rejoin)**: 9号機をLINSTORクラスタに再参加
6. **linstor-migration (live)**: Region B内マイグレーション検証
7. **linstor-bench**: 9号機含むベンチマーク

### Iteration 10: os-setup フル実行 (Region A) + 全スキル最大深度 (300-420分)

1. テストVM 9900 を Region B へ退避
2. **linstor-node-ops (depart)**: 6号機をLINSTORから正常離脱
3. **os-setup**: 6号機でフルOS再インストール
4. **bios-setup**: 6号機でBIOS設定確認
5. **linstor-node-ops (rejoin)**: 6号機をクラスタに再参加
6. **linstor-migration (cold)**: VM 9900 を Region A へ戻す
7. **linstor-migration (region)**: DR レプリカ再設定
8. **linstor-bench**: 全リージョンフルベンチマーク
9. **ib-switch**: 全コマンド実行
10. 最終 status 確認 → 全スキル正常動作をレポート

## 各イテレーション共通手順

### 事前チェック (毎回実行)
```
./pve-lock.sh status          # ロック状態
./issue.sh list               # 未完了課題
linstor node list             # 全ノードOnline
linstor resource list         # 全リソースUpToDate
```

### 事後処理 (毎回実行)
1. 発見された問題を `./issue.sh add` で登録
2. 問題の修正 (スキルSKILL.md、スクリプト、設定)
3. 修正内容をコミット
4. `report/` にイテレーションレポート作成
5. 次イテレーションの事前チェックで修正を検証

## サーバ選択優先順位 (破壊的操作用)

1. 9号機 (Region B satellite、最低リスク)
2. 6号機 (Region A satellite、非コントローラ)
3. 8号機 (Region B satellite)
4. 5号機 (Region A satellite)
5. 7号機 (Region B satellite)
6. 4号機 (LINSTORコントローラ、iteration 7のみ)

## 検証項目

| チェック | コマンド | 期待値 |
|---------|---------|--------|
| 全ノードOnline | `linstor node list` | 6ノードONLINE |
| リソースUpToDate | `linstor resource list` | Inconsistent/Outdated なし |
| PVEクラスタ正常 | `pvecm status` | Quorate: Yes |
| IBポート正常 | `sx6036-console.py ports` | 6ポート Active QDR |
| iDRAC FW | `racadm getsysinfo` | 2.65.65.65 |
| PERC VD正常 | `racadm raid get vdisks` | VD0 Optimal |
| pve-lock解放 | `./pve-lock.sh status` | Not locked |

## レポート計画

### レポート構成
10イテレーション全体で **1本のサマリレポート** + **各イテレーションの詳細セクション** として作成する。

### ファイル名
`report/<timestamp>_skill_training_10iterations.md`

### 添付ファイル
`report/attachment/<レポートファイル名>/`
- `plan.md` — 本計画ファイル (必須)
- `iteration_N_fixes.diff` — 各イテレーションで適用した修正のdiff (修正があった場合)
- `iteration_N_screenshots/` — スクリーンショット (BIOS, PERC VNC等)

### レポート構造
```markdown
# スキルトレーニング (10イテレーション) レポート

- **実施日時**: 開始〜完了
- **対象**: 4-9号機、全14スキル

## 添付ファイル
- [実装プラン](attachment/.../plan.md)

## 前提・目的
- 全スキルの品質向上と待ち時間最適化

## 環境情報
- サーバ構成、OS/PVE/LINSTORバージョン

## サマリ
| Iteration | 実行スキル | 発見問題数 | 修正数 | 所要時間 |
|-----------|-----------|-----------|--------|---------|

## 発見・修正した問題の一覧
| # | 問題 | 発見Iter | 修正内容 | 修正ファイル |

## Iteration 1: status/read-only
### 実行結果
### 発見された問題
### 適用した修正

## Iteration 2: ...
(以下同様)

## 待ち時間最適化の成果
- 各イテレーションでの並行実行パターンと効果

## 結論・今後の課題

## クリーンアップ
```

### レポート作成タイミング
- 全10イテレーション完了後に最終レポートを作成
- 各イテレーション完了時に issue.sh で問題を登録し、修正をコミット (レポートは最後にまとめて書く)

## クリーンアップ (全イテレーション完了後)

1. テストVM (VMID 9900) が残っていれば削除
2. LINSTOR クラスタ状態の最終確認 (全ノード Online, 全リソース UpToDate)
3. **4-9号機を全台シャットダウン**:
   - 4-6号機: `./pve-lock.sh run ipmitool -I lanplus -H 10.10.10.2X -U claude -P Claude123 chassis power soft`
   - 7-9号機: `./pve-lock.sh run ipmitool -I lanplus -H 10.10.10.2X -U claude -P Claude123 chassis power soft`
   - シャットダウン完了確認: `ipmitool ... chassis power status` で Off を確認
4. tmp/<session-id>/ の一時ファイル削除

## 重要ファイル

- `config/linstor.yml` — LINSTOR構成
- `config/server[4-9].yml` — サーバ設定
- `.claude/skills/*/SKILL.md` — 各スキル定義
- `scripts/linstor-multiregion-status.sh` — 状態確認
- `scripts/linstor-migrate-live.sh` — ライブマイグレーション
- `scripts/linstor-migrate-cold.sh` — コールドマイグレーション
- `scripts/os-setup-phase.sh` — OSセットアップ
