# TX1320 iRMC SMB silent failure N1 仮説検証 + RAID10 install 完走 (Issue #69 続編)

## Context

前セッション `report/2026-05-19_163800_tx1320_raid10_smb_real_root_cause.md` (s-expressive-bubble) で silent failure の真因が **iRMC FW 9.08F の SMB redirector が file open + AIO read 後に USB device を生成しない** ことまで packet + Samba debug log で確定。 60 秒間隔の retry サイクル + 数時間連続失敗で give-up state (ConnectCD POST に socket は返すが SMB negotiate を一切送らない状態) も観測。 ネットワーク経路品質は無罪。

未検証の新仮説 **N1**: trans2 setpathinfo (info_level=521 / SMB_SET_FILE_UNIX_BASIC = chmod 試行) が EPERM で iRMC abort。 対策は ISO chown nobody:nogroup + smb.conf `[public] force user = nobody` で Samba 側の chmod 試行を成立させる。

本セッションは N1 のみに集中検証し、 確定すれば本セッション内で deploy + install 完走 (Issue #69 close を目指す)。 N1 反証なら N2/N3 は次セッション持ち越し (Samba debug log の setpathinfo NT_STATUS を必ず記録)。

ping baseline は本セッション開始時点で `5 packets / 0% loss / avg 167ms` (前セッションの 228ms より良好)。 give-up state は数時間放置で解除されている可能性が高いが、 確実性のため Phase 1 で Manager.Reset を必ず実施する。

## 仮説 N1 (本セッションで検証)

iRMC は Samba から `trans2 setpathinfo info_level=521` 受信後の chmod 試行 (effective uid=65534=nobody) が **root:root 0644 ISO に対して EPERM** で abort し、 USB device 生成に進めない。 対策:

- ISO ownership: `root:root` → `nobody:nogroup`
- smb.conf [public]: `force user = nobody` / `force group = nogroup` 追加

これで Samba 側の chmod が nobody 自身が所有するファイルへの chmod 操作になり EPERM が解消、 iRMC が USB SCSI emulation 開始まで進める想定。

## 実施フェーズ

### Phase 0: Pre-flight (~5 min)

1. sid 取得: Glob `pattern: "*.jsonl", path: "/home/ubuntu/.claude/transcripts"` → mtime 最新の UUID 先頭 8 文字 → `mkdir -p tmp/<sid>`
2. ping precheck: `ping -c 10 -i 1 -W 2 10.254.254.9` → `tmp/<sid>/ping-precheck.log`
3. BMC status: `BMC_SCHEME=https BMC_CURL_OPTS='--ciphers DEFAULT@SECLEVEL=0' ./scripts/bmc-power.sh status 10.254.254.9 claude Claude123`
4. VirtualMedia status: `./scripts/irmc-virtualmedia.sh --type=CD status 10.254.254.9 claude Claude123`
5. smb.conf backup: `cp /etc/samba/smb.conf tmp/<sid>/smb.conf.backup`
6. smbclient baseline: `smbclient -L //10.1.6.1 -U guest%guest -m NT1 -p 445` → `tmp/<sid>/smbclient-baseline.txt`
7. ISO 状態確認: `stat /var/samba/public/debian-training-tx1320-raid10.iso` → `tmp/<sid>/iso-baseline.log`

### Phase 1: BMC Manager.Reset で give-up state 解除 (~5 min)

- POST `/redfish/v1/Managers/iRMC/Actions/Manager.Reset` with `{"ResetType":"GracefulRestart"}` 期待 HTTP 204
- 5s × 34 iter までで `bmc-power.sh status` が PowerState を返したら復帰確定 (~170s 上限)
- 200s 経っても復帰せず → 中止、 cleanup 不要 (まだ smb.conf も ISO も未変更)

### Phase 2: N1 検証 — chown + force user=nobody + ConnectCD + Samba debug log 観察 (~15 min)

- `smb.conf.test-n1`: backup + `log level = 10` + `[public] force user = nobody / force group = nogroup`
- `phase2-n1.sh`: chown nobody:nogroup ISO → cp smb.conf.test-n1 → truncate `/var/log/samba/log.{10.254.254.9,.}` → smbcontrol reload-config + close-share → DisconnectCD POST → sleep 10s → ConnectCD POST
- Members polling: 24 iter × 5s = 120s、 `Members@odata.count >= 1` で early exit
- ログ解析: setpathinfo の NT_STATUS、 smb_posix_open の status、 AIO read の頻度を grep

### Phase 3: 結果分岐

- N1 確定 (Members>=1) → Phase 4 (deploy 完走)
- N1 反証 (Members=0 維持) → Phase 5 cleanup + Phase 6 で NT_STATUS を必ず記録

### Phase 4: deploy + install 完走 (~50 min、 N1 確定時のみ)

- `./oplog.sh ./scripts/tx1320-raid10-orchestrate.sh deploy config/training_tx1320.yml`
- SOL monitor は orchestrate が内部で起動
- `pvese-patch: bypassed list-devices via /dev/sr1 direct mount` を grep で確認
- 完走後 lsblk + storcli VD0 で RAID10 healthy 確認

### Phase 5: Cleanup + 互換性復元 (~5 min)

- `cp tmp/<sid>/smb.conf.backup /etc/samba/smb.conf` + reload-config + close-share
- `chown root:root /var/samba/public/debian-training-tx1320-raid10.iso`
- `diff /etc/samba/smb.conf tmp/<sid>/smb.conf.backup` exit 0
- smbclient 再採取 + baseline と diff exit 0

### Phase 6: レポート + Issue update (~15 min)

- `report/2026-05-20_<HHMMSS>_tx1320_raid10_smb_n1_*.md` + attachment
- Issue #69 状態を update
- メモリ `training_tx1320.md` の SMB セクション追記

## 安全弁・中止条件

- Phase 1 BMC reset 後 200s 復帰せず → 中止、 cleanup 不要
- Phase 2 chown / smb.conf cp / reload-config 失敗 → 即 Phase 5 cleanup
- Phase 4 deploy 60 min 経っても install 未完了 → SOL 解析 + Phase 5 cleanup + レポート記載
- 互換性復元 diff != 0 → ユーザ通知 + 他作業中止
- iRMC 5 連続 HTTP 5xx → Phase 4 skip、 Phase 5 cleanup + レポート

## 触る・触らないファイル

### 一時的に変更 (セッション末で完全復元)
- `/etc/samba/smb.conf`
- `/var/samba/public/debian-training-tx1320-raid10.iso` ownership
- `/var/log/samba/log.{10.254.254.9,.}` (truncate、 復元不要)

### 読むだけ
- `scripts/irmc-virtualmedia.sh`, `scripts/bmc-power.sh`, `scripts/tx1320-raid10-orchestrate.sh`, `scripts/sol-monitor.py`
- `config/training_tx1320.yml`
- メモリファイル

### 新規作成
- `tmp/<sid>/` 配下: phase1-reset.sh, phase1-poll.sh, phase2-n1.sh, phase2-poll.sh, phase5-cleanup.sh + smb.conf 3 種 + log 群
- `report/2026-05-20_<HHMMSS>_*.md` + attachment

## 主な参考ファイル

- `scripts/irmc-virtualmedia.sh` — `--type=CD status` / PATCH payload
- `scripts/bmc-power.sh` — BMC status / Reset 系
- `scripts/irmc-bios-raid-setup.sh` の S1 step — Manager.Reset GracefulRestart の既存実装パターン
- `scripts/tx1320-raid10-orchestrate.sh` — deploy フロー
- `scripts/sol-monitor.py` — INSTALLER_STAGES + machine-id mtime + installer-syslog 三本立て
- `config/training_tx1320.yml` — smb_host=10.1.6.1 / smb_share_path=\\public / smb_user=guest / smb_pass=guest
- `report/2026-05-19_163800_tx1320_raid10_smb_real_root_cause.md` — 前セッション
- `report/attachment/2026-05-19_163800_tx1320_raid10_smb_real_root_cause/smb.conf.test3` — force user=nobody 参考実装
- `/home/ubuntu/.claude/projects/-home-ubuntu-projects-pvese/memory/training_tx1320.md` — SMB attach 既知の落とし穴
