# server10-13 Seagate ST1200MM0018 write filter 解析 Phase 6 — Hitachi 由来 + PSID 取得済 シナリオ

## Context

10-13号機 (Supermicro X10DRT-P / Nutanix OEM 筐体) の data HDD (Seagate ST1200MM0018, FW Rev 7FA9) は Phase 3-5 を通じて、`ASC=0x81` (vendor reject) で WRITE 系 opcode が drive firmware level でブロックされていることが判明している。これまで「Nutanix OEM filter」と推定していたが、**ユーザの新情報により HDD は Hitachi ストレージアレイ `HT-F40SC-DBSQ5` から取り出した中古品**だと判明した。

これは前提を根本から変える:

- 旧仮説: Nutanix が drive firmware に opcode filter を焼いた → host 側 bypass 不可 (確定済)
- 新仮説: **Hitachi storage array が drive を array-bound / TCG SED Locked / write-filtered 状態で retire した** → drive 側のリセット手段 (PSID Revert / vendor MODE / SEND DIAGNOSTIC) で解除可能性あり

特に重要なのは:
1. ユーザが drive 物理ラベルを撮影済み (`/public/image` の SMB 共有) で **PSID 番号が取得可能** — TCG PSID Revert は drive を factory blank に戻す強力な経路
2. Phase 3 で「未試行」と確定している経路: SECURITY PROTOCOL IN/OUT (0xA2/0xB5), MODE SELECT vendor pages (0x00, 0x20-0x3E), SEND DIAGNOSTIC vendor pages, WRITE BUFFER mode 0
3. Phase 3 で「0x93 WRITE SAME(16) は任意パターン書き込み可」が新発見済 — 別経路としてフィージビリティ確認のみ実施

意図する成果は **`dd if=/dev/zero of=/dev/sdX bs=512 count=1 oflag=direct` が成功する状態を作ること**。それが達成されれば 10-13号機 4台で LINSTOR/DRBD 構築が可能になり Issue #61 が unblock される。失敗すればハードウェア壁を最終確定し、Toshiba SSD のみで LINSTOR を構築する代替案に切り替える。

## 関連リソース

### 公式ドキュメント (Phase 1 で取得)
- SCSI Commands Reference Manual Rev H: https://www.seagate.com/files/staticfiles/support/docs/manual/Interface%20manuals/100293068h.pdf
- ENT PERF 10K v8 Product Manual Rev C: https://www.seagate.com/www-content/product-content/enterprise-performance-savvio-fam/enterprise-performance-10k-hdd/ent-perf-10k-v8/en-us/docs/100746003c.pdf
- SAS Interface Manual Rev C: https://www.seagate.com/staticfiles/support/disc/manuals/Interface%20manuals/100293071c.pdf
- SeaTools 5.1 Windows: https://www.seagate.com/www-content/support-content/_shared/downloads/SeaTools-5.1-windows-installer.exe (参考保存のみ)

### 既存ファイル (参照)
- `/home/ubuntu/projects/pvese/CLAUDE.md` — POSIX sh / `tmp/<sid>/` / SSH 静的 IP / pve-lock 規約
- `/home/ubuntu/projects/pvese/REPORT.md` — レポートフォーマット
- `/home/ubuntu/projects/pvese/.claude/skills/playwright/SKILL.md` — Playwright fallback テンプレ (curl 失敗時)
- `/home/ubuntu/projects/pvese/report/2026-05-07_184741_server10_hw_err_phase5.md` — Phase 5 結論・撤退基準の前例
- `/home/ubuntu/projects/pvese/report/2026-05-04_191138_server10_hw_err_phase3.md` — Phase 3 opcode 試行ログ
- `/public/image` (SMB `//10.1.6.1/public/image`) — drive 物理ラベル写真 (PSID 番号含む)

### 新規作成スクリプト
- `/home/ubuntu/projects/pvese/scripts/seagate-vendor-probe.sh` — read-only VPD/MODE/LOG/SECURITY probe 一括
- `/home/ubuntu/projects/pvese/scripts/seagate-mode-page-sweep.sh` — vendor mode page (0x00, 0x20-0x3F) + subpage 列挙
- `/home/ubuntu/projects/pvese/scripts/seagate-write-attempt.sh` — 1 操作 + dd 検証 + JSON 1 行出力

## Phase 1: 公式資料 + 物理ラベル写真の収集 (目標 30 分)

1. セッション初期化:
   - Glob で `/home/ubuntu/.claude/transcripts/*.jsonl` 最新の先頭 8 文字を `<sid>` に
   - `mkdir -p tmp/<sid>` `mkdir -p docs/seagate` `mkdir -p tmp/<sid>/label-img`
   - `./issue.sh start 61 --owner <sid>`

2. PDF 取得 (curl 直):
   - Write `tmp/<sid>/dl-seagate.sh` で curl により 3 PDF + 1 EXE を `docs/seagate/` に保存
   - HTTP 403/302 redirect 失敗時のみ `tmp/<sid>/dl-seagate-pw.py` (Playwright skill 流用) で fallback
   - SHA-256 を `docs/seagate/SHA256SUMS` に記録

3. 物理ラベル写真の取り込み:
   - `mount -t cifs //10.1.6.1/public /mnt/smb` (Phase 5 と同じ手順、ローカルに mount するか pve10 で取りに行くか選択)
   - `cp /mnt/smb/image/* tmp/<sid>/label-img/` でローカル保存
   - Read ツールで写真を視覚的に確認、PSID 番号 (32 桁英数字) を文字起こし
   - PSID は `tmp/<sid>/psid.txt` にメモ (機密扱い、レポート添付時はマスク要否を判断)

## Phase 2: ドキュメント精読 + Hitachi `HT-F40SC-DBSQ5` の web 調査 (目標 60-90 分)

### 2-1. SCSI Commands Reference (100293068h.pdf) — 重点章

`Read pages: "1-15"` で目次取得 → 以下章へ展開:

| 探す内容 | 期待される情報 |
|---|---|
| MODE SELECT/SENSE 全 mode page list | vendor pages 0x00, 0x20-0x3E の Seagate 実装 |
| SECURITY PROTOCOL IN/OUT | TCG protocol ID 一覧、PSID 認証フロー、Lock/Unlock 状態 byte |
| Sense Key / ASC 一覧 | `ASC=0x81 ASCQ=0x00,0x01` の Seagate vendor 公式定義 |
| WRITE BUFFER mode | mode 0/5/7/0x0E 詳細、Microcode Download プロセス |
| FORMAT UNIT options | DPRY/IP/CMPLST/fmtpinfo の組み合わせと挙動 |
| SEND DIAGNOSTIC pages | Self-Test 区分と vendor diagnostic page list |

### 2-2. ENT PERF 10K v8 Product Manual (100746003c.pdf)

| 章 | 重点 |
|---|---|
| Drive personality / customer customization | Hitachi OEM カスタムの構成箇所 (どこに焼かれるか) |
| Format Block (520B/sector) | Hitachi DIF 識別、IP=1 の意味 |
| Security features (SED/FIPS/Opal/SeaCAP) | sedutil で読める範囲、PSID Revert の効果範囲 |
| Diagnostics / SMART | vendor self-test の実行方法 |

### 2-3. Hitachi `HT-F40SC-DBSQ5` の web 調査

WebSearch で:
- `"HT-F40SC-DBSQ5"` 完全一致 (型番から具体的なシリーズ・容量・ドライブ役割を特定)
- `"HT-F40SC" Hitachi disk shelf` (シェルフ形式・OEM 系統)
- `"Hitachi" "HT-F40SC" drive retire reuse format` (取り外し後の reuse 手順)
- `Hitachi VSP G series drive ASSIGN command release` (VSP 系の drive ownership 解除)
- `Hitachi storage SED OPAL TCG PSID factory reset`
- `Seagate ST1200MM0018 1FF201-046 Hitachi OEM unlock`

WebFetch で:
- Hitachi 公式 service manual 抜粋 (公開分)
- StorageReview / theregister / lkml-style mailing list の議論
- Mihail Pavlov / Lior Kaplan 等の SCSI hacker blog (PSID Revert 実例)

### 2-4. 出力
`tmp/<sid>/phase2_findings.md` に以下を記録:
- Seagate ASC=0x81 公式定義
- vendor MODE/LOG/Diag pages の用途マッピング
- TCG PSID Revert の成功事例とリスク
- Hitachi `HT-F40SC-DBSQ5` シリーズの drive ownership 仕様

## Phase 3: 未試行 SCSI コマンド計画 (目標 30 分、実行は Phase 4)

リスク順に **probe → recoverable → destructive** で並べる。

### 3-1. probe (リスク 0)
1. `sg_inq -p 0x00,0x80,0x83,0x86,0xb0,0xb1,0xb2,0xc0,0xc1 /dev/sdb` (VPD 全 page)
2. `sg_modes --all --dbd /dev/sdb` (全 mode page + subpage)
3. `sg_modes -p 0x00 /dev/sdb` (vendor unique page 0x00)
4. mode page sweep (0x20-0x3F + subpage 0x00-0xFF) を `seagate-mode-page-sweep.sh` で
5. `sg_senddiag -l /dev/sdb` (supported diag pages)
6. `sg_persist -k -d /dev/sdb` (PR keys) + `sg_persist -r -d /dev/sdb` (reservation)
7. `sg_logs --all /dev/sdb` (vendor log pages)
8. `sg_raw -r 64 /dev/sdb 5A 0A 19 00 00 00 00 00 40 00` (Mode Sense for protocol-specific port page)
9. **TCG/SED probe**: `sedutil-cli --query /dev/sdb` で Locking/Locked/MBREnabled 状態確認

### 3-2. PSID Revert (リスク 中、ただし TCG SED Locked であれば破壊的でない)
- 前提: Phase 1 で取得した PSID 番号
- コマンド: `sedutil-cli --yesIreallywanttodothis --PSIDrevert <PSID> /dev/sdb`
- 効果: Locking SP を factory state にリセット、Lock disable、MBR shadow disable、user data は MEK 破棄により読めなくなる (drive 側で zeroize 同等)
- 検証直後: `dd if=/dev/zero of=/dev/sdb bs=512 count=1 oflag=direct seek=10000`
- **このステップが成功すれば即 breakthrough**。10号機 sdb で成功確認後、sdc + 11/12/13 号機 8 本に展開

### 3-3. state-change (recoverable, リスク低)
- `sg_persist --out --register --param-sark=0` で Hitachi 残留 reservation を解除 → dd 検証
- vendor MODE page で write protect 候補 bit を toggle (現値を保存して書き換え) → dd 検証

### 3-4. state-change (destructive、最後の手段)
- `sg_senddiag --pf --raw=...` で vendor diagnostic 実行 (Self-Test ではなく vendor unique page)
- `WRITE BUFFER mode 0` (no save) で空 buffer download → ASC=0x81 vs 別 sense → dd 検証
- `sg_sat_set_features` で SAT 透過確認 (SAS なので通らない想定)

### 3-5. 「WRITE SAME(16) (0x93) を block 経路に組み込む」フィージビリティ
- dm-linear + user-space block target で WRITE(10/16) → WRITE SAME(16) 翻訳
- 実装コスト: 数日。**Phase 6 では実装せず**、PSID Revert / MODE 経路が全滅した場合の Phase 7 候補として記録

## Phase 4: 実行計画 (目標 90-120 分、reboot 0-1 回)

### 4-1. ステップ順序
1. pve10 BMC On (cold) + SSH 開通待ち → 5 分
2. `apt install -y sg3-utils sdparm sedutil` 確認 → 1 分 (Phase 2 で導入済の可能性)
3. `seagate-vendor-probe.sh /dev/sdb` 実行 → 5 分。出力 Read で精査
4. `seagate-vendor-probe.sh /dev/sdc` 実行 → 5 分 (差異確認)
5. `sedutil-cli --query` で SED 状態確認 → 1 分
6. **PSID Revert (sdb)** → `sedutil-cli --yesIreallywanttodothis --PSIDrevert <PSID> /dev/sdb` → 即 dd 検証 → 2 分
   - 成功なら sdc + 11/12/13 号機 8 本に展開 (各 BMC On 5 分 + Revert 2 分 = 7 分 × 4 ノード = 28 分)
   - 失敗ならステップ 7 へ
7. mode page sweep → 怪しい page を識別 → 候補 bit を 1 つずつ書き換え → dd 検証 → 各 2 分 × 10 候補 = 20 分
8. SEND DIAGNOSTIC vendor pages probe → 5 分
9. WRITE BUFFER mode 0 probe → 2 分
10. ATA-PT 透過確認 → 2 分
11. 結果整理 → BMC Off → 5 分

### 4-2. リスク評価

| 操作 | リスク | 影響 | 撤退方法 |
|---|---|---|---|
| VPD/MODE SENSE/LOG SENSE | 0 | なし | — |
| PERSISTENT RESERVE register/clear | 低 | reservation 状態変化 | clear で復元 |
| MODE SELECT vendor bit toggle | 中 | drive personality 変化、再起動で固定化リスク | 元値を保存 → 同 page で書き戻す |
| **PSID Revert** | **中** | drive 上のユーザデータ破棄 (今回は無価値なので OK)、TCG state リセット | drive 側で revert 不可、ただし factory state なので「使えなくなる」ではなく「使える状態」になる想定 |
| SEND DIAGNOSTIC | 中 | self-test 開始で数時間 lock | background 発行、abort で復帰 |
| WRITE BUFFER mode 0 | 高 | 不正 mode で hang/brick の可能性 | mode 0 (no save) のみ probe |
| ATA-PT | 0 | SAS-PT は通常 reject | — |

### 4-3. 検証方法 (各 state-change 後)
```sh
dd if=/dev/zero of=/dev/sdX bs=512 count=1 oflag=direct seek=$((RANDOM % 1000000))
echo $?
dmesg -T | tail -20
sg_logs --page=0x2f /dev/sdX
```
rc=0 + dmesg に sense なし → write 通過。それ以外は失敗扱い。

## Phase 5: レポート作成

`report/2026-05-08_<HHMMSS>_server10-13_phase6_hitachi_origin_analysis.md` を Write ツールで作成。

添付:
- `tmp/<sid>/label-img/*.jpg` → `report/attachment/<日付ディレクトリ>/label-*.jpg` (PSID 部分はマスクの要否をユーザに確認)
- `tmp/<sid>/probe-sdb/`, `probe-sdc/` の全ファイル
- mode page sweep 結果
- 各 state-change 試行の dd 結果 (JSON Lines)
- `phase2_findings.md`

レポート構成 (REPORT.md 準拠):
- 前提・目的 (Hitachi 仮説への切替)
- 各 Phase の実施内容と結果
- 結論 (PSID Revert 成否で 2 分岐)
- 再現方法
- 残された可能性と撤退条件
- 全ノードシャットダウン履歴 / クリーンアップ状況

## 失敗パターンと撤退条件

| 失敗 | 判断 | 次 Action |
|---|---|---|
| Phase 1 で SCSI Cmds Ref が取れない | curl + Playwright 両方失敗 → web 調査のみで Phase 2 縮小 | Phase 3 に進む |
| Phase 1 で物理ラベル写真が読めない / PSID 不明 | Phase 4-3-2 をスキップ、MODE/Diag のみで進める | Phase 4-3-3 以降 |
| **PSID Revert 成功** | breakthrough、4 ノード 8 本に展開 | Issue #61 unblock、LINSTOR 構築フェーズへ |
| **PSID Revert で write 通らず**, mode/diag も全敗 | Hitachi 仮説も棄却 | Phase 5 結論 = 完全撤退、Toshiba SSD のみ案 |
| WRITE BUFFER mode 0 で drive hang | BMC ForceOff + 30 分 cold → 復活確認 | 復活すれば記録、復活しなければ drive 1 本失う前提で他は触らない |

最終ギブアップ条件: **Phase 4 完了時点で 1 つも write が通らなければ Issue #61 を closed-wontfix** にし、Toshiba SSD のみ LINSTOR 構築 (4 ノード × 240GB) または別ストレージ調達の代替案を立てる。

## 想定セッション時間

| Phase | 時間 |
|---|---|
| Phase 1 (PDF + 写真取得) | 30 分 |
| Phase 2 (精読 + web 調査) | 60-90 分 |
| Phase 3 (script 設計、Write のみ) | 30 分 |
| Phase 4 (実行 + 検証) | 90-120 分 (PSID Revert 成功なら +30 分の横展開) |
| Phase 5 (レポート) | 30 分 |
| **合計** | **約 4-5 時間** |

## Verification

- Phase 1 完了: `docs/seagate/` に 3 PDF + 1 EXE が存在、SHA256 一致、PSID 番号が `tmp/<sid>/psid.txt` に記録済
- Phase 2 完了: `tmp/<sid>/phase2_findings.md` に Seagate ASC=0x81 定義、TCG PSID Revert 手順、Hitachi `HT-F40SC-DBSQ5` シリーズの仕様が整理済
- Phase 3 完了: `scripts/seagate-vendor-probe.sh` 等 3 スクリプトが Write 完了、構文チェック (`sh -n`) パス
- Phase 4 完了: `dd if=/dev/zero of=/dev/sdX bs=512 count=1 oflag=direct seek=N` の rc=0 を **1 本以上** で達成 (breakthrough) もしくは「全試行で ASC=0x81 継続」を確定 (撤退)
- Phase 5 完了: `report/2026-05-08_*_server10-13_phase6_hitachi_origin_analysis.md` が REPORT.md フォーマットで存在、添付ディレクトリに probe 出力 / 物理ラベル写真 / dd 結果 JSON が揃う
- Issue 更新: 結果に応じて `./issue.sh resolve 61` (breakthrough) もしくは `./issue.sh wontfix 61` (撤退)
