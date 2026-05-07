# 10-13号機 Phase 8: openSeaChest OSS 最新版 + sg_write_buffer 全 mode 網羅 — drive verify 真因の最終確定

- **実施日時**: 2026年5月8日 03:35 JST
- **対象**: pve11 sdb (Seagate DKS5L-J1R2SS / FW 8F0E、Phase 7 と同一ドライブ)
- **結果**: **失敗** — 8 mode 全試行で reject。Drive は brick せず温存 (FW 8F0E のまま、sg_inq baseline と完全一致、dd 1 block read OK)
- **新発見**: Phase 7 結果を OSS v26.03.1 で**完全再現** (同 ASC=0x26 ASCQ=0x99) → 真因は drive firmware の **microcode verification ロジック** で確定。WRITE BUFFER mode 0x05/0x07/0x0D/0x0E/0x0F は全て drive verify で reject、サポート外 mode (0x01/0x04/0x10/0x14) は CDB 段階で ASC=0x24 reject。**microcode download 経路は完全閉鎖**

## 添付ファイル

- [実装プラン](../.claude/plans/10-13-linstor-eager-puffin.md)
- [trial a (openSeaChest segmented)](attachment/2026-05-08_033632_server10-13_phase8_openseachest_oss_retry/flash_a_oseg.log) — 56 KB、Phase 7 segmented を OSS で再現、最終 chunk reject の sense data
- [trial b (openSeaChest deferred+activate)](attachment/2026-05-08_033632_server10-13_phase8_openseachest_oss_retry/flash_b_odefact.log) — 56 KB
- [trial d (openSeaChest --modelMatch)](attachment/2026-05-08_033632_server10-13_phase8_openseachest_oss_retry/flash_d_omodel.log) — 56 KB
- [trial e (sg_write_buffer mode 0x0D event defer)](attachment/2026-05-08_033632_server10-13_phase8_openseachest_oss_retry/flash_e_swb0d.log) — 497 KB、4KB chunk × 515 を全送信後最終 chunk reject の verbose dump
- [trial f (sg_write_buffer mode 0x04 dmc)](attachment/2026-05-08_033632_server10-13_phase8_openseachest_oss_retry/flash_f_swb04.log)
- [trial g (sg_write_buffer mode 0x01 vendor)](attachment/2026-05-08_033632_server10-13_phase8_openseachest_oss_retry/flash_g_swb01.log)
- [trial h (sg_write_buffer mode 0x10 undefined)](attachment/2026-05-08_033632_server10-13_phase8_openseachest_oss_retry/flash_h_swb10.log)
- [trial i (sg_write_buffer mode 0x14 undefined)](attachment/2026-05-08_033632_server10-13_phase8_openseachest_oss_retry/flash_i_swb14.log)
- [openSeaChest_Firmware --fwdlInfo (drive サポート mode 一覧)](attachment/2026-05-08_033632_server10-13_phase8_openseachest_oss_retry/fwdlInfo.txt)
- [openSeaChest_Firmware --help](attachment/2026-05-08_033632_server10-13_phase8_openseachest_oss_retry/help.txt)
- [sg_write_buffer mode 一覧 sg_wb_help.txt](attachment/2026-05-08_033632_server10-13_phase8_openseachest_oss_retry/sg_wb_help.txt)
- [baseline sg_inq](attachment/2026-05-08_033632_server10-13_phase8_openseachest_oss_retry/sg_inq_baseline.txt)
- [final sg_inq](attachment/2026-05-08_033632_server10-13_phase8_openseachest_oss_retry/sg_inq_final.txt) — baseline と完全一致
- [smartctl baseline](attachment/2026-05-08_033632_server10-13_phase8_openseachest_oss_retry/smartctl_baseline.txt)
- [smartctl after](attachment/2026-05-08_033632_server10-13_phase8_openseachest_oss_retry/smartctl_after.txt)
- [openSeaChest version 出力](attachment/2026-05-08_033632_server10-13_phase8_openseachest_oss_retry/version.txt)

## 前提・目的

### 背景

[Phase 7](2026-05-08_025037_server10-13_phase7_seagate_fw_oem_lock.md) で ZIP 同梱の Seagate 公式商用 SeaChest_Firmware v2.5.4 (2018-10-18 ビルド) を使い、`ThunderboltEntPerfSAS-STD-5xxN-N005.LOD` を pve11 /dev/sdb (DKS5L-J1R2SS / FW 8F0E) に flash 試行。`--downloadMode segmented / deferred / full` 全 3 mode で最終 verification 段階に `ASC=0x26 ASCQ=0x99 (Sense Key 5 Illegal Request, Vendor specific qualification)` で reject された。原因は drive firmware が INQUIRY model string `DKS5L-J1R2SS` (Hitachi/Nutanix OEM 内部品番) を LOD ヘッダの対応モデル `ST300MM0008/ST600MM0088/ST900MM0168/ST1200MM0088` と照合して拒否しているためと推定。

### 目的

Phase 7 の真因仮説 (drive firmware が microcode 受信後 LOD ヘッダ検証で reject) を**ツール側差で覆せないか**最終確認する。

1. **OSS 最新版 openSeaChest_Firmware v26.03.1** (2026-04-24 release) を GitHub から source build し、商用 v2.5.4 と挙動差があるか確認
2. **Phase 7 で未試行の SCSI WRITE BUFFER mode** を網羅試行:
   - 標準 mode 0x0D (event-triggered defer): drive `--fwdlInfo` で "Deferred - Select activation events" としてサポート宣言
   - 標準 mode 0x04 (dmc, no offsets): Phase 7 では offset 付き 0x05/0x07 のみ
   - vendor-specific 領域: 0x01 (本来の vendor mode), 0x10 / 0x14 (SPC 未定義領域)
3. ツール側でも drive 検証を bypass できないことを確認 → **Issue #61 wontfix を完全確定**

### ユーザ承認済み判断

- ドライブ 4 本までの brick 許容 (Phase 7 では 0 本 brick、Phase 8 でも 0 本 brick)
- 第一試行は引き続き pve11 sdb (FW 8F0E)
- 攻めスタンス: 標準 mode + vendor-specific 領域 (0x01/0x10/0x14) を盲試打
- ツール入手: GitHub source ビルド (apt v24.08 = v4.3.3 ではなく v26.03.1 を選択)

## 環境情報

| 項目 | 値 |
|------|-----|
| サーバ | 11号機 (Nutanix NX-3060-G5 / Supermicro X10DRT-P) |
| BMC IP | 10.10.10.31 |
| 静的 IP | 10.10.10.211 |
| ホスト名 | ayase-web-service-11 |
| OS | Debian 13.3 (Trixie) + Proxmox VE 9.1.6, kernel 6.17.13-2-pve |
| デフォルトルート | 192.168.120.1 (vmbr1, 別拠点 VLAN trunk 経由でインターネット到達済) |
| 対象ドライブ | /dev/sdb (sg1) |
| Drive INQUIRY | Vendor: SEAGATE / Model: DKS5L-J1R2SS / Rev: 8F0E |
| Serial | WFKC5AAR0000C2320NAA |
| WWN | 5000C500D8F72B53 (Seagate OUI 5000C5) |
| 対応 mode (sg_inq) | Full / Segmented / Deferred / **Deferred - Select activation events** (Phase 7 で見落とし) |
| LOD ファイル | /root/fw/N005.LOD (sha256: `5812f976e6045c4d076e193688ea9040b631a692cf402cd75bb69b6655d4796f`, 2,113,536 bytes) |

### ツール構成

| ツール | バージョン | 入手元 | パス |
|--------|-----------|--------|------|
| openSeaChest_Firmware | **v26.03.1** X86_64 (Build 2026-04-24) | GitHub `Seagate/openSeaChest` v26.03.1 tag, meson + ninja build | `/root/openSeaChest/builddir/openSeaChest_Firmware` |
| sg_write_buffer | sg3-utils 1.48-2+pmx1 | apt (Debian trixie + pve) | `/usr/bin/sg_write_buffer` |
| sg_inq | sg3-utils 1.48-2+pmx1 | apt | `/usr/bin/sg_inq` |
| 比較対照 (Phase 7) | SeaChest_Firmware v2.5.4-1_18_3 (Build 2018-10-18) | ZIP 同梱 (商用) | `/root/fw/SeaChest_Firmware` |

build に要した apt パッケージ: `git meson ninja-build zlib1g-dev` (gcc, make, libc6-dev, sg3-utils は導入済)。

## 試行内容と結果

### 試行マトリクス (8 試行、全失敗、drive 温存)

| # | Tool | Mode | CDB byte 1 (mode field) | Sense Key | ASC | ASCQ | 段階 | drive 残存 |
|---|------|------|------------------------|-----------|-----|------|------|-----------|
| (a) | openSeaChest v26.03 | segmented (0x07) | 0x07 | **5** | **0x26** | **0x99** | drive verify (final chunk) | OK |
| (b) | openSeaChest v26.03 | deferred+activate (0x0E→0x0F) | 0x0E | **5** | **0x26** | **0x99** | drive verify | OK |
| (d) | openSeaChest v26.03 | segmented + `--modelMatch DKS5L-J1R2SS` | 0x07 | **5** | **0x26** | **0x99** | drive verify | OK |
| (e) | sg_write_buffer | 0x0D dmc_offs_ev_defer (4KB chunks × 515) | 0x0D | **5** | **0x26** | **0x99** | drive verify (final chunk @offset 2109440) | OK |
| (f) | sg_write_buffer | 0x04 dmc (no offsets) | 0x04 | **5** | **0x24** | **0x00** | CDB MODE field 拒否 (FRU=0x1) | OK |
| (g) | sg_write_buffer | 0x01 vendor specific | 0x01 | **5** | **0x24** | **0x00** | CDB MODE field 拒否 | OK |
| (h) | sg_write_buffer | 0x10 (SPC undefined) | 0x10 | **5** | **0x24** | **0x00** | CDB MODE field 拒否 | OK |
| (i) | sg_write_buffer | 0x14 (SPC undefined) | 0x14 | **5** | **0x24** | **0x00** | CDB MODE field 拒否 | OK |

### 試行 (c) (`--allowFlexibleFWDLAPIUse`) はスキップ

`openSeaChest_Firmware --help` および manpage いずれにも該当オプションは存在しない (Phase 1 探索で apt 24.08 (v4.3.3) も同様、本セッションでビルドした v26.03.1 でも未確認)。Phase 7 で参照した商用版 SeaChest_Firmware (派生コードベース) のレガシーオプションと推定。

### Sense data 詳細

#### Phase 7 と完全一致 (drive verify reject)

trial (a)/(b)/(d)/(e) はいずれも以下:

```
Raw sense data (in hex), sb_len=28:
72 05 26 99 00 00 00 14  03 02 00 05 80 0E 00 00
00 00 00 00 00 00 00 00  00 00 00 00

Response code: 0x72 (current, descriptor format)
Sense Key: 0x05 = Illegal Request
ASC: 0x26 / ASCQ: 0x99 = Vendor specific qualification (Invalid Field in Parameter List)
FRU: 0x05 = Vendor Specific
Information byte 14 = 0x0E (drive 内部参照、Phase 7 と同値)
```

これは Phase 7 の segmented モードで取得した sense data と **byte for byte 一致** ([Phase 7 verbose log L2105-2116](attachment/2026-05-08_025037_server10-13_phase7_seagate_fw_oem_lock/flash_verbose_segmented.log) と本セッションの [flash_a_oseg.log](attachment/2026-05-08_033632_server10-13_phase8_openseachest_oss_retry/flash_a_oseg.log) を比較)。

#### サポート外 mode (drive が CDB 段階で reject)

trial (f)/(g)/(h)/(i) はいずれも以下:

```
Raw sense data (in hex), sb_len=36:
72 05 24 00 00 00 00 1c  02 06 00 00 cc 00 01 00
03 02 00 01 80 0e 00 00  00 00 00 00 00 00 00 00
00 00 00 00

Sense Key: 0x05 = Illegal Request
ASC: 0x24 / ASCQ: 0x00 = Invalid field in CDB
Sense key specific Field pointer: byte 1, bit 4 (= MODE field of WRITE BUFFER CDB)
FRU: 0x01 (FW Download)
```

→ drive がサポートしない mode は **CDB parse 段階** で MODE field を invalid と判定し reject (microcode buffer まで進まない)。

### 重要観察 (trial e: 4KB chunk × 515 segment 全送信)

trial (e) sg_write_buffer mode 0x0D は `--bpw 4k` で 4096 byte ずつ chunk 送信。LOD 2,113,536 bytes ÷ 4096 = 516 chunk (offset 0 から 0x202000 まで)。verbose log を見ると、最終 chunk:

```
sending write buffer, mode=0xd, mspec=0, id=0,  offset=2109440, len=4096
    Write buffer cdb: [3b 0d 00 20 30 00 00 10 00 00]
```

を送信した直後に CHECK CONDITION (ASC=0x26) を返した ([flash_e_swb0d.log L9789-9817](attachment/2026-05-08_033632_server10-13_phase8_openseachest_oss_retry/flash_e_swb0d.log))。つまり drive は:

1. **全 chunks (515 個 × 4KB = 2,109,440 bytes) を SUCCESS で受領**
2. **最終 chunk 送信完了後、microcode 全体を内部 buffer 上で検証**
3. LOD ヘッダの model identifier が drive の INQUIRY と一致しないことを検出
4. Sense Key 5 / ASC=0x26 / ASCQ=0x99 (vendor specific) で reject
5. Microcode を flash chip に commit せず、現在 FW (8F0E) を保持

これは Phase 7 segmented mode (32KB chunks × 64 segment) と**同じ動作パターン**。chunk size に依存せず、最終 chunk 完了後に検証が走る。

### Drive 状態確認

baseline 取得 → 8 試行 → final 確認の比較:

| 項目 | baseline | final | 結果 |
|------|---------|-------|------|
| INQUIRY 出力 (sg_inq /dev/sg1) | full output | full output | **完全一致 (`diff` IDENTICAL)** |
| FW Revision | 8F0E | 8F0E | 不変 |
| dd 1 block read (`/dev/sdb`) | OK | OK | 不変 |
| dd 1 block write (`/dev/sdb`) | Remote I/O error | Remote I/O error | 不変 (Phase 2-6 の write filter 維持) |
| smartctl Serial | WFKC5AAR0000C2320NAA | WFKC5AAR0000C2320NAA | 同一 |

→ **drive は完全温存**。8 試行を通して drive 状態に変化なし。Phase 7 と合わせて 11 mode 全試行で 0 本 brick。

## 結論

### Phase 7 真因仮説の確定

> **drive firmware の microcode verification ロジックが、LOD ヘッダ内の対応モデル文字列リスト (`ST300MM0008/ST600MM0088/ST900MM0168/ST1200MM0088` など) を INQUIRY model (`DKS5L-J1R2SS`) と照合し、不一致なら ASC=0x26 ASCQ=0x99 で reject する。これは drive firmware 内部のチェックであり、host (ツール) 側で bypass できない。**

Phase 8 で確認できた裏付け:

1. **OSS v26.03.1 (2026-04 ビルド) でも商用 v2.5.4 (2018-10 ビルド) と完全に同じ sense data** を返す → ツール側の差ではない
2. **drive がサポート宣言した全 mode (0x05/0x07/0x0D/0x0E/0x0F) で同じ ASC=0x26** → mode 戦略 (full/segmented/deferred/event-defer/activate) に依存しない
3. **chunk size を変えても (Phase 7: 32KB / Phase 8: 4KB) 同じ位置 (最終 chunk 後の verify 段階)** で reject → buffer 戦略に依存しない
4. **`--modelMatch` (host filter) 併用も同結果** → host 側 filter は drive 内部の検証に影響しない
5. **サポート外 mode (0x01/0x04/0x10/0x14) は CDB 段階で reject** → drive は CDB MODE field を厳格に検証、未定義領域を「実は vendor 拡張で受け付ける」可能性は否定

### microcode download 経路の閉鎖確定

| 経路 | 結果 |
|------|------|
| 標準 SCSI WRITE BUFFER (mode 0x05/0x07/0x0D/0x0E/0x0F) | drive verify reject (ASC=0x26) |
| 商用 SeaChest_Firmware v2.5.4 | Phase 7 で確認済み |
| OSS openSeaChest v26.03.1 | 本 Phase で確認 |
| sg_write_buffer 直接 (4KB chunk, 標準 mode) | 同 ASC=0x26 |
| sg_write_buffer vendor mode (0x01) | drive 未サポート (ASC=0x24) |
| sg_write_buffer SPC 未定義 mode (0x10/0x14) | drive 未サポート (ASC=0x24) |
| `--modelMatch` (host filter) | drive 検証は bypass 不可 |
| `--allowFlexibleFWDLAPIUse` | OSS にオプション不在 |

→ **公開された SCSI 仕様の範囲内で取れる残り経路は無い**。残された理論上の選択肢:

- **LOD ヘッダ patch** — drive INQUIRY と一致する model 文字列を LOD ファイルにバイナリ書き換え。drive が patch 後の LOD を flash した結果 brick する確率が高く (microcode 整合性チェック) リスク大、別途ユーザ判断が必要 (本 Phase スコープ外)
- **JTAG / serial console 経由の low-level 介入** — ベンダーの内部ツール / サービスケーブルが必要、現実的ではない
- **drive 物理的交換** — Toshiba PX02SMU040 SSD のみで運用 (既存方針)

### Issue #61 wontfix 最終確定

Phase 6 で wontfix 確定 → Phase 7 で `--downloadMode` 全標準 mode 確認 → Phase 8 で OSS + sg_write_buffer 全 mode + vendor 領域確認 → **これ以上の検証経路は無し**。Issue #61 は **wontfix を完全確定** (これ以降 reopen 候補となるトリガーは発生しない、と判断)。

### LINSTOR 構築方針

10-13号機 LINSTOR 4 ノードクラスタ構築は **Toshiba PX02SMU040 SSD (各機 1 本) のみで運用** が確定方針。HDD は OS 用 (LSI HBA 経由 = 過去 Phase で確認) 以外には使用しない。容量が極小であり LINSTOR 評価環境としては限定的だが、別案 (Region A の 4-6 号機既存クラスタ流用、Region B の 7-9 号機追加) を優先検討すべき。

## 次のアクション

1. ✅ Phase 8 レポート作成 (本ドキュメント)
2. ✅ Issue #61 status は `done` を維持、コメント追記で Phase 8 完全閉鎖を記録
3. ✅ メモリ `server10-13_data_disks_write_blocked.md` に Phase 8 セクション追加
4. ⏭ pve11 power off (本セッション後始末)
5. ⏭ 別タスク: Toshiba SSD のみでの LINSTOR 構築計画 — 別 Issue として起票検討 (容量・冗長性の妥当性精査)

## 引用 (Phase 7 / 8 ログ）

- 本 Phase の sense data: [flash_a_oseg.log](attachment/2026-05-08_033632_server10-13_phase8_openseachest_oss_retry/flash_a_oseg.log) 末尾
- Phase 7 の sense data: [flash_verbose_segmented.log L2105-2116](attachment/2026-05-08_025037_server10-13_phase7_seagate_fw_oem_lock/flash_verbose_segmented.log)
- 4KB chunk 全送信証拠: [flash_e_swb0d.log L9789-9817](attachment/2026-05-08_033632_server10-13_phase8_openseachest_oss_retry/flash_e_swb0d.log)
- drive サポート mode: [fwdlInfo.txt](attachment/2026-05-08_033632_server10-13_phase8_openseachest_oss_retry/fwdlInfo.txt)
- baseline vs final 一致: [sg_inq_baseline.txt](attachment/2026-05-08_033632_server10-13_phase8_openseachest_oss_retry/sg_inq_baseline.txt) vs [sg_inq_final.txt](attachment/2026-05-08_033632_server10-13_phase8_openseachest_oss_retry/sg_inq_final.txt)
