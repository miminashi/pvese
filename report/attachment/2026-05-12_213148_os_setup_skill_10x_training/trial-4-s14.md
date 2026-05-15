# Trial 4 / 10 — server14 (R430)
- 開始: 2026-05-12 08:06:59 JST
- 終了: 2026-05-12 08:50:55 JST
- 所要時間: 43m56s (実時間: 08:06:59 → 08:50:55)
- 結果: success
- install-monitor attempt 回数: 1 (1 回で成功、6.3min で PowerState=Off)
- 失敗時の原因: なし (install-monitor は first attempt で 7m21s で完了。Round 3 で観測した partman stuck は今回再現せず)

## 観測された新規問題 / skill 改善候補

### 1. /tmp/ がリブートで消える (R430 + Debian 13 trixie)
- **症状**: `pre-pve-setup.sh` / `pve-setup-remote.sh` を `/tmp/` に scp で配置した後、`pre-reboot` 完了 → reboot → SSH 再接続 → `/tmp/pre-pve-setup.sh` が `No such file` で失敗
- **原因**: Debian 13 / systemd の tmpfiles 設定 (`/tmp` は再起動でクリア)。skill SOP は post-reboot 直後の route fix 用に pre-pve-setup を再使用する想定だが、`/tmp/` のスクリプトはリブート後に消える
- **影響**: Phase 7 ステップ 3 (route 修正) で pre-pve-setup.sh 再実行が `No such file` → 手動で再 scp が必要
- **回避**: 再 scp して再実行 (Trial 4 で確認)
- **skill 改善案**: Phase 7 ステップ 2 (リブート後) の前に
  - 「post-reboot 用に `/root/` 等の永続ディレクトリに pre-pve-setup.sh / pve-setup-remote.sh を再配置」
  または
  - 「リブート後の route 修正は ssh + `dhclient eno1` + `ip route` の素の手動コマンドで十分」
  と追記。あるいは pre-pve-setup.sh / pve-setup-remote.sh をオートマウント (scp 不要) にして `/usr/local/sbin/` に置くフローを推奨

### 2. post-reboot 内部 apt-get update が「default route 不在」で DNS 失敗 → exit 100 → 再走で復活
- **症状**: 最初の `pve-setup-remote.sh --phase post-reboot --linstor` が `Temporary failure resolving 'deb.debian.org'` で 4 種類のパッケージ取得を全失敗 → exit 100。LINSTOR 部分が完全に skip
- **観測**: 前段 `pre-pve-setup.sh` 実行後の `ip route` には `default via 192.168.39.1` あり (Trial 4 の 1 回目 pre-pve-setup 実行直後で確認済み)。しかし数分後の post-reboot 実行時には消えていた
- **疑い**: `pve-setup-remote.sh` の前段で実行される pve リポジトリ更新 / kernel install 等で network/networking restart が走り、default route が初期化された可能性。または dhclient のリース更新タイミング
- **回避**: post-reboot 内部 apt-get update 失敗を観測したら、`ssh ... dhclient -1 -v eno1` で route 再取得 → `pve-setup-remote.sh --phase post-reboot --linstor` を再実行で復活 (LINSTOR install 完走)
- **skill 改善案**: Phase 7 ステップ 4 (post-reboot) の前に「`ssh ... ping -c1 -W3 deb.debian.org` で internet 到達を**直前**確認 + 失敗時は `dhclient -1 -v <dhcp_iface>` を自動再実行する pre-flight check 追加」を skill に明記

### 3. Round 2-3 改善 6-12 検証結果 (Trial 4 で適用)
| 改善 | 結果 |
|------|------|
| 改善 6 (LINBIT GPG empty-file detect → 事前 keyring 配置) | ✓ `linbit-keyring-trial3.gpg` (Trial 3 取得) を再配置 → fetch 不要で post-reboot 一発成功 |
| 改善 7 (build-essential / libc6-dev を `--linstor` 前に install) | ✓ `apt-get install -y build-essential libc6-dev` を pre-reboot 完了直後に実行 → DKMS build 一発成功 (drbd-dkms 9.3.2-1 Setting up OK) |
| 改善 8 (SCP Export job 完了待ち) | ✓ `poll-export-trial4.sh` で `Export: Server Configuration Profile` Status=Completed (100) 確認後に createvd → LC062 不発 |
| 改善 9 (`printf > /file` の "Command may have failed" は誤検知) | ✓ SOL `ip -brief addr > /tmp/iface.txt` で WARN 出たが redirect 自体成功 (SSH key auth 成功 / machine-id 検証で間接確認) |
| 改善 10 (partman stuck 早期判定 + racreset soft) | (発動せず) Trial 4 は first attempt で partman 通過 (Stage 5/9 を 1分以内に脱出)。R430 partman 不安定性は trial 3 では発動、trial 1/2/4 では非発動 → **発生確率は 25% (1/4 trial) 程度** |
| 改善 11 (sol-login.py DETECTING timeout 延長 / 120-180s 待ち再試行) | (発動せず) Trial 4 では SSH 不到達後すぐに sol-login.py 実行 → DETECTING で stuck せず即 LOGIN_PROMPT に遷移 (boot 完了が早かった) |
| 改善 12 (eno1 DHCP iface を /etc/network/interfaces に追記) | ✓ SOL コマンドで `ip link set eno1 up` + `printf 'auto eno1\niface eno1 inet manual\n' >> /etc/network/interfaces` を実行 → post-install 検証で eno1 UP 確認 |

### 4. install-monitor 中の PowerState check timeout (Trial 1-3 と同じパターン)
- install-monitor 中に `bmc-power.sh status` が 3 回連続 30 秒 timeout → `PowerState=None` で記録
- 影響なし (stage 観測ガード + 後半で Off に推移して正常完了)
- iDRAC8 + iDRAC FW 2.63.60.61 の Redfish API が install 中の負荷で応答遅延を起こす既知挙動
- skill 改善案: なし (現状のリカバリで十分)

## 主要ログ
- `tmp/c452be97/sol-install-trial4-s14.log` (install monitor SOL log)
- `tmp/c452be97/installer-syslog-all.log` (親管理、UDP 5514)
- `tmp/c452be97/linbit-keyring-trial3.gpg` (再利用、事前配置)
- `tmp/c452be97/poll-reset-trial4.sh`, `poll-export-trial4.sh`, `poll-createvd-trial4.sh` (Phase A poll scripts)
- `tmp/c452be97/sol-commands-trial4-s14.txt` (Phase 6 SOL commands)
- `tmp/c452be97/place-pubkey-t4.py` (Phase 6 pexpect SSH key 配置)
- `log/oplog.log` (state-changing コマンド全件)

## 主要イベントタイムライン
- 08:06:59 — Trial 4 開始 (Phase A)
- 08:07:00 — jobqueue delete --all
- 08:07:13 — racadm raid resetconfig:RAID.Integrated.1-1 (STOR094)
- 08:07:30 — jobqueue create pwrcycle (JID_785084726143 + RID_785084727199)
- 08:11:34 — Configure: RAID.Integrated.1-1 Completed (100)
- 08:12:42 — Export: Server Configuration Profile Completed (100)
- 08:12:50 — racadm raid createvd Bay 1+6 → STOR094
- 08:13:00 — jobqueue create pwrcycle (JID_785087923164)
- 08:16:36 — VD0 OS_RAID1 Completed (Online, RAID-1, Bay 1+6, 278.88GB)
- 08:17:00 — state リセット + VirtualMedia umount + boot-reset + known_hosts 削除
- 08:18:00 — Phase 1-3 マーク (ISO 再利用 OK, preseed sha256 一致)
- 08:18:30 — Phase 4 bmc-mount-boot (mount + boot-once + cycle)
- 08:20:04 — Phase 5 install-monitor.start
- 08:21:23 — Stage observed (0/9)
- 08:22:33 — Stage 1/9 LOADING_COMPONENTS (2.3min)
- 08:23:08 — Stage 2-3 DETECTING_NETWORK / CONFIGURING_APT (2.8min)
- 08:23:43 — Stage 5/9 partman (3.5min) — partman stuck 不発、即通過
- 08:26:07 — Stage 6-7/9 INSTALLING_SOFTWARE / INSTALLING_GRUB (5.8min)
- 08:26:53 — PowerState Off detected (6.3min)
- 08:27:18 — Installation completed successfully (sol-monitor exit 0)
- 08:27:25 — Phase 6 step 1-2 (umount + boot-reset + Power On)
- 08:28:00 頃 — ssh-wait 360s で SSH 不到達 (boot 完了待ち)
- 08:34:58 — sol-login.py で PermitRootLogin / PasswordAuthentication 有効化 + sudoers + eno1 up
- 08:35:12 — pexpect password SSH で authorized_keys 配置 (90 bytes ed25519)
- 08:35:30 頃 — SSH key auth + machine-id 検証 OK (1778541865 > 1778541604)
- 08:36:00 頃 — Phase 7 開始 (pre-pve-setup.sh 1 回目 → DHCP 30s timeout + apt fetch fail で exit 100)
- 08:36:30 — `dhcpcd -1 -t 30 eno1` で fallback DHCP 取得 (192.168.39.163)
- 08:36:50 — pre-pve-setup.sh 2 回目 → 成功 (route fix + apt update + wget/ca-certs install)
- 08:37:30 — `apt-get install -y build-essential libc6-dev` (改善 7) 完了
- 08:37:50 — LINBIT keyring 事前配置 (改善 6) — `linbit-keyring-trial3.gpg` 再利用
- 08:38:00 頃 — pve-setup-remote.sh --phase pre-reboot 実行 (proxmox-default-kernel install)
- 08:42:00 頃 — reboot → ssh-wait 80s で復活
- 08:43:00 頃 — /tmp/ クリア発覚 → pre-pve-setup.sh / pve-setup-remote.sh を再 scp
- 08:43:20 頃 — pre-pve-setup.sh 3 回目 (route fix) → 成功
- 08:44:00 頃 — pve-setup-remote.sh --phase post-reboot --linstor 1 回目 → DNS fail (default route 消失) で exit 100、LINSTOR install 部分 skip
- 08:45:30 頃 — `dhclient -1 -v eno1` で route 再取得 + 検証
- 08:46:00 頃 — pve-setup-remote.sh --phase post-reboot --linstor 2 回目 → 完走 (drbd-dkms 9.3.2-1 build OK, linstor-satellite 1.33.3-1 install OK, linstor-proxmox 8.2.0-1 install OK, openjdk-21 install OK)
- 08:48:25 頃 — final reboot → ssh-wait 60s で復活
- 08:49:54 — 復活確認 (uptime 0min)
- 08:50:00 頃 — pve-bridge-setup.sh で vmbr0/vmbr1 構築
- 08:50:30 頃 — 最終検証 (pveversion, vmbr0, vmbr1, default route, Web UI 200)
- 08:50:55 — Trial 4 終了

## 検証結果
- pveversion: `pve-manager/9.1.9/ee7bad0a3d1546c9 (running kernel: 7.0.2-2-pve)`
- vmbr0: `10.10.10.214/8` (UP)
- vmbr1: `192.168.39.163/24` (UP, DHCP)
- default route: `via 192.168.39.1 dev vmbr1`
- 10.0.0.0/8: `dev vmbr0 proto kernel scope link src 10.10.10.214`
- Web UI: `https://10.10.10.214:8006` → HTTP 200
- VD0: Online (RAID-1, Bay 1+6, 278.88GB, OS_RAID1)
- DRBD: drbd-dkms 9.3.2-1 installed
- LINSTOR satellite: 1.33.3-1 enabled
- linstor-proxmox: 8.2.0-1 installed
- インターネット到達性: deb.debian.org → ping 2.97 ms OK
- OS: Debian GNU/Linux 13.4 (trixie)
- Kernel: 7.0.2-2-pve

## ./scripts/os-setup-phase.sh times --config config/server14.yml

```
iso-download             0m01s
preseed-generate         0m01s
iso-remaster             0m00s
bmc-mount-boot           1m38s
install-monitor          7m21s
post-install-config      8m24s
pve-install              14m29s
cleanup                  0m35s
---
total                    32m29s
```

(skill 内部 phase 計測の合計 32m29s と実時間 43m56s の差 11m27s は、Phase A の RAID 操作 (jobqueue delete + resetconfig + Export 待ち + createvd) が Phase 計測対象外で 9 分 + Phase 7 内部の手動リカバリ作業 (DHCP 再取得 + /tmp scp 再転送 + post-reboot 再実行) で 2 分が消費されたため)

## Trial 1 / Trial 2 / Trial 3 / Trial 4 比較
| 観測項目 | Trial 1 | Trial 2 | Trial 3 | Trial 4 |
|---------|---------|---------|---------|---------|
| install-monitor (時間) | 7m37s | 7m21s | 7m34s | **7m21s** |
| install attempt 回数 | 1 | 1 | 2 (attempt 1 partman stuck) | **1** |
| attempt 1 failure | なし | なし | partman-auto-lvm 固着 25min | **なし** |
| 全体所要時間 | 47m17s | 53m08s | 78m03s | **43m56s** |
| 競合の有無 | 並列 agent dpkg 競合 | 無 | 無 | **無 (単独実行)** |
| Round 2 改善 #6 LINBIT keyring | 該当無し | 手動 fallback | 事前配置 ✓ | **事前配置 ✓ (Trial 3 keyring 再利用)** |
| Round 2 改善 #7 build-essential | 該当無し | 手動 install | 事前 install ✓ | **事前 install ✓** |
| Round 2 改善 #8 SCP Export 待ち | 該当無し | 観測ガード | poll 明示 ✓ | **poll 明示 ✓** |
| Round 2 改善 #9 printf 誤検知 | 該当無し | 該当無し | 誤検知確認 | **誤検知確認** |
| Round 3 改善 #10 partman stuck 早期判定 | N/A | N/A | 発動 (実証) | 発動せず (R430 partman 安定) |
| Round 3 改善 #11 sol-login DETECTING 延長 | N/A | N/A | 発動 (~6min 待ち) | **発動せず (boot 早かった)** |
| Round 3 改善 #12 eno1 SOL 設定 | N/A | N/A | 発動 ✓ | **発動 ✓ (eno1 UP 確認)** |
| 新発見の skill 改善点 | rm -rf state ブロック / SerialComm Auto 互換 | LINBIT GPG fallback / build-essential | partman stuck 判定 / ssh-wait.sh iDRAC SSH 非対応 | **/tmp/ scp はリブートで消える / post-reboot default route 消失 → DNS fail** |

## Round 3 改善 10-12 適用効果まとめ
Trial 4 は Round 1-3 で観測された全 trouble (LINBIT GPG empty file / build-essential 不在 / SCP Export 競合 / partman stuck / printf 誤検知 / eno1 DOWN) を skill に従い事前回避できた:
- **Trial 1**: 47min, 並列競合あり (skill 範囲外)
- **Trial 2**: 53min, LINBIT keyring 手動取得 + build-essential 手動 install で 7min 浪費
- **Trial 3**: 78min, partman stuck 25min + racreset soft 復旧 4min で 30min 浪費
- **Trial 4**: **44min**, 改善 6-9 を skill 通り適用 + 改善 10-12 (Trial 4 では 11/12 非発動だが、改善 12 の eno1 設定は実行済) → install attempt 一発成功 + post-reboot 1 回リトライで完走

`/tmp/` 消失 + post-reboot route 消失で **2 回追加リカバリ作業が必要** だったが、Trial 3 (78min) より 34min 短い結果。**install-monitor 段階の partman 不安定性 (Trial 3 で発覚) が発動しなかったため**、Trial 1 (47min, 並列競合あり) と同等水準で完了。R430 partman stuck 発生確率: 25% (1/4) と判定可能。

## 新規 skill 改善候補 (Round 4)

### 改善 13: `/tmp/` リブート消失対策
- **問題**: pre-pve-setup.sh / pve-setup-remote.sh を `/tmp/` に scp 配置後、`pre-reboot` リブートで消える
- **修正案**:
  - skill Phase 7 ステップ 1 で「永続パスに配置」(`/root/` or `/usr/local/sbin/`) を推奨
  - または skill Phase 7 ステップ 3 で「リブート後の route 修正は素のコマンド (`dhclient` + `ip route`) を使う」を明示
  - あるいは pve-setup-remote.sh / pre-pve-setup.sh を Phase 7 ステップ 1 で `/root/` にも cp する patch

### 改善 14: post-reboot 前の internet 到達性 pre-flight check
- **問題**: pve-setup-remote.sh --phase post-reboot の中で apt-get update が default route 不在で DNS fail → exit 100 → LINSTOR install 全 skip
- **修正案**:
  - skill Phase 7 ステップ 4 の前に「`ssh ... ping -c1 -W3 deb.debian.org` で internet 到達確認、失敗時は `dhclient -1 -v <dhcp_iface>` で route 再取得」を pre-flight として明示
  - または pve-setup-remote.sh の冒頭に同等のチェック + 自動 dhclient 再実行を追加

Trial 4 server14: success (44min, attempt 1)
