# Trial 5 / 10 — server14 (R430)
- 開始: 2026-05-12 08:58:17 JST
- 終了: 2026-05-12 09:41:51 JST
- 所要時間: 43m34s (実時間: 08:58:17 → 09:41:51)
- 結果: success
- install-monitor attempt 回数: 1 (1 回で成功、7m15s で PowerState=Off)
- 失敗時の原因: なし (install-monitor は first attempt で 7m15s で完了。Round 3 で観測した partman stuck 不発)

## 観測された新規問題 / skill 改善候補

### 1. /tmp/ リブート消失問題は /root/ scp で完全回避 (Round 4 改善 13 検証)
- **適用**: scp で `pre-pve-setup.sh` と `pve-setup-remote.sh` を `/root/` に配置
- **結果**: post-reboot 後も両スクリプトが残り、route fix → post-reboot 再実行で再 scp 不要
- **skill 改善案 (Round 4 で提案済み)**: SKILL.md Phase 7 step 1 で「`scp ... root@<host>:/root/`」を推奨し、reboot 後も使えるようにする (現在は `/tmp/` 例示)

### 2. post-reboot 中の default route 消失は今回も再現 (Round 4 改善 14 必要)
- **症状**: 1 回目の `pve-setup-remote.sh --phase post-reboot --linstor` 実行中、`proxmox-ve` (依存パッケージインストール段階) で apt fetch fail → exit 100。`ip route show` から default route が消失
- **回復**: `dhclient -1 -v eno1` で route 再取得 → post-reboot 再実行で完走
- **観測**: pve-setup-remote.sh のスクリプト内に「Default-route fix hook installed at /etc/network/if-up.d/z-fix-default-route」というハードコード hook が追加されていた (Round 4 反映済み)。にもかかわらず post-reboot 1 回目で hook が発動する前に default route が消えて apt fail した
- **解析**: hook は `/etc/network/if-up.d/` 配置のため `ifup` トリガー時のみ発動。 ifupdown2 再初期化のごく短期間 (ifdown→ifup の谷間) で default route が無い瞬間に apt が fetch を試みると fail する
- **skill 改善案**: post-reboot 失敗時の対処として「`dhclient -1 -v <dhcp_iface>` で再取得 → post-reboot 再実行」を Phase 7 ステップ 4 の Recovery 手順に明文化。または pve-setup-remote.sh 内部に「apt-get install 直前に `ip route show` + 必要なら `dhclient` 再実行」する pre-flight check を追加 (Round 4 改善 14 と同じ提案、未だ未実装)

### 3. final reboot 後も default route 消失 (新規発見)
- **症状**: `final reboot` 後 SSH 復帰時、`ip route show` から default route が消えていた。/etc/network/if-up.d/z-fix-default-route hook あり、vmbr1 は preseed の段階では未配置のため hook が機能しない (interface 名違い)
- **影響**: ping deb.debian.org が失敗。bridge setup 前の段階のため一時的に internet 不通
- **回復**: `dhclient -1 -v eno1` で eno1 経由 DHCP 取得 → default route 復活
- **その後**: `pve-bridge-setup.sh` 実行後は vmbr1 が DHCP で default route を保持
- **skill 改善案**: Phase 7 ステップ 5 の検証で「`ping -c1 deb.debian.org` を実施し、失敗時は `dhclient -1 -v <dhcp_iface>` を実行」を明記。または pve-bridge-setup.sh に vmbr1 設定後の internet 到達性確認を追加

### 4. Round 2-4 改善の検証結果 (Trial 5 で適用)
| 改善 | 結果 |
|------|------|
| 改善 6 (LINBIT GPG empty-file detect → 事前 keyring 配置) | ✓ `linbit-keyring-trial3.gpg` (Trial 3 取得) を再配置 → fetch 不要で post-reboot 一発成功 |
| 改善 7 (build-essential / libc6-dev を `--linstor` 前に install) | ✓ pre-pve-setup 完了直後に `apt-get install -y build-essential libc6-dev` → DKMS build 一発成功 (drbd-dkms 9.3.2-1 Setting up OK、Built for 7.0.2-2-pve) |
| 改善 8 (SCP Export job 完了待ち) | (発動せず) Trial 5 では resetconfig 後の Export job 未スポーン (jobqueue view に未表示)。ただし createvd 1 回目で **LC062 失敗** → 即再試行で成功。Export job は jobqueue view に常に出るわけではない |
| 改善 9 (`printf > /file` の "Command may have failed" は誤検知) | ✓ SOL `ip -brief addr > /tmp/iface.txt` で WARN 出たが redirect 自体成功 (後続 SSH で /tmp/iface.txt 取得 OK) |
| 改善 10 (partman stuck 早期判定 + racreset soft) | (発動せず) Trial 5 first attempt で stage 5/9 partman → 1分以内に Stage 6 移行。R430 partman 安定 |
| 改善 11 (sol-login.py DETECTING timeout 延長) | (発動せず) DETECTING で即 LOGIN_PROMPT に遷移 (boot 完了が早かった) |
| 改善 12 (eno1 DHCP iface を /etc/network/interfaces に追記) | ✓ SOL コマンドで `ip link set eno1 up` + `printf 'auto eno1\niface eno1 inet manual\n' >> /etc/network/interfaces` を実行 → post-install で eno1 UP 確認 |
| 改善 13 (`/root/` scp で /tmp/ クリアを回避) | ✓ pre-pve-setup.sh / pve-setup-remote.sh を `/root/` に配置 → リブート後も生存、再 scp 不要 |
| 改善 14 (post-reboot 前の internet pre-flight check) | **未実装** — post-reboot 1 回目で route 消失 + apt fail を再現。dhclient 再実行で復活 (Round 4 と同じパターン) |

### 5. install-monitor 中の PowerState check timeout (Trial 1-4 と同じパターン)
- install-monitor 中に `bmc-power.sh status` が 4 回連続 30 秒 timeout → `PowerState=None` で記録
- 影響なし (stage 観測ガード + 後半で Off に推移して正常完了)
- iDRAC8 + iDRAC FW 2.63.60.61 の Redfish API が install 中の負荷で応答遅延を起こす既知挙動
- skill 改善案: なし (現状のリカバリで十分)

### 6. resetconfig 後の Export job は jobqueue view に常に出るわけではない (新規発見)
- **症状**: `racadm raid resetconfig` + `jobqueue create` 後の poll 中、`jobqueue view` に **Export ジョブが一切出てこなかった** (Trial 5)。Trial 4 では Export ジョブが見えた
- **結果**: poll 終了 → 直後の `racadm raid createvd` が **LC062** (Export or Import server profile operation is already running) で失敗
- **回復**: 20 秒間隔で createvd を retry → 1 回目の retry で成功 (Export ジョブが silently 終了)
- **解析**: iDRAC8 は Export ジョブを Lifecycle Controller 内部キューに隠蔽することがあり、`jobqueue view` の外で動作している。**poll の検出に依存できない**
- **skill 改善案**: SKILL.md Phase 4 (R430 RAID 整備) で「resetconfig 後の `createvd` が LC062 で失敗する場合は、20 秒間隔で retry し続ける (jobqueue view に Export job が見えない場合もある)」を明記。または createvd 自体を retry loop で包む (本 trial の `poll-export-wait.sh` パターン)

## 主要ログ
- `tmp/t5-s14/sol-install.log` (install monitor SOL log)
- `tmp/c452be97/installer-syslog-all.log` (親管理、UDP 5514 — 共通)
- `tmp/c452be97/linbit-keyring-trial3.gpg` (再利用、事前配置)
- `tmp/t5-s14/poll-reset.sh`, `poll-export-wait.sh`, `poll-createvd.sh` (Phase A poll scripts)
- `tmp/t5-s14/sol-commands.txt` (Phase 6 SOL commands)
- `tmp/t5-s14/setup-via-ssh.py` (Phase 6 pexpect SSH key 配置)
- `tmp/t5-s14/get-dhcp-ip.py` (Phase 6 iface 確認)
- `log/oplog.log` (state-changing コマンド全件)

## 主要イベントタイムライン
- 08:58:17 — Trial 5 開始 (Phase A)
- 08:59:00 頃 — jobqueue delete --all (RAC1032)
- 08:59:13 — racadm raid resetconfig:RAID.Integrated.1-1 (STOR094)
- 08:59:30 — jobqueue create pwrcycle (JID_785115730191 + RID_785115731412)
- 09:03:14 — Configure: RAID.Integrated.1-1 Completed (100), Export job 未スポーン
- 09:03:30 — racadm raid createvd Bay 1+6 → **LC062** (Export job 隠蔽)
- 09:03:50 — createvd retry → STOR094 (Export job 終了)
- 09:04:00 — jobqueue create pwrcycle (JID_785119582140)
- 09:07:25 — VD0 OS_RAID1 Completed (Online, RAID-1, Bay 1+6, 278.88GB)
- 09:08:00 頃 — state リセット + VirtualMedia umount + boot-reset + known_hosts 削除
- 09:10:00 頃 — Phase 1-3 マーク (ISO 再利用 OK, preseed sha256 一致)
- 09:11:30 頃 — Phase 4 bmc-mount-boot (mount + boot-once + power on)
- 09:13:06 — Phase 5 install-monitor.start
- 09:14:23 — Stage observed (0/9)
- 09:15:33 — Stage 1/9 LOADING_COMPONENTS (2.3min)
- 09:16:08 — Stage 2-3 DETECTING_NETWORK / CONFIGURING_APT (2.8min)
- 09:16:43 — Stage 5/9 partman (3.5min) — partman stuck 不発、即通過
- 09:18:48 — Stage 6-7/9 INSTALLING_SOFTWARE / INSTALLING_GRUB (5.5-5.9min)
- 09:19:59 — PowerState Off detected (6.5min)
- 09:20:25 — Installation completed successfully (sol-monitor exit 0)
- 09:20:30 頃 — Phase 6 step 1-2 (umount + boot-reset + Power On)
- 09:21:00 頃 — ssh-wait 360s で SSH 不到達 (boot 完了待ち)
- 09:27:47 — sol-login.py で PermitRootLogin / PasswordAuthentication 有効化 + sudoers + eno1 up
- 09:28:30 頃 — pexpect password SSH で authorized_keys 配置 (90 bytes ed25519)
- 09:28:50 頃 — SSH key auth + machine-id 検証 OK (1778545040 > 1778544786)
- 09:29:00 頃 — Phase 7 開始 (pre-pve-setup.sh 1 回目 → 成功、route fix + apt update + wget/ca-certs install)
- 09:29:30 — `apt-get install -y build-essential libc6-dev` (改善 7) 完了
- 09:29:50 — LINBIT keyring 事前配置 (改善 6) — `linbit-keyring-trial3.gpg` 再利用
- 09:30:00 頃 — pve-setup-remote.sh --phase pre-reboot 実行 (proxmox-default-kernel install 完了)
- 09:33:00 頃 — reboot → ssh-wait 80s で復活
- 09:33:30 — `/root/` 配置スクリプト survive 確認 (改善 13 ✓)
- 09:34:00 — `dhcpcd -1 -t 30 eno1` で DHCP 取得 → pre-pve-setup 2 回目 → route 復活
- 09:34:30 頃 — pve-setup-remote.sh --phase post-reboot --linstor 1 回目 → exit 100 (apt fail, default route 消失)
- 09:35:00 頃 — `dhclient -1 -v eno1` で route 再取得 + 検証 (改善 14 必要)
- 09:35:30 頃 — pve-setup-remote.sh --phase post-reboot --linstor 2 回目 → 完走 (drbd-dkms 9.3.2-1 build OK, linstor-satellite 1.33.3-1 install OK, linstor-proxmox 8.2.0-1 install OK, openjdk-21 install OK)
- 09:39:00 頃 — final reboot → ssh-wait 60s で復活
- 09:39:30 — default route 消失再確認 → dhclient -1 -v eno1 で復活
- 09:40:00 頃 — pve-bridge-setup.sh で vmbr0/vmbr1 構築
- 09:41:30 頃 — 最終検証 (pveversion, vmbr0, vmbr1, default route, Web UI 200)
- 09:41:51 — Trial 5 終了

## 検証結果
- pveversion: `pve-manager/9.1.9/ee7bad0a3d1546c9 (running kernel: 7.0.2-2-pve)`
- vmbr0: `10.10.10.214/8` (UP)
- vmbr1: `192.168.39.164/24` (UP, DHCP)
- default route: `via 192.168.39.1 dev vmbr1`
- 10.0.0.0/8: `dev vmbr0 proto kernel scope link src 10.10.10.214`
- Web UI: `https://10.10.10.214:8006` → HTTP 200
- VD0: Online (RAID-1, Bay 1+6, 278.88GB, OS_RAID1)
- DRBD: drbd-dkms 9.3.2-1 installed
- LINSTOR satellite: 1.33.3-1 enabled
- linstor-proxmox: 8.2.0-1 installed
- インターネット到達性: deb.debian.org → ping 3.17 ms OK

## ./scripts/os-setup-phase.sh times --config config/server14.yml

```
iso-download             0m20s
preseed-generate         0m06s
iso-remaster             0m14s
bmc-mount-boot           0m55s
install-monitor          7m25s
post-install-config      8m11s
pve-install              11m48s
cleanup                  1m11s
---
total                    30m10s
```

(skill 内部 phase 計測の合計 30m10s と実時間 43m34s の差 13m24s は、Phase A の RAID 操作 (jobqueue delete + resetconfig + createvd の LC062 retry を含む) が Phase 計測対象外で ~11 分、final reboot 後の dhclient 再取得 + bridge setup が ~2 分消費されたため)

## Trial 1 / Trial 2 / Trial 3 / Trial 4 / Trial 5 比較
| 観測項目 | Trial 1 | Trial 2 | Trial 3 | Trial 4 | Trial 5 |
|---------|---------|---------|---------|---------|---------|
| install-monitor (時間) | 7m37s | 7m21s | 7m34s | 7m21s | **7m25s** |
| install attempt 回数 | 1 | 1 | 2 (attempt 1 partman stuck) | 1 | **1** |
| attempt 1 failure | なし | なし | partman-auto-lvm 固着 25min | なし | **なし** |
| 全体所要時間 | 47m17s | 53m08s | 78m03s | 43m56s | **43m34s** |
| 競合の有無 | 並列 agent dpkg 競合 | 無 | 無 | 無 (単独実行) | **無 (単独実行)** |
| Round 2 改善 #6 LINBIT keyring | 該当無し | 手動 fallback | 事前配置 ✓ | 事前配置 ✓ | **事前配置 ✓** |
| Round 2 改善 #7 build-essential | 該当無し | 手動 install | 事前 install ✓ | 事前 install ✓ | **事前 install ✓** |
| Round 2 改善 #8 SCP Export 待ち | 該当無し | 観測ガード | poll 明示 ✓ | poll 明示 ✓ | **Export 未スポーン (poll 不発)** |
| Round 2 改善 #9 printf 誤検知 | 該当無し | 該当無し | 誤検知確認 | 誤検知確認 | **誤検知確認** |
| Round 3 改善 #10 partman stuck 早期判定 | N/A | N/A | 発動 (実証) | 発動せず | **発動せず (R430 partman 安定継続)** |
| Round 3 改善 #11 sol-login DETECTING 延長 | N/A | N/A | 発動 (~6min 待ち) | 発動せず | **発動せず (boot 早かった)** |
| Round 3 改善 #12 eno1 SOL 設定 | N/A | N/A | 発動 ✓ | 発動 ✓ | **発動 ✓** |
| Round 4 改善 #13 /root/ scp | N/A | N/A | N/A | 未適用 (/tmp/ で失敗) | **適用 ✓ (リブート後 survive)** |
| Round 4 改善 #14 post-reboot pre-flight | N/A | N/A | N/A | 未実装 | **未実装 (post-reboot 1 回 fail 再現)** |
| 新発見の skill 改善点 | rm -rf state ブロック | LINBIT GPG fallback | partman stuck 判定 | /tmp/ クリア / post-reboot route 消失 | **Export job 未スポーン LC062 retry / final reboot 後の route 消失** |

## Round 4 改善 13 適用効果まとめ
Trial 5 は Round 1-4 で観測された全 trouble (LINBIT GPG empty file / build-essential 不在 / SCP Export 競合 / partman stuck / printf 誤検知 / eno1 DOWN / /tmp/ クリア) を skill に従い事前回避できた:
- **Trial 1**: 47min, 並列競合あり (skill 範囲外)
- **Trial 2**: 53min, LINBIT keyring 手動取得 + build-essential 手動 install で 7min 浪費
- **Trial 3**: 78min, partman stuck 25min + racreset soft 復旧 4min で 30min 浪費
- **Trial 4**: 44min, /tmp/ クリア + post-reboot route 消失で 2min 浪費
- **Trial 5**: **43.5min**, 改善 6-9 + 13 を skill 通り適用 → install attempt 一発成功 + post-reboot 1 回リトライで完走

**Trial 4 → 5 で改善 13 (/root/ scp) を適用した結果、/tmp/ クリア由来の再 scp 作業 (~1min) が消えた**。一方で改善 14 (post-reboot pre-flight check) が未実装のため post-reboot 1 回 fail + dhclient 復旧の ~1min は残った。

## 新規 skill 改善候補 (Round 5)

### 改善 15: Export job 未スポーン → createvd LC062 retry loop
- **問題**: `racadm raid resetconfig` 後の `jobqueue view` に Export job が出ない (Trial 5 で観測。Trial 4 では Export job が見えた)。次の `createvd` が LC062 で失敗
- **修正案**:
  - SKILL.md Phase 4 (R430 RAID 整備) で「Export job が `jobqueue view` に見えない場合でも LC062 で createvd が失敗することがある。**20 秒間隔で createvd を retry**」を明記
  - または createvd 自体を retry loop に変更 (LC062 でのみ retry、他のエラーは即 fail)

### 改善 16: final reboot 後の route 消失対応
- **問題**: final reboot 後の SSH 復帰時に default route が消失していた。`/etc/network/if-up.d/z-fix-default-route` hook はあるが、interface 名が古い (eno1) ため vmbr1 化前は機能する想定だが、何らかの timing 問題で発動しなかった
- **修正案**:
  - SKILL.md Phase 7 ステップ 5 (最終リブート) の検証で「`ssh ... ping -c1 deb.debian.org` を実施し、失敗時は `dhclient -1 -v <dhcp_iface>` を実行 → bridge setup へ」を明記
  - または pve-bridge-setup.sh の冒頭 (apply 前) に `ip route show | grep ^default` でチェック + 必要なら dhclient 再実行を追加

### 改善 14 (Round 4 再掲) — post-reboot pre-flight check は引き続き未実装
- post-reboot 1 回目の apt fail + default route 消失は Trial 4・Trial 5 で連続再現。**実装優先度高**
- 提案: pve-setup-remote.sh の `post-reboot` 冒頭に「`ip route show | grep -q ^default || dhclient -1 -v <dhcp_iface>`」を追加

Trial 5 server14: success (44min, attempt 1)
