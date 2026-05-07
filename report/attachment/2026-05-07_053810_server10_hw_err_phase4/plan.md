# Plan: Phase 3 で blocked された 2 手段の再試行 (Track A: Seagate FW / Track B: AOS CE)

## Context

Phase 3 (`report/2026-05-04_191138_server10_hw_err_phase3.md`) で完全ギブアップとなった 10-13号機 Seagate DKS5x ASC=0x81 vendor reject に対し、ISO/firmware の入手段階で blocked になった 2 手段を、ユーザの手動 web 操作で取得 → claude が続行する形で再試行する。

- **Track A (Seagate firmware 書き換え, Phase 3c+3d)**: `apps1.seagate.com` の login wall で claude 自動取得不可だった `.LOD` を、ユーザが ServiceWare account でダウンロードして提供 → claude が `sg_write_buffer mode 7/5/4` で書き換え
- **Track B (Nutanix AOS CE Live boot, Phase 3g)**: `portal.nutanix.com` の login wall + reCAPTCHA で claude 自動取得不可だった AOS CE ISO を、ユーザが NEXT account でダウンロード → claude が VirtualMedia mount + Live boot + AOS shell で `disk_release` 等を試行

目標と完了条件は Phase 3 と同じ: pve10 /dev/sdb で `dd if=/dev/zero of=/dev/sdb bs=512 count=1 oflag=direct` 成功 (= ASC=0x81 解除)。確定後のみ pve10 sdc → pve11-13 sdb/sdc の合計 8 本に横展開。

リスク受容 (ユーザ確認済、Phase 3 と同じ):
- HDD brick 許容 (pve10 sdb 1 本で先行検証)
- PVE OS disk (sda) の Live boot 経由書き換え許容、OS 再インストール許容
- 累積 18 時間タイムボックス
- 成功・失敗を問わず Phase 5 で全 4 ノードシャットダウン

---

## ユーザに依頼するファイル取得作業 (ブラウザ手動)

両方とも未取得のため、claude は Phase 0 終端でユーザに案内し、ファイル到着を待つ。**両方揃わなくても、片方届いた段階で先に Track A を進められる**。

### A. Seagate firmware (.LOD) — Track A 用

| 項目 | 値 |
|------|------|
| 入手先候補 1 | https://apps1.seagate.com/downloads/request.html (ServiceWare Portal、要 account 登録) |
| 入手先候補 2 | https://www.seagate.com/support/by-topic/firmware/ |
| 検索キー | OEM 型番: `DKS5H-J1R2SS` / 汎用型番: `ST1200MM0088` (Enterprise Performance 10K v8、1.2TB SAS) |
| 期待ファイル | `<modelname>.LOD` (firmware blob、8-16 MB 程度) |
| 配置先 | ローカル `/home/ubuntu/projects/pvese/tmp/<sid>/firmware.LOD` (claude が SCP で各ノードへ転送) |
| 注記 | 現状 FW Rev は `7FA9`。同 Rev でも書き換えに成功すれば opcode フィルタが消える可能性あり。Phase 3 で SeaChest_Info が `Firmware Download Support: Full, Segmented, Deferred` を確認済 |

### B. Nutanix AOS CE ISO — Track B 用

| 項目 | 値 |
|------|------|
| 入手先候補 1 | https://portal.nutanix.com/page/downloads?product=ce → My Nutanix login (NEXT account 登録) → Community Edition |
| 入手先候補 2 | https://next.nutanix.com (community forum、要 login) |
| 期待ファイル | `phoenix-ce-<version>.iso` または `nutanix-ce-<version>.iso` (~5GB) |
| 配置先 | SMB share `\\10.1.6.1\public\` 配下 (ホスト側ディレクトリ `/var/samba/public/`) にユーザがファイルマネージャ等で配置 |
| 命名 | `aos-ce.iso` を推奨 (claude 側で `config/server10.yml` の `iso_filename` を一時変更) |
| 注記 | NEXT account 自動登録は reCAPTCHA でブロックされるが、ユーザ手動なら可。認証メールも必要 |

---

## 実装ステップ

### Phase 0: 準備 + ファイル取得待ち (ファイル到着次第)

1. セッション ID 取得 (Glob `*.jsonl` in `/home/ubuntu/.claude/transcripts` → 先頭 8 文字)
2. `mkdir -p tmp/<sid>`
3. `./issue.sh start 61 --owner <sid>` で Issue #61 を取得
4. 上記「ユーザに依頼する取得作業」をユーザに案内、両方の取得状況を確認
5. ファイル検証:
   - Track A: Read で `tmp/<sid>/firmware.LOD` のサイズ・先頭バイト確認
   - Track B: SSH で `ls /var/samba/public/aos-ce.iso` 等で SMB host 側のサイズ確認
6. 両方 or 片方が届いたら次の Phase へ。Track A は brick リスクが drive 単位のみのため先行

### Phase A: Seagate firmware 書き換え (1-2 時間、pve10 sdb 限定)

1. **電源 ON + baseline**:
   - `./oplog.sh ./pve-lock.sh run ./scripts/bmc-power.sh on 10.10.10.30 claude Claude123`
   - `./scripts/ssh-wait.sh 10.10.10.210 --timeout 300 --interval 10`
   - SSH で `dd if=/dev/zero of=/dev/sdb bs=512 count=1 oflag=direct` → ASC=0x81 再現確認
   - `sg_inq /dev/sdb` で現状 FW Rev 7FA9 を記録
2. **LOD アップロード**: `scp -F ssh/config tmp/<sid>/firmware.LOD root@10.10.10.210:/tmp/fw.LOD`、`md5sum` 比較
3. **mode 7** (Microcode + offsets + save + activate、最優先): `sg_write_buffer --mode=7 --id=0 --in=/tmp/fw.LOD /dev/sdb` → 成功時 `sg_inq` で Rev 確認、`dd ... oflag=direct` 試行
4. **mode 5** (Microcode + save、再起動で適用): mode 7 reject 時のみ。`sg_write_buffer --mode=5 ...` → `sg_start --stop /dev/sdb && sg_start /dev/sdb` で再起動 → 検証
5. **mode 4** (Microcode のみ、揮発): mode 5 reject 時のみ。即座に `dd ... oflag=direct` 試行 (再起動で揮発)
6. **brick 復旧**: I/O hang 時は `echo 1 > /sys/block/sdb/device/delete` + `echo "- - -" > /sys/class/scsi_host/host0/scan` を `scp + ssh` パターンで実行 (CLAUDE.md の引数内 `"- - -"` 制約あり)
7. **成功時** → Phase 4 (横展開)、**全 mode reject** → Phase B、**brick** → Phase B (sdc は触らない)

### Phase B: Nutanix AOS CE Live boot (3-5 時間、PVE 破壊許容)

1. **ISO 配置検証**: SMB host 上で AOS CE ISO の存在確認、`config/server10.yml` の `iso_filename` を `aos-ce.iso` に一時変更 (Phase 5 で復元)
2. **pve10 shutdown**: Phase A で起動中なら `ssh root@10.10.10.210 systemctl poweroff` → BMC で Off 確認
3. **BMC session + VirtualMedia mount**:
   - `./scripts/bmc-session.sh login 10.10.10.30 claude Claude123 tmp/<sid>/cookie tmp/<sid>/csrf`
   - SMB path は **必ず** `./bin/yq '.smb_share_path' config/server10.yml` で読み取って渡す (シェルリテラルで `'\public'` を書くと二重バックスラッシュで silent failure。Issue #18 既報)
   - `./scripts/bmc-virtualmedia.sh config 10.10.10.30 ... 10.1.6.1 <smb_path>` → `mount` → `verify` で `Inserted=true` 確認
4. **boot-next + Power On**:
   - `./oplog.sh ./pve-lock.sh run ./scripts/bmc-power.sh boot-next 10.10.10.30 claude Claude123 Cd`
   - `./oplog.sh ./pve-lock.sh run ./scripts/bmc-power.sh on 10.10.10.30 claude Claude123`
5. **boot menu 監視 + Live mode 選択**:
   - `./scripts/sol-monitor.py` をバックグラウンドで起動 (run_in_background=true)
   - `./scripts/bmc-kvm-interact.py screenshot tmp/<sid>/screen-1.png` で boot 画面確認
   - GRUB に到達したら `bmc-kvm-interact.py sendkeys` で "Live (RAM)" 等の RAM only モードを選択 (--screenshot で操作後確認)
6. **AOS Live shell 操作** (`sol-login.py` または KVM 経由で対話):
   - root 昇格後、順に試行: `genesis stop` → `disk_release /dev/sdb` → `edit-hades --mark-removed=/dev/sdb` → `ses_admin --clear-write-protect /dev/sdb` → `clean_disks --disk=/dev/sdb` (or `disk_operator.py --action=cleanup`)
   - 各コマンド後 `dd if=/dev/zero of=/dev/sdb bs=512 count=1 oflag=direct` で write 試行、dmesg + sense data を `tmp/<sid>/aos-shell.log` に記録
7. **AOS shutdown → PVE 復帰**:
   - `systemctl poweroff` → BMC Off 確認
   - `./scripts/bmc-virtualmedia.sh umount ...`
   - `./scripts/bmc-power.sh boot-next 10.10.10.30 claude Claude123 None` (or Hdd)
   - Power On + SSH 開通待機 → PVE 起動確認
   - **PVE 起動不能時**: `os-setup` skill で再インストール (35-50 分、preseed 構築済資産で復旧)
8. **成功時** → Phase 4、**失敗時** → Phase 5

### Phase 4: 横展開 (成功時のみ)

pve10 sdb で完了条件成立後:

1. 成功手順を `tmp/<sid>/unblock-{fw,aos}.sh` にまとめる
2. pve10 sdc に適用 → 成功確認
3. pve11/12/13 を BMC On、各 sdb/sdc に適用 (Track A は LOD scp + sg_write_buffer、Track B は AOS CE Live boot を各ノードで実行)
4. LINSTOR satellite を 4 ノードで再起動 (`./scripts/linstor-multiregion-node.sh`)
5. ZFS pool 作成 → LINSTOR resource pool 登録 → 既存 pvese-cluster-c (controller=pve10) に統合

### Phase 5: クリーンアップ + シャットダウン + レポート (15-30 分)

成功・失敗を問わず実施:

1. ISO/LOD 撤去:
   - SMB share の AOS CE ISO 削除をユーザに依頼 (or SSH で削除可能な場所なら `rm`)
   - `config/server10.yml` の `iso_filename` を元 (`debian-preseed-s10.iso`) に戻す
   - 各ノード `/tmp/fw.LOD` を `rm -f` (BMC Off で揮発するが念のため)
2. 各ノード `systemctl poweroff` → `bmc-power.sh status` で 4 台 Off 確認、Off でなければ `bmc-power.sh off`
3. レポート作成: `report/2026-05-04_<HHMMSS>_server10_hw_err_phase4.md` (REPORT.md ルール準拠)、添付ログを `report/attachment/<同名>/` に配置
4. Issue #61 更新: 成功時 close、失敗時 blocked 継続 + 試行網羅性記録

---

## 中断条件・分岐ロジック

| 状況 | 判断 |
|------|------|
| 任意時点で `dd ... oflag=direct` 成功 | Phase 4 (横展開) へ。残 phase スキップ |
| Phase A 全 mode reject | Phase B へ |
| Phase A で sdb brick | Phase B へ (sdc は触らない、AOS 経由救済を期待) |
| Phase B で AOS shell 到達不可 (boot 失敗 / 言語選択ハング) | KVM screenshot + SOL log を保存して Phase 5 |
| Phase B で AOS shell からも write 不可 | Phase 5 (drive firmware 焼付フィルタの最終確証) |
| 累積 18 時間経過 | 即時 Phase 5 |
| ファイル両方未到着 + ユーザ取得 abort | Phase 5 (試行不能で blocked 継続) |
| 成功・失敗を問わず | Phase 5 で全ノード Off |

---

## 成功判定 (Phase 全体)

`pve10 /dev/sdb` で:

1. `dd if=/dev/zero of=/dev/sdb bs=512 count=1 oflag=direct` exit 0
2. `dmesg --since "1 minute ago"` に ASC=0x81 なし
3. `mkfs.ext4 -F /dev/sdb` 完走
4. `zpool create -f testpool /dev/sdb && zpool destroy testpool` 完走
5. (横展開後) 8 本 (pve10-13 × sdb/sdc) で 1-4 が再現

---

## 修正・追加ファイル

- `tmp/<sid>/firmware.LOD` (ユーザ手動配置)
- `tmp/<sid>/phase-a-fw.sh` — sg_write_buffer mode 7/5/4 順試行ラッパー
- `tmp/<sid>/phase-b-aos.sh` — VirtualMedia mount + boot + AOS shell 操作ラッパー
- `tmp/<sid>/cookie`, `tmp/<sid>/csrf` — BMC session
- `config/server10.yml` — `iso_filename` を一時変更 (Phase 5 で復元)
- `report/2026-05-04_<HHMMSS>_server10_hw_err_phase4.md` (Phase 5 で作成)
- `report/attachment/2026-05-04_<HHMMSS>_server10_hw_err_phase4/` (添付ログ)

---

## 流用する既存資産 (絶対パス)

- `/home/ubuntu/projects/pvese/scripts/bmc-power.sh` — 全 phase の電源・boot-next 制御
- `/home/ubuntu/projects/pvese/scripts/bmc-virtualmedia.sh` — Phase B の config/mount/umount/verify (10号機 BMC は modern Redfish パスで動作確認済)
- `/home/ubuntu/projects/pvese/scripts/bmc-session.sh` — Phase B の BMC CGI 認証
- `/home/ubuntu/projects/pvese/scripts/sol-monitor.py` — Phase B の boot 監視
- `/home/ubuntu/projects/pvese/scripts/sol-login.py` — Phase B の AOS shell 対話操作
- `/home/ubuntu/projects/pvese/scripts/ssh-wait.sh` — Phase A/B 共通の SSH 復帰待機
- `/home/ubuntu/projects/pvese/scripts/bmc-kvm-interact.py` — Phase B の boot menu / KVM 操作
- `/home/ubuntu/projects/pvese/.claude/skills/os-setup/SKILL.md` — Phase B 復旧時の OS 再インストール
- `/home/ubuntu/projects/pvese/.claude/skills/bios-setup/SKILL.md` — KVM screenshot + sendkey 参照
- `/home/ubuntu/projects/pvese/oplog.sh` — 状態変更ログ
- `/home/ubuntu/projects/pvese/pve-lock.sh` — 電源・PVE 系排他
- `/home/ubuntu/projects/pvese/bin/yq` — `config/server10.yml` の `smb_share_path` 読み取り (バックスラッシュ問題回避必須)

---

## 検証 (端から端)

成功時:

1. `ssh -F ssh/config root@10.10.10.210 dd if=/dev/zero of=/dev/sdb bs=512 count=1 oflag=direct && echo OK`
2. `ssh -F ssh/config root@10.10.10.210 sg_inq /dev/sdb | grep "Product revision"` (Track A 成功時 Rev 変更、Track B 成功時は元 Rev のまま)
3. `ssh -F ssh/config root@10.10.10.210 zpool create -f testpool /dev/sdb && zpool list testpool && zpool destroy testpool`
4. 横展開後の 8 本ループ確認 (CLAUDE.md の `for` 禁止に従い、スクリプトファイル化して `sh tmp/<sid>/verify-all.sh`)
5. LINSTOR satellite ONLINE 4 ノード確認

失敗時:

1. `report/2026-05-04_<HHMMSS>_server10_hw_err_phase4.md` が REPORT.md 準拠で存在
2. 添付ログ (各 phase の dmesg / sg_raw / SOL log / KVM screenshot) が attachment ディレクトリに配置
3. Issue #61 が blocked 継続で試行手段の網羅性が更新
4. `bmc-power.sh status` で 4 ノードが BMC 電源 Off
