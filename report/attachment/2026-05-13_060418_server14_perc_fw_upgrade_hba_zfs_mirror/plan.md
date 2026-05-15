# 14号機 RAID 再構成: Bay 0+1 HW RAID-1 (boot) + Bay 2-7 ZFS RAID-Z1 (data)

## Context

14号機 (Dell PowerEdge R430 / iDRAC8 / PERC H730P Mini FW **25.5.5.0005**) は現在 Bay 1+6 (ST9300653SS×2) の RAID-1 上で Debian 13 + PVE 9.1.9 が稼働中。ただしこの構成は 2026-05-12 のリトライで「Bay 0+1 RAID-1 が BGI 26% で停滞」した結果の回避策で、本来希望される構成 (4-9号機と同じパターン、参考 `report/2026-03-30_025702_linstor_zfs_raidz1_benchmark.md`) に整え直す。

**目標構成** (1-indexed の「1, 2」 = 0-indexed の Bay 0+1):
- **Boot**: HW RAID-1 on **Bay 0 + Bay 1** (ST300MP0026 12Gb/s + ST9300653SS 6Gb/s)
- **Data**: ZFS RAID-Z1 on **Bay 2, 3, 4, 5, 6, 7** (5×DKS5E K300SS 277.27GB + 1×ST9300653SS 278.88GB) → 各 disk を PERC non-RAID mode で expose、~1.4TB usable

**ユーザ方針**: 「予想外に時間がかかってもかまわない (最大 24 時間)。じっくり調査せよ」「私の判断がどうしても必要なこと以外は、続行可否を確認せずに続行してください」
- 各 Phase で SMART long self-test、複数 disk 横並び検証、BGI 長時間観測 (最大 4-6h)、ZFS scrub 等を含む
- 自律実行: 各 Phase 完了時にユーザ確認は不要。継続判断は Claude 側で実施
- ユーザ判断が必要な場合のみ AskUserQuestion で問い合わせ (該当条件は下記「失敗時の停止判断」表に明記)

**Bay 0+1 BGI 26% 停滞のリスク管理**:
1. **PERC FW 25.5.5.0005 → 25.5.9.0001 に更新**してから retry (15号機の FW で BGI 進行成功)
2. **全 5 本の DKS5E K300SS** が 10-13号機の Hitachi write filter と同じか事前検証 (uniform behavior の確認)
3. Bay 0+1 で再度 BGI 停滞 → Phase 7 で 4 時間観測後に AskUserQuestion で代替 pair を問い合わせ (失敗時判断表 Phase 7 「Y」)

**OS 再インストール**: os-setup スキルで preseed-server14.cfg (LVM 方式既存) を使ってクリーンインストール。

**参照済過去レポート**:
- `report/2026-05-12_040320_server14_os_install_retry.md` (Bay 0+1 BGI 停滞の根本原因仮説)
- `report/2026-04-01_004941_region_b_raid_os_setup.md` (Region B RAID 再構成パターン)
- `report/2026-03-30_025702_linstor_zfs_raidz1_benchmark.md` (`zpool create raidz1 sdb sdc sdd sde sdf sdg`)
- `report/2026-05-08_012907_server10-13_phase6_hitachi_origin_analysis.md` (Hitachi write-block 真因 + Phase 1-8 検証パス)
- `report/2026-05-08_033632_server10-13_phase8_openseachest_oss_retry.md` (Phase 8 sg_write_buffer 全 mode 検証)

**プロジェクト制約**: CLAUDE.md 厳守 — `./` 付き相対パス、`tmp/<sid>/`、状態変更は `./pve-lock.sh run ./oplog.sh`、SSH リダイレクト/パイプ/forループ/変数展開 禁止 (scp+ssh パターンまたはスクリプトファイル経由)。

---

## 実行フロー (依存関係)

```
Phase 1 → Phase 2 → Phase 3 ─┬→ Phase 4 (DKS5E 全数検証, ~2-4h) ─┐
                              └→ Phase 5 (Bay 0 SMART long, ~1-2h) ┤
                                                                     ↓
                                  Phase 6 (PERC FW 更新, ~40 min)
                                                                     ↓
                                  Phase 7 (VD 再構成 + BGI 観測 ~4-6h) [DESTRUCTIVE]
                                                                     ↓
                                  Phase 8 (OS 再インストール, ~1-3h)
                                                                     ↓
                                  Phase 9 (ZFS RAID-Z1 + scrub, ~1-2h)
                                                                     ↓
                                  Phase 10 (検証 + コールド再起動 + レポート)
```

各 Phase は完了後に短い報告 (発見事項) のみ出して、Claude 側で自律的に次 Phase へ進む。ユーザ判断が必要な場合 (= 下記「失敗時の停止判断」表の該当条件) のみ AskUserQuestion で停止する。

---

## Phase 1: ベースライン採取 + 現状ストレステスト (read-only)

**目的**: 14号機 + 15号機の現状ディスク・VD・コントローラ状態を網羅取得 + 現 OS_RAID1 が安定動作していることを baseline として確立。

**手順**:

### 1.1 静的情報取得 (個別 Bash 呼び出し)
- `ssh -F ssh/config pve14 lsblk -o NAME,SIZE,MODEL,SERIAL,TYPE,FSTYPE`
- `ssh -F ssh/config pve14 pvesm status`
- `ssh -F ssh/config pve14 pvs` / `lvs` / `vgs`
- `ssh -F ssh/config pve14 cat /proc/mdstat` (mdraid 不在確認)
- `ssh -F ssh/config pve14 lspci -k -d ::0104` (PERC controller PCI 情報)
- `ssh -F ssh/config pve14 dmesg | grep -i -E "megaraid|perc|sd[a-h]"` (パイプ不可なので別途 grep 用スクリプト)
- `ssh -F ssh/config idrac14 racadm getsysinfo`
- `ssh -F ssh/config idrac14 racadm storage get controllers`
- `ssh -F ssh/config idrac14 racadm storage get pdisks`
- `ssh -F ssh/config idrac14 racadm storage get vdisks`
- 同じ 4 つの racadm を `idrac15` でも実行

### 1.2 現 VD0 (Bay 1+6) ストレステスト (1 時間)
- 目的: 現 OS_RAID1 が今後の作業 baseline として stable か確認
- スクリプト `tmp/<sid>/vd0-stress.sh`: `dd if=/dev/urandom of=/var/tmp/stress.bin bs=1M count=2048 conv=fdatasync; dd if=/var/tmp/stress.bin of=/dev/null bs=1M; rm /var/tmp/stress.bin` を 3 回ループ
- scp → `./pve-lock.sh run ./oplog.sh ssh -F ssh/config pve14 sudo sh /tmp/vd0-stress.sh`
- 同時に `dmesg --follow` で I/O エラー監視 (別 SSH セッション、bg)
- 完了後 `racadm storage get vdisks` で VD0 Optimal 維持確認

**保存**: `tmp/<sid>/baseline/*.txt`、最終的に report 添付。

**成功判定**: pve14 で `/dev/sda` (現 VD0=Bay 1+6) 認識、8 PD 全て列挙、ストレステストで I/O エラー無し。

**所要**: 1.5-2 時間

---

## Phase 2: 診断ツール導入 (低リスク)

**目的**: pve14 に perccli64 + smartctl + sg3-utils + zfsutils-linux + lsscsi を入れて、ホスト側からの SCSI/SMART/PERC アクセス基盤を確立。

**手順**:

### 2.1 apt パッケージ
- 192.168.39.1 default GW 確認 (`ssh -F ssh/config pve14 ip route show default`)
- `ssh -F ssh/config pve14 sudo apt-get update`
- `ssh -F ssh/config pve14 sudo apt-get install -y smartmontools sg3-utils lsscsi parted xfsprogs zfsutils-linux fio`

### 2.2 perccli 入手 + インストール (実行時に手段確定)

**入手手段の優先順位**:
1. (a) Dell サポート `dell.com/support/home/` → ServiceTag `GLYHKF2` → "PERC CLI" Linux 用 `.tar.gz`
   - 配布形態: `.tar.gz` 内に `perccli_xxx.deb` または `.rpm`
   - `.deb` 直接 → `dpkg -i`
   - `.rpm` のみ → `rpm2cpio` で展開、バイナリ `/opt/MegaRAID/perccli/perccli64` を抽出 (sh スクリプト経由)
2. (b) Broadcom storcli64 (代替、PERC 互換) — `https://docs.broadcom.com/docs/Unified_storcli`
3. (c) 14号機にすでに apt で `megacli` があるか確認 (なくても OK)

**ローカル → pve14 転送**: ローカルマシン (192.168.39.x 経由 DL) → scp で `/var/tmp/perccli-XXX.tar.gz` 配置

**動作確認**:
- `ssh -F ssh/config pve14 sudo /opt/MegaRAID/perccli/perccli64 /c0 show`
- `ssh -F ssh/config pve14 sudo /opt/MegaRAID/perccli/perccli64 /c0 show all`
- 期待出力: "Product Name = PERC H730P Mini", "FW Package Build = 25.5.5.0005"

### 2.3 smartctl megaraid 経路確認
- `ssh -F ssh/config pve14 sudo smartctl -d megaraid,0 -a /dev/sda`
- megaraid PD ID は `perccli64 /c0/eall/sall show` の DID (Device ID) で確定

### 2.4 wrapper script 生成
- `scripts/server14-perccli-install.sh` を新規作成 (Phase 2 を再現可能に)

**成功判定**: `perccli64 /c0 show` rc=0、`smartctl -d megaraid,N` で 8 PD 全 SMART 取得可。

**所要**: 30-60 分 (Dell サポートサイトの取得時間含む)

---

## Phase 3: 全 PD + コントローラ詳細診断 (read-only, SMART long self-test 含む)

**目的**: 8 PD 全 SMART + link speed + error counter + SMART long self-test を取得。Bay 0 の link speed mismatch 仮説を実機確認。

**手順**:

### 3.1 perccli + smartctl baseline 採取
- `perccli64 /c0 show all` (controller info, FW, BBU, cache, foreign config)
- `perccli64 /c0/eall/sall show all` (全 PD: Link Speed Negotiated/Max, Media Error, Other Error, Predictive Failure, SMART Alert, Manufactured Date, FW)
- `perccli64 /c0/vall show all` (VD0 状態、BGI/CC 進捗)
- `smartctl -d megaraid,N -a /dev/sda` を N=0..7 で 8 個並列

### 3.2 SMART long self-test (並列実行、~1-4 時間)
- 各 PD で `smartctl -d megaraid,N -t long /dev/sda` を 8 個並列起動
- 進捗監視: 1 時間ごとに `smartctl -d megaraid,N -l selftest /dev/sda`
- 完走後の結果確認 (PASS / FAIL / errors)

### 3.3 link speed 詳細
- Bay 0 (ST300MP0026 12Gb/s 想定) の **Current Link Speed (Negotiated)** vs **Max Link Speed (Capable)**
- 全 PD の port number, expander chain
- backplane SAS 速度確認 (`perccli64 /c0/eall show` で Enclosure 情報)

### 3.4 15号機との比較 (FW 25.5.5 vs 25.5.9 差分)
- 同じコマンドを pve15 でも実行 (Phase 2 で 15号機にも perccli インストール)
- diff で controller settings 差分を文書化

**保存**: `tmp/<sid>/diag/perccli-*.txt`, `smartctl-*.txt`、レポート添付。

**成功判定**: 8 PD 全 SMART 取得、SMART long self-test 全 PASS、link speed 文書化、15号機との差分明確化。

**特記**: SMART long self-test 中も PD は I/O 可能 (低優先度バックグラウンド)。並列で他作業可。

**所要**: 1-4 時間 (SMART long の disk 速度依存)

---

## Phase 4: 全 DKS5E K300SS Hitachi write-block 検証 (Bay 2,3,4,5,7 全数)

**目的**: 5 本の DKS5E が 10-13号機 の DKS5x-J1R2SS と同じ Hitachi write filter (ASC=0x81 LA Check Error) を持つか **全数判定**。1 本だけだと外れ値の可能性、5 本横並びで uniform behavior を確認。書込み不可ならば ZFS RAID-Z1 不成立 → Phase 7-9 計画変更。

**手順**:

### 4.1 全 5 本を non-RAID 化 (Bay 2, 3, 4, 5, 7)
- 各 Bay について個別 Bash 呼び出し (for ループ禁止):
  - `./pve-lock.sh run ./oplog.sh ssh -F ssh/config idrac14 racadm storage converttononraid:Disk.Bay.2:Enclosure.Internal.0-1:RAID.Integrated.1-1`
  - 同様に Bay 3, 4, 5, 7 (Bay 6 は現 VD0 member なので除外)
- `./pve-lock.sh run ./oplog.sh ssh -F ssh/config idrac14 racadm jobqueue create RAID.Integrated.1-1 --realtime` (5 件まとめて適用)
- realtime job 非対応の場合は `-s TIME_NOW -r pwrcycle` で計画停止

### 4.2 SCSI rescan + 新 disk 認識
- Write `tmp/<sid>/rescan.sh` (find ベース、リダイレクト不可なので shell loop)
- `scp tmp/<sid>/rescan.sh root@10.10.10.214:/tmp/`
- `ssh -F ssh/config pve14 sudo sh /tmp/rescan.sh`
- `ssh -F ssh/config pve14 lsscsi`
- `ssh -F ssh/config pve14 lsblk` で `/dev/sdb..sdf` (5 disks) 識別

### 4.3 各 disk の identity 取得
- `sg_inq /dev/sdb` 〜 `sg_inq /dev/sdf` (5 回個別)
- ベンダ ID (例: HGST, HITACHI, SEAGATE)、モデル、FW Rev、Unit Serial Number を採取
- 期待: 10-13号機 DKS5x-J1R2SS と同じ HGST/Hitachi 系か、別系列か

### 4.4 書込みテスト (5 本全数、2 段階)

**Step A: 1 セクタ書込み (10-13号機 Phase 1 相当)**
- Write `tmp/<sid>/dks5e-write-1sec.sh`:
  ```sh
  #!/bin/sh
  set -eu
  DEV=$1
  echo "=== Test 1-sector write on $DEV ==="
  dd if=/dev/zero of=$DEV bs=512 count=1 oflag=direct && echo "WRITE_OK_1SEC" || echo "WRITE_FAILED_1SEC"
  ```
- 5 disk に対して個別実行: `./pve-lock.sh run ./oplog.sh ssh ... sh /tmp/dks5e-write-1sec.sh /dev/sdb` を 5 回

**Step B: 64KB 書込み + dmesg 確認** (失敗時のみ詳細)
- Step A で失敗した disk について `dmesg --since "1 minute ago"` で ASC/ASCQ 確認
- スクリプト `tmp/<sid>/dks5e-write-64k.sh`:
  ```sh
  dd if=/dev/zero of=$DEV bs=64K count=1 oflag=direct
  ```
- 同様の sense data ASC=0x81 ASCQ=0x00 確認

**Step C: 1 本のみ追試 (失敗の場合、10-13号機 Phase 2 相当)**
- 失敗した 1 本に対して:
  - `sg_logs /dev/sdX` (全 log page)
  - `sg_modes /dev/sdX` (mode pages, write protect, write cache 設定)
  - `sdparm --all /dev/sdX`
  - `sg_inq -p sm /dev/sdX` (security mode page)
  - `sg_inq -p 0x80 /dev/sdX` (unit serial)
- **Phase 3-8 までの網羅は不要** (10-13号機で wontfix 確定済)

### 4.5 判定分岐
- **5 本全て WRITE_OK_1SEC** → uniform writable、Phase 9 ZFS RAID-Z1 構築可、自律的に Phase 5 へ
- **5 本全て WRITE_FAILED_1SEC + ASC=0x81** → Hitachi write filter 確定、ZFS RAID-Z1 不成立 → **AskUserQuestion で代替案 (a/b/c) を問い合わせ** (失敗時判断表 Phase 4 「Y」)
- **mixed (一部 OK / 一部 NG)** → 自律判断: writable な disk のみで縮退 ZFS pool (例: 4 本 RAIDZ1) を構成して継続。差分 (FW Rev, serial) を記録

### 4.6 全 disk を元の状態に戻す
- 5 本を non-RAID から RAID member (Ready) に戻す: `racadm storage converttoraid:Disk.Bay.N:...` を 5 回個別実行
- jobqueue 適用、再起動 (realtime 不可なら powercycle)

**保存**: `tmp/<sid>/dks5e-test/*.txt`、レポート添付。

**所要**: 2-4 時間 (Bay 状態変更 + reboot 含む)

**リスク**: 中。Bay 2-5,7 状態変更は破壊的だが、現 OS_RAID1 (Bay 1+6) には触れない。

---

## Phase 5: Bay 0 (ST300MP0026 12Gb/s) 健全性詳細確認

**目的**: 前回 BGI 26% 停滞の真因が「link speed mismatch」だったか、「Bay 0 ディスク自体の問題」だったかを切り分け。SMART long self-test まで含めて深掘り。

**手順**:

### 5.1 Phase 3 で取得した Bay 0 SMART を精査
- Reallocated Sector Count, Pending Sector Count, Unrecoverable Read Error Count
- GLIST (Grown defect list)
- Temperature history
- Power-on hours, Start-stop count
- 製造日 (古い disk なら寿命近い可能性)

### 5.2 Bay 0 を non-RAID 化
- Phase 4 と同手順 (`racadm storage converttononraid:Disk.Bay.0:...`)
- SCSI rescan → `/dev/sdX` 識別

### 5.3 書込みテスト
- 1 セクタ → 64KB → 1MB 段階的に
- 失敗なら dmesg ASC/ASCQ
- 成功なら fio で 1 分間 random write (低負荷、損耗回避) → `fio --name=test --filename=/dev/sdX --rw=randwrite --bs=4k --runtime=60 --time_based=1`

### 5.4 link speed 確認
- Bay 0 単独で `perccli64 /c0/e?/s0 show all` の Current Link Speed (Negotiated) vs Max Link Speed (Capable)
- backplane が 12Gb/s を許すか確認 (15号機 Bay 0 と比較)

### 5.5 SMART short + long self-test
- Phase 3 で既に long を起動済の場合は結果のみ確認
- short test 5-10 分: `smartctl -d sat -t short /dev/sdX` (non-RAID なので megaraid 不要)
- long test 1-2 時間: `smartctl -d sat -t long /dev/sdX`
- 完走後 `smartctl -l selftest /dev/sdX`

### 5.6 元に戻す
- Bay 0 を non-RAID → Ready (RAID member) に戻す

**成功判定**:
- SMART OK + dd 成功 + SMART long PASS + link 速度確認 → Bay 0 健全、自律的に Phase 6 へ
- いずれか異常 → Bay 0 故障、Phase 7 で Bay 0+1 RAID-1 は **再失敗確実** → **AskUserQuestion で計画変更を問い合わせ** (Bay 1+6 維持 / 別 pair 試行 / 計画中止) (失敗時判断表 Phase 5 「Y」)

**所要**: 1-2 時間

---

## Phase 6: PERC FW 25.5.5.0005 → 25.5.9.0001 アップグレード

**目的**: 15号機と PERC FW を統一。BGI 26% 停滞の改善期待。

**手順**:

### 6.1 事前バックアップ
- `perccli64 /c0 show all > /var/tmp/perccli-pre-fwupdate.txt` (パイプ不可なので scp 経由でローカル取得)
- 実際は: `ssh -F ssh/config pve14 sudo /opt/MegaRAID/perccli/perccli64 /c0 show all` → 出力を tmp/<sid>/ に保存
- 現 VD0 (Bay 1+6) Optimal 確認
- `racadm storage get vdisks > tmp/<sid>/vdisks-pre-fwupdate.txt`

### 6.2 DUP 入手 (実行時)
- Dell サポート → ServiceTag `GLYHKF2` → "PERC H730P Mini RAID Controller Firmware" → `.BIN`
- 例: `SAS-RAID_Firmware_xxxxx_LN_25.5.9.0001_A0X.BIN`
- **25.5.5.0005 DUP も並行 DL** (rollback 用)
- ローカル DL → SMB share `//10.1.6.1/public/` or scp で 14号機 `/var/tmp/` に配置

### 6.3 graceful shutdown (推奨、安全寄り)
- `./pve-lock.sh run ./oplog.sh ssh -F ssh/config pve14 sudo systemctl poweroff`
- 完了確認: `racadm getsysinfo` で Power=Off

### 6.4 racadm update 実行
- `./pve-lock.sh run ./oplog.sh ssh -F ssh/config idrac14 racadm update -f SAS-RAID_xxx.BIN -l //10.1.6.1/public/ -u <smb_user> -p <smb_pass>`
- `racadm jobqueue view` で進捗監視 (5 分毎)
- 完了まで 15-30 分想定

### 6.5 検証
- `racadm serveraction powercycle` で起動
- 起動後 (~5 分):
  - `ssh -F ssh/config pve14 uname -a` (SSH 復帰確認)
  - `perccli64 /c0 show | grep "FW Package"` で **25.5.9.0001** 確認
  - `racadm storage get vdisks` で VD0 Optimal 維持確認
  - VD0 stress test 軽量 (`dd if=/dev/zero of=/var/tmp/post.bin bs=1M count=100`)

### 6.6 失敗時のロールバック
- FW update 失敗 → `racadm update --force -f 25.5.5_DUP.BIN ...` で downgrade
- VD0 corrupted → foreign config import 試行、最悪は Phase 8 OS 再インストールで救済 (Bay 1+6 のまま)

**成功判定**: FW 25.5.9.0001 確認、VD0 健全、pve14 起動成功。

**所要**: 30-60 分 (DUP DL + 適用 + reboot)

---

## Phase 7: VD 再構成 [DESTRUCTIVE]

**目的**: 現 VD0 (Bay 1+6) を削除し、新 VD0 (Bay 0+1 RAID-1) + Bay 2-7 を non-RAID mode に変更。BGI 進行を最大 4-6h まで観測。

**事前確認**:
- ユーザに「現 OS_RAID1 を削除します。OS は再インストールになります」と明示確認 (このタイミングでもう一度)
- pve14 で重要データなし (まだ初期状態) を確認: `ls /root/`, `find /home -type f` 等

**手順**:

### 7.1 graceful shutdown
- `./pve-lock.sh run ./oplog.sh ssh -F ssh/config pve14 sudo systemctl poweroff`
- 完了確認

### 7.2 現 VD0 削除
- `./pve-lock.sh run ./oplog.sh ssh -F ssh/config idrac14 racadm storage deletevd:Disk.Virtual.0:RAID.Integrated.1-1`
- `./pve-lock.sh run ./oplog.sh ssh -F ssh/config idrac14 racadm jobqueue create RAID.Integrated.1-1 -s TIME_NOW -r pwrcycle`
- 完了確認: `racadm storage get vdisks` で VD0 不存在

### 7.3 新 VD0 (RAID-1, Bay 0+1) 作成
- `./pve-lock.sh run ./oplog.sh ssh -F ssh/config idrac14 racadm storage createvd:RAID.Integrated.1-1 -rl r1 -pdkey:Disk.Bay.0:Enclosure.Internal.0-1:RAID.Integrated.1-1,Disk.Bay.1:Enclosure.Internal.0-1:RAID.Integrated.1-1 -name OS_RAID1`
- `./pve-lock.sh run ./oplog.sh ssh -F ssh/config idrac14 racadm jobqueue create RAID.Integrated.1-1 -s TIME_NOW -r pwrcycle`

### 7.4 BGI 長時間監視 (最重要、最大 4-6 時間)
- 監視スクリプト: `tmp/<sid>/bgi-monitor.sh`:
  ```sh
  #!/bin/sh
  while true; do
    date
    racadm storage get vdisks
    sleep 300
  done
  ```
- ssh で起動して 300 秒毎に状態出力
- **判定基準**:
  - 30 分以内に BGI 100% or skip (Optimal Not Applicable) → 成功
  - 26% で 1 時間以上停滞 → 警告、追加 1 時間観測継続
  - 26% で 4 時間以上停滞 → 失敗確定、停止
- 失敗の場合 → **AskUserQuestion で代替 pair を問い合わせ** (失敗時判断表 Phase 7 「Y」):
  - 代替案 (a): Bay 1+6 構成に戻す (前回成功実績)
  - 代替案 (b): Bay 1+7 / Bay 1+2 等の別 pair 試行
  - 代替案 (c): Bay 0+6 (12Gb/s ST300MP + 6Gb/s ST9300、別 series)

### 7.5 Bay 2-7 を non-RAID mode に変換 (BGI 成功後)
- 6 個別 Bash 呼び出し: `racadm storage converttononraid:Disk.Bay.2:...` for N=2,3,4,5,6,7
- `racadm jobqueue create RAID.Integrated.1-1 --realtime` (または `-s TIME_NOW -r pwrcycle`)

### 7.6 起動 + 確認
- `racadm serveraction powercycle`
- 起動後 (~5 分):
  - `lsblk` で `/dev/sda` (新 VD0 ~278GB) + `/dev/sdb..sdg` (Bay 2,3,4,5,6,7 non-RAID, ~277-278GB×6) 認識
  - `perccli64 /c0/vall show all` で VD0 Optimal
  - `perccli64 /c0/eall/sall show all` で Bay 2-7 が "JBOD" or "Non-RAID" 状態

**リスク**: 高。VD 削除 → OS 喪失。BGI 失敗時の OS 復旧経路 = Phase 8 で再インストールに頼る。

**所要**: 1-6 時間 (BGI 進行次第)

---

## Phase 8: OS 再インストール (os-setup スキル経由)

**目的**: 新 VD0 (Bay 0+1 RAID-1) に Debian 13 + PVE 9.1.9 をクリーンインストール。

**手順**:
- **os-setup スキル**を呼び出し、`config/server14.yml` + `preseed/preseed-server14.cfg` で 14号機の通しセットアップ
- preseed は LVM 方式既存 (Bay 0+1 を Bay 1+6 と同じ ST 系 RAID-1 として扱える)
- post-install: SSH 鍵配置 + PVE setup + vmbr0/vmbr1 構築 (前回と同じ)

**注意**:
- preseed の `partman-auto/disk string /dev/sda` で新 VD0 (Bay 0+1) を対象
- Bay 2-7 の non-RAID disks (`/dev/sdb..sdg`) は preseed/early_command で `[ -b "$disk" ] || continue` の条件付きで `/dev/sda` のみ wipe (既存 preseed が対応済)
- iDRAC racreset soft が必要になる可能性あり (前回 attempt 6)
- VirtualMedia 連続切替の回避策 (前回知見) を os-setup スキルが内部処理

**成功判定**: pve14 が新 VD0 上で起動、SSH 鍵認証 OK、`pve-manager/9.1.9` 認識、vmbr0=10.10.10.214、vmbr1=192.168.39.x。

**所要**: 1-3 時間 (前回 2h13m、attempt 数次第)

**リスク**: 中。os-setup スキルの retry 機構に委ねる。

---

## Phase 9: ZFS RAID-Z1 構築 + scrub (Bay 2-7 = sdb..sdg)

**目的**: Bay 2-7 の 6 disks (DKS5E ×5 + ST9300653SS ×1) で ZFS RAID-Z1 pool を作成、PVE storage 登録、scrub で整合性確認。

**前提**: Phase 4 で 5 本の DKS5E が writable と確認済 (Hitachi write-block されていない)。

**手順**:

### 9.1 ホスト側 disk 確認
- `ssh -F ssh/config pve14 lsblk -o NAME,SIZE,MODEL,SERIAL,WWN`
- sdb..sdg が non-RAID として認識されている (約 277-278GB × 6)
- `ssh -F ssh/config pve14 ls -l /dev/disk/by-id/`
- 各 disk の disk-by-id 名 (wwn-* または scsi-*) を確定

### 9.2 全 6 disk の最終 write check
- Write `tmp/<sid>/zfs-disks-write-test.sh`: 6 disks に対して dd 1 セクタ write
- scp → `./pve-lock.sh run ./oplog.sh ssh -F ssh/config pve14 sudo sh /tmp/zfs-disks-write-test.sh`
- 全 6 disks WRITE_OK 確認

### 9.3 ZFS pool 作成 (disk-by-id 名で)
- Write `tmp/<sid>/zfs-create.sh`:
  ```sh
  #!/bin/sh
  set -eu
  zpool create -o ashift=12 -O compression=off -O atime=off datapool raidz1 \
    /dev/disk/by-id/wwn-xxx-1 \
    /dev/disk/by-id/wwn-xxx-2 \
    /dev/disk/by-id/wwn-xxx-3 \
    /dev/disk/by-id/wwn-xxx-4 \
    /dev/disk/by-id/wwn-xxx-5 \
    /dev/disk/by-id/wwn-xxx-6
  zpool status datapool
  zfs list
  ```
  - `ashift=12` (4Kn 対応、Bay 2-7 が 4Kn の場合)
  - `compression=off, atime=off` は過去レポート 2026-03-30 と同じ設定
- scp → `./pve-lock.sh run ./oplog.sh ssh -F ssh/config pve14 sudo sh /tmp/zfs-create.sh`

### 9.4 PVE storage 登録
- `ssh -F ssh/config pve14 sudo pvesm add zfspool data1 --pool datapool --content images,rootdir`
- `ssh -F ssh/config pve14 sudo pvesm status` で `data1` active

### 9.5 ZFS scrub (整合性確認、~30-60 分)
- `./pve-lock.sh run ./oplog.sh ssh -F ssh/config pve14 sudo zpool scrub datapool`
- 進捗監視: `zpool status datapool` を 5 分毎
- 完了後 `errors: No known data errors` 確認
- DKS5E の Hitachi 個体差 (もしあれば) ここで検出可能

### 9.6 fio 性能ベンチマーク (オプション、過去レポート 2026-03-30 との比較)
- `fio --name=zfs-rand-read --filename=/datapool/test.bin --rw=randread --bs=4k --size=1G --runtime=60 --time_based=1`
- `fio --name=zfs-rand-write ...` 同様
- 結果を過去 7-9号機 ベンチマークと比較 (ARC キャッシュの影響評価)

**容量計算**:
- 6 disks × 277.27GB (DKS5E に揃う) raw = 1.66TB
- RAID-Z1: usable = 5/6 = 1.39TB (理論値、ZFS metadata で実 1.3TB 程度)

**Phase 4 で Hitachi write-block 確定の場合の代替** (Phase 4 で AskUserQuestion 済の結果に従う):
- DKS5E ×5 が使用不可
- 残り disk: Bay 6 ST9300653SS (278GB) のみ → RAIDZ1 不成立
- **代替案** (Phase 4 で問い合わせ済):
  - (a) Data なし運用 (boot OS_RAID1 のみ)
  - (b) Bay 6 を RAID-0 single VD として `pvesm add dir` で simple storage
  - (c) DKS5E の Hitachi lock 突破試行 (10-13号機 Phase 8 で wontfix 確定済、効果薄い)

**所要**: 1-2 時間 (scrub 含む)

**リスク**: 中。zpool create 失敗 → 個別 disk diagnostics → Phase 4 検証の再実行。

---

## Phase 10: 最終検証 + コールド再起動 + レポート

**目的**: 全構成永続化を確認し、レポートを作成。

**検証**:

### 10.1 構成 snapshot
- `perccli64 /c0/vall show all` で VD0 (RAID-1, Bay 0+1) Optimal + FW 25.5.9.0001 確認
- `perccli64 /c0/eall/sall show all` で Bay 2-7 が non-RAID
- `zpool status datapool` / `zfs list` で ZFS pool active
- `pvesm status` で local + local-lvm + data1 (zfspool) 全 active
- `df -h`, `lsblk`, `pveversion -v`

### 10.2 コールド再起動テスト (永続化確認)
- `./pve-lock.sh run ./oplog.sh ssh -F ssh/config idrac14 racadm serveraction powercycle`
- 5 分待ち
- SSH 復帰 → 上記 10.1 を再確認
- 全構成が再起動後も維持

### 10.3 Web UI 確認
- `curl -k https://10.10.10.214:8006/` で HTTP 200 (またはローカルマシンから手動アクセス)

### 10.4 レポート作成
- `TZ=Asia/Tokyo date +%Y-%m-%d_%H%M%S` で timestamp
- `report/<timestamp>_server14_raid_zfs_rebuild.md` を REPORT.md 形式
- 添付: `report/attachment/<reportname>/plan.md` (本ファイル)
- 含めるべき情報:
  - 前提・目的・環境情報
  - Phase 4 DKS5E 全数検証結果 (writable / write-blocked 判定)
  - Phase 5 Bay 0 健全性結果
  - Phase 6 PERC FW 更新ログ
  - Phase 7 Bay 0+1 BGI 進行ログ (前回 stall との比較)
  - Phase 9 ZFS pool 構成 + scrub 結果 + fio ベンチ (実施した場合)
  - 知見と注意点
- `issues/issues.yml` 更新 (新規 issue で完了記録)

**所要**: 1-2 時間

---

## Critical files

| ファイル | 役割 | 操作 |
|---|---|---|
| `/home/ubuntu/.claude/plans/os-raid-14-idempotent-sparrow.md` | 本プラン | edit |
| `config/server14.yml` | 14号機設定 | read |
| `config/server15.yml` | 比較対象 (FW 25.5.9) | read |
| `preseed/preseed-server14.cfg` | LVM 方式 preseed (既存利用) | read |
| `ssh/config` | pve14/idrac14 エイリアス | read |
| `scripts/server14-perccli-install.sh` | Phase 2 perccli 導入 wrapper | **新規** |
| `scripts/server14-disk-investigation.sh` | Phase 1+3 baseline 採取 wrapper | **新規** (任意) |
| `scripts/server14-perc-fw-update.sh` | Phase 6 racadm update wrapper | **新規** |
| `state/server14-disks-baseline.md` | Phase 1+3 結果サマリ | **新規** (任意) |
| `report/<timestamp>_server14_raid_zfs_rebuild.md` | 完了レポート | **新規** |
| `issues/issues.yml` | 新規 issue 追加 + close | edit |

**os-setup スキル経由のため変更なし**:
- preseed の wipe 対象、partman LVM、early_command は既存のまま使える
- scripts/idrac-virtualmedia.sh, scripts/remaster-debian-iso.sh, scripts/pre-pve-setup.sh, scripts/pve-setup-remote.sh, scripts/pve-bridge-setup.sh — 既存

---

## 失敗時の判断 (自律 / ユーザ確認の区分)

各 Phase で問題が発生した場合の対応。**ユーザ判断**列が「Y」のものだけ AskUserQuestion で停止する。それ以外は Claude が自律判断。

| 段階 | 失敗条件 | ユーザ判断 | 対応 |
|---|---|---|---|
| Phase 1 | 現 VD0 ストレステストで I/O エラー | **Y** | 即停止、現 OS_RAID1 自体が不安定 — 計画全体の見直しが必要 |
| Phase 2 | perccli インストール失敗 | N | storcli64 にスイッチ、両方失敗ならスキップして smartctl + sg3-utils のみで継続 |
| Phase 3 | SMART long self-test で 1-2 本だけ FAIL | N | 該当 disk を特定し記録、Phase 4/5/7 計画から該当 disk を除外して継続 |
| Phase 3 | SMART long で OS_RAID1 member (Bay 1 or 6) が FAIL | **Y** | OS の信頼性に影響 — 続行可否を確認 |
| Phase 4 | DKS5E 5 本全て ASC=0x81 で write 不可 | **Y** | Phase 9 計画変更要 — 代替案 (a/b/c) のどれにするか確認 |
| Phase 4 | DKS5E mixed (一部 OK 一部 NG) | N | writable な disk だけで Phase 9 を構成 (4 本 RAIDZ1 等)、結果報告 |
| Phase 5 | Bay 0 SMART 異常 / dd 失敗 | **Y** | Phase 7 で Bay 0+1 RAID-1 構築不可 — Bay 1+6 維持 or 別 pair 試行を確認 |
| Phase 6 | FW update 失敗 / VD0 corrupted | **Y** | rollback の判断 — 25.5.5 に戻すか、Bay 1+6 OS_RAID1 修復 vs 再インストールを確認 |
| Phase 7 | Bay 0+1 BGI 26% で 4 時間以上停滞 | **Y** | 代替 pair (Bay 1+6 / 1+7 / 0+6 等) のどれにするか確認 |
| Phase 8 | OS 再インストール失敗 (attempt 6 でも) | N | os-setup スキルの retry → 自動的に追加 attempt を実施。10 attempt 超で **Y** |
| Phase 9 | zpool create 失敗 | N | 個別 disk 診断 → 該当 disk を除外して再試行。4 本以下になったら **Y** |

---

## 未確定事項 (実行時に解決)

1. **perccli Debian 配布形態**: Dell `.tar.gz` 内 `.deb` 有無
2. **Dell DUP URL**: ServiceTag `GLYHKF2` 用 PERC FW 25.5.9.0001 `.BIN`
3. **iDRAC 2.63 で realtime config job のサポート**: Phase 4 / 7 で reboot 要否
4. **DKS5E K300SS の OEM identity**: Phase 4 `sg_inq` で確定 (HGST / Hitachi / Seagate)
5. **DKS5E 5 本の FW Rev**: 同一なら uniform behavior 期待、差異あれば mixed 判定要警戒
6. **PERC FW 更新方式**: iDRAC racadm update vs ホスト perccli download — Phase 6 開始時に再確認
7. **Bay 0+1 BGI 進行**: PERC FW 25.5.9 後に link speed mismatch を許容するか — Phase 7 実機確認
8. **OS 再インストール時の attempt 必要回数**: 前回は 6 回必要、今回はどうか
9. **DKS5E の 4Kn / 512n / 520B 区別**: 10-13号機の DKS5x-J1R2SS は 520B (要 sg_format) だった可能性。DKS5E が同じなら ZFS pool 作成前に 512n に reformat が必要

---

## 実行時間目安 (じっくり調査 mode)

```
Phase 1 (baseline + stress)  → 1.5-2 時間
Phase 2 (tool install)       → 30-60 分
Phase 3 (PD diag + SMART long) → 1-4 時間
Phase 4 (DKS5E 全数検証)     → 2-4 時間 ← 分岐点
Phase 5 (Bay 0 SMART long)   → 1-2 時間 ← 分岐点
Phase 6 (FW update)          → 30-60 分
Phase 7 (VD rebuild + BGI)   → 1-6 時間 ← 分岐点 (最大 4-6h 待機)
Phase 8 (OS reinstall)       → 1-3 時間
Phase 9 (ZFS pool + scrub)   → 1-2 時間
Phase 10 (verify + report)   → 1-2 時間

合計: 10 〜 22 時間 (24 時間以内に収まる)
順調なら 10-12 時間、深掘り多めなら 18-22 時間
```

各 Phase 完了時に短い進捗ログを出力 (発見事項のみ)。続行可否はユーザに確認せず、Claude が自律的に次 Phase へ進む。「失敗時の判断」表の **「ユーザ判断 Y」** に該当する条件が発生した場合のみ AskUserQuestion で停止する。
