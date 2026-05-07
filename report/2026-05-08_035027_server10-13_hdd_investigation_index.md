# 10-13号機 HDD 調査レポート一覧 (2026-05-03 〜 2026-05-08)

- **実施日時**: 2026年5月8日 03:50 JST

## 添付ファイル

- [実装プラン](attachment/2026-05-08_035027_server10-13_hdd_investigation_index/plan.md)

## 前提・目的

10-13号機 (Nutanix OEM, Supermicro X10DRT-P) のデータ HDD については、2026-05-03 のストレージ棚卸しから 2026-05-08 の Phase 8 完全閉鎖確定まで、**合計 9 本のレポート**に調査経緯が分散して記録されている。

最終結論は「Hitachi firmware の opcode 別 write filter (ASC=0x81) によって恒久的に書き込み不可、Issue #61 LINSTOR 構築は wontfix 確定」。

本レポートはこれら 9 本の調査レポートを時系列順にインデックス化し、将来このトピックを参照する際 (別ハードウェアでの再発調査、Toshiba SSD 単独運用への切替時、関連スキル更新時など) のエントリポイントを提供することを目的とする。

## 環境情報

- **対象サーバ**: 10-13号機 (Nutanix OEM, Supermicro X10DRT-P, 2U Twin Server CSE-217HQ+)
  - 10号機: NX-1065-G5
  - 11-13号機: NX-3060-G5
- **対象ドライブ**: Seagate DKS5x シリーズ (10K Enterprise Performance, Hitachi/Nutanix OEM firmware)
  - 10/11号機: 512B セクタ (即利用可)
  - 12/13号機: Nutanix T10-PI 520B セクタ (`sg_format` で 512B リフォーマット必要)
- **関連 issue**: #61 (10-13号機 LINSTOR 構築 — wontfix 完全確定)

## レポート一覧 (時系列順)

| 日付 (JST) | Phase | レポート | 要約 | 結論 |
|------------|-------|----------|------|------|
| 2026-05-03 22:47 | — | [ストレージ構成インベントリ](2026-05-03_224709_server10-13_storage_inventory.md) | 10-13号機ストレージ棚卸し。10/11は512B即可、12/13はNutanix T10-PI 520Bで`sg_format`必須と判定 | 確認完了 |
| 2026-05-04 03:41 | Phase 1 | [LINSTOR セットアップ — HW Error でギブアップ](2026-05-04_034112_server10-13_linstor_giveup_hw_error.md) | `sg_format`成功も全8本データHDDのwriteがASC=0x81 (Hardware Error) で全ブロック。ZFS pool 作成不能 | ギブアップ |
| 2026-05-04 10:02 | Phase 2 | [Phase 2 完全ギブアップ](2026-05-04_100222_server10_hw_error_phase2_giveup.md) | 6 sub-phase (情報収集/state init/HBA介入/再format/SANITIZE/SED) 試行。WRITE系reject、FORMAT/SANITIZE通る → opcode別フィルタ仮説確立 | opcodeフィルタ確定 |
| 2026-05-04 19:11 | Phase 3 | [Phase 3 リモート全手段ギブアップ + WRITE SAME(16) 新発見](2026-05-04_191138_server10_hw_err_phase3.md) | SCSI opcode全網羅で **WRITE SAME(16) (0x93) は任意パターン書込み可能**を新発見。Linuxブロック層で実用化困難 | リモート全閉鎖 |
| 2026-05-07 05:38 | Phase 4 | [Phase 4 AOS local boot 試行 + prot_mask 検証](2026-05-07_053810_server10_hw_err_phase4.md) | Phoenix Foundation ISO loopback boot 試行。device swap で UEFI Boot Order 破綻。`mpt3sas.prot_mask=1` は opcode filter と無関係で bypass 不能 | bypass 不可 |
| 2026-05-07 18:47 | Phase 5 | [Phase 5 Phoenix CE installer 確認](2026-05-07_184741_server10_hw_err_phase5.md) | AOS boot 完走し Phoenix shell 到達。dd でも Remote I/O error。**Phoenix CE installer ですら write 不可** → host OS 側で bypass 不能と最終確認 | firmware level 確定 |
| 2026-05-08 01:29 | Phase 6 | [Phase 6 Hitachi 由来分析 + SED/Vendor MODE 棄却](2026-05-08_012907_server10-13_phase6_hitachi_origin_analysis.md) | 物理ラベルから PSID 取得し SED Lock + PSID Revert 試行も全 7 本 TCG 非対応。Vendor MODE pages (0x00/0x23/0x38) reset でも変化なし | SED 仮説棄却 |
| 2026-05-08 02:50 | Phase 7 | [Phase 7 Seagate firmware flash — OEM Lock](2026-05-08_025037_server10-13_phase7_seagate_fw_oem_lock.md) | Seagate 公式 EP10K v8 LOD (N005) flash 試行。全 4 mode (Segmented/Deferred/Full/Buffer ID) で `ASC=0x26 ASCQ=0x99` (model identifier mismatch) reject | flash 不可 |
| 2026-05-08 03:36 | Phase 8 | [Phase 8 openSeaChest OSS + sg_write_buffer 全 mode 網羅](2026-05-08_033632_server10-13_phase8_openseachest_oss_retry.md) | OSS openSeaChest v26.03.1 と sg_write_buffer で SCSI WRITE BUFFER mode 全 8 種網羅。全て drive verify 段階で model mismatch reject | **全経路閉鎖最終確定** |

## 結論

- 公開 SCSI 仕様の範囲では Hitachi firmware の opcode filter は解除不能
- microcode download も OEM signature check (LOD ヘッダ vs INQUIRY model `DKS5L-J1R2SS`) で全て reject
- Issue #61 (10-13号機 LINSTOR 構築) は wontfix 最終確定 (2026-05-08 Phase 8)
- 10-13号機の LINSTOR 構築は Toshiba SSD 単独運用で代替検討する

### 関連メモリ (Claude Code memory)

- `server10-13_data_disks_write_blocked.md` — Phase 6-8 の最終結論まとめ
- `server10-13_data_disks.md` — 10/11 は 512B 即可、12/13 は 520B 要 `sg_format`
- `server10_nutanix_oem.md` — Nutanix OEM 共通の制約 (Supermicro 公式 FW silent reject 等)
- `server10_lsi_hba_oprom.md` — OS ディスク認識に LSI HBA OPROM=Enabled が必須

## 参考: 関連するが本一覧には含めないレポート

OS ディスク (LSI HBA) のブート復旧はデータ HDD 調査とは別文脈のため本一覧から除外:

- [10号機 disk first boot 復旧 + VirtualKeyboard 経由キー送信実装](2026-05-02_060639_server10_disk_first_boot_recovery.md) — LSI HBA OPROM 有効化で OS boot 復旧

## 再現方法

本レポートはインデックス (まとめ) であり再現対象の実験は含まない。各 Phase の再現手順は個別レポート内の「再現方法」セクションを参照すること。
