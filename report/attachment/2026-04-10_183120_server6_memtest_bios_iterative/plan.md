# 6号機 BIOS メモリ設定変更 + メモリテスト反復計画

## Context

6号機 (Supermicro X11DPU) の DIMM P2-DIMMA1 に Uncorrectable Memory エラーが報告されている。既に BIOS で Hard PPR が適用済みで、BIOS MRC が P2-DIMMA1 を自動無効化中。現在は P1-DIMMA1 (~15GB) のみで稼働。

**目的:** BIOS のメモリ関連設定を段階的に変更し、各設定でメモリテストを実行して、設定変更が DIMM 挙動に与える影響を体系的に調査する。

## ツール選定: Memtest86+ v8.00

- オープンソース・無料、UEFI ブート対応
- ダウンロード: `https://memtest.org/download/v8.00/mt86plus_8.00_x86_64.grub.iso.zip`

## BIOS メモリ関連設定一覧

**パス:** `Advanced > Chipset Configuration > North Bridge > Memory Configuration`

| 設定 | 現在値 | 選択肢 | テスト対象 |
|------|--------|--------|-----------|
| PPR Type | Hard PPR | Disabled / **Hard PPR** / Soft PPR | **Yes** |
| SDDC | Disabled | Enabled / **Disabled** | **Yes** |
| Memory Rank Sparing | Disabled | Enabled / **Disabled** | **Yes** |
| Memory Frequency | Auto | **Auto** / 1866 / 2133 / 2400 / 2666 | **Yes** |
| Patrol Scrub | Enabled | **Enabled** / Disabled | No (既に最適) |
| Failing DIMM Lockstep | Disabled | Enabled / **Disabled** | No (2 DIMM必要) |

## テストマトリクス

| テスト# | 変更設定 | 変更値 |
|---------|---------|--------|
| **T1** | (なし — ベースライン) | 現在設定のまま |
| **T2** | PPR Type | Disabled |
| **T3** | PPR Type | Soft PPR |
| **T4** | SDDC | Enabled |
| **T5** | Memory Frequency | 1866 |
| **T6** | Memory Rank Sparing | Enabled |

## 実行手順

### Phase 0: 事前準備
### Phase 1: ISO ダウンロード・VirtualMedia マウント
### Phase 2: 初回 BIOS 設定 + Boot Order 変更
### Phase 3: テスト T1 実行・結果記録 (ベースライン)
### Phase 4: 設定変更 + テスト反復 (T2〜T6)
### Phase 5: 結果判定・クリーンアップ

## サブエージェント委譲計画 (全て Sonnet モデルで実行)

| エージェント | 担当 |
|------------|------|
| Agent A | Phase 0 + Phase 1: 事前準備、ISO ダウンロード、VirtualMedia マウント |
| Agent B | Phase 2 + T1: BIOS Boot Order 変更 + ベースラインテスト |
| Agent C | T2: PPR Type = Disabled |
| Agent D | T3: PPR Type = Soft PPR |
| Agent E | T4: SDDC = Enabled |
| Agent F | T5: Memory Frequency = 1866 |
| Agent G | T6: Memory Rank Sparing = Enabled |
| Agent H | Phase 5: BIOS 復元、Boot Order 復元、VirtualMedia アンマウント、レポート作成 |

## スクリーンショット保存ルール

各テストで以下のタイミングでスクリーンショットを撮影し、最終レポートに含める:

| タイミング | ファイル名パターン |
|-----------|-------------------|
| POST DIMM メッセージ | `tN-post-dimm.png` |
| BIOS 設定変更後 | `tN-bios-setting.png` |
| memtest86+ 起動直後 | `tN-memtest-start.png` |
| memtest86+ 1パス完了 | `tN-memtest-result.png` |
