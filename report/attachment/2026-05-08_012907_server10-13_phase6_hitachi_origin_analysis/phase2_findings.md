# Phase 2 findings: Seagate doc + Hitachi context analysis

## 🎯 核心的発見: ASC=0x81 = "LA Check Error" + SED Lock 機構

### 1. ASC=0x81 ASCQ=0x00 の Seagate 公式定義

SCSI Commands Reference Manual Rev H (100293068h.pdf) Table 29 (page 31-36) より:

| ASC | ASCQ | Description | Sense Key |
|-----|------|-------------|-----------|
| 80 | 00 | General Firmware Error Qualifier | 9 |
| 81 | 00 | Reassign Power—Fail Recovery Failed | (none) |
| **81** | **00** | **LA Check Error, LCM bit = 0** | **4 (Hardware Error)** |
| **81** | **00** | **LA Check Error** | **B (Aborted Command)** |

Phase 3 で観測された `<<vendor>>ASC=0x81 ASCQ=0x0` は **「LA Check Error」(Logical Address Check Error)** = Seagate ファームウェアが **対象 LBA への access を内部チェックで拒否** している状態。

### 2. Product Manual Section 8.4 "Drive locking" の決定的記述

ENT PERF 10K HDD v8 Product Manual (100746003c.pdf) Section 8.4 より直接引用:

> The variable "LockOnReset" should be set to "PowerCycle" to ensure that the data bands will be locked if power is lost. In addition "ReadLockEnabled" and **"WriteLockEnabled" must be set to true** in the locking table in order for the bands "LockOnReset" setting of "PowerCycle" to actually lock access to the band when a "PowerCycle" event occurs. **This scenario occurs if the drive is removed from its cabinet. The drive will not honor any data read or write requests until the bands have been unlocked. This prevents the user data from being accessed without the appropriate credentials when the drive has been removed from its cabinet and installed in another system.**

これは **今回のシナリオに完全一致**:

| シナリオの段階 | ドライブ状態 |
|---|---|
| Hitachi `HT-F40SC-DBSQ5` で稼働中 | Lock 認証済 (BandMaster による unlock 状態) |
| Hitachi 筐体から取り外し → power down | LockOnReset=PowerCycle により Locked へ遷移 |
| Supermicro X10DRT-P (10-13号機) に挿入 | 認証情報なし → Locked 維持 |
| Linux から read | Hitachi が ReadLockEnabled=false にしていれば read 可能 (Phase 1-3 と整合) |
| Linux から write | **WriteLockEnabled=true により reject、ASC=0x81 "LA Check Error"** |

### 3. ラベル写真の物的証拠

`tmp/s10ph6/label-img/IMG_0319.jpg` に **"Seagate Secure"** ロゴあり = SED 対応 drive 確定。さらに PSID 番号も読み取り可能:

| 項目 | 値 |
|---|---|
| Model | ST1200MM0018 (Enterprise Performance 10K HDD v8 1.2TB SAS AF) |
| SN | W402BQQ2 |
| PN | 1FF201-046 |
| FW (label) | 7FA3 (Phase 3 観測値 7FA9 と異なる → 別個体 or FW 上書き履歴あり) |
| WWN | 5000C500B853E3D4 |
| **PSID** | **DQGPRJY1XZ9A3L2BUXWKQV1BCKHLM6AF** (32 文字) |
| DOM | 10MAY2018 |
| Site | WUXISG (Wuxi, China) |
| **Seagate Secure** | **YES (SED 対応確定)** |

### 4. Phase 3 の opcode 結果との整合性

| OP | Cmd | 結果 | SED Lock 観点での解釈 |
|---|---|---|---|
| 0x2A | WRITE(10) | ❌ ASC=0x81 | Band Lock (WriteLockEnabled=true) で reject |
| 0x8A | WRITE(16) | ❌ ASC=0x81 | 同上 |
| 0x41 | WSAME(10) | ❌ ASC=0x81 | 同上 |
| 0x2E | WAV(10) | ❌ ASC=0x81 | 同上 |
| 0x8E | WAV(16) | ❌ ASC=0x81 | 同上 |
| 0x04 | FORMAT UNIT | ✅ 通る | "data destruction" 系で band 制約をバイパスしてる可能性。完了しても band 設定そのものはリセットされない |
| 0x07 | REASSIGN BLOCKS | ✅ 通る | 内部 sparing、user data 経路を経由しない |
| 0x3F | WRITE LONG | ✅ 通る | raw sector + ECC 直書き、user write 経路を経由しない |
| 0x48 | SANITIZE | ✅ 通る | "data destruction" 系で band 制約をバイパスしてる可能性 |
| 0x93 | **WSAME(16)** | ✅ 通る | **おそらく Seagate firmware の特殊扱い** (UNMAP/discard 系として扱われている?) |

**重要**: FORMAT/SANITIZE が通っても **SED の Locking SP は変わらない** ため、再 power-on 後 また Locked に戻り write 不可。Phase 2 で SANITIZE OVERWRITE を完走させても次回起動後に dd が ASC=0x81 を返したのはこのため。

### 5. RevertSP (Section 8.11) — 唯一かつ正規の解除手段

> 8.11 RevertSP
> The SED models will support the RevertSP feature which erases all data in all bands on the device and **returns the contents of all SPs (Security Providers) on the device to their original factory state**. In order to execute the RevertSP method **the unique PSID (Physical Secure ID) printed on the drive label** must be provided. PSID is not electronically accessible and can only be manually read from the drive label or scanned in via the 2D barcode.

これにより:
- Locking SP が factory state に戻る
- WriteLockEnabled / ReadLockEnabled / LockOnReset が default に戻る
- 全 band が消去される (我々にとって OK、ユーザデータは無価値)
- 再起動後も Lock 状態が消えたまま維持される

実行コマンド (sedutil-cli):
```sh
sedutil-cli --yesIreallywanttodothis --PSIDrevert DQGPRJY1XZ9A3L2BUXWKQV1BCKHLM6AF /dev/sdb
```

Linux pve10 で `sedutil` (Phase 2 で apt install 済み) が利用可能。

### 6. SECURITY PROTOCOL IN/OUT (3.43-3.44)

Seagate は B5h (SECURITY PROTOCOL OUT) / A2h (SECURITY PROTOCOL IN) を **SED モデルでのみ** サポートと Section 8.9 に明記:

> 8.9 Supported commands
> The SED models support the following two commands in addition to the commands supported by the standard (non-SED) models:
> - Security Protocol Out (B5h)
> - Security Protocol In (A2h)

これは sedutil-cli が裏で打つコマンド。`sedutil-cli --query /dev/sdb` で TCG SP の現状 (Locking enabled / Locked / MBREnabled / Singleuser) を確認可能。

### 7. Hitachi `HT-F40SC-DBSQ5` 機種特定

WebSearch 2 回試行 (キーワード "HT-F40SC-DBSQ5", "Hitachi VSP HUS SED OPAL") では具体特定できず。Hitachi 内部部品番号の可能性が高い。ただし機種特定は **必須ではない** — TCG OPAL/SED は標準仕様で、Hitachi/NetApp/EMC/HPE 等のすべての enterprise storage vendor が同じ機構で drive を保護している。Seagate Product Manual 8.4 が「別 cabinet に移すと lock」と明記しているため、機種に関わらず PSID Revert で解除可能。

## 結論 — Phase 4 でやること

**最優先 (90% breakthrough 期待)**:
1. pve10 BMC On
2. `sedutil-cli --query /dev/sdb` で SED Lock 状態を確認 (期待値: Locking enabled / Locked / WriteLockEnabled=Y)
3. `sedutil-cli --yesIreallywanttodothis --PSIDrevert DQGPRJY1XZ9A3L2BUXWKQV1BCKHLM6AF /dev/sdb`
4. `dd if=/dev/zero of=/dev/sdb bs=512 count=1 oflag=direct seek=10000` で write 通過確認
5. 成功したら sdc + 11/12/13 号機の sdb/sdc 全 8 本に展開

**フォールバック (PSID Revert 失敗時)**:
- vendor MODE pages, SEND DIAGNOSTIC vendor pages の sweep
- ただし Section 8.4 の記述から、SED Lock 解除以外の経路はほぼ無い

## メモ

- ラベル FW=7FA3 vs Phase 3 観測 FW=7FA9: 別個体 or 履歴あり。実機で `sg_inq` 確認必要
- 11/12/13 号機の PSID は別ラベル参照必要 (各 drive に固有)。今回は 10号機 sdb に対応する 1 枚だけ取得済み
- PSID Revert で band が消去されるが、データ HDD は Phase 3-5 で SANITIZE 既済みのため空 → 影響なし
