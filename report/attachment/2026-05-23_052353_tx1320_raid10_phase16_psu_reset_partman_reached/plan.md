# Phase 16: TX1320 RAID10 OS install — Phase 15 patch commit + PSU reset + 1-deploy で install 完遂を目指す

## Context

Phase 15 (2026-05-23 bubbly-ripple) で cdrom-detect.postinst patch (`PVESE_PATCH_CDROM_DETECT=1`) を実装し、sanity 5/5 pass + `(1*installer)` window 観測まで達成したが、iRMC S4 FW 9.08F の USB redirector が deploy ごとに state degradation を起こし、d-i 内部 (cdrom-detect 到達前) で reset loop に陥って install 完遂未達。Manager.Reset 2 回 + PSU cold reset 1 回でも改善せず。Phase 15 の最後に stock Debian 13.3.0 ISO の GRUB menu が VGA に正常表示できることを確認 → HW + iRMC NFS attach + BIOS + GRUB stage は健全 = reset loop は wrapper/patch 無関係。

Phase 16 では:
1. Phase 15 patch を main に **commit** (sanity pass + 設計合理性 = 実機検証前でも commit 候補品質、ユーザ承認済)
2. iRMC 状態を **必要に応じて PSU cold reset でクリーン化** (ユーザ依頼)
3. PSU reset 直後の単発 deploy で patch 動作 + install 完遂を狙う (deploy-careful.sh パターン)
4. 結果 (成功/blocked) を Phase 16 レポートにまとめる。fallback 案 (FW update / PXE / 別 base ISO) は **Phase 17 への持ち越し**

最終目標: OS インストール完了 (preseed 完走 + RAID10 + SSH login)。

## ユーザ確認済の方針 (AskUserQuestion 2026-05-23)

| 項目 | 決定 |
|------|------|
| Phase 15 patch の commit タイミング | 実機検証前にコミット |
| PSU reset + 1-deploy が失敗した場合の fallback 優先度 | Phase 16 終了 + 次セッション判断 (本 Phase では実施しない) |

## タスクリスト

### Task 1: Phase 15 patch を main に commit (第 1 段階、最優先)

- workdir 差分 (未コミット):
  - `scripts/remaster-debian-iso.sh` (L72-73 docker env + L97-165 patch logic + L174 cpio find/sed 化)
  - `scripts/tx1320-raid10-orchestrate.sh` (L137-145 build() の `export PVESE_PATCH_CDROM_DETECT=1` + log enhancement)
- これら 2 ファイルだけを stage して commit。他の workdir 変更 (CLAUDE.md, README.md, issues.yml, preseed.cfg.template 等) が混在しないように個別 add
- commit メッセージは `tmp/<sid>/commit-msg.txt` に Write ツールで書いてから `git commit -F` で実行 (HEREDOC は自動承認されない)
- 内容: `Phase 15: add PVESE_PATCH_CDROM_DETECT=1 cdrom-detect.postinst patch for TX1320 /dev/sr1 priority` + Phase 15 sanity 5/5 pass の言及 + issue #72 参照
- commit 後 `git log -1` で確認、push はしない (CLAUDE.md ルールで自動許可せず)

### Task 2: iRMC 現状確認 + 必要に応じて PSU cold reset (第 2 段階)

- iRMC 状態確認:
  - `./scripts/bmc-power.sh status 10.254.254.9 claude Claude123` で PowerState + Booted
  - `./scripts/irmc-virtualmedia.sh status 10.254.254.9 claude Claude123` で CDImage + VirtualMedia AllowableValues
  - もし PowerState=On かつ booted=Yes (= 前セッションの reset loop が継続中) → ForceOff してから判断
- **degradation 兆候**: AllowableValues に `ConnectCD` も `DisconnectCD` も両方出ない / VirtualMedia Members count が不整合 / Manager.Reset 直後でも CDImage 状態が宙吊り
- 兆候があれば AskUserQuestion でユーザに **PSU 抜差し (2-3 秒)** を依頼
- 兆候がなければ Manager.Reset GracefulRestart + 240s 待機を 1 回だけ試して直接 Task 3 へ
- PSU reset 後の iRMC 復帰: `tmp/<sid>/wait-bmc-recover.sh` (Phase 15 で再利用可能パターン) で PowerState=Off + AllowableValues=['On'] を確認

### Task 3: 「PSU reset → 即座 1-deploy」(deploy-careful.sh パターン適用)

Phase 15 の `report/attachment/2026-05-23_013410_tx1320_raid10_phase15_cdrom_detect_patch/deploy-careful.sh` を `tmp/<sid>/deploy-careful.sh` にコピーして実行 (内容は再利用可能、改変は最小)。Phase 15 と Phase 16 で同じパターンを試すのは、PSU reset 直後の **初回 deploy が BIOS Setup 落ち** の典型症状 (Phase 15 Step 5) を回避するため。

deploy-careful.sh の構造 (Phase 15 で確認済):
1. ForceOff + 120s poll で PowerState=Off 確認
2. **30s settle** (iRMC 内部状態安定化)
3. PATCH CDImage config (NFS)
4. ConnectCD (OEM Action)
5. mount (AllowableValues=DisconnectCD 出現確認、60s poll)
6. **60s USB redirector 安定化 pad**
7. boot-override Cd UEFI
8. **15s pre-power pad**
9. PowerOn

これは `orchestrate.sh deploy()` (sleep 8s のみ) とは大きく異なる。orchestrate.sh はそのまま使わず deploy-careful.sh を採用 (本 Phase では orchestrate.sh の修正はしない、Phase 17 で integrate を検討)。

build フェーズは `SKIP_STORCLI_FETCH=1 ./oplog.sh ./scripts/tx1320-raid10-orchestrate.sh build config/training_tx1320.yml` で実施 (Phase 15 で確立、ISO は既に存在するが念のため再 build で md5 一致を保証)。

### Task 4: SOL monitor + patch marker 検証 (決定的判定)

deploy 完了直後に SOL monitor を起動 (orchestrate.sh の `monitor --timeout` 引数 bug 回避):

```sh
ipmitool -I lanplus -H 10.254.254.9 -U claude -P Claude123 sol payload enable 2 4
.venv/bin/python scripts/sol-monitor.py \
    --bmc-ip 10.254.254.9 --bmc-user claude --bmc-pass Claude123 \
    --log-file tmp/<sid>/install.log --timeout 1800 --powerstate-interval 60
```

判定 marker (grep -ac、Phase 15 引き継ぎ):

| 段階 | Marker | 期待値 |
|------|--------|--------|
| GRUB → kernel | `Linux version` | >= 1 |
| preseed/early_command | `pvese: preseed/early_command start` / `end` | >= 1 / >= 1 |
| d-i UI 起動 | `(1\*installer)` | >= 1 |
| **Phase 15 patch 決定的 marker** | `pvese-patch v1: bypassed list-devices via /dev/sr1 direct mount` | >= 1 |
| cdrom-detect 失敗 (=patch 効いてない) | `No device for installation media` | 0 (絶対零) |
| partman | `pvese: partman/early_command end (rc=0)` | >= 1 |
| RAID10 setup | `pvese: raid10-setup OK: RAID10 created` | >= 1 |
| Install 完了 | `Installation complete` | >= 1 |

途中で reset loop 検出 (`Loading bootloader 0` 反復 / `Booting Automated Install` 反復 / SOL session reconnect 多発) があれば Task 5 へ。

### Task 5: cdrom-detect 突破後の install 完遂検証 (best case)

Task 4 で `pvese-patch v1: bypassed` が出て partman に到達した場合:
- `setup-raid10-storcli.sh` (`/cdrom/storcli64.bin` を `/usr/local/bin/storcli64` に配置 → RAID10 vd 作成) の動作確認 → Phase 14 で path 修正済、partman/early_command で rc=0 が出るか観測
- install 完了 → reboot → `ssh -F ssh/config root@10.254.254.250` (config/training_tx1320.yml の static_ip) で login 検証 → `cat /etc/os-release` + `lsblk` + `cat /proc/mdstat` 確認

### Task 6: Phase 16 レポート作成 + Phase 17 引き継ぎ

- `report/2026-05-23_<HHMMSS>_tx1320_raid10_phase16_<short>.md` を REPORT.md のフォーマットで作成
- 成功時: install 完遂、patch 立証、SSH login OK の情報、issue #72 完了
- blocked 時: reset loop の SOL log snippet、Phase 15 との比較、Phase 17 への引き継ぎ案 (FW update / PXE / 別 base ISO) を明示
- 添付ファイル: SOL log, OEM screenshots (boot 進行確認用)、deploy-careful.sh のコピー

## Critical files (本 Phase で参照/操作)

### 修正対象 (Task 1 で commit、本 Phase 内では code 修正は行わない、commit のみ)
- `scripts/remaster-debian-iso.sh` (Phase 15 で実装済の patch logic、L72-73 + L97-165 + L174)
- `scripts/tx1320-raid10-orchestrate.sh` (Phase 15 で実装済の export 行、L137-145)

### 再利用 (修正なし、Task 3 で実行)
- `report/attachment/2026-05-23_013410_tx1320_raid10_phase15_cdrom_detect_patch/deploy-careful.sh` (Phase 15 で動作確認済の pad パターン)
- `scripts/irmc-virtualmedia.sh` (NFS PATCH + ConnectCD / DisconnectCD / mount 内部待機、Phase 14-15 で確立)
- `scripts/bmc-power.sh` (forceoff / poweron / boot-override、Phase 14-15 で確立)
- `scripts/sol-monitor.py` (Task 4 で SOL log capture + marker timing、`orchestrate.sh monitor --timeout` の wrapper bug を回避)

### 参照のみ (Phase 14 から不変、念のため再 build 時に sanity 再確認)
- `preseed/preseed.cfg.template` (HEAD のまま、cdrom-detect L76-83 のコメント更新は Phase 17 で文言整理)
- `config/training_tx1320.yml` (static_ip 10.254.254.250、Phase 14 で conflict-free 確認済)
- `scripts/setup-raid10-storcli.sh` (Phase 14 で storcli64.bin path 修正済、Task 5 で partman 実機検証)

## Phase 16 で扱わない (Phase 17 以降に持ち越し)

ユーザ確認に従い、本 Phase では fallback 路線を実施しない。以下は Task 6 のレポートに「Phase 17 引き継ぎ候補」として記録するのみ:

| # | 候補 | 概要 |
|---|------|------|
| F1 | iRMC FW 9.08F → 最新版 (9.6xF 系) update | USB redirector の state degradation が known FW bug の可能性。Fujitsu support サイトから FW BIN 取得経路を確立 → iRMC Web UI Maintenance/Firmware Update or Redfish OEM Action で適用 |
| F2 | PXE/netboot 経路に pivot | tftp-server スキル + dnsmasq で TFTP/DHCP セットアップ、BIOS UEFI PXE boot 有効化 + boot-override Pxe、preseed を tftp://... URL で配信 |
| F3 | 別 base ISO (Debian 12 / Ubuntu) で patch 機能再確認 | Debian 13 kernel + iRMC USB の組み合わせが problematic な可能性を切り分け。同 patch 設計が他 base で機能するか実証 |
| F4 | `tx1320-raid10-orchestrate.sh monitor --timeout` 引数 bug 修正 | Phase 12 以降持ち越しの wrapper bug |
| F5 | `preseed/preseed.cfg.template` の cdrom-detect コメント文言更新 | Phase 15 patch で実質解決済の文言整理 |

## Verification (Task 完了の判定基準)

| Task | 判定 |
|------|------|
| Task 1 | `git log -1 --stat` で `scripts/remaster-debian-iso.sh` + `scripts/tx1320-raid10-orchestrate.sh` の 2 ファイル変更が含まれる新 commit を確認、その他ファイルは含まれない |
| Task 2 | iRMC `bmc-power.sh status` で PowerState=Off + AllowableValues=['On']、`irmc-virtualmedia.sh status` で AllowableValues=['ConnectCD'] (clean) |
| Task 3 | deploy-careful.sh が rc=0 で完走、PowerState=On 到達確認、boot-override Cd 設定確認 |
| Task 4 | `pvese-patch v1: bypassed list-devices via /dev/sr1 direct mount` >= 1 (= Phase 16 最大成果) もしくは `No device for installation media` (= 患部に到達したが patch 不発、文書化) |
| Task 5 | `Installation complete` + `ssh -F ssh/config root@10.254.254.250 'uname -a'` rc=0 (= 最終目標達成) |
| Task 6 | report ファイル作成、issue #72 status 更新 (成功なら close、blocked なら blocked) |

## 注意事項 (CLAUDE.md / Phase 15 教訓)

- BMC 操作は **`pve-lock.sh` 不要** (training-tx1320 は LINSTOR/PVE クラスタ非参加、単独機)
- 全ての BMC 状態変更は `./oplog.sh` で記録 (`./oplog.sh ./scripts/bmc-power.sh forceoff ...` 形式)
- 一時ファイル (deploy script, SOL log, commit-msg) は `tmp/<sid>/` に書く (`<sid>` は Glob で取得した transcript UUID 先頭 8 文字)
- PSU 抜差しは必ず AskUserQuestion 経由でユーザに依頼 (本セッションのユーザ指示)
- `pvese-patch v1: bypassed` marker が 1 回でも出れば Phase 15 投資の立証完了 (= Phase 16 主要成果)、install 完遂は次のステップ
