# Phase 1: 監視・診断 トレーニングレポート

- **実施日時**: 2026年4月4日 02:00 〜 02:30 JST
- **対象**: Phase 1 (Iteration 1-9)

## 添付ファイル

- [実装プラン](attachment/2026-04-04_023058_phase1_monitoring_baseline/plan.md)

## 前提・目的

- 背景: リージョン A+B 全体操作トレーニング (117 イテレーション) の Phase 1
- 目的: 全6ノードの稼働状態を確認し、ベースラインを確立する。非破壊的読み取り操作のみ
- 前提条件: 前セッションで6号機 os-setup 完了 (2026-04-04)、Region B は電源 Off 状態

## 環境情報

| 項目 | Region A (4-6号機) | Region B (7-9号機) |
|------|-------------------|-------------------|
| ハードウェア | Supermicro X11DPU | Dell PowerEdge R320 |
| OS | Debian 13.3 (Trixie) | 同左 |
| PVE | 9.1.7 | 9.1.6 |
| カーネル | 6.17.13-2-pve | 同左 |
| ストレージ | LINSTOR/DRBD ZFS raidz1 | 同左 |
| iDRAC FW | - | 2.65.65.65 |

## イテレーション結果

### Iteration 1: 全環境ヘルスチェック

**手順**: 電源状態 + SSH + PVE クラスタ確認

| サーバ | 電源 | SSH | PVE クラスタ |
|--------|------|-----|-------------|
| 4号機 | On | OK | pvese-cluster1 メンバー |
| 5号機 | On | OK | pvese-cluster1 メンバー |
| 6号機 | On | **FAIL** (publickey) | 未参加 (quorum 2/3) |
| 7号機 | **Off** | FAIL | 確認不可 |
| 8号機 | **Off** | FAIL | 確認不可 |
| 9号機 | **Off** | FAIL | 確認不可 |

### Iteration 2: LINSTOR/DRBD 状態確認

| ノード | LINSTOR 状態 | DRBD | Auto-eviction |
|--------|-------------|------|---------------|
| ayase-web-service-4 | Online (COMBINED) | UpToDate | - |
| ayase-web-service-5 | Online (SATELLITE) | UpToDate | - |
| ayase-web-service-6 | **未登録** | - | - |
| ayase-web-service-7 | OFFLINE | - | Disabled |
| ayase-web-service-8 | OFFLINE | - | Disabled |
| ayase-web-service-9 | OFFLINE | - | **2026-06-02** |

- リソース: `pm-5b16a893` (pve4+pve5 のみ, UpToDate)
- ZFS プール: pve4/pve5 各 1.27 TiB / 1.81 TiB

### Iteration 3: BMC/iDRAC センサー・SEL

**Region A 温度 (安定)**:

| センサー | 4号機 | 5号機 | 6号機 |
|---------|-------|-------|-------|
| CPU1 Temp | 34C | 31C | 27C |
| CPU2 Temp | 28C | 25C | 28C |
| System Temp | 21C | 22C | 22C |
| Fan RPM | **8600-8900** | 4200-4300 | 4100-4400 |

- 4号機: ファン高回転 (他の約2倍)、シャーシ侵入検知
- 6号機: SEL 345件 (Unknown #0xfe が大半)、**DIMM エラーなし**
- 全サーバ: CMOS Battery Failed (既知の経年劣化)

**Region B** (電源 Off): Inlet Temp 20-22C、他は na

### Iteration 4-6: LINSTOR マルチリージョンステータス (3回実施)

3回とも同一結果 (再現性確認済み):

| 設定項目 | 期待値 | 実際 | 一致 |
|---------|--------|------|------|
| pve4 Aux/site | region-a | region-a | OK |
| pve5 Aux/site | region-a | region-a | OK |
| pve6 Aux/site | region-a | **未登録** | NG |
| pve7 Aux/site | region-b | region-b | OK |
| pve8 Aux/site | region-b | region-b | OK |
| pve9 Aux/site | region-b | **未設定** | NG |
| pve4-pve5 Protocol | C | C | OK |
| cross-region paths | 6ペア | 4ペア (pve6/9欠) | NG |

### Iteration 7-9: センサー再確認 + Region B 起動後確認

**再現性**: Region A 温度は Iteration 3 と ±3C 以内で安定。

**Region B 起動後** (Iteration 9):

| センサー | 7号機 | 8号機 | 9号機 |
|---------|-------|-------|-------|
| Inlet Temp | 20C | 21C | 20C |
| CPU Die Temp | 35C | 32C | 35C |
| Fan1A | 9600 RPM | 9600 RPM | 9600 RPM |
| Power | 126W | 126W | 126W |
| ECC/Memory | なし | なし | なし |

## 再現性評価

| 指標 | Iter 1-3 | Iter 4-6 | Iter 7-9 | 結果 |
|------|----------|----------|----------|------|
| ノード状態 | 一貫 | 一貫 (3回同一) | 一貫 | **再現性確認済み** |
| 温度偏差 | ±0C | - | ±3C | **安定** |
| LINSTOR 状態 | 一貫 | 一貫 | 一貫 | **再現性確認済み** |

## 発見した問題と改善

| # | 問題 | 影響 | 対策 | 反映先 |
|---|------|------|------|--------|
| 1 | pve6 SSH 鍵未配置 | SSH 接続不可 | pve4 経由で配置完了 | `os-setup` スキル Phase 6 に注記追加済み |
| 2 | pve6 LINSTOR 未登録 | マルチリージョン不完全 | Phase 8 以降で登録 | - |
| 3 | pve9 Aux/site 未設定 | マルチリージョン設定不完全 | 要修正 | - |
| 4 | pve9 Auto-eviction 有効 | リソース意図せぬ退去リスク | 無効化必要 | - |
| 5 | 4号機ファン高回転 | 安定だが監視要 | ベースラインとして記録 | - |
| 6 | 6号機 SEL 345件 | SEL 溢れリスク | クリア推奨 | - |
| 7 | Issue #41 DIMM エラー | SEL にエラーなし | 解消の可能性 | Issue 更新検討 |

## スキル/ドキュメント変更

- `.claude/skills/os-setup/SKILL.md`: Phase 6 ステップ 3 に「両プラットフォーム共通」の注記追加。Supermicro でも SOL 経由 SSH 鍵配置が必須であることを明記

## 参考

- [6号機 os-setup 完了レポート](2026-04-04_002107_server6_os_setup_complete.md)
