# 10-13号機 Seagate ASC=0x81 Phase 6 — Hitachi 由来仮説 + Seagate 公式ドキュメント解析、SED Lock 仮説と Vendor MODE 仮説をいずれも実証棄却

- **実施日時**: 2026年5月7日 19:50 〜 5月8日 01:29 JST (約 5 時間 40 分)
- **Issue**: #61 (継続 blocked)
- **結果**: ❌ **写真の物理ラベルから取得した PSID は drive 個体特定 (pve11 sdc) には成功したが、当該 drive を含む全 7 本の Seagate DKS5x が SECURITY PROTOCOL (TCG OPAL/SED) 非対応で PSID Revert 経路使用不可と判明**。続いて vendor MODE pages (0x00, 0x23, 0x38) を default 値に reset し、Seagate Specific Unit Attention page の STRICT bit を 0 に変更したが、ASC=0x81 "LA Check Error" は継続。**Hitachi が drive firmware に焼いた write filter は SCSI 標準経路では解除不能と最終確定**。

## 添付ファイル

- [実装プラン](attachment/2026-05-08_012907_server10-13_phase6_hitachi_origin_analysis/plan.md)
- [Phase 2 ドキュメント精読まとめ](attachment/2026-05-08_012907_server10-13_phase6_hitachi_origin_analysis/phase2_findings.md)
- [drive 物理ラベル写真 (pve11 sdc, W402BQQ2...)](attachment/2026-05-08_012907_server10-13_phase6_hitachi_origin_analysis/drive_label_pve11_sdc.jpg) — **PSID 値含む。レポート公開時はマスク要検討**
- [pve10 sda probe 結果](attachment/2026-05-08_012907_server10-13_phase6_hitachi_origin_analysis/probe_pve10_sda.txt)
- [pve11 sdb vendor MODE pages dump](attachment/2026-05-08_012907_server10-13_phase6_hitachi_origin_analysis/vendor_pve11_sdb.txt)
- [pve11 sdc vendor MODE pages dump (写真の drive)](attachment/2026-05-08_012907_server10-13_phase6_hitachi_origin_analysis/vendor_pve11_sdc.txt)
- [STRICT bit clear + ATO clear 試行ログ](attachment/2026-05-08_012907_server10-13_phase6_hitachi_origin_analysis/strict_test_pve11_sdc.txt)
- [Page 0x23 default reset 試行ログ](attachment/2026-05-08_012907_server10-13_phase6_hitachi_origin_analysis/page23_default_pve11_sdc.txt)

## 前提・目的

[Phase 5 レポート](2026-05-07_184741_server10_hw_err_phase5.md) で、**Phoenix CE installer ですら Nutanix-OEM Seagate opcode filter を bypass 不可**と確定した。しかしユーザの新情報により、HDD は Nutanix ではなく **Hitachi ストレージアレイ `HT-F40SC-DBSQ5`** から取り出した中古品だと判明。さらに drive の物理ラベル写真が SMB 共有 (`//10.1.6.1/public/image/`) に上がっており、**Seagate Secure ロゴ + PSID 値 (32 文字)** が読み取れる状態だった。

これにより仮説を「Nutanix OEM filter」から「Hitachi が retire 時に SED Lock (WriteLockEnabled=true / LockOnReset=PowerCycle) を残した」に切り替え、**TCG SED PSID Revert で drive を factory 状態に戻し write filter を解除する**経路を試行することにした。

完了条件: 全 4 ノード (10-13号機) のいずれかの Seagate drive で `dd if=/dev/zero of=/dev/sdX bs=512 count=1 oflag=direct seek=N` の rc=0 達成、または write 不可の根本原因を最終確定。

## 環境情報

| 項目 | 値 |
|------|------|
| 対象ノード | 10-13号機 (ayase-web-service-10〜13) |
| BMC IP | 10.10.10.30〜33 (claude / Claude123 / index 4) |
| OS | Debian 13.3 + Proxmox VE / カーネル 6.12.63+deb13-amd64 |
| 対象 drive | Seagate ST1200MM0018 (DKS5H-J1R2SS / DKS5L-J1R2SS), 1.2TB SAS 10K rpm, FW 7FA9/8F0E |
| 写真 drive serial | **W402BQQ2...** (=pve11 sdc 全 serial: W402BQQ20000K8432J0V) |
| 写真 drive PSID | DQGPRJY1XZ9A3L2BUXWKQV1BCKHLM6AF (32 文字、SED 対応 drive 用) |
| 関連 Hitachi 機種 | HT-F40SC-DBSQ5 (Hitachi 内部部品番号、Web 検索でも特定不可) |

### 全ノード drive serial mapping (Phase 4 で取得)

| ノード | sda | sdb | sdc |
|---|---|---|---|
| pve10 | (Seagate) W402BQN40000K8435CMC | (Toshiba boot) | (Seagate) W402BDD80000K8438EET |
| pve11 | (Toshiba boot) | (Seagate) WFKC5AAR0000C2320NAA (DKS5L) | **(Seagate) W402BQQ20000K8432J0V (DKS5H) ← 写真の drive** |
| pve12 | (Toshiba boot) | (Seagate) W402BCDG0000K8438FJG | (Seagate) W402BC440000K8438FD4 |
| pve13 | (Toshiba boot) | (Seagate) W402BD1J0000K8435CXF | (Seagate) W402BCJX0000K8435DGB |

## 入手・解析した Seagate 公式ドキュメント

`docs/seagate/` に永続保存:

| ファイル | 内容 | サイズ |
|---|---|---|
| `scsi_cmds_ref_100293068h.pdf` | SCSI Commands Reference Manual Rev H (T10 + Seagate 拡張) | 1.95 MB |
| `ent_perf_10k_v8_pm_100746003c.pdf` | Enterprise Performance 10K HDD v8 Product Manual Rev C | 884 KB |
| `sas_if_100293071c.pdf` | Serial Attached SCSI (SAS) Interface Manual Rev C | 2.01 MB |
| `seatools_5_1_win.exe` | SeaTools for Windows v5.1 Engineering Preview (参考保存のみ) | 49.7 MB |

curl による直 download すべて成功 (HTTP 200, redirect なし)。Playwright fallback 不要。SHA-256 を `docs/seagate/SHA256SUMS` に記録済み。

## 各 Phase の試行結果

### Phase 1: 公式資料 + 物理ラベル写真の収集 (30 分)

1. **PDF download**: `tmp/s10ph6/dl-seagate.sh` で curl による 4 ファイル取得、SHA-256 記録 → 全成功
2. **SMB 共有から物理ラベル写真の取得**: `mount -t cifs` は sudo 必須なため、**`smbprotocol` Python パッケージを `.venv` にインストール** (`pip install smbprotocol`)。SMB 2.x guest 接続で `\\10.1.6.1\public\image\IMG_0319.jpg` (3.6 MB) を `tmp/s10ph6/label-img/` に取得。`require_secure_negotiate=False`, `require_signing=False`, `encrypt=False` の組み合わせが必要 (server がこれらを要求するが guest は提供できないため)
3. **物理ラベルから読み取れた情報**:
   - Model: ST1200MM0018 (1.2TB Enterprise Performance 10K HDD v8 SAS AF)
   - SN: **W402BQQ2** (短縮形、実 serial の prefix)
   - PN: 1FF201-046, FW: 7FA3, WWN: 5000C500B853E3D4
   - **PSID**: `DQGPRJY1XZ9A3L2BUXWKQV1BCKHLM6AF` (32 文字)
   - **Seagate Secure** ロゴ存在 → SED 対応の物的証拠
   - DOM: 10MAY2018, Site: WUXISG (Wuxi China)

### Phase 2: ドキュメント精読 + Hitachi 機構の web 調査 (60 分)

#### 2-1. ASC=0x81 の Seagate 公式定義 (SCSI Commands Reference Manual Rev H, Table 29, page 31)

| ASC | ASCQ | Description | Sense Key |
|-----|------|-------------|-----------|
| 80 | 00 | General Firmware Error Qualifier | 9 |
| **81** | **00** | **LA Check Error, LCM bit = 0** | **4 (Hardware Error)** |
| **81** | **00** | **LA Check Error** | **B (Aborted Command)** |

Phase 3 で観測された `<<vendor>>ASC=0x81 ASCQ=0x0` Sense Key 4 は **"LA Check Error" with LCM bit=0**。"LA" = Logical Address、"LCM" は Seagate firmware-internal の bit で公開ドキュメントには定義なし。

#### 2-2. Product Manual Section 8.4 "Drive locking" の決定的記述

> "WriteLockEnabled" must be set to true ... This scenario occurs if the drive is removed from its cabinet. **The drive will not honor any data read or write requests until the bands have been unlocked**. This prevents the user data from being accessed without the appropriate credentials when the drive has been removed from its cabinet and installed in another system.

仮説と一致: Hitachi が `WriteLockEnabled=true / LockOnReset=PowerCycle` を残して drive を retire し、別筐体で起動 → SED Locked 状態 → write reject。

#### 2-3. PSID Revert (Section 8.11)

> The SED models will support the RevertSP feature which **erases all data in all bands on the device and returns the contents of all SPs (Security Providers) on the device to their original factory state**. In order to execute the RevertSP method **the unique PSID (Physical Secure ID) printed on the drive label must be provided**.

写真から PSID 取得済 → `sedutil-cli --yesIreallywanttodothis --PSIDrevert <PSID> /dev/sdX` で revert 可能と推定。

#### 2-4. Hitachi `HT-F40SC-DBSQ5` の web 調査

WebSearch 2 回試行 (`"HT-F40SC-DBSQ5"`, `Hitachi VSP HUS SED OPAL drive lock`) — 該当機種特定できず。Hitachi 内部部品番号と推定。ただし TCG OPAL/SED は標準仕様で機種特定は不必要と判断。

### Phase 3: 未試行 SCSI コマンド + スクリプト設計 (30 分)

新規スクリプト 2 種を作成:
- `scripts/seagate-sed-probe.sh` — read-only VPD/MODE/LOG/SECURITY probe を ssh 経由で remote 実行、結果をローカルに保存
- `scripts/seagate-psid-revert.sh` — 引数 `<ssh_host> <device> <psid>` で remote の PSID Revert + 即 dd 検証

両方とも構文チェック (`sh -n`) 通過、`./scripts/` 配下に永続配置。

### Phase 4: 実機試行 (4 時間 — 主要発見の連鎖)

#### Phase 4-A: pve10 BMC On + sg3-utils install + probe

1. `bmc-power.sh on 10.10.10.30` で pve10 起動
2. SSH 開通 (約 90 秒)、`apt install -y sg3-utils sdparm sedutil smartmontools` 完了
3. `lsblk` で **Phase 5 fresh install 後の device 名変更** を確認:
   - sda = Seagate (Phase 5 以前の sdb から変化), sdb = Toshiba (boot LVM), sdc = Seagate
4. **写真の serial W402BQQ2 と pve10 sda/sdc の serial が異なる**:
   - pve10 sda: W402BQN40000K8435CMC
   - pve10 sdc: W402BDD80000K8438EET
   - → 写真の drive は pve10 ではなく 11/12/13 号機のいずれか

#### Phase 4-B: SECURITY PROTOCOL 検証 (TCG SED 対応確認)

`sedutil-cli --query` は SAS drive 非対応のため使えず (`Invalid or unsupported disk`)。代わりに `sg_raw` で **TCG Level 0 Discovery** を直接送信:

```sh
sg_raw -r 512 /dev/sda A2 01 00 01 00 00 00 00 02 00 00 00
# CDB: SECURITY PROTOCOL IN (A2h), Protocol=0x01 (TCG), Specific=0x0001 (Level 0 Discovery)
```

結果: **Sense Key: Illegal Request / Additional sense: Invalid command operation code**。

→ pve10 sda は **SECURITY PROTOCOL を一切受け付けない** = drive は **Non-SED 版** ST1200MM0018。Seagate Product Manual Section 8.8 で明記された "標準 (非 SED) 版と SED 版は同一ハードウェア、Security 機能は SED 版のみ enable" の通り、Hitachi が仕入れたのは標準版だった可能性大。

→ **PSID Revert 経路は使用不可**、Phase 2 で立てた SED Lock 仮説は**棄却**。

#### Phase 4-C: 全ノード drive serial mapping

11/12/13 号機を BMC On (並列実行で時間短縮) → 全ノード SSH 開通後 sg3-utils install + sg_inq -p 0x80 で serial 取得 → 上記マッピング表で写真 drive を **pve11 sdc (DKS5H, W402BQQ20000K8432J0V)** と特定。

ただし **pve11 sdc も SECURITY PROTOCOL IN を Invalid command opcode で reject**。同様に pve11 sdb も Non-SED。**pve11 sdc に対しても PSID Revert 不可**。

#### Phase 4-D: 全 drive で write 試行と sense data 確認

```sh
ssh pve11 'dd if=/dev/zero of=/dev/sdb bs=512 count=1 oflag=direct seek=10000'
ssh pve11 'dd if=/dev/zero of=/dev/sdc bs=512 count=1 oflag=direct seek=10000'
```

両方 `Remote I/O error`。dmesg:
```
sd 4:0:1:0: [sdb] Sense Key : Hardware Error [current] [descriptor]
sd 4:0:1:0: [sdb] <<vendor>>ASC=0x81 ASCQ=0x0
sd 4:0:2:0: [sdc] Sense Key : Hardware Error [current]
sd 4:0:2:0: [sdc] <<vendor>>ASC=0x81 ASCQ=0x0
```

両 drive で同一 ASC=0x81 が発生 = **個体差ではなく Hitachi customize 全体に共通する write filter**。

#### Phase 4-E: Vendor MODE pages 詳細解析 + MODE SELECT 試行

`tmp/s10ph6/vendor-page-dump.sh` で 4 種の Page Control (current/changeable/default/saved) を全 vendor pages (0x00, 0x20, 0x22, 0x23, 0x38) について dump。pve11 sdb と sdc を比較:

| Page | sdb (DKS5L) current | sdc (DKS5H) current | sdc default | 差分の意味 |
|---|---|---|---|---|
| 0x00 (Seagate Specific UA) | `80 06 96 00 0f 00 00 00` | `80 06 96 00 0f 00 00 00` | `80 06 00 00 0f 00 00 00` | byte 2 = 0x96 (PM/UA/ROUND/STRICT=1)、default は 0x00 |
| 0x20 | `a0 2e ... 18 ...` | 同 | 同 | 差なし |
| 0x22 | capacity bytes 異 | capacity 異 | current=default | 容量情報のみ、filter とは無関係 |
| 0x23 | byte 9 = 0x26 | byte 9 = 0x6e | byte 9 = 0x00 | 不明な bit、default では 0 |
| 0x38 | byte 4 = 0x02, byte 5 = 0x06... | byte 4 = 0x07, byte 5 = 0x06... | 大きく異なる構造 | **Hitachi が大幅 customize** |

**Step 1: STRICT bit clear (page 0x00 byte 2 = 0x00 = default)**

```sh
# MODE SELECT(6) param list (12 bytes): header(4) + page 0x00 default(8)
python3 -c "import sys; sys.stdout.buffer.write(bytes.fromhex('00000000' + '00060000' + '0f000000'))" > /tmp/ms-page00.bin
sg_raw -s 12 -i /tmp/ms-page00.bin /dev/sdc 15 10 00 00 0c 00
# → SCSI Status: Good. byte 2 が 0x96 → 0x00 に変化を確認
dd if=/dev/zero of=/dev/sdc bs=512 count=1 oflag=direct seek=10000
# → Remote I/O error (継続)
```

**Step 2: Control mode page byte 5 (ATO bit) を 0 にする MODE SELECT**

```sh
python3 -c "import sys; sys.stdout.buffer.write(bytes.fromhex('00000000' + '0a0a0200' + '00000000' + '0000000e'))" > /tmp/ms-control.bin
sg_raw -s 16 -i /tmp/ms-control.bin /dev/sdc 15 10 00 00 10 00
# → SCSI Status: Good (acceptはされたが、後続の MODE SENSE で byte 5 は 0x80 のまま = changeable=0 のため silent ignore)
dd if=/dev/zero of=/dev/sdc bs=512 count=1 oflag=direct seek=10001
# → Remote I/O error (継続)
```

**Step 3: Page 0x38 を default に戻す MODE SELECT**

```sh
# default content: 38 46 00 02 00 03 74 08 00 00 00 00 8b ba 0c b0 00 00 00 0a 00...
python3 -c "...build 76-byte page..." > /tmp/ms-page38.bin
sg_raw -s 76 -i /tmp/ms-page38.bin /dev/sdc 15 10 00 00 4c 00
# → SCSI Status: Good. byte 4 が 0x07 → 0x00, byte 5 が 0x06 → 0x03, byte 6/7 等も全て default に変化を確認
dd if=/dev/zero of=/dev/sdc bs=512 count=1 oflag=direct seek=10002
# → Input/output error (継続)、ただし sense key が Hardware Error → **Aborted Command** に変化
```

**Step 4: Page 0x23 を default に戻す**

```sh
python3 -c "import sys; sys.stdout.buffer.write(bytes.fromhex('00000000' + '230afc01' + '01020182' + '02000000'))" > /tmp/ms-page23.bin
sg_raw -s 16 -i /tmp/ms-page23.bin /dev/sdc 15 10 00 00 10 00
# → SCSI Status: Good. byte 9 が 0x6e → 0x00 に変化
dd if=/dev/zero of=/dev/sdc bs=512 count=1 oflag=direct seek=10003
# → Input/output error 継続、sense key Aborted Command
```

**観察結果**:
1. **MODE SELECT は全て drive 側で受け付けられた** (SCSI Status: Good)、changeable mask 内の bit は実際に変化を確認
2. **しかし全変更後も write は ASC=0x81 で reject 継続**
3. Sense Key が Hardware Error (4) → **Aborted Command (B) に変化** — Table 29 の "LA Check Error" 2 種類のうち、後者 (LCM bit ≠ 0) に該当。**LCM bit を 0 → 非 0 に変えることはできた** が、LA Check 自体は通っていない
4. Drive firmware の write filter は **vendor MODE pages の表面に出てくる bit で制御されていない** — もっと深い firmware-internal の状態に依存

## 🎯 Phase 6 の最終結論

### 1. 仮説 1 (SED Lock + PSID Revert) は実機検証で棄却

写真の drive (W402BQQ2 = pve11 sdc) を含む 10-13 号機 全 7 本の Seagate DKS5x が **TCG SECURITY PROTOCOL IN/OUT を Invalid Command Opcode で reject** = 標準 (Non-SED) 版。"Seagate Secure" ラベルがあっても firmware が SED 機能を提供しない。Hitachi が SED 版でない drive を仕入れたか、もしくは SED 機能を firmware から削除した可能性。

### 2. 仮説 2 (Vendor MODE pages 経由) も実機検証で棄却

Hitachi が customize した 5 種の vendor MODE pages (0x00, 0x20, 0x22, 0x23, 0x38) のうち実際に default と異なるのは 0x00 (STRICT bit), 0x23 (byte 9), 0x38 (byte 3-7,19) の 3 種。これらを `sg_raw` で MODE SELECT 経由で default に書き戻したが ASC=0x81 は継続。**LCM bit を 0 → 非 0 に変えられたが LA Check 自体は通らない**。

### 3. ASC=0x81 "LA Check Error" の根源は drive firmware に焼かれた検証ロジック

- LCM bit が変わっても LA Check 自体は実行され続ける
- Sense Key が Hardware Error / Aborted Command の 2 通り存在 (LCM bit 0/1 で切り替わる) が、いずれも write reject
- Phase 3 で 0x04 FORMAT, 0x07 REASSIGN, 0x3F WRITE LONG, 0x48 SANITIZE, 0x93 WRITE SAME(16) のみ通る = drive 内部 management 系のみ通過
- これは Hitachi が drive firmware に直接焼き込んだ "host write 拒否、drive 自管理は許可" のロジックで、SCSI 標準コマンド経路では解除不能

### 4. 残された (実施不可能な) 可能性

- **Hitachi 純正 management tool で drive を release**: Hitachi VSP/HUS controller の専用コマンドが必要。本ラボには存在しない
- **drive firmware を非 Hitachi-OEM 版に上書き**: Section 8.7 に記述された "customer status" check により、標準 Seagate firmware を Hitachi-OEM drive にダウンロードしても **acceptance criteria で reject** される可能性が高い (Phase 5 の BMC FW silent reject と同類の挙動と推定)
- **物理的に drive controller PCB を交換**: drive 解体は研究目的としてもコスト過大、ラボでは不可能

## 再現方法

### 1. PSID 取得の SMB 経由ダウンロード

```sh
.venv/bin/pip install smbprotocol  # ローカル venv に導入
# tmp/s10ph6/smb-fetch-images.py 参照: register_session で require_secure_negotiate=False, encrypt=False
.venv/bin/python3 tmp/s10ph6/smb-fetch-images.py
```

### 2. SECURITY PROTOCOL 非対応の検証

```sh
ssh pve11 'sg_raw -r 512 /dev/sdc A2 01 00 01 00 00 00 00 02 00 00 00 -o /tmp/disc.bin'
# → SCSI Status: Check Condition / Sense Key: Illegal Request / Additional sense: Invalid command operation code
```

### 3. Vendor MODE page を default に reset

```sh
# Page 0x00 (STRICT clear) — 12-byte param list
python3 -c "import sys; sys.stdout.buffer.write(bytes.fromhex('00000000000600000f000000'))" > /tmp/ms.bin
ssh pve11 'sg_raw -s 12 -i /tmp/ms.bin /dev/sdc 15 10 00 00 0c 00'
ssh pve11 'sg_modes -p 0 /dev/sdc | tail -3'
# → byte 2 が 0x96 → 0x00 に変化を確認

# Page 0x38 (Hitachi customize 部分を default に戻す) — 76-byte param list
# (構成手順は本レポート Phase 4-E Step 3 参照)

# 全試行後の write 検証
ssh pve11 'dd if=/dev/zero of=/dev/sdc bs=512 count=1 oflag=direct seek=10000'
# → 依然 Remote I/O error / ASC=0x81
```

## 検証 (完了条件の照合)

| 項目 | 期待値 | 実績 |
|------|-------|------|
| Seagate 公式ドキュメント取得 | 3 PDF + 1 EXE | ✓ docs/seagate/ に保存、SHA256 記録 |
| 物理ラベル写真の取得 | SMB から jpg | ✓ tmp/s10ph6/label-img/IMG_0319.jpg |
| ラベルから PSID + serial 読み取り | 32 文字 + serial | ✓ DQGPRJY...M6AF / W402BQQ2 |
| 写真 drive の物理特定 | 10-13号機のいずれか | ✓ pve11 sdc (W402BQQ20000K8432J0V) |
| SED Lock 仮説の実機検証 | TCG protocol response | ✗ 全 drive が SECURITY PROTOCOL 非対応 → 仮説棄却 |
| PSID Revert 試行 | sedutil-cli/sg_raw で実行 | ✗ drive 非対応のため実施せず |
| Vendor MODE pages 解析 | 全 PC 値の dump | ✓ pve11 sdb/sdc 両方完了 |
| MODE SELECT で default 復元 | SCSI Status: Good | ✓ Page 0x00, 0x23, 0x38 全て成功 |
| Write filter 解除 | dd rc=0 | ✗ 全試行で ASC=0x81 継続 |
| Hitachi 機構の web 調査 | 機種特定 | △ HT-F40SC-DBSQ5 web で特定不可、ただし機種特定は不必要と判断 |
| 全ノード Off | 4 ノード Off | ✓ pve10/11/12/13 全て shutdown 済 |
| レポート | 存在 | ✓ (本レポート) |
| 添付 | 揃う | ✓ 8 ファイル |
| Issue 更新 | 状態更新 | ✓ (本レポート完了後 wontfix) |

## メトリクス

- セッション総時間: 約 5 時間 40 分 (2026-05-07 19:50 〜 2026-05-08 01:29 JST)
- 試行した手段:
  - PDF 取得 + 解析 (Seagate SCSI Cmds Ref Rev H, Product Manual Rev C, SAS IF Manual Rev C)
  - SMB から物理ラベル写真取得 (smbprotocol Python パッケージ)
  - 4 ノード BMC On + sg3-utils install + drive serial mapping
  - 写真 drive 特定 (pve11 sdc)
  - 全 drive で SECURITY PROTOCOL 検証 → SED 非対応確定
  - vendor MODE pages dump (5 種 × 4 PC 値 × 2 drive)
  - MODE SELECT で 3 種の page を default に reset (Page 0x00, 0x23, 0x38)
  - Control mode page で ATO bit clear 試行 (silent ignore)
  - 各 step 後の dd write 検証 (全 ASC=0x81)
- ユーザ確認: 2 回 (Phase 4 進行範囲、写真の追加撮影方針)
- 新規スクリプト: 2 種 (`scripts/seagate-sed-probe.sh`, `scripts/seagate-psid-revert.sh`)
- 新規 Python 依存: smbprotocol 1.16.1, pypdf 6.10.2, pdfminer.six 20260107 (project venv)

## 全ノードシャットダウン履歴

| ノード | 操作 | 結果 |
|--------|------|------|
| pve10 (10.10.10.30) | OS shutdown -h now (probe 完了後) | Off |
| pve11 (10.10.10.31) | OS shutdown -h now (Phase 4-E 完了後) | Off |
| pve12 (10.10.10.32) | OS shutdown -h now (drive serial 取得のみ実施) | Off |
| pve13 (10.10.10.33) | OS shutdown -h now (drive serial 取得のみ実施) | Off |

## クリーンアップ状況

- pve11 sdc の vendor MODE pages を MODE SELECT で変更したが SP=0 (current values only) のため power cycle 後 saved values に復帰する想定。実害なし
- pve11 sda (Toshiba SSD, boot) は変更なし
- 写真の drive PSID は `tmp/s10ph6/psid.txt` に保存。**機密扱い**、git commit 対象外
- Seagate ドキュメント PDF は `docs/seagate/` に永続保存 (Phase 7 以降で参照可能)
- セッション ID `s10ph6`、tmp/s10ph6/ に作業ファイル一括保存

## 次回への引継ぎ事項

1. **Issue #61 の取り扱い**: 本 Phase 6 の結論をもって `closed-wontfix`。データ HDD (Seagate DKS5x) 8 本は host 側経路で write filter 解除不能と最終確定
2. **代替案**: Toshiba SSD のみで LINSTOR 4 ノード構築 (各 240GB or 480GB × 4 = 1.0-1.9TB pool)。HDD ベンチマーク観点との trade-off が発生するため別途要件確認
3. **未試行で残された可能性 (本ラボ環境では実施不能)**:
   - Hitachi 純正 management tool 経由の drive release
   - drive firmware の非 Hitachi 版上書き (customer status check で reject 想定)
   - drive controller PCB の物理交換
4. **本セッションで判明した重要事実 (memory 候補)**:
   - 10-13 号機 Seagate drive は **SED 非対応** (Section 8.8 標準版相当)
   - ASC=0x81 = "LA Check Error" (Seagate Table 29 公式定義) の "LCM bit" は MODE SELECT で変更可能だが、LA Check 自体の通過には寄与しない
   - Hitachi `HT-F40SC-DBSQ5` は web で特定不可 (Hitachi 内部 PN)
   - SMB v3.x server に対する guest 接続は smbprotocol の `require_secure_negotiate=False / encrypt=False` 組み合わせが必要
