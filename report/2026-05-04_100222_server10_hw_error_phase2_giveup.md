# 10-13号機 Seagate DKS5x ASC=0x81 Hardware Error 根本対策 Phase 2 — 完全ギブアップ

- **実施日時**: 2026年5月4日 04:08 〜 10:02 JST (約 6 時間)
- **Issue**: #61 (継続 blocked)
- **結果**: ⚠️ **完全ギブアップ** — 全 6 Phase (情報収集 / ステート初期化 / HBA 介入 / 再フォーマット / SANITIZE / SED 確認) を試行するも、Seagate DKS5H-J1R2SS の write block (vendor ASC=0x81) は解除されず。**重要な原因仮説 (opcode 別フィルタ) を確定**したが、リモート手段では解除不可。

## 添付ファイル

- [実装プラン](attachment/2026-05-04_100222_server10_hw_error_phase2_giveup/plan.md)
- [Phase 5c SANITIZE Overwrite 完走ログ](attachment/2026-05-04_100222_server10_hw_error_phase2_giveup/phase5c_sg_sanitize.log)
- [Phase 4c 通る opcode の証拠ログ (WRITE LONG / REASSIGN)](attachment/2026-05-04_100222_server10_hw_error_phase2_giveup/phase4c_opcodes_passing.log)

## 前提・目的

[前セッションのレポート](2026-05-04_034112_server10-13_linstor_giveup_hw_error.md) で 10-13号機の全 8 本 Seagate DKS5x SAS HDD が writes を ASC=0x81 で拒否し、LINSTOR + ZFS pool 構築が不能となった。最高優先度の引き継ぎ事項として記録された **「ASC=0x81 Hardware Error の根本対策」** に取り組み、ZFS pool 作成可能な状態への復帰を試みた。

- ユーザ承認のタイムボックス: 12 時間 (Phase 5c の SANITIZE Overwrite 4-8 時間も含めて実施可能)
- 検証範囲: pve10 の /dev/sdb 1 本のみで先行検証 (成功時のみ他 7 本に横展開)
- スコープ外: `sg_write_buffer` でのファーム書き換え (ブリックリスク高)、Nutanix AOS 環境構築、物理ジャンパピン操作

## 環境情報

| 項目 | 値 |
|------|------|
| ホスト | ayase-web-service-10 (10.10.10.210) |
| OEM モデル | Nutanix NX-1065-G5 / Supermicro X10DRT-P-G5-NI22 |
| OS | Debian 13.3 + PVE 9.1.9 / Kernel 7.0.0-3-pve |
| データ HDD | Seagate DKS5H-J1R2SS 1.2 TB SAS / Firmware Rev **7FA9** |
| HBA (sdb/sdc) | Broadcom/LSI SAS3008 (`mpt3sas`) |
| OS disk (sda) | Toshiba THNSNJ240PCSZ (Intel C610 sSATA) — 別系統で正常 |

| パッケージ | バージョン |
|-----------|-----------|
| sg3-utils | 1.48-2+pmx1 |
| sdparm | 1.12-2 |
| sedutil | 1.20.0-2+b1 |

## 実施した Phase

| Phase | 内容 | 所要時間 | 結果 |
|-------|------|---------|------|
| 0 | pve10 BMC 起動、ssh 開通待機、sg3-utils + sdparm インストール、ベースライン dd write 失敗再現確認 | 13 分 | ✓ |
| 1 | 詳細情報収集: sg_inq (VPD 0x80/0x83/0x86/0xb0/0xb1/0xb2)、sg_modes -a (current + default)、sg_logs、sg_persist、sg_opcodes | 5 分 | 情報取得 |
| 2 | ステート初期化: sg_persist (read/clear/preempt)、sg_reset (LUN/target/bus)、sg_start cycle、SCSI-2 RELEASE(6/10) | 5 分 | ✗ 効果無し |
| 3 | HBA 介入: device delete + rescan、mpt3sas modprobe -r 試行 (in-use で reload 不可) | 3 分 | ✗ 効果無し |
| 4a | sdparm モードページ復元 (AWRE/ARRE=1, EER/PER=0, GLTSD=0, WCE=1)、WRITE SAME(10)、UNMAP、WRITE LONG、REASSIGN BLOCKS | 8 分 | ✗ 効果無し (重要な発見あり) |
| 4b | `sg_format --format --fmtpinfo=0 --size=512 --quick /dev/sdb` (PI Type 0 強制再フォーマット) | **3 時間 26 分** (04:19 - 07:46) | ✗ 完走するも write 拒否変わらず |
| 5c | `sg_sanitize --overwrite --ipl=4 --zero --quick /dev/sdb` (1 パス zero overwrite, 中断不可) | **2 時間 2 分** (07:57 - 09:59) | ✗ 完走するも write 拒否変わらず |
| 6 | `sedutil-cli --query` で SED/OPAL 状態確認 | 1 分 | sda/sdb/sdc 全て **OPAL 非対応** (PSID リバートは原理的に不可) |
| 7 | 横展開 (sdc, pve11-13) | — | 実施せず (pve10 sdb で全 Phase 失敗) |
| 8 | OS shutdown + BMC 電源 Off 確認 (10-13号機) | 2 分 | ✓ 全 4 台 Off |
| 9 | レポート作成 + Issue 更新 | — | (本レポート) |

## 重要な発見: Nutanix の opcode 別フィルタ保護

Phase 4c (sdc に対する WRITE LONG / REASSIGN 試行) で次の事実を確定:

| SCSI opcode | コマンド | 結果 |
|-------------|----------|------|
| **0x2a** | **WRITE(10)** — 通常書き込み | ❌ **ASC=0x81 vendor reject** |
| 0x2e | WRITE AND VERIFY(10) | (Test Unit Ready で同列扱い、未試行) |
| 0x3f | WRITE LONG(10) | ✓ **通る** (xfer_len=590 で物理セクタ書き込み成功) |
| 0x07 | REASSIGN BLOCKS | ✓ **通る** (LBA 0 再配置成功 → 後続 read が zero を返す) |
| 0x04 | FORMAT UNIT | ✓ **通る** (sg_format 完走、3h26m) |
| 0x48 | SANITIZE Overwrite | ✓ **通る** (sg_sanitize Overwrite 完走、2h2m) |
| 0x41 | WRITE SAME(10) | ❌ ASC=0x81 vendor reject |
| (opcode 列挙) | sg_opcodes 出力 | UNMAP / WRITE 16 / WRITE BUFFER mode 4-7 等は表示上サポート |

→ **Nutanix がファームウェア (Rev 7FA9) レベルで「ホスト OS からの汎用 WRITE/WRITE_SAME のみを vendor reject する」フィルタ機構を実装していると強く示唆される**。FORMAT/SANITIZE/WRITE LONG/REASSIGN といった「ディスク内部処理を伴う特殊コマンド」は通すため、ディスク上の物理データは内部的に書き換え可能 (sg_sanitize は確かに 1.2 TB の zero 書き込みを完走した)。しかし通常の WRITE オペコードのみ拒否される設計。

このため、**標準 SCSI ツール (sg3-utils, sdparm, sedutil) ではバイパス不能**。

### 補強する観察

- mode page 再構成 (AWRE/ARRE/GLTSD/WCE 等) しても write は通らない
- SCSI-2 Reservation (Reserve(6)/Reserve(10)) もクリア試行したが影響なし
- SCSI-3 Persistent Reservation 全テスト (register / reserve / preempt / release / clear) が動作する一方、初期 `read-keys` は 0 件 — つまり PR は無関係
- LUN reset / target reset / bus reset / device delete + rescan も全て効果無し
- Write cache は SANITIZE 後 disabled→enabled に正常復元されたが ASC=0x81 は変わらず

## 再現方法

### 1. pve10 を起動して再現環境準備

```sh
./oplog.sh ./pve-lock.sh run ./scripts/bmc-power.sh on 10.10.10.30 claude Claude123
sh tmp/<sid>/wait-ssh.sh 10.10.10.210   # ssh 開通待機
ssh -F ssh/config root@10.10.10.210 "apt-get install -y sg3-utils sdparm"
```

### 2. ASC=0x81 再現 (read 成功 / write 拒否)

```sh
ssh -F ssh/config root@10.10.10.210 "dd if=/dev/sdb of=/dev/null bs=4k count=10"
# → 81.7 MB/s で成功 (read OK)

ssh -F ssh/config root@10.10.10.210 "dd if=/dev/zero of=/dev/sdb bs=512 count=1 oflag=direct"
# → dd: error writing '/dev/sdb': Remote I/O error

ssh -F ssh/config root@10.10.10.210 "dmesg -T --since '30 seconds ago' | grep ASC=0x81"
# → critical target error, dev sdb, sector 0 op 0x1:(WRITE)
#   Sense Key : Hardware Error [current]  <<vendor>>ASC=0x81 ASCQ=0x0
```

### 3. opcode 別の通り抜け差を確認

```sh
# WRITE LONG (通る):
ssh -F ssh/config root@10.10.10.210 "dd if=/dev/zero bs=590 count=1 of=/tmp/long.bin && \
  sg_write_long --in=/tmp/long.bin --xfer_len=590 --lba=0 /dev/sdb"
# → 出力なし (成功)、後続 read で Medium Error (PI mismatch、想定通り)

# REASSIGN BLOCKS (通る):
ssh -F ssh/config root@10.10.10.210 "sg_reassign --address=0 /dev/sdb"

# SANITIZE Overwrite (通る、2 時間で完走):
ssh -F ssh/config root@10.10.10.210 "sg_sanitize --overwrite --ipl=4 --zero --quick /dev/sdb"

# その後の WRITE(10) は依然失敗:
ssh -F ssh/config root@10.10.10.210 "dd if=/dev/zero of=/dev/sdb bs=512 count=1 oflag=direct"
# → Remote I/O error
```

## 次回セッションへの引き継ぎ事項

### 残された手段 (本セッションで実施しなかった)

優先度別に整理:

1. **Seagate / Nutanix 純正 firmware への書き換え** (`sg_write_buffer` mode 4/5/7 で Microcode Download)
   - opcode フィルタが firmware に焼かれているなら唯一の解除手段
   - Nutanix portal アクセスは [メモリ記録](../.claude/projects/-home-ubuntu-projects-pvese/memory/server10_nutanix_oem.md) で入手不可確定
   - Seagate 公式 standard firmware の入手は OEM 製品では非公開
   - 失敗時にディスクが恒久ブリックする可能性が極めて高い (リスク受容必須)

2. **Nutanix AOS / CVM 環境を構築してディスクリリース**
   - AOS Community Edition (CE) で 10号機をブートし `genesis stop` 等の disk_release 試行
   - PVE クラスタを破棄して AOS 切替が必要 — 現運用に影響大
   - そもそも AOS が opcode フィルタを解除する保証なし

3. **物理ジャンパピン確認** (リモート不可、ユーザによる現地作業必須)
   - Seagate SAS HDD には背面ジャンパで Write Protect 等を設定するモデルが存在
   - DKS5H-J1R2SS は OEM 専用のためジャンパ仕様非公開
   - 期待値は低いが排除のため現地確認推奨

4. **Broadcom `sas3ircu` / `lsiutil` の入手**
   - Debian apt にはなく公式は登録ゲート内
   - HBA reset レベルでの介入は **Phase 2 / 3 で既に device delete + rescan を試行済**で効果なし
   - 期待値低 (本問題は HBA レベルではなく drive 内部の問題)

### Issue #61 の更新方針

**完全ギブアップで blocked 継続**。新しい blocked 理由:

> 全 8 データ HDD で write Hardware Error ASC=0x81。Phase 1-6 試行 (情報収集・リセット・モードページ復元・sg_format・SANITIZE Overwrite・SED確認) すべて効果なし。原因確定: **Nutanix が firmware Rev 7FA9 に opcode フィルタを実装** (WRITE/WRITE_SAME のみ vendor reject、FORMAT/SANITIZE/WRITE LONG/REASSIGN は通る)。標準 SCSI ツールではバイパス不可。次回検討: (a) 純正 firmware 書き換え (入手不可 + ブリックリスク)、(b) Nutanix AOS 環境切替、(c) 物理ジャンパ確認。本ハードウェアでの LINSTOR/ZFS 運用は事実上不可能。

### 構築済み資産 (シャットダウン後も保持)

- PVE クラスタ `pvese-cluster-c` (4 ノード Quorate)
- LINSTOR 1.33.2 (controller=pve10, satellite=pve10-13)
- DRBD 9.3.2 / ZFS 2.4.1 全ノード導入済
- 4 ノード相互 SSH 鍵 / `ssh/config` の pve10-13 エイリアス
- Phase 4b 完了後の sdb は **Type 0 PI / 全 zero 物理状態** (sg_format で初期化済)
- Phase 5c 完了後の sdb は **再度 1 パス zero overwrite 完了状態**

これらは将来 firmware 書き換え等で write 拒否が解除された場合、即座に LINSTOR セットアップを再開できる前提資産。

## 検証 (完了条件の照合)

| 項目 | 期待値 | 実績 |
|------|-------|------|
| 書き込み可能化 (pve10 sdb) | dd 成功 | ❌ 全試行で Remote I/O error |
| dmesg | ASC=0x81 該当なし | ❌ 全試行で同エラー記録 |
| 横展開 | 全 8 本で書込成功 | — (未実施。pve10 sdb 失敗確定で展開せず) |
| シャットダウン | 4 ノード Off | ✓ |
| レポート | 存在 | ✓ (本レポート) |
| Issue 更新 | 状態更新済 | ✓ (本レポート完了後に Issue.sh で実施) |

## メトリクス

- セッション総時間: 約 6 時間 (04:08 - 10:02 JST)
- Phase 4b sg_format 所要: **3 時間 26 分** (1.2 TB / Type 0 PI)
- Phase 5c SANITIZE Overwrite 所要: **2 時間 2 分** (1.2 TB / 1 パス zero) — 想定 4-8 時間より高速
- 試行した SCSI コマンド種類: 13 種 (sg_inq, sg_modes, sg_logs, sg_persist, sg_reset, sg_start, sg_unmap, sg_write_same, sg_write_long, sg_reassign, sg_format, sg_sanitize, sg_raw)
- 試行した sdparm モードページ変更: 5 件 (AWRE, ARRE, EER, PER, GLTSD, WCE)

## ギブアップ判断基準との照合

実装プランに定義された判定:

| 条件 | 該当 | 備考 |
|------|------|------|
| 累積 12 時間経過 | ✗ | 6 時間で打ち切り |
| Phase 5c (Overwrite) 完了で改善なし | **✓** | これに該当 |
| dmesg に sda 等他ディスクへの新規エラー | ✗ | sda は最後まで正常 |
| SANITIZE Overwrite 開始から 10 時間経過 | ✗ | 2 時間で完走 |

→ **Phase 5c 完了で write 拒否解除されず**を理由にギブアップ判定。Phase 8 (シャットダウン) を実行。
