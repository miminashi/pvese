# Seagate 純正 Firmware を 10-13号機 Hitachi-OEM Drive に Flash

## Context

10-13号機 (Supermicro X10DRT-P / Nutanix OEM) のデータ HDD 8 本は Hitachi OEM 仕様 (DKS5H/L-J1R2SS) で、host からの write_buffer SCSI コマンドが vendor-specific ASC=0x81 (LA Check Error) で拒否される。Phase 2-6 (2026-05-04 〜 05-08) で sg_format / sg_sanitize / sdparm / sedutil / 24+ SCSI opcode を全試行したが解除不能と確定し、Issue #61 を wontfix とした。

ただし Phase 6 結論には**唯一の残存経路**として「Hitachi firmware を Seagate 純正 firmware で上書きし、書き込みフィルタ自体を吹き飛ばす」(SCSI WRITE BUFFER opcode 0x3B mode 0x07 = microcode download / segmented) があったが、当時 LOD ファイル未入手で試行スキップしていた。

ユーザが Reddit 投稿 (r/HomeServer, Excellent_Land7666) を参考に Seagate 純正 LOD を入手し `/var/samba/public/upload/EntPerf-Thunderbolt-STD-SAS-5xxN-N005.zip` にアップロード済み。これにより Phase 6 が諦めた最後の経路がついに実行可能となった。本タスクは **Phase 7** として位置付ける。

**到達目標**: 8 本のうち 1 本でも Seagate 純正 firmware に書き換え後 `dd` で write 成功すれば突破口。最終的に全 8 本で成功すれば Issue #61 reopen → fixed として LINSTOR 構築復活。

**ユーザ承認済み判断**:
- 接続性復旧は BMC 経由電源確認まで自動実行
- ドライブ 4 本までの brick (起動不能) を許容
- 第一試行は **pve11 sdb (FW 8F0E、唯一他と異なる FW)**

## Critical Files

### 既存 (参照)
- `/home/ubuntu/projects/pvese/CLAUDE.md` — プロジェクトルール
- `/home/ubuntu/projects/pvese/oplog.sh`, `pve-lock.sh`, `issue.sh` — ラッパー
- `/home/ubuntu/projects/pvese/ssh/config` — pve10-13 alias
- `/home/ubuntu/projects/pvese/scripts/seagate-sed-probe.sh` — read-only probe (baseline 取得に再利用)
- `/home/ubuntu/projects/pvese/scripts/bmc-power.sh` — BMC 電源管理 (Step 1 で使用)
- `/home/ubuntu/projects/pvese/report/2026-05-08_012907_server10-13_phase6_hitachi_origin_analysis.md` — Phase 6 レポート
- `/home/ubuntu/projects/pvese/docs/seagate/scsi_cmds_ref_100293068h.pdf` — WRITE BUFFER mode 仕様
- `/var/samba/public/upload/EntPerf-Thunderbolt-STD-SAS-5xxN-N005.zip` — 入力 ZIP (変更不可)
- `/home/ubuntu/projects/pvese/issues/issues.yml` — Issue #61

### 新規 (実装フェーズで作成)
- `/home/ubuntu/projects/pvese/scripts/seagate-fw-flash.sh` — 単一 drive flash + verify (Step 4 主体)
- `/home/ubuntu/projects/pvese/scripts/seagate-fw-flash-node.sh` — ノード単位水平展開 (Step 7)
- `tmp/<sid>/fw/` — ZIP 展開先
- `tmp/<sid>/baseline-pre/`, `tmp/<sid>/post-flash/` — probe 出力
- `tmp/<sid>/flash-*.log` — 各 flash 詳細ログ
- `report/2026-MM-DD_HHMMSS_server10-13_phase7_seagate_fw_flash_*.md` — Phase 7 レポート

## openSeaTools と SeaChest Utilities の対応

- **Reddit の `openSeaTools_Firmware`** = Seagate OSS 版 (`opensource-seagate/openSeaChest`)、CLI 名 `openSeaChest_Firmware`
- **PVE 上 apt 版 `SeaChest Utilities 26.03.1`** = 同 OSS のパッケージング、CLI 名 `openSeaChest_Firmware`
- **ZIP 同梱 `SeaChest_Firmware_254_1183_64`** = Seagate **公式商用ビルド v25.4**、Reddit より新しいモデル個別対応含む可能性

戦略: apt 版で先行試行 → 失敗時に同梱の公式ビルド → 最終手段で `sg_write_buffer` 直接。

## Step 1: 接続性復旧 (read-only / 電源管理)

```sh
for ip in 10.10.10.210 10.10.10.211 10.10.10.212 10.10.10.213; do
  ping -c 1 -W 2 "$ip"  # 個別 Bash 呼び出しに分割
done
```

ping 不通の場合:
1. **BMC 電源確認**: `./scripts/bmc-power.sh status 10.10.10.30 claude Claude123` 〜 33
2. Off → `./pve-lock.sh run ./oplog.sh ./scripts/bmc-power.sh on <bmc_ip> claude Claude123`、150 秒待機後 ssh 再試行
3. **On かつ ping 不通**: VLAN trunk (1083) 配信障害確定 → ユーザに別拠点経由のネット復旧を依頼してセッション一時停止

issue 開始: `./issue.sh start 61 --owner phase7-fw-flash` (Issue #61 reopen)

## Step 2: ZIP 展開と資料確認 (read-only)

```sh
mkdir -p tmp/<sid>/fw
unzip -d tmp/<sid>/fw/ /var/samba/public/upload/EntPerf-Thunderbolt-STD-SAS-5xxN-N005.zip
chmod +x tmp/<sid>/fw/'command line tools'/SeaChest/SeaChest_Firmware_254_1183_64
```

確認事項 (Read ツールで):
- READMEFIRST PDF: 対応モデルリスト (ST900MM0168 系列が明示されているか / DKS5x が exclude されていないか)
- `SeaChest_Firmware.254-Lin.txt`: `--downloadFW`, `--downloadMode segmented`, `--modelMatch` 仕様
- LOD 先頭 256 バイトを `xxd` で確認 (header の "MODL" / model identifier)

## Step 3: Baseline 取得 (read-only / 第一対象 = pve11 sdb)

```sh
scp -F ssh/config tmp/<sid>/fw.tar pve11:/root/fw.tar
ssh -F ssh/config pve11 tar xf /root/fw.tar -C /root/
ssh -F ssh/config pve11 chmod +x /root/fw/.../SeaChest_Firmware_254_1183_64

./scripts/seagate-sed-probe.sh pve11 /dev/sdb tmp/<sid>/baseline-pre/
ssh -F ssh/config pve11 openSeaChest_Firmware --device /dev/sdb --info > tmp/<sid>/baseline-pre/info.txt
ssh -F ssh/config pve11 openSeaChest_Firmware --device /dev/sdb --showSupportedFWDLModes > tmp/<sid>/baseline-pre/dlmodes.txt
```

`--showSupportedFWDLModes` は Phase 6 でも未取得。drive 側が公式に sup する mode を確認。

## Step 4: Firmware Flash (pve11 sdb)

新規スクリプト `scripts/seagate-fw-flash.sh <ssh_host> <device> <lod_path>` を作成し、以下を実行:

1. flash 前 sg_inq で revision 記録
2. **apt 版で試行**:
   ```sh
   ./pve-lock.sh run ./oplog.sh ssh -F ssh/config pve11 \
     openSeaChest_Firmware --device /dev/sdb \
       --downloadFW /root/fw/firmware/ThunderboltEntPerfSAS-STD-5xxN-N005.LOD \
       --downloadMode segmented \
       --confirm this-will-update-the-firmware-on-the-drive
   ```
3. 失敗時フォールバック (順次):
   - `--downloadMode deferred` (mode 0x0E, save) → activate を分離
   - 同梱公式バイナリ `/root/fw/.../SeaChest_Firmware_254_1183_64` で同オプション
   - `--modelMatch <regex>` を併用 (model check bypass の試行)
   - `sg_write_buffer --mode=7 --in=/root/fw/.../*.LOD --length=2097152 /dev/sdb`
   - `sg_write_buffer --mode=5` (legacy, 一括送信)

4. 全 fallback 失敗 → drive 状態は不変のはず。Step 5 検証で確認。
5. 全ログを `tmp/<sid>/flash-pve11-sdb.log` に保存。oplog 経由で `log/oplog.log` にも結果記録。

**安全策**:
- segmented mode は逐次反映 → 中断は drive 状態未定義になるため Ctrl+C 厳禁を script header に明記
- flash 中に電源断は致命的 → 開始前に BMC で電源 On を再確認
- 各 fallback 前に `sg_inq` で revision 取得 (途中変化を捉える)

## Step 5: Verify (pve11 sdb)

flash 完走後、power cycle を**挟まず先に**検証:
1. `sg_inq /dev/sdb` で revision 確認: `8F0E` → `N005`/Seagate 標準値 = **半分成功**
2. INQUIRY vendor が `HITACHI` → `SEAGATE` に変化 = **完全成功**
3. `dd if=/dev/zero of=/dev/sdb bs=512 count=1 oflag=direct seek=10000` で write 試行 → rc=0 達成が **最終ゴール**
4. 失敗継続なら power cycle (BMC reset) → 再度同手順
5. write 成功時は `sg_format --format --fmtpinfo=0 --size=512 /dev/sdb` で 520→512B 化

## Step 6: 失敗時の対処

- **ASC=0x26 (Invalid Field)** → model mismatch reject。Phase 6 で記録した write filter とは別ルートでブロック。LOD header patch 検討は **本セッションでは実施せず**、Issue #61 に Phase 7 結果として追記
- **ASC=0x81 (LA Check Error) 継続** → write filter が microcode download にも適用 = Phase 6 結論の最終確定。Issue #61 の wontfix を維持
- **brick (post-flash で全コマンド timeout/abort)** → ユーザ承認 4 本枠を消費。残ドライブで継続

いずれの結果でも `report/2026-MM-DD_HHMMSS_server10-13_phase7_seagate_fw_flash_<result>.md` を作成。

## Step 7: 成功時の水平展開

pve11 sdb で dd rc=0 達成時:

1. **2 本目検証**: pve12 sdb (FW 7FA9 代表) で同手順 → 7FA9 群でも成功するか確認
2. 成功なら新規スクリプト `scripts/seagate-fw-flash-node.sh <ssh_host>` で **ノード内 sdb→sdc 順次** flash (同時 2 drive は power 系リスクあり避ける)
3. **ノード並列**: pve10/12/13 は別ノードなので並列実行可 (各ノード内は sequential)
4. 全 8 drive 成功後:
   - `./scripts/linstor-multiregion-node.sh add pve10..13` で LINSTOR 復帰
   - Issue #61 を fixed クローズ
5. 失敗が **4 本超過した時点でループ中断**、wontfix 維持で Toshiba SSD 単独運用に切り替え

## 検証

- **dry-run**: `--showSupportedFWDLModes` で drive 側 supported mode を読み取り (write 不要)
- **構文チェック**: 新規スクリプト作成時 `sh -n scripts/seagate-fw-flash.sh` 必須
- **per-step verify**: Step 3 baseline → Step 4 flash → Step 5 verify を **同一ドライブで連続実行**し各段階の差分を取る (sg_inq, dmesg sense, dd rc)
- **rollback**: firmware 上書き後の rollback は実質不可 (元の Hitachi LOD は drive 内のみ存在し抽出困難)。**brick した drive は LINSTOR 候補から外す**運用で許容
- **end-to-end test**: 1 drive 成功時点で `sg_format` 後に `mkfs.ext4 + dd` で 100MB 書き込み・ハッシュ照合まで実施。これで「真に通常 IO 可能」を確証

## ルール遵守チェックリスト

- ✅ 全状態変更操作は `./oplog.sh` で記録
- ✅ クラスタ影響操作は `./pve-lock.sh run` でラップ
- ✅ スクリプトは `./scripts/...` (./ 付き相対パス)
- ✅ 一時ファイルは `tmp/<sid>/`
- ✅ SSH は `-F ssh/config`、静的 IP (`10.10.10.0/8`) のみ
- ✅ パイプ・複合コマンドはスクリプトに書いて `sh tmp/<sid>/...` で実行
- ✅ Issue #61 を `./issue.sh start 61 --owner phase7-fw-flash` で reopen → 結果に応じて fixed/wontfix
- ✅ Plan モード完了後に作業実施、完了時に Phase 7 レポート作成
