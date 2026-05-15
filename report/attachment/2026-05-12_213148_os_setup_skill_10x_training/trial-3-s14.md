# Trial 3 / 10 — server14 (R430)
- 開始: 2026-05-12 06:44:42 JST
- 終了: 2026-05-12 08:02:45 JST
- 所要時間: 78m03s (実時間: 06:44:42 → 08:02:45)
- 結果: success
- install-monitor attempt 回数: 2 (1 回目は partman で "No root file system" stuck → racreset soft 経由でリトライ)
- 失敗時の原因: attempt 1 partman-auto-lvm が `No matching physical volumes found` の後で stage 5/9 に固着し、SOL TUI に「No root file system / Please correct this from the partitioning menu」dialog が表示されたまま 25 分以上進まなかった。preseed の `partman/confirm boolean true` でも先に進まない real failure。`racadm racreset soft` + bmc-mount-boot/install-monitor reset 後の attempt 2 は完走 (6.3min で PowerState=Off)

## 観測された新規問題 / skill 改善候補

### 1. install attempt 1 で partman-auto-lvm 初期化失敗 → racreset soft で復旧 (skill 通り)
- **症状**: installer-syslog (UDP 5514) は `22:03:23 partman: No matching physical volumes found` の直後で停止し、SOL は `No root file system / <Continue>` dialog が無限ループ
- **trial 1 / trial 2 との差**: trial 1/2 では同じ preseed + 同じ disk wipe で問題なく `partman-lvm: Volume group "vg0" successfully created` まで到達した。trial 3 attempt 1 は disk wipe (`for disk in /dev/sda; do sgdisk --zap-all`) は完走したものの、partman-auto-lvm が `vg0` を作れずに固着した。原因は再現性が低く、racreset soft で復旧する PERC/iDRAC の内部状態か (Round 2 s15 GRUB 無限ループと類似)
- **判定基準**: stage 5/9 で 20 分以上停滞 + installer-syslog の `partman:` が `No matching physical volumes found` の後で 10 分以上沈黙 + SOL に `<Continue>` dialog が継続表示 → false-positive ではなく真の partman 失敗。3 連続失敗を待たず即 racreset soft 推奨
- **復旧手順 (実証)**:
  1. `./pve-lock.sh wait ./oplog.sh ./scripts/bmc-power.sh forceoff <BMC_IP> claude Claude123`
  2. `./pve-lock.sh wait ./oplog.sh ssh -F ssh/config idrac<N> racadm racreset soft`
  3. iDRAC SSH 経由で `racadm getsysinfo` が応答するまで待機 (約 2-3 分)
  4. `os-setup-phase.sh reset bmc-mount-boot install-monitor post-install-config`
  5. VirtualMedia 再 mount + boot-once + Power On + sol-monitor 再実行
- **skill 改善案**: Phase 5 step 4 の「3 連続失敗で racreset soft」の閾値を「partman 段階で 20 分以上停滞 + installer-syslog で同種エラー再発」に変更。または「同じ failure 種類 (partman vs GRUB) が 2 回連続なら racreset」と段階化。Trial 1 では並列 agent 競合があったため真に「初回成功」は trial 2 のみ → R430 は **partman 初期化が不安定で 2-3 回に 1 回は失敗する hardware-class 問題** の可能性

### 2. sol-monitor.py が攻略不能 dialog をパッシブ監視のみで放置 (skill 既知)
- 25 分間 stage 5/9 観測のみで上位 stage に遷移せず PowerState=On のまま。skill 既知の「dialog 表示だけでは fail と判断しない」ガイド通りだが、25 分超えてから人間 (= 自分) が installer-syslog/KVM で判定する必要があった
- skill 改善案: sol-monitor.py に `--stage-stall-timeout <sec>` を追加し「同一 stage で N 秒以上滞留 → exit 5 (stage stall)」を出すと自動リカバリ判断が早くなる。現状は時間管理を呼出側がやる必要がある

### 3. Round 2 改善 6-9 の検証結果
| 改善 | 結果 |
|------|------|
| 改善 6: LINBIT GPG empty-file detect → 事前 keyring 配置 | ✓ trial 2 で取得した `tmp/<sid>/linbit-keyring-trial2.gpg` を再利用し、attempt 2 post-reboot で **wget fetch 不要 / DKMS GPG fail 不発** |
| 改善 7: `apt install build-essential` を `--linstor` 前に流す | ✓ pre-reboot 完了後・post-reboot 前に `apt-get install -y build-essential libc6-dev` を流したところ DKMS build 成功 (`drbd-dkms (9.3.2-1)` の Setting up が一発) |
| 改善 8: resetconfig 後の SCP Export job 完了待ち | ✓ poll script で `Export: Server Configuration Profile` Status=Running → Completed を確認してから createvd へ。LC062 不発 |
| 改善 9: `printf > /file` の "Command may have failed" は誤検知 | ✓ Phase 6 で `ip -brief addr > /tmp/iface.txt` 実行時に WARN 出たが redirect 自体成功 (SSH 後の動作で間接検証 OK) |

### 4. sol-login.py の "DETECTING" stage が boot 完了前に timeout する (再現)
- Phase 6 step 3 の最初の sol-login.py 実行で「DETECTING: sending Enter to probe」を 12 回繰り返して 180s で fail
- 原因: R430 + Debian 13 minimal の boot 時間が 5 分以上かかり、SSH 不到達期間中に sol-login.py が login prompt を見つけられなかった
- 対策: ssh-wait.sh が 5 分 timeout で fail した後、追加で 2-3 分待ってから sol-login.py を実行すると stage DETECTING → LOGIN_PROMPT へ即遷移 (今回の attempt 2 では 6 分後に成功)
- skill 改善案: Phase 6 step 3 で「最初の sol-login.py が DETECTING で timeout したら 120 秒待って再試行」を追記。または sol-login.py の DETECTING timeout default を 180s → 360s に延長

### 5. ssh-wait.sh が iDRAC SSH (claude user, key auth) に対応していない (Round 1.5 知見の再確認)
- `./scripts/ssh-wait.sh 10.10.10.34 ...` を iDRAC racreset 復旧確認で使ったが `root@10.10.10.34` を試して全 fail
- 直接 `ssh -F ssh/config idrac14 racadm getsysinfo` で確認可能だった
- skill 改善案: ssh-wait.sh に `--user <name>` flag を追加し iDRAC SSH も対応。または「iDRAC racreset 後の SSH 復旧確認は `ssh -F ssh/config idrac<N> racadm getsysinfo` を使う」を Phase 5 step 4 に明記

## 主要ログ
- tmp/c452be97/sol-install-trial3-s14-attempt1.log (failed attempt, stage 5/9 で stuck)
- tmp/c452be97/sol-install-trial3-s14-attempt2.log (success, full 7 stages)
- tmp/c452be97/installer-syslog-all.log (親管理、UTC 22:03/22:37 で server14 の partman ログ)
- tmp/c452be97/linbit-keyring-trial3.gpg (trial 2 から再利用)
- /home/ubuntu/.claude/projects/-home-ubuntu-projects-pvese/c452be97-0d9a-4a0f-aa04-7364fbbe1ee3/tool-results/b0s8r573s.txt (post-reboot 出力 178 KB)
- log/oplog.log (state-changing コマンド全件)

## 主要イベントタイムライン
- 06:44:42 — Trial 3 開始 (Phase A)
- 06:45:35 — jobqueue delete → resetconfig + pwrcycle 開始
- 06:50:19 — resetconfig + SCP Export 両完了 (改善 8 検証 OK)
- 06:50:35 — createvd Bay 1+6 → 06:55:55 Completed (Online, Bay 1+6, 278.88GB)
- 06:56:25 — state リセット + VirtualMedia umount/boot-reset + known_hosts 削除
- 06:57:00 — Phase 1-3 マーク (ISO 再利用 OK, preseed sha256 一致)
- 06:58:00 — Phase 4 bmc-mount-boot 完了 (mount + boot-once + cycle)
- 06:58:46 — Phase 5 attempt 1 install-monitor.start
- 07:01:08 — Stage 1/9 (LOADING_COMPONENTS, 2.2min)
- 07:03:24 — Stage 5/9 (CONFIGURING_APT/partman, 2.8min)
- 07:03–07:13 — Stage 5/9 で 10 分間滞留、SOL に `No root file system <Continue>` dialog
- 07:13:00 — 親 installer-syslog で server15 の `finish-install going down NOW` 観測 (server14 ではない別 sibling)
- 07:13:10 — sol-monitor 停止 (false positive 判定)
- 07:13:30 — KVM screenshot 黒画面、SOL poke で `<Continue>` dialog 確定 → attempt 1 真の失敗判定
- 07:26:43 — ForceOff → racadm racreset soft → iDRAC 再起動完了確認 (3 分)
- 07:33:00 — bmc-mount-boot reset + 再 mount + boot-once + Power On
- 07:34:25 — Phase 5 attempt 2 install-monitor.start
- 07:36:40 — Stage 1/9 (LOADING_COMPONENTS, 2.0min)
- 07:37:15 — Stage 5/9 (2.6min)
- 07:38:00 頃 — installer-syslog で `partman-lvm: Volume group "vg0" successfully created` 観測 → partman は今回正常通過
- 07:39:57 — Stage 6/9 (INSTALLING_SOFTWARE, 5.3min)
- 07:40:25 — Stage 7/9 (INSTALLING_GRUB, 5.8min)
- 07:41:11 — PowerState Off detected (6.3min)
- 07:41:45 — Installation completed successfully (sol-monitor exit 0)
- 07:47:00 頃 — Phase 6 step 1-2 (umount + boot-reset + Power On)
- 07:48:30 — sol-login.py で PermitRootLogin/PasswordAuthentication 有効化、sshd restart
- 07:49:30 頃 — pexpect password SSH で authorized_keys 配置 (90 bytes ed25519)
- 07:49:45 頃 — SSH key auth + machine-id 検証 OK (1778539112 > 1778538865)
- 07:50:00 頃 — Phase 7 開始 (pre-pve-setup → build-essential 事前 install → LINBIT keyring 事前配置)
- 07:50:43 — `apt-get install -y build-essential libc6-dev` 完了 (改善 7 検証)
- 07:50:50 — LINBIT keyring `/usr/share/keyrings/linbit-keyring.gpg` 配置 (1164 bytes、改善 6 検証)
- 07:51:00 頃 — pve-setup-remote.sh --phase pre-reboot 実行 (PVE repo 追加 + kernel install)
- 07:54:00 頃 — reboot → ssh-wait 70s で復活
- 07:55:00 頃 — pre-pve-setup 再実行 (default route fix)
- 07:55:30 頃 — pve-setup-remote.sh --phase post-reboot --linstor 実行
- 07:57:00 頃 — linstor-satellite + drbd-dkms install Success (改善 6+7 で fail なし)
- 07:58:30 頃 — final reboot → ssh-wait 50s で復活
- 08:01:00 頃 — pve-bridge-setup.sh で vmbr0/vmbr1 構築
- 08:02:00 頃 — Web UI HTTP 200 確認
- 08:02:45 — Trial 3 終了

## 検証結果
- pveversion: `pve-manager/9.1.9/ee7bad0a3d1546c9 (running kernel: 7.0.2-2-pve)`
- vmbr0: `10.10.10.214/8` (UP)
- vmbr1: `192.168.39.162/24` (UP, DHCP)
- default route: `via 192.168.39.1 dev vmbr1`
- Web UI: `https://10.10.10.214:8006` → HTTP 200
- VD0: Online (RAID-1, Bay 1+6, 278.88GB, OS_RAID1)
- DRBD: drbd-dkms 9.3.2-1 installed
- LINSTOR satellite: enabled
- インターネット到達性: deb.debian.org → ping OK

## ./scripts/os-setup-phase.sh times --config config/server14.yml

```
iso-download             0m20s
preseed-generate         0m11s
iso-remaster             0m13s
bmc-mount-boot           0m53s
install-monitor          7m34s
post-install-config      7m21s
pve-install              12m17s
cleanup                  0m36s
---
total                    29m25s
```

(skill 内部 phase 計測の合計 29m25s と実時間 78m03s の差 48m38s は、attempt 1 partman 失敗で消費した 30 分 (06:58 install start → 07:27 racreset 開始 → 07:34 attempt 2 開始) + racreset 復旧待ち 4 分 + Phase 6 boot 待ち 5 分等で発生)

## Trial 1 / Trial 2 / Trial 3 比較
| 観測項目 | Trial 1 | Trial 2 | Trial 3 |
|---------|---------|---------|---------|
| install-monitor (時間) | 7m37s | 7m21s | 7m34s |
| install attempt 回数 | 1 | 1 | **2** |
| attempt 1 failure | なし | なし | partman-auto-lvm 固着 (stage 5/9 で 25min stuck) |
| 全体所要時間 | 47m17s | 53m08s | **78m03s** |
| 競合の有無 | 並列 agent dpkg 競合 | 無 (単独実行) | 無 (単独実行、s15 sibling と installer-syslog 共有のみ) |
| Round 2 改善検証 (#6 LINBIT keyring) | 該当無し | ✓ 手動 fallback | ✓ 事前配置で fall back 不要 |
| Round 2 改善検証 (#7 build-essential) | 該当無し | ✓ 手動 install | ✓ 事前 install で DKMS 一発成功 |
| Round 2 改善検証 (#8 SCP Export 待ち) | 該当無し | 観測ガード OK | ✓ poll script で明示確認 |
| Round 2 改善検証 (#9 printf > /file WARN) | 該当無し | 該当無し | ✓ 誤検知確認 |
| 新発見の skill 改善点 | rm -rf state ブロック / SerialComm Auto 互換 | LINBIT GPG fallback / build-essential | **partman stuck の判定基準 + racreset soft の早期発動 / ssh-wait.sh iDRAC SSH 非対応** |

## Round 2 改善 6-9 適用効果まとめ
Trial 2 で踏んだ全ての post-reboot トラブル (LINBIT GPG 404 → empty file / build-essential 不在 → DRBD DKMS fail / printf > /file の誤検知 WARN / SCP Export job 競合) を **事前に回避**できた:
- Trial 2 では post-reboot 内部で 2 度のリカバリ作業 (keyring 手動取得 + build-essential 手動 install) で 7 分以上を消費したが、Trial 3 では **改善 6-9 を skill 通りに適用したことで post-reboot 自体が一発で完走**
- 結果として Phase 7 内部時間は Trial 2 14m05s → Trial 3 12m17s に短縮 (約 2 分短縮)
- 一方で Trial 3 は attempt 1 partman 失敗で wall time が増加 → **Round 2 改善は post-reboot 部分には十分機能するが、install-monitor 段階の partman 不安定性 (R430 + PERC) を解決する別軸の改善が必要**

Trial 3 server14: success (78min, attempt 2)
