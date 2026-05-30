# N6 step 2 再開: iRMC 物理電源切離後の SMB worker 復活確認 → patched smbd deploy → attach 検証 → install 実走

セッション: `silly-token` (sid=`efc9ff28`、 継続)
日時: 2026-05-21 (前セッションから継続)

## Context

前ターンで [training_tx1320_smb_n6_step2_blocked.md](/home/ubuntu/projects/pvese/report/2026-05-21_055913_tx1320_raid10_smb_n6_step2_blocked.md) を完了:
- ✅ Phase 0 (typo patch 適用): Samba 4.19.5 source の `source3/smbd/smb2_trans2.c:2026` で `SMB1SERVER` → `WITH_SMB1SERVER` を grep 確認済
- ✅ Phase 1 (10.1.6.6 SMB share 起動): samba 4.19.5+dfsg-4ubuntu9.4 install + smb.conf (NT1 + smb1 unix extensions = yes + log level 10) + smbd/nmbd active、 ローカル smbclient 接続成功
- ❌ Phase 2 (baseline 再現失敗): iRMC SMB worker 完全停止状態を発見、 Manager.Reset / VirtualMediaServiceRestart / PATCH 再投入 / host power-cycle すべて無効
- ✅ Phase 3 (build): `make -j2` で 11m27s 完走、 `bin/default/source3/smbd/smbd --version` で Version 4.19.5 動作確認

**ユーザが iRMC の物理電源切離 (AC コード抜き) を完了** → iRMC SMB worker が復活した想定で再開。 本ターンは:

1. iRMC Redfish 復活確認 → SMB worker 動作確認 (config 復元 + tcpdump + Samba log で観測)
2. **10.1.6.6 上に patched smbd を deploy** (passwordless sudo、 build artifact 同 host)
3. iRMC を 10.1.6.6 へ向け、 SMB attach 検証 (level=513 INVALID_LEVEL 消失 + Members >= 1)
4. 検証成功なら OS install 実走 (60-90 min)

10.1.6.6 を deploy 先に選ぶ理由:
- build host = deploy host で ABI / RUNPATH 完全整合 (10.1.6.1 では `chrpath` / LD_LIBRARY_PATH / unversioned .so alias 等の追加対応が必要)
- passwordless sudo (本セッションで操作自動化可)、 10.1.6.1 は sudo パスワード必須
- 前セッションは iRMC SMB worker 停止のため 10.1.6.6 が SMB target 候補から脱落していたが、 物理電源切離後は再評価可能

10.1.6.6 が iRMC から到達できない場合のフォールバックは 10.1.6.1 deploy (ユーザに sudo パスワード相当の協力依頼 — `install-instructions.md` 参照)。

## 戦略

| 軸 | 採用 | 理由 |
|----|------|------|
| build host | **10.1.6.6** (済) | passwordless sudo、 完了済 |
| SMB server (検証) | **10.1.6.6** (第一選択)、 10.1.6.1 はフォールバック | sudo 自由、 ABI 整合性 |
| smbd 入れ替え方式 | **/usr/sbin/smbd を patched build dir からの直 cp** で差し替え、 RUNPATH は build dir パス (10.1.6.6 上では既に有効) のまま | shared libs は build dir に集約済、 system samba と共存可能 (10.1.6.6 内では `make install` 不要) |
| ISO ファイル | Phase 5 検証は **既存 700 MB ダミー** で OK (qfsinfo level=513 段階で SMB OK/NG が決着)、 Phase 6 install は **10.1.6.6 で real ISO を再生成** (`scripts/remaster-debian-iso.sh` を Docker 経由で実行) | attach 検証は ISO 中身に依存しない |
| 設定 | `config/training_tx1320.yml` の `smb_host` を再び `10.1.6.6` に変更 (前ターン rollback 済 `10.1.6.1` から戻す) | スクリプトはこの値を yq で読む |

## 重要ファイル

### 既存 artifact (前ターンで保全済、 再 build 不要)
- `report/attachment/2026-05-21_055913_tx1320_raid10_smb_n6_step2_blocked/smbd-patched` (sha256=`0ff2a3438c250770fdbf29332513649bda932ed2721ddd34087d936a46e1f6c4`, 98 KB)
- `report/attachment/2026-05-21_055913_tx1320_raid10_smb_n6_step2_blocked/samba-patched-full.tar.gz` (sha256=`d6de6cd4b48aebf3379baadfb16288007e376eb092da0df0aba02a58b81ff2ca`, 2 MB)
- `report/attachment/2026-05-21_055913_tx1320_raid10_smb_n6_step2_blocked/install-instructions.md` (10.1.6.1 deploy 用 fallback 手順)
- 10.1.6.6 上の `~/samba-build/samba-4.19.5/bin/default/source3/smbd/smbd` (本物の patched binary)
- 10.1.6.6 上の `~/samba-build/samba-4.19.5/bin/shared/{,private/}` (shared libs)
- 10.1.6.6 上の samba パッケージ (4.19.5+dfsg-4ubuntu9.4 active)、 smb.conf 整備済、 dummy ISO 配置済

### 修正対象
- `config/training_tx1320.yml`: `smb_host: 10.1.6.1` → `10.1.6.6` に再変更
- 10.1.6.6 の `/usr/sbin/smbd` (差し替え、 backup を `/usr/sbin/smbd.orig.<ts>` に取る)

### 新規 (本ターンの記録)
- `tmp/efc9ff28/` 配下 (既存)、 新規 ログを追記
- `report/2026-05-21_<HHMMSS>_tx1320_raid10_smb_n6_step2_success.md` (本ターン完了時、 成功なら) または `_step2_continued.md` (失敗時)

## 実施手順

### Phase A: iRMC 状態確認 (5 min)

1. **Redfish 復活ポーリング** (本ターン開始時に bash でループ): `curl -sk -u claude:Claude123 https://10.254.254.9/redfish/v1/` が `@odata.id` を返すまで 10s 間隔、 最大 5 分
2. **PowerState 確認**: `https://.../Systems/0` で `PowerState` を取得 (Off ならそのまま、 On なら不要操作)
3. **OEM VirtualMedia 設定確認**: 前ターン rollback で `CDImage.Server=10.1.6.1` のはず。 verify
4. **InternalEventLog 新規エントリ確認**: 物理電源切離直後 (`Created` が今日の時刻)、 `Power up` 等の event があれば SMB worker process も fresh 可能性大

### Phase B: SMB worker 復活確認 (5-10 min)

**目的**: iRMC が現行設定 (10.1.6.1) または 10.1.6.6 への SMB 試行を実際に行うか観測。 前ターンは「Manager.Reset でも復活せず」だったが、 物理電源切離なら復活している想定。

1. iRMC の CDImage 設定を **10.1.6.6** に PATCH (`./scripts/irmc-virtualmedia.sh config 10.254.254.9 claude Claude123 10.1.6.6 public debian-preseed-tx1320.iso guest guest`)
2. 10.1.6.6 上で **同期 (foreground) tcpdump** を 3-5 分実行 (`sudo timeout 240 tcpdump -i any -n "host 10.254.254.9"`)
3. 並行で host を power-on (boot-override Cd UEFI + forceoff + on) — USB CD read 要求が SMB worker 起動の通常 trigger
4. 期待: tcpdump で SYN / SMB nego / qfsinfo level=513 / NT_STATUS_INVALID_LEVEL を観測 → SMB worker 復活 + bug 再現 = baseline OK
5. 0 packet が再現する場合: iRMC が完全に永続的に壊れている可能性 → 10.1.6.1 fallback 経路へ移行 (Phase E)

### Phase C: patched smbd deploy on 10.1.6.6 (5 min)

baseline 再現 OK 後:

1. 10.1.6.6 で `sudo systemctl stop smbd nmbd`
2. backup: `sudo cp /usr/sbin/smbd /usr/sbin/smbd.orig.$(date +%s)`
3. install patched: `sudo cp ~/samba-build/samba-4.19.5/bin/default/source3/smbd/smbd /usr/sbin/smbd`
4. 動作確認: `sudo /usr/sbin/smbd --version` → "Version 4.19.5" 表示なら ABI OK。 shared lib エラーなら RUNPATH 問題 (build dir のまま使えるはず、 既に build dir が同 host にある)
5. `sudo truncate -s 0 /var/log/samba/log.*` (clean slate)
6. `sudo systemctl start smbd nmbd && sudo systemctl status smbd` → active (running)
7. ローカルから `smbclient -L //10.1.6.6/ -U guest%guest -m NT1` → public share 一覧で OK

### Phase D: patch 修正検証 (10-15 min)

1. iRMC で fresh attach 試行: umount → 5s 待 → config 再投入 (10.1.6.6)
2. 必要に応じ host power-cycle (boot-override Cd UEFI + forceoff + on) で USB CD read を trigger
3. 同期 tcpdump + Members polling を 3-5 分:
   - **成功**: Samba log に `level = 513` 出現 + `NT_STATUS_INVALID_LEVEL` 消失、 SMB OK 応答が観測される (=`call_trans2qfsinfo` の reply が OK)、 `Members@odata.count >= 1`
   - **部分成功**: level=513 OK だが別エラーで Members=0 → tcpdump で response packet を確認、 capability negotiation (level=0x200) も要求されているか
   - **失敗 (依然 INVALID_LEVEL)**: patch 適用ミス / `lp_smb1_unix_extensions()` 効いていない / 別 #if defined で弾かれている → 再 grep + 再 patch

### Phase E: 10.1.6.1 fallback (Phase B/D で 10.1.6.6 が依然到達不能の場合のみ)

10.1.6.6 へ iRMC が永続的に到達できない (asymmetric routing 等) と判明したら:
1. iRMC config を 10.1.6.1 に戻す
2. [install-instructions.md](/home/ubuntu/projects/pvese/report/attachment/2026-05-21_055913_tx1320_raid10_smb_n6_step2_blocked/install-instructions.md) の方法 A (tarball を /opt/samba-patched に展開 + ld.so.conf 登録 + /usr/sbin/smbd 差し替え) を試行
3. ユーザに sudo パスワード or 手動 install を依頼

### Phase F: real ISO で OS install 実走 (60-90 min) — Phase D 成功時

1. 10.1.6.6 で real ISO を生成: 必要なら `apt install docker.io`、 base ISO + storcli64.deb + preseed を準備して `./scripts/remaster-debian-iso.sh` を 10.1.6.6 上で実行。 もしくは 10.1.6.1 から `sudo rsync` で既存 `/var/samba/public/debian-training-tx1320-raid10.iso` を copy
2. iRMC ImageName を real ISO に更新 (PATCH)
3. `./scripts/tx1320-raid10-orchestrate.sh deploy config/training_tx1320.yml` で iRMC ConnectCD + boot-override + power cycle
4. `.venv/bin/python ./scripts/sol-monitor.py --bmc-ip 10.254.254.9 --bmc-user claude --bmc-pass Claude123 --log-file tmp/efc9ff28/sol.log --timeout 2700 --powerstate-interval 30` で installer 監視 (45 min timeout)
5. 完走後: ssh で host 接続テスト、 lsblk / `pveversion` 確認

### Phase G: report + memory + issue update

#### G-1. レポート本体作成

[REPORT.md](/home/ubuntu/projects/pvese/REPORT.md) のルールに従う。 タイムスタンプは `TZ=Asia/Tokyo date +%Y-%m-%d_%H%M%S` で取得 (LLM 推測禁止)。

**ファイル名と分岐**:
| 結末 | ファイル名 | タイトル |
|------|-----------|---------|
| Phase D + F すべて成功 (patch 効果実証 + OS install 完走) | `report/<TS>_tx1320_raid10_smb_n6_step2_success.md` | TX1320 N6 step 2 完了: Samba 4.19.5 typo patch で SMB attach 成立 + OS install 完走 (Issue #69 解決) |
| Phase D 成功 / Phase F 失敗 (attach OK だが install で別 issue) | `report/<TS>_tx1320_raid10_smb_n6_step2_attach_ok_install_blocked.md` | TX1320 N6 step 2 部分達成: patch で SMB attach 成立、 install は別エラーで継続 |
| Phase D 失敗 (patch 効かず or iRMC 再 give-up) | `report/<TS>_tx1320_raid10_smb_n6_step2_patch_ineffective.md` | TX1320 N6 step 2 継続: patched smbd でも INVALID_LEVEL 残存 (N6-alt 検討) |
| Phase E fallback で 10.1.6.1 deploy 経由成功 | `report/<TS>_tx1320_raid10_smb_n6_step2_fallback_success.md` | TX1320 N6 step 2 fallback 経由完了: 10.1.6.1 deploy + 検証 |
| iRMC 再 give-up で復活なし | `report/<TS>_tx1320_raid10_smb_n6_step2_irmc_dead_again.md` | TX1320 N6 step 2 ブロック: 物理電源切離後も iRMC SMB worker 復活せず |

**レポート本文 sections** (必須):
1. **冒頭メタ**: 実施日時 (JST 分まで)、 担当 (silly-token)、 Issue #69 状態、 対象機 / 追加リソース、 親レポートへのリンク (前ターン分含む chain)
2. **添付ファイル一覧** (Markdown リンク、 sha256 と容量併記): plan.md / pcap / Samba log / patched smbd / tarball / sol log / 各 Phase ログ
3. **前提・目的**: 前ターン (`_blocked.md`) からの引き継ぎ + 本ターンの追加目的 (物理電源切離後の検証)
4. **重要な発見** (next-session must-read): iRMC SMB worker 復活確認の結果、 patch 効果実証 (level=513 → OK)、 install 完走 (or 失敗パターン詳細)
5. **環境情報**: 10.1.6.6 / 10.1.6.1 / iRMC の構成表 (前ターン report と同形式)
6. **実施内容** (Phase 毎): A〜F のコマンド + 観測値 + ログ抜粋。 特に Phase B (tcpdump) と Phase D (Samba log) は具体 grep 結果を貼る
7. **完了事項** (チェックリスト)
8. **未完了 / 次セッション課題**: もし install が一部のみ完走したら何を引き続き行うか、 upstream Samba PR 提出など
9. **再現方法**: コマンドベース手順 (本ターン使用した sh ファイル相当)
10. **関連 Issue**: #69 含む chain 関係を整理 + 本ターン entry を追加
11. **関連ファイル**: 修正 / 新規作成リスト (config/training_tx1320.yml、 10.1.6.6 上の /usr/sbin/smbd 含む)
12. **重要な教訓** (次セッションへの引き継ぎ): 物理電源切離が必要だった経緯、 RUNPATH 注意、 同期 tcpdump の重要性等

#### G-2. attachment ディレクトリ整備

`report/attachment/<TS>_tx1320_raid10_smb_n6_step2_<status>/` に以下を保存:
- `plan.md` (本ファイル `/home/ubuntu/.claude/plans/pvese-report-2026-05-20-231624-tx1320-ra-silly-token.md` をコピー)
- `phaseA-irmc-recovery.log` (Phase A の Redfish polling + PowerState + OEM VirtualMedia 確認結果)
- `phaseB-smb-traffic.pcap` (10.1.6.6 で取得した tcpdump、 同期 capture)
- `phaseB-tcpdump-summary.txt` (`tcpdump -r ... -n | head -100` の抜粋)
- `phaseC-deploy.log` (smbd 差し替えの一連ログ + `smbd --version` 出力)
- `phaseD-samba.log` (10.1.6.6 `/var/log/samba/log.*` を grep + tail で抜粋、 `level = 513` + status 行)
- `phaseD-members-polling.txt` (Members@odata.count の 120s 推移)
- `phaseF-sol.log` (install 実走時の SOL 全文、 サイズ大の場合 `head -1000` + `tail -500`)
- `phaseF-installer-syslog.log` (sol-monitor の `--installer-syslog` 出力)
- `smbd-patched-sha256.txt` (`sha256sum /usr/sbin/smbd` を deploy 前後で記録)
- 追加で 10.1.6.6 上の `/etc/samba/smb.conf`、 patched smbd `--version`、 `smbstatus` 出力 (sudo 必要)

容量目安: pcap が 100-500 KB、 Samba log が 1-10 MB (debug=10 のまま走らせると膨らむため必要に応じ抜粋に絞る)。

#### G-3. メモリ更新

[`training_tx1320_smb_n6_step2.md`](/home/ubuntu/.claude/projects/-home-ubuntu-projects-pvese/memory/training_tx1320_smb_n6_step2.md) を**追記更新** (新規ファイル作成しない、 既存を上書き):
- 本ターンの実施結果を冒頭サマリに反映: `(本ターン silly-token 2026-05-21 後半で物理電源切離後の検証完了、 patch 効果実証 ✅ / install 完走 ✅)` 等
- iRMC SMB worker の復活手段が「物理電源切離 (AC コード抜き)」と確定したことを **How to apply** セクションに記載 — 次セッションが同じ症状に遭遇したら最初に試すべき手段として明示
- patched smbd の RUNPATH 注意 (10.1.6.1 deploy 時は LD_LIBRARY_PATH / chrpath 必要) を保存

[`MEMORY.md` index](/home/ubuntu/.claude/projects/-home-ubuntu-projects-pvese/memory/MEMORY.md) の該当行を更新:
- 既存: `🚨 training-tx1320 N6 step 2 部分達成: ... iRMC SMB worker 完全停止 ... → 物理電源切離が必要`
- 新規: `🎯🎯🎯 training-tx1320 N6 step 2 完全達成: 物理電源切離で iRMC SMB worker 復活 → patched samba 4.19.5 (1 文字 typo fix) で SMB attach 成立 + install 完走 → Issue #69 完了`
- (失敗時は適切に書き換え)

#### G-4. Issue update

```sh
# 成功時 (Phase D + F 両方 OK):
./issue.sh start 69 --owner silly-token
./issue.sh verify 69
./issue.sh done 69 --report report/<TS>_tx1320_raid10_smb_n6_step2_success.md

# 部分成功 (Phase D OK / F 失敗):
./issue.sh start 69 --owner silly-token
./issue.sh block 69 "patch で SMB attach は成立 (✅)、 install 別エラーで継続中。 詳細→ report/<TS>_tx1320_raid10_smb_n6_step2_attach_ok_install_blocked.md"

# patch 失敗 / fallback / iRMC dead-again はそれぞれ block で詳細記録
```

新規 issue 候補:
- **upstream Samba bug 報告**: `./issue.sh add "Samba 4.19+ smb2_trans2.c fsinfo_unix_valid_level SMB1SERVER typo を upstream に報告 + PR" --label upstream --desc "本ターンで build + 動作確認まで完了したため、 samba-technical / bugzilla / GitHub PR で patch 提出可能。 詳細→ report/<TS>_..."`

#### G-5. CLAUDE.md / config 更新 (必要時)

- 本ターンで判明した「iRMC SMB worker は Manager.Reset では復帰しない、 物理電源切離が必要」を Tips として CLAUDE.md に追記すべきか検討
- `config/training_tx1320.yml` の最終状態: `smb_host: 10.1.6.6` (成功 deploy 先) または `10.1.6.1` (fallback / 失敗時 rollback) を確定

#### G-6. 旧 plan ファイルの保全

`/home/ubuntu/.claude/plans/pvese-report-2026-05-20-231624-tx1320-ra-silly-token.md` (本ファイル) を最終レポートの attachment にコピー (REPORT.md ルールの「プランファイル添付必須」に準拠)。

#### G-7. (副次成果) upstream Samba への bug 報告

本ターン完了後の **別タスク** として扱う:
- Samba bugzilla で新規 bug 登録 (タイトル: `SMB1 SMB_QUERY_POSIX_FS_INFO returns INVALID_LEVEL due to fsinfo_unix_valid_level typo SMB1SERVER ↔ WITH_SMB1SERVER`)
- 影響範囲: Samba 4.19+ (本ターン build で実証) + master + v4-21-stable
- patch: 1 行差分、 既存 `proposed-patch.diff` を流用 + 本ターン検証実績を Reporter コメントとして追加
- 提出窓口優先順: (1) samba-technical@lists.samba.org メーリングリスト、 (2) bugzilla.samba.org、 (3) GitHub PR (samba-team/samba)
- 上記は新規 issue としてバックログに残し、 別セッションで実施

## 検証方法 (Phase D の判定軸)

| 検証項目 | 方法 | 期待結果 |
|---------|------|---------|
| **patched smbd 起動** | `sudo systemctl status smbd && smbclient -L //10.1.6.6/ -U guest%guest -m NT1` | active (running) + public share 表示 |
| **iRMC SMB worker 復活** | 同期 tcpdump 5 min で SYN 観測 | iRMC → 10.1.6.6:445 SYN >= 1 |
| **🎯 patch 効果** | Samba log で `smbd_do_qfsinfo : level = 513` + 続く reply の status 行 | `NT_STATUS_OK` (前は `NT_STATUS_INVALID_LEVEL`) |
| **VirtualMedia attach** | `curl .../VirtualMedia` の `Members@odata.count` | `>= 1` (前は 0) |
| **install 完走** | sol-monitor で `Installation complete` stage or PowerState Off 観測 | timeout 45 min 内 |

## リスクと対策

| リスク | 対策 |
|--------|------|
| iRMC が Phase A の polling 5 min で復活しない | 追加 5 min 延長、 それでも復活なければ user に 2 回目の物理切離を依頼 |
| Phase B で 10.1.6.6 にまだ到達しない | Phase E (10.1.6.1 fallback) へ移行 |
| Phase C で patched smbd が shared lib エラー | build dir は同 host にあるため RUNPATH そのまま動くはず。 万一エラーなら `LD_LIBRARY_PATH=/home/ubuntu/samba-build/samba-4.19.5/bin/shared:.../private` を systemd unit に export、 もしくは `/etc/ld.so.conf.d/` に追加 |
| Phase D で patch しても INVALID_LEVEL 残る | patch 適用先間違い / lp_smb1_unix_extensions の default false 化 を疑い再確認、 もしくは別の #if defined 経路を grep |
| Phase D で attach 成立しても install で別の SMB error | tcpdump + Samba log 観察、 N6 step 3 として別 patch 検討 |
| Phase F で real ISO 生成に失敗 | 既知 ISO の rsync (10.1.6.1 から sudo 必要 → user 依頼)、 もしくは host 内で wget netinst して remaster |
| patched smbd 差し替えで 10.1.6.6 が再起動できなくなる | 元 binary を `/usr/sbin/smbd.orig.<ts>` で backup、 `sudo apt install --reinstall samba` でも復元可 |

## 想定総所要時間

| Phase | 時間 |
|-------|------|
| A (iRMC 復活確認) | 5 min (本ターン中、 並行で plan 詰める) |
| B (SMB worker 復活確認) | 5-10 min |
| C (deploy on 10.1.6.6) | 5 min |
| D (検証) | 10-15 min |
| E (fallback、 必要時) | +30 min |
| F (install、 成功時) | 60-90 min |
| G (report) | 15-20 min |
| **合計 (成功 path)** | **~2 時間** |
