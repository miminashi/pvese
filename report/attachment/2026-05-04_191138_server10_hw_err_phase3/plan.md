# 10号機 Seagate DKS5x ASC=0x81 Phase 3 — 残された全手段の段階的試行

## Context

- **背景**: Phase 2 (`report/2026-05-04_100222_server10_hw_error_phase2_giveup.md`) で、Nutanix firmware Rev 7FA9 が **opcode 別フィルタ** (WRITE(10)=0x2a / WRITE_SAME(10)=0x41 のみ vendor reject、FORMAT/SANITIZE/WRITE_LONG/REASSIGN は通る) を実装と確定。標準 SCSI ツールではバイパス不能と判断され完全ギブアップ。
- **動機**: ユーザから「残された手段で claude 実施可能なものを試行」「10号機 HDD は最悪 brick OK」「PVE OS 再インストールも許容 (sda 退避なし)」「累積 18 時間まで」「pve10 sdb で確定後のみ横展開」の承認を得た。
- **意図する成果**: pve10 sdb 1 本で `dd if=/dev/zero of=/dev/sdb bs=512 count=1 oflag=direct` の成功 = opcode フィルタ解除を達成。成功すれば横展開し LINSTOR/ZFS pool 構築。失敗すれば失敗手段の網羅性を確定したレポートを作成。
- **claude 実施可能な未試行手段**:
  1. WRITE(16)/WRITE AND VERIFY/COMPARE AND WRITE/WRITE BUFFER 等の **未試行 opcode 全網羅** (Phase 4c log で確認、未試行確定)
  2. Seagate ST1200MM0088 / DKS5H-J1R2SS firmware の web 入手試行 (Playwright)
  3. sg_write_buffer mode 4/5/7 (Microcode Download) で firmware 書き換え (brick リスク受容)
  4. sg_write_buffer mode 2 + sdparm vendor page (0xF0-0xFF) の試行
  5. Broadcom sas3ircu / lsiutil 入手と HBA レベル介入
  6. **Nutanix AOS Community Edition Live boot で disk_release 試行** (sda 退避なし、OS 再インストール許容)

## 実装ステップ

### Phase 0: 準備 (10 分)

1. セッション ID 取得: Glob `pattern: "*.jsonl", path: "/home/ubuntu/.claude/transcripts"` → 先頭 8 文字
2. `mkdir -p tmp/<sid>`
3. `./issue.sh` で関連 issue (#61) を `start <sid>` で取得
4. pve10 BMC 電源 ON: `./oplog.sh ./pve-lock.sh run ./scripts/bmc-power.sh on 10.10.10.30 claude Claude123`
5. SSH 開通待機 (`ssh-wait.sh 10.10.10.210` パターン、最長 5 分)
6. パッケージ確認: `ssh -F ssh/config root@10.10.10.210 'apt list --installed sg3-utils sdparm blktrace 2>/dev/null'`、必要なら `apt-get install -y` 追加
7. ベースライン再現確認: `dd ... oflag=direct` が依然失敗、ASC=0x81 が出ること
8. LBA 1000 を試験 LBA に固定 (LBA 0 は Phase 2 で REASSIGN 済)

### Phase 3a: 未試行 SCSI opcode の全網羅試行 (30 分、brick リスクなし)

各 opcode を `sg_raw` で実行 → `dmesg` で sense 確認 → 該当 LBA 読み戻し検証。

| Opcode | コマンド | CDB (16 進) | データ |
|--------|---------|-------------|-------|
| 0x8a | WRITE(16) | `8a 00 00 00 00 00 00 00 03 e8 00 00 00 01 00 00` | zero 512B |
| 0x2e | WRITE AND VERIFY(10) | `2e 00 00 00 03 e8 00 00 01 00` | zero 512B |
| 0x8e | WRITE AND VERIFY(16) | `8e 00 00 00 00 00 00 00 03 e8 00 00 00 01 00 00` | zero 512B |
| 0x93 | WRITE SAME(16) | `93 00 00 00 00 00 00 00 03 e8 00 00 00 01 00 00` | zero 512B |
| 0x89 | COMPARE AND WRITE | `89 00 00 00 00 00 00 00 03 e8 00 00 00 01 00 00` | LBA1000 read 結果 + zero 512B |
| 0x8b | ORWRITE(16) | `8b 00 00 00 00 00 00 00 03 e8 00 00 00 01 00 00` | zero 512B |
| 0x9a | WRITE STREAM(16) | `9a 00 00 00 00 00 00 00 03 e8 00 00 00 01 00 00` | zero 512B (期待値低) |
| 0xa1 | ATA PASS-THROUGH | `a1 08 0e 00 00 00 00 00 00 ec 00 00` (read-only) | 排除目的 |

**試行スクリプト**: 1 つでも通ったら次の opcode は試さず Phase 3b に進む。全 reject なら Phase 3c へ。

### Phase 3b: WRITE(16) 通過時のワークアラウンド検証 (3-4 時間、Phase 3a で通過時のみ)

- Phase 3a で 16-byte CDB が通った場合のみ
- `/sys/block/sdb/queue/max_sectors_kb` を `max_hw_sectors_kb` まで引き上げ → blktrace で実際に 16-byte CDB が出るか確認
- 16-byte が出る → `mkfs.ext4` / `zpool create` を実行
- 10-byte しか出ない → ワークアラウンド困難と判定 → 3c へ

### Phase 3c: Seagate firmware 入手試行 (1-2 時間、brick リスクなし)

`tmp/<sid>/seagate-fw-search.py` を Playwright で作成 (dell-fw-download skill の stealth pattern 流用):

1. seagate.com/support/downloads/、seagate.com/support/enterprise/firmware/ 等を網羅探索
2. SeaChest_Lite for Linux を取得 (login 不要)
3. Web Archive (`web.archive.org/web/*/dl.seagate.com/*ST1200MM*`)、GitHub mirror (`github.com/search?q=DKS5H+OR+ST1200MM0088+filename:.LOD`) 探索
4. Supermicro `X10DRT-P` 関連 firmware の探索 (long shot)

**入手判定**: `.LOD` バイナリが手元 `tmp/<sid>/firmware.LOD` に保存されればその後 3d へ。30 分試行して何も得られなければ 3e へスキップ。

### Phase 3d: Microcode Download (sg_write_buffer mode 4/5/7) (1 時間、**brick リスク高**)

Phase 3c で LOD 入手成功時のみ。pve10 sdb のみで先行検証。

1. `scp tmp/<sid>/firmware.LOD root@10.10.10.210:/tmp/fw.LOD`
2. **mode 7** (Microcode + offsets + save + activate) を最優先: `sg_write_buffer --mode=7 --id=0 --in=/tmp/fw.LOD /dev/sdb`
3. mode 7 reject 時 → **mode 5** (Microcode + save、再起動で適用): `sg_write_buffer --mode=5 ... && sg_start --stop /dev/sdb && sg_start /dev/sdb`
4. mode 5 reject 時 → **mode 4** (Microcode のみ、揮発): `sg_write_buffer --mode=4 ...`、通れば mkfs/zpool を即実行
5. 成功時: `sg_inq /dev/sdb` で Firmware Rev 確認 (7FA9 以外なら成功)、`dd ... oflag=direct` で確認
6. brick 時: BMC power cycle で復旧試行、ダメなら sdb は失う、Phase 3e は sdc には適用せず 3f に進む

### Phase 3e: sg_write_buffer mode 2 + vendor mode page (30-60 分、brick リスク中)

Phase 3d で全 Microcode mode が reject された場合のみ。

1. `sg_read_buffer --mode=2 --id=0x00/0x01/0xfe/0xff --length=4096 /dev/sdb` で vendor area dump
2. zero buffer を `sg_write_buffer --mode=2` で書き戻し → `dd ... oflag=direct` 試行
3. `sdparm --page=0xf0/0xfe --hex /dev/sdb` で vendor page dump、フィルタ enable bit 探索 → `--set=<bit>=0 --save`

### Phase 3f: Broadcom sas3ircu / lsiutil 入手・試行 (1-2 時間、brick リスク低)

1. `tmp/<sid>/broadcom-fw-download.py` を Playwright で作成 (dell-fw-download パターン流用、Akamai stealth + UA)
2. `sas3ircu` (P16 Linux x64) と `lsiutil` を取得、10号機にアップロード
3. `sas3ircu 0 display` で HBA 状態確認
4. PHY reset / disconnect / hot spare 設定など HBA レベル介入を一通り試行
5. 各操作後に `dd ... oflag=direct` 試行

### Phase 3g: Nutanix AOS Community Edition Live boot (5-6 時間、PVE 破壊リスク許容済)

1. `tmp/<sid>/aos-ce-download.py` で Playwright 経由で AOS CE ISO 取得 (NEXT account 自動登録 / `s.nohara.2001@gmail.com` 使用、必要なら community.nutanix.com の直リンク取得)
2. ISO (~5GB) を SMB share に配置 (config/server10.yml に `aos_ce_iso_filename` 一時追加)
3. pve10 を `systemctl poweroff`
4. BMC VirtualMedia mount (`bmc-virtualmedia.sh` で AOS CE ISO)
5. boot-next を VirtualMedia に設定 (`bmc-power.sh boot-next`)、power on
6. SOL + KVM screenshot で boot menu を傍受、Live mode (RAM only) を選択 (`bmc-kvm-interact.py` で sendkey)
7. AOS Live shell で `genesis stop`、`disk_release /dev/sdb`、`edit-hades`、`ses_admin --clear-write-protect` 等を逐次試行
8. AOS shutdown → VirtualMedia umount → boot override reset → power cycle で PVE 復帰試行
9. PVE が起動しない場合: os-setup skill 通しで OS 再インストール (35-50 分)、preseed 等の構築済資産で復旧

### Phase 4: 横展開 (成功時のみ)

pve10 sdb で **dd 成功確定後** に実施:

1. 成功手順を `tmp/<sid>/unblock.sh` にまとめる
2. pve10 sdc に適用、成功確認
3. pve11/12/13 を BMC On、各 sdb/sdc に適用
4. LINSTOR satellite を 4 ノードで再起動 (`scripts/linstor-multiregion-node.sh`)
5. ZFS pool 作成 → LINSTOR resource pool 登録
6. 既存 pvese-cluster-c (controller=pve10) に統合

### Phase 5: シャットダウン + レポート + Issue 更新 (10-20 分)

**成功・失敗を問わず、必ず全ノードを電源 Off まで落とす** (ユーザ明示指示)。

1. 起動済の全ノード OS shutdown: `ssh -F ssh/config root@<host> systemctl poweroff` を pve10-13 のうち電源 On のノード分実施
2. BMC 電源 Off 確認: `./oplog.sh ./pve-lock.sh run ./scripts/bmc-power.sh status 10.10.10.30/31/32/33 claude Claude123` で全ノード Off を確認、Off になっていなければ `bmc-power.sh off` を実行
3. レポート作成: `report/2026-05-04_<HHMMSS>_server10_hw_err_phase3.md` (REPORT.md ルール準拠) — 成功時もアウトカム + 横展開状況 + シャットダウン履歴を記録
4. 添付ログ配置: `report/attachment/2026-05-04_<HHMMSS>_server10_hw_err_phase3/`
5. Issue #61 更新: 成功時 close、失敗時 blocked 継続 + 試行手段の網羅性記録

## 中断条件・分岐ロジック

| 状況 | 判断 |
|------|------|
| 任意 phase で `dd ... oflag=direct` 成功 | Phase 4 (横展開) へ。以降の phase スキップ |
| Phase 3a 全 opcode reject | 3b スキップ → 3c へ |
| Phase 3c で 30 分探索しても LOD 入手不可 | 3d スキップ → 3e へ |
| Phase 3d で sdb brick | 3e スキップ → 3f へ (sdc は触らない) |
| Phase 3f まで全失敗 | 3g (AOS CE) を実行 |
| 累積 18 時間経過 | 即時切り上げ → Phase 5 |
| 成功 (Phase 4 完了) | Phase 5 へ進み **全ノードシャットダウン** (ユーザ明示) |
| 失敗 (3g まで全敗) | Phase 5 へ進み **全ノードシャットダウン** (ユーザ明示) |

## 成功判定 (Phase 全体)

`pve10` で以下が **すべて** 成立:

1. `ssh -F ssh/config root@10.10.10.210 dd if=/dev/zero of=/dev/sdb bs=512 count=1 oflag=direct` が exit 0
2. `dmesg -T --since "1 minute ago" | grep ASC=0x81` が空
3. `mkfs.ext4 -F /dev/sdb` 完走
4. `zpool create -f testpool /dev/sdb && zpool destroy testpool` 完走
5. (横展開後) 8 本 (pve10-13 × sdb/sdc) 全てで上記 1-4 が再現

## 修正・追加ファイル

実装中に新規作成 / 修正するもの:

- `tmp/<sid>/` 配下の試行スクリプト (commit しない、毎回再作成)
  - `phase3a-opcodes.sh` — sg_raw で 8 種 opcode を順次試行
  - `phase3c-seagate-fw-download.py` — Playwright で Seagate firmware 探索
  - `phase3d-microcode-download.sh` — sg_write_buffer 試行
  - `phase3e-vendor-buffer.sh` — mode 2 / sdparm vendor page 試行
  - `phase3f-broadcom-fw-download.py` — Playwright で Broadcom utility 探索
  - `phase3g-aos-ce-download.py` — Playwright で AOS CE ISO 取得
- `config/server10.yml` — Phase 3g 用に `aos_ce_iso_filename` 一時追加 (Phase 5 で復元 or 残置を選択)

## 流用する既存資産 (絶対パス)

- `/home/ubuntu/projects/pvese/scripts/bmc-power.sh` — 全 phase の電源制御
- `/home/ubuntu/projects/pvese/scripts/bmc-virtualmedia.sh` — Phase 3g ISO mount
- `/home/ubuntu/projects/pvese/scripts/bmc-session.sh` — Phase 3g BMC 認証
- `/home/ubuntu/projects/pvese/scripts/sol-monitor.py` — Phase 3g boot 監視
- `/home/ubuntu/projects/pvese/scripts/sol-login.py` — Phase 3g AOS shell 操作
- `/home/ubuntu/projects/pvese/scripts/ssh-wait.sh` — SSH 復帰待機
- `/home/ubuntu/projects/pvese/scripts/bmc-kvm-interact.py` — Phase 3g boot menu key 操作
- `/home/ubuntu/projects/pvese/.claude/skills/dell-fw-download/SKILL.md` — Phase 3c/3f/3g の Playwright stealth template
- `/home/ubuntu/projects/pvese/.claude/skills/playwright/SKILL.md` — Playwright 基盤
- `/home/ubuntu/projects/pvese/.claude/skills/os-setup/SKILL.md` — Phase 3g 復旧時の OS 再インストール
- `/home/ubuntu/projects/pvese/.claude/skills/bios-setup/SKILL.md` — KVM screenshot + sendkey
- `/home/ubuntu/projects/pvese/oplog.sh` — 全 phase の状態変更操作ログ
- `/home/ubuntu/projects/pvese/pve-lock.sh` — 電源系・PVE 系操作の排他
- `/home/ubuntu/projects/pvese/.venv/bin/python` — Playwright 実行
- Phase 2 SANITIZE 済の sdb (zero pattern 物理状態) — 初期状態既知

## リスク受容 (ユーザ確認済)

- pve10 sdb の brick 許容
- pve10 OS disk (sda) の AOS CE による書き換え許容 (退避なし、OS 再インストール許容)
- 累積 18 時間タイムボックス
- pve11-13 は sdb 確定後のみ起動 (Phase 4 まで電源 Off 維持)
- PVE クラスタ pvese-cluster-c は Phase 3a-3f 中は維持、Phase 3g 中のみ pve10 が一時離脱 (quorum=3 想定で残 3 台で維持可)
- **成功・失敗を問わず Phase 5 で全ノードシャットダウン** (ユーザ明示指示)。pvese-cluster-c は本セッション終了後 Off の状態

## 検証 (端から端)

成功時:

1. `ssh -F ssh/config root@10.10.10.210 dd if=/dev/zero of=/dev/sdb bs=512 count=1 oflag=direct && echo OK`
2. `ssh -F ssh/config root@10.10.10.210 sg_inq /dev/sdb | grep "Product revision"` (firmware 変更確認)
3. `ssh -F ssh/config root@10.10.10.210 zpool create -f testpool /dev/sdb && zpool list testpool && zpool destroy testpool`
4. 横展開後: `for h in pve10 pve11 pve12 pve13; do for d in sdb sdc; do ssh -F ssh/config root@$h "dd if=/dev/zero of=/dev/$d bs=512 count=1 oflag=direct && echo $h/$d=OK"; done; done` が全件 OK
5. LINSTOR satellite 復旧: `linstor node list` で 4 ノード ONLINE
6. ZFS pool 作成 + LINSTOR resource pool 登録: `linstor storage-pool list` で 4 ノード分表示

失敗時:

1. レポート (`report/2026-05-04_*_server10_hw_err_phase3.md`) が REPORT.md ルール準拠で存在
2. 添付ログ (各 phase の dmesg / sg_raw 出力) が attachment ディレクトリに配置
3. Issue #61 が blocked 継続で試行手段の網羅性が更新
4. 全 4 ノードが BMC 電源 Off
