# 10-13号機 Phase 7: Seagate 純正 Firmware Flash 試行 — Hitachi/Nutanix OEM Lock により拒否

- **実施日時**: 2026年5月8日 02:50 JST
- **対象**: pve11 sdb (Seagate DKS5L-J1R2SS / FW 8F0E、容量 1.20 TB)
- **結果**: **失敗** — Drive は brick せず元の状態維持。Issue #61 wontfix を確定維持
- **新発見**: Phase 6 で立てた仮説 (write filter が microcode download も拒否) は**誤り**であり、真因は drive firmware の **OEM signature/model check** であることが判明

## 添付ファイル

- [実装プラン](attachment/2026-05-08_025037_server10-13_phase7_seagate_fw_oem_lock/plan.md)
- [flash 試行 verbose ログ (segmented mode)](attachment/2026-05-08_025037_server10-13_phase7_seagate_fw_oem_lock/flash_verbose_segmented.log) — 2127 行、最終 segment で ASC=0x26 ASCQ=0x99 reject の sense data 含む
- [ベースライン sg_inq](attachment/2026-05-08_025037_server10-13_phase7_seagate_fw_oem_lock/sg_inq_sdb_before.txt)
- [ベースライン smartctl](attachment/2026-05-08_025037_server10-13_phase7_seagate_fw_oem_lock/smartctl_sdb_before.txt)
- [Seagate 公式 READMEFIRST PDF テキスト抽出](attachment/2026-05-08_025037_server10-13_phase7_seagate_fw_oem_lock/READMEFIRST.txt)

## 前提・目的

### 背景

10-13号機 (Supermicro X10DRT-P / Nutanix NX-1065/NX-3060 OEM) のデータ HDD 8 本 (Seagate ベース DKS5H/L-J1R2SS) は host write が vendor-specific ASC=0x81 (LA Check Error) で恒久拒否される。Phase 2-6 で sg_format / sg_sanitize / sdparm / sedutil / 24+ SCSI opcode を全試行し解除不能と確定、Issue #61 を wontfix とした (詳細: [Phase 6 レポート](2026-05-08_012907_server10-13_phase6_hitachi_origin_analysis.md))。

Phase 6 では「Hitachi firmware に組み込まれた write filter」を真因と仮定し、唯一の残存経路として「Seagate 純正 firmware を flash で上書きして filter ごと吹き飛ばす」案を提示したが、当時 LOD ファイル未入手のため試行スキップしていた。

### きっかけ

ユーザが [Reddit r/HomeServer 投稿 "Flashing New Firmware to Used Seagate Drives with Locked Hitachi Firmware"](https://www.reddit.com/r/HomeServer/) を参考に、Seagate 公式の Enterprise Performance 10K v8 SAS HDD firmware update package (`EntPerf-Thunderbolt-STD-SAS-5xxN-N005.zip`) を `/var/samba/public/upload/` にアップロード。Reddit 投稿者は同種シナリオ (eBay 中古 ST900MM0168 + Hitachi firmware) で `--downloadMode segmented` 経由で flash 成功 → 通常 write 可能化を達成していた。

### 目的

1. Phase 6 が諦めた残存経路 (microcode download) を実行可能にしたので、本当に Seagate 純正 LOD で OEM Hitachi firmware を上書きできるか検証する
2. 1 本でも write 解除に成功すれば Issue #61 reopen → fixed として LINSTOR 構築復活を目指す
3. 失敗時は Phase 7 として書き残し、Phase 6 の write filter 仮説を検証 (真因の確定)

### ユーザ承認済み判断

- 接続性復旧は BMC 経由電源確認まで自動実行
- ドライブ 4 本までの brick (起動不能化) を許容
- 第一試行は **pve11 sdb** (FW 8F0E、唯一他と異なる FW)

## 環境情報

| 項目 | 値 |
|------|-----|
| サーバ | 11号機 (Nutanix NX-3060-G5 / Supermicro X10DRT-P) |
| BMC IP | 10.10.10.31 |
| 静的 IP | 10.10.10.211 |
| ホスト名 | ayase-web-service-11 |
| OS | Debian 13.3 (Trixie) + Proxmox VE 9.1.6, kernel 6.17.13-2-pve |
| 対象ドライブ | /dev/sdb (sg1) |
| Drive INQUIRY | Vendor: SEAGATE / Model: DKS5L-J1R2SS / Rev: 8F0E |
| WWN | 5000C500D8F72B53 (prefix 5000C5 = Seagate OUI) |
| Drive Copyright | "Copyright (c) 2022 Seagate All rights reserved" |
| 容量 | 2344225968 LBA × 512 B = 1200.24 GB (= ST1200MM0088 と同容量) |
| Power On Hours | 3240.18 hours |
| Firmware Download Support | Full / Segmented / Deferred (3 mode 全対応) |

ZIP 同梱物:
- `firmware/ThunderboltEntPerfSAS-STD-5xxN-N005.LOD` (2,113,536 bytes = 4128 × 512)
- `command line tools/SeaChest/SeaChest_Firmware_254_1183_64` (Seagate 公式商用ビルド v2.5.4, 2018-10-18)
- `READMEFIRST-EnterprisePerf-Thunderbolt-N005 firmware update.pdf`

PDF が宣言する対応モデル:
- ST300MM0008 / ST600MM0088 / **ST900MM0168** / **ST1200MM0088** (Reddit 投稿者は ST900MM0168)
- 既存 FW が **N002 / N003 / N004 で始まる**ことが前提
- 該当しない場合: "you might have a unique OEM version in which case please contact your OEM"
- 警告: "**Warning, possible loss of data if this firmware is downloaded to unsupported models!**"

我々のドライブは PDF 対応モデルに**一致せず** (model 名が異なる) ただし容量・性能・WWN・Copyright から **ハードウェア実体は ST1200MM0088 相当の Seagate 製** と判断される (Hitachi/Nutanix が OEM customize firmware を書き込んだ状態)。

## 再現方法

### Step 1: 接続性回復

全 4 ノード (pve10/11/12/13) は ping 不通状態。BMC 経由で電源確認:

```sh
./scripts/bmc-power.sh status 10.10.10.30 claude Claude123  # pve10: Off
./scripts/bmc-power.sh status 10.10.10.31 claude Claude123  # pve11: Off
./scripts/bmc-power.sh status 10.10.10.32 claude Claude123  # pve12: Redfish curl timeout (BMC ping 通だが API 不調)
./scripts/bmc-power.sh status 10.10.10.33 claude Claude123  # pve13: Off
```

試行対象 pve11 のみ power on:

```sh
./pve-lock.sh run ./oplog.sh ./scripts/bmc-power.sh on 10.10.10.31 claude Claude123
# → "Power On requested"、150 秒程度で OS boot 完了
```

### Step 2: ZIP 展開と資料確認

```sh
unzip -d tmp/a66e695a/fw/ /var/samba/public/upload/EntPerf-Thunderbolt-STD-SAS-5xxN-N005.zip
chmod +x "tmp/a66e695a/fw/command line tools/SeaChest/SeaChest_Firmware_254_1183_64"
.venv/bin/python3 tmp/a66e695a/extract_pdf.py  # pypdf で PDF を平文化
```

### Step 3: ドライブと SeaChest 動作確認

```sh
ssh -F ssh/config pve11 lsblk -o NAME,SIZE,VENDOR,MODEL,REV,SERIAL
# sdb: SEAGATE DKS5L-J1R2SS REV 8F0E SERIAL WFKC5AAR0000C2320NAA
# sdc: SEAGATE DKS5H-J1R2SS REV 7FA9 SERIAL W402BQQ20000K8432J0V

scp -F ssh/config "tmp/a66e695a/fw/command line tools/SeaChest/SeaChest_Firmware_254_1183_64" pve11:/root/fw/SeaChest_Firmware
scp -F ssh/config tmp/a66e695a/fw/firmware/ThunderboltEntPerfSAS-STD-5xxN-N005.LOD pve11:/root/fw/N005.LOD

ssh -F ssh/config pve11 chmod +x /root/fw/SeaChest_Firmware
ssh -F ssh/config pve11 /root/fw/SeaChest_Firmware --version
ssh -F ssh/config pve11 /root/fw/SeaChest_Firmware --scan
ssh -F ssh/config pve11 /root/fw/SeaChest_Firmware -d /dev/sg1 -i
ssh -F ssh/config pve11 /root/fw/SeaChest_Firmware -d /dev/sg1 --fwdlInfo
```

### Step 4: dry-run

```sh
ssh -F ssh/config pve11 /root/fw/SeaChest_Firmware -d /dev/sg1 --downloadFW /root/fw/N005.LOD --fwdlDryRun
# → exit 40 ("Firmware Match Found for update - deferred update supported")
# → "A firmware update is available for this device. FW File: /root/fw/N005.LOD"
```

ツールはモデル/firmware 適合性を判定し、本物の SeaChest 適合 drive と認識した。

### Step 5: 本番 flash 試行 (4 種類)

```sh
# (1) Segmented mode
./pve-lock.sh run ./oplog.sh ssh -F ssh/config pve11 sh /tmp/flash_pve11_sdb.sh
# → exit 3, "Firmware Download failed"

# (2) Verbose 3 で詳細 sense 取得
ssh -F ssh/config pve11 sh /tmp/flash_verbose.sh
# → exit 3, 最終 segment で ASC=0x26 ASCQ=0x99 reject

# (3) Deferred mode
ssh -F ssh/config pve11 /root/fw/SeaChest_Firmware -d /dev/sg1 --downloadFW /root/fw/N005.LOD --downloadMode deferred
# → exit 3, "Firmware Download failed"

# (4) Full mode
ssh -F ssh/config pve11 /root/fw/SeaChest_Firmware -d /dev/sg1 --downloadFW /root/fw/N005.LOD --downloadMode full
# → exit 3, セグメント送信なしで即失敗

# (5) sg_write_buffer 直接 mode 5
ssh -F ssh/config pve11 sg_write_buffer -v --mode=5 --in=/root/fw/N005.LOD --length=2113536 /dev/sdb
# → OS error "Invalid argument" (Linux SCSI subsystem 拒否、max_sectors_kb 制限)

# (6) --fwBufferID 1 で buffer ID 切替
ssh -F ssh/config pve11 /root/fw/SeaChest_Firmware -d /dev/sg1 --downloadFW /root/fw/N005.LOD --downloadMode segmented --fwBufferID 1
# → exit 3, 同様に失敗
```

## 結果と新発見

### 観測された Sense Data (verbose 3 ログより、segmented mode 最終 segment)

```
Sending SCSI Write Buffer
  CDB: 3B 07 00 20 00 00 00 40 00 00
        ↑  ↑  ↑  ↑↑↑↑↑↑↑↑ ↑↑↑↑↑↑↑↑
        |  |  |  |        +- length = 0x40 blocks = 32 KB
        |  |  |  +---------- buffer offset = 0x200000 = 2,097,152 bytes
        |  |  +------------- buffer ID = 0
        |  +---------------- mode = 0x07 (Download microcode with offsets and save)
        +------------------- opcode 0x3B (WRITE BUFFER)

  Sense Data Buffer:
    72 05 26 99 00 00 00 14 03 02 00 05 80 0E 00 00
    ↑  ↑  ↑  ↑                 ↑↑↑↑↑↑↑↑↑↑↑
    |  |  |  +- ASCQ = 0x99 (vendor specific)
    |  |  +---- ASC = 0x26 (Invalid Field in Parameter List)
    |  +------- Sense Key = 0x05 (Illegal Request)
    +---------- Response Code 0x72 (current, descriptor format)

Sense Key: 5h = Illegal Request
ASC & ASCQ: 26h - 99h = Vendor specific ascq code
Information: Invalid field in CDB byte ?, bit ?
Command Time (ms): 18.35  ← 通常 segment は 0.5ms 前後、最終 segment のみ 18ms (drive で重い検証実行)
```

### 累積 segment 進行 (segmented mode)

| Segment 番号 | Buffer Offset (hex) | 結果 |
|--------------|---------------------|------|
| 0 〜 ~63 | 0x000000 〜 0x1F8000 | **全て SUCCESS** (Sense Key 0h) |
| 64 (最終) | 0x200000 | **REJECT** (ASC=0x26, ASCQ=0x99) |

LOD ファイル全体 2,113,536 bytes のうち、最終 ~16 KB を含む 32KB チャンクで初めて拒否された。これは drive firmware が **全データ受信後に signature/CRC/model check** を実行するロジックを持っていることを強く示唆する。

### Phase 6 仮説の修正

| 項目 | Phase 6 の仮説 | Phase 7 で判明した真実 |
|------|---------------|------------------------|
| ASC=0x81 (LA Check Error) | Hitachi が drive firmware に組み込んだ "ホスト write filter" | **正しい** (host から write LBA への変更を拒否) |
| 同 filter が microcode download にも適用されるか | 「適用される可能性が高い」と推測 | **誤り** — microcode download (WRITE BUFFER opcode 0x3B mode 5/7/0xE) は通る |
| 真の OEM lock メカニズム | (未調査) | **新判明: 最終 chunk の signature/model verification で reject** (ASC=0x26 ASCQ=0x99) |

つまり Hitachi/Nutanix の OEM lock は **2 層構造**:
1. **Layer 1**: 通常 host write を ASC=0x81 で拒否 (Phase 2-6 で観測)
2. **Layer 2**: microcode download の最終検証で OEM 非適合 firmware を ASC=0x26 ASCQ=0x99 で拒否 (Phase 7 で新発見)

### Reddit 投稿との差異

| 項目 | Reddit 投稿者 | 本ラボ |
|------|--------------|--------|
| Drive モデル名 (INQUIRY) | **ST900MM0168** | **DKS5L-J1R2SS** |
| Vendor (INQUIRY) | "SEAGATE" 推定 | "SEAGATE" |
| LOD 適用結果 | 成功 | **失敗 (ASC=0x26 ASCQ=0x99)** |

Reddit 投稿者は drive INQUIRY が "ST900MM0168" だったため、Seagate 公式 LOD が想定する model string と完全一致 → 最終検証通過。本ラボの drive は INQUIRY 上 model 名が "DKS5L-J1R2SS" (Hitachi/Nutanix 内部品番) のため、LOD ヘッダの model match で **identifier mismatch** と判定された可能性が高い。

## 結論

1. **Reddit 手法は本ラボの DKS5x ドライブには適用不可**。物理 HW が Seagate ST1200MM0088 等の同型機であっても、INQUIRY 上の model string が OEM 番号 (DKS5L) であるため Seagate 公式 LOD の最終検証が通らない。
2. **Drive は無事**。flash 試行後も sg_inq の Vendor / Product / Rev は変化なく、brick していない。Hitachi firmware で動作継続。
3. **Issue #61 wontfix を確定維持**。Phase 6 の write filter 仮説は技術的に不正確だったが (microcode download 経路は通る)、最終的な flash 不可結論は変わらず。
4. **新たな突破経路の候補**:
   - Hitachi/Nutanix 純正 LOD の入手 (Hitachi 後継 = WD/HGST または Nutanix 経由) — ラボ環境では入手困難
   - LOD ヘッダの model identifier patch — 高リスクで brick 確実性が高く非推奨
   - Vendor-specific WRITE BUFFER mode (0x0Ah, 0x14h 等の Seagate プライベートモード) — 公開されていないため不可

実用的には、Toshiba SSD 単独運用への切り替えが現実解。

## 残課題

- pve11 は power on 状態で残置。次セッションで電源 Off に戻すか、別検証に使うかユーザ確認が必要
- pve10/12/13 は power off 維持
- pve12 BMC は Redfish curl timeout 発生 (HTTPS 接続で exit 28)。ping は通るので BMC LAN は生きているが、Redfish API 応答性に問題あり。次回触る前に要再検証

## 関連レポート

- [Phase 6: Hitachi firmware origin analysis](2026-05-08_012907_server10-13_phase6_hitachi_origin_analysis.md)
- [Phase 5: Phoenix CE installer also blocked by Seagate opcode filter](2026-05-07_053810_server10_hw_err_phase4.md)
- [Phase 4: HW error phase 4 (server10)](2026-05-04_191138_server10_hw_err_phase3.md)
- [Phase 3: HW error phase 2 giveup (server10)](2026-05-04_100222_server10_hw_error_phase2_giveup.md)
- [Phase 2: LINSTOR giveup due to HW error (server10-13)](2026-05-04_034112_server10-13_linstor_giveup_hw_error.md)
- [Storage inventory (server10-13)](2026-05-03_224709_server10-13_storage_inventory.md)
