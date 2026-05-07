# 10-13号機 HDD 調査レポート一覧 (まとめレポート作成)

## Context

10-13号機 (Nutanix OEM, Supermicro X10DRT-P) のデータ HDD は、Hitachi firmware の opcode 別 write filter (ASC=0x81) によって恒久的に書き込み不可と判明し、Issue #61 LINSTOR 構築は wontfix 確定 (2026-05-08)。
2026-05-03 のストレージ棚卸しから 2026-05-08 の Phase 8 完全閉鎖確定まで、合計 9 本のレポートに調査経緯が分散して記録されている。

将来このトピックを参照する際 (例: 別ハードウェアでの再発調査、対応する SSD 単独運用への切替時) に、関連レポートを一覧で辿れるインデックスレポートを `report/` 配下に作成する。

## 作成するレポート

- **パス**: `/home/ubuntu/projects/pvese/report/<TIMESTAMP>_server10-13_hdd_investigation_index.md`
- **タイトル**: `10-13号機 HDD 調査レポート一覧 (2026-05-03 〜 2026-05-08)`
- **TIMESTAMP**: `TZ=Asia/Tokyo date +%Y-%m-%d_%H%M%S` で取得 (LLM 推測禁止 — REPORT.md ルール)

## 構成

### 1. メタ情報セクション
- 実施日時 (取得した TIMESTAMP を JST で記載)
- 添付ファイル: 本プランファイル (`attachment/<basename>/plan.md`)

### 2. 前提・目的セクション
- 10-13号機 HDD 調査が 2026-05-03 〜 2026-05-08 にかけて 9 本のレポートに分散
- 結論: ASC=0x81 firmware lock により全経路閉鎖、Issue #61 wontfix
- 本レポートの目的: 各調査レポートへのインデックスを提供

### 3. 環境情報セクション
- 対象サーバ: 10-13号機 (Nutanix OEM NX-1065-G5 / NX-3060-G5, Supermicro X10DRT-P)
- 対象ドライブ: Seagate DKS5x シリーズ (10K Enterprise Performance, Hitachi/Nutanix OEM firmware)
- 関連 issue: #61 (10-13号機 LINSTOR 構築 — wontfix)

### 4. レポート一覧表 (本体)

時系列順 (2026-05-03 → 2026-05-08) の表形式:

| 日付 (JST) | Phase | レポート (リンク) | 要約 | 結論 |
|------------|-------|-------------------|------|------|
| 2026-05-03 22:47 | — | [ストレージ構成インベントリ](2026-05-03_224709_server10-13_storage_inventory.md) | 10-13号機ストレージ棚卸し。10/11は512B即可、12/13はNutanix T10-PI 520Bで`sg_format`必須 | 確認完了 |
| 2026-05-04 03:41 | Phase 1 | [LINSTOR セットアップ — HW Error でギブアップ](2026-05-04_034112_server10-13_linstor_giveup_hw_error.md) | `sg_format`成功も全8本データHDDのwriteがASC=0x81でブロック。ZFS pool作成不能 | ギブアップ |
| 2026-05-04 10:02 | Phase 2 | [Phase 2 完全ギブアップ](2026-05-04_100222_server10_hw_error_phase2_giveup.md) | 6 sub-phase試行で opcode別フィルタ仮説確立 (WRITE系reject、FORMAT/SANITIZE通る) | opcodeフィルタ確定 |
| 2026-05-04 19:11 | Phase 3 | [Phase 3 リモート全手段ギブアップ](2026-05-04_191138_server10_hw_err_phase3.md) | SCSI opcode全網羅で WRITE SAME(16) (0x93) 任意パターン書込み可能を新発見。実用化は困難 | リモート全閉鎖 |
| 2026-05-07 05:38 | Phase 4 | [Phase 4 AOS local boot 試行 + prot_mask発見](2026-05-07_053810_server10_hw_err_phase4.md) | Phoenix Foundation ISO loopback boot試行。`mpt3sas.prot_mask=1`はopcode filterと無関係でbypass不能 | bypass不可 |
| 2026-05-07 18:47 | Phase 5 | [Phase 5 Phoenix CE installer 確認](2026-05-07_184741_server10_hw_err_phase5.md) | AOS boot完走しPhoenix shell到達も dd で Remote I/O error。Phoenix CEからもwrite不可 | firmware level確定 |
| 2026-05-08 01:29 | Phase 6 | [Phase 6 Hitachi 由来 + SED/Vendor MODE 棄却](2026-05-08_012907_server10-13_phase6_hitachi_origin_analysis.md) | PSID取得しSED Lock + PSID Revert試行も 7本全てTCG非対応。Vendor MODE pages reset でも変化なし | SED仮説棄却 |
| 2026-05-08 02:50 | Phase 7 | [Phase 7 Seagate firmware flash — OEM Lock](2026-05-08_025037_server10-13_phase7_seagate_fw_oem_lock.md) | Seagate公式EP10K v8 LOD (N005) flash試行。全4 modeで `ASC=0x26 ASCQ=0x99` (model mismatch) reject | flash不可 |
| 2026-05-08 03:36 | Phase 8 | [Phase 8 openSeaChest OSS + sg_write_buffer 全mode](2026-05-08_033632_server10-13_phase8_openseachest_oss_retry.md) | OSS openSeaChest v26.03.1とsg_write_buffer mode全8種網羅。全て model mismatch で reject | **全経路閉鎖最終確定** |

### 5. 結論セクション

- 公開SCSI仕様の範囲では Hitachi firmware の opcode filter は解除不能
- Issue #61 wontfix 最終確定 (2026-05-08 Phase 8)
- LINSTOR 構築は Toshiba SSD 単独運用で代替検討
- 関連メモリ: [server10-13_data_disks_write_blocked.md](../memory/server10-13_data_disks_write_blocked.md)

### 6. 参考情報

- OS ディスク (LSI HBA) のブート復旧については別文脈のため本一覧から除外:
  - 参考: [2026-05-02_060639_server10_disk_first_boot_recovery.md](2026-05-02_060639_server10_disk_first_boot_recovery.md)
- 関連 CLAUDE.md / メモリ:
  - `[server10_lsi_hba_oprom.md]` (LSI HBA OPROM 必須)
  - `[server10-13_data_disks.md]` (10/11 は 512B 即可、12/13 は 520B 要 sg_format)
  - `[server10-13_data_disks_write_blocked.md]` (Phase 6-8 結論)

## 添付ファイル

REPORT.md ルールに従い、本プランファイルを `report/attachment/<basename>/plan.md` にコピーして添付する。

```sh
mkdir -p report/attachment/<TIMESTAMP>_server10-13_hdd_investigation_index/
# Read ツールで /home/ubuntu/.claude/plans/10-13-hdd-shimmering-galaxy.md を読み
# Write ツールで report/attachment/<basename>/plan.md に書く (.claude/ はセンシティブパスのため cp 不可)
```

## 作業手順

1. `TZ=Asia/Tokyo date +%Y-%m-%d_%H%M%S` でタイムスタンプ取得
2. `report/<TIMESTAMP>_server10-13_hdd_investigation_index.md` を Write
3. `mkdir -p report/attachment/<basename>/`
4. プランファイルを Read → Write で `attachment/<basename>/plan.md` にコピー
5. PostToolUse hook により Discord 通知が自動で飛ぶ

## 検証

- レポートのリンクが全て有効な相対パスになっていること (`report/` 起点)
- 表が時系列順 (2026-05-03 → 2026-05-08) になっていること
- Phase 番号 (Phase 1 〜 Phase 8) と日付が REPORT.md の事実関係と一致すること

## 修正対象ファイル (Write のみ、Edit なし)

- `report/<TIMESTAMP>_server10-13_hdd_investigation_index.md` (新規)
- `report/attachment/<TIMESTAMP>_server10-13_hdd_investigation_index/plan.md` (新規)
