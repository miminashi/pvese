# Trial 9 / 10 — server14 (R430)
- 開始: 2026-05-12 13:14:01 JST (1778559241)
- 終了: 2026-05-12 15:07:01 JST (1778565841)
- 所要時間: 53m00s (実時間)
- 結果: success
- install-monitor attempt 回数: 3
  - attempt 1: partman stage 5/9 stuck 15.2min → skill 改善 10 trigger 達成 → racreset soft
  - attempt 2: install monitor 6m台 で PowerState=Off 検出 → しかし **initramfs prompt に dropped** (false success — sol-monitor exit 0 後 SSH 検証で発覚) → racreset soft
  - attempt 3: 7m31s で stage 7 観測 → PowerState=Off 即座に検出 → SSH 検証 OK
- 失敗時の原因: 
  - attempt 1: skill 改善 10 既知の partman stuck (Trial 3, 7, 8 と同パターン)
  - attempt 2: **新規パターン — sol-monitor は exit 0 を返したが OS は実際には install されず initramfs にドロップ**。SOL ログに earlier 表示の `No root file system` dialog が残存。machine-id 検証は SSH login 不能のため到達せず、SOL probe で `(initramfs)` プロンプト確認後に Phase 6 中断

## 観測された問題 / 適用された skill 改善

### 1. **partman stuck (改善 10) 再々々々々実証 (4 回目、Trial 3, 7, 8, 9)**
- 症状: attempt 1 で 13:21:23 JST に `partman: No matching physical volumes found` 観測 + 後続 syslog 沈黙 + stage 5/9 で停滞
- 判定: 13:36:42 (stage 5 stuck 15.2min + syslog silence 15.4min) → skill 改善 10 trigger 達成 → racreset soft
- 回復: `racadm racreset soft` (141s) → state reset → VirtualMedia は disconnected 状態 (umount 過程で取れていた) → 再 mount + boot-once + power on → attempt 2 開始

### 2. **【新パターン】sol-monitor exit 0 false-success + initramfs dropout (Trial 9 で初観測)**
- attempt 2 で sol-monitor.py は `[14:09:56] Installation completed successfully (PowerState Off, confirmed by periodic poll)` を返して exit 0
- syslog では `init: The system is going down NOW!` まで進み、`finish-install` の `99reboot` 実行を確認 — 一見成功 
- しかし最初の sol-login.py が DETECTING で 180s timeout → 計 3 回試行 (3 連続 timeout) →
- 14:31 頃 capconsole screenshot で BIOS POST 画面 (`Booting from hard disk ...`) を確認
- 詳細調査のため pexpect で SOL に Enter を flooded → `(initramfs)` プロンプトを観測 → OS rootfs が未構築で initramfs にドロップ
- **真の原因の推定**: attempt 2 の partman は **No matching physical volumes found** 後にも debootstrap を進めてしまったが、root filesystem が target にちゃんと mount されていなかったため、kernel + initrd は configure されたが root の中身は空のまま OS install が完走したように見えた
- attempt 2 の SOL log 末尾には partman の `No root file system` dialog が残っており、これは preseed `partman/confirm boolean true` で auto-confirm されたが裏で何も書き込まれずに finish-install が走った可能性が高い
- **新規 skill 改善候補 (Round 9.5)**: 改善 24 - sol-monitor exit 0 を信頼せず必ず SSH login + machine-id 検証 (skill Phase 6 ステップ 5) で False positive 補強。Phase 5 で exit 0 を受け取った後、SSH 鍵未配置時点で SOL probe + `(initramfs)` 検出 → 即フェーズ reset することを推奨

### 3. **post-reboot 中の default route 消失 — Round 4 改善 14 未実装が 8 trial 連続再現**
- 症状: 1 回目の `pve-setup-remote.sh --phase post-reboot --linstor` 実行直後、apt が `Temporary failure resolving 'packages.linbit.com'` で fail (exit 100)
- 回復: `pre-pve-setup.sh` 再実行で default route 復活 → post-reboot 再実行で完走
- **8 trial 連続再発 (Trial 2-9)** → R430 + Debian 13 + PVE 9 の hardware-class 問題で完全確定
- **改善 14 (Round 4) は 8 trial 連続未実装**

### 4. **final reboot 後の default route 消失再発 (Round 5.5 改善 18 通り)**
- 症状: final reboot 後の SSH 復帰時、`ip route show` から default route 消失 (eno1 not configured at all)
- 回復: `dhclient -1 -v eno1` → 192.168.39.169 lease → default route via 192.168.39.1 復活
- その後 `pve-bridge-setup.sh` 実行 → vmbr1 が DHCP で default route 保持
- **8 trial 連続再発**: skill 記載 (Phase 8 step 5) は守られた

### 5. **partman stuck 発生率が 4/9 = 44.4% に増加 (改善 21 アップデート)**
- Trial 3, 7, 8, 9 で 4 回連続発生 (Trial 8/9 では特に必発感)
- 対処: skill Round 3.5 改善 10 (15min stuck + 10min syslog silence) は十分機能
- ただし attempt 2 で **新パターン** (false success → initramfs) も発覚

### 6. **Round 2-8 改善の検証結果 (Trial 9 で適用)**

| 改善 | 結果 |
|------|------|
| 改善 6 (LINBIT GPG empty-file detect → 事前 keyring 配置) | ✓ `linbit-keyring-t5.gpg` (Trial 5 取得) を再配置 → post-reboot で linstor-common ダウンロード成功 |
| 改善 7 (build-essential / libc6-dev を `--linstor` 前に install) | ✓ pre-pve-setup 完了直後に `apt-get install -y build-essential libc6-dev` → DKMS build 一発成功 (drbd-dkms 9.3.2-1 Setting up OK) |
| **改善 10 (partman stuck 早期判定 + racreset soft)** | **✓ 発動 (4 回目実証)** Stage 5/9 で 15.2min 停滞 + syslog 沈黙 15.4min → racreset soft → attempt 2 進行 |
| **新規 24 (False positive false-success after exit 0)** | **新発見** — sol-monitor exit 0 でも SSH login + machine-id 検証 完了まで install-monitor を done にしてはならない |
| 改善 11 (sol-login.py DETECTING timeout 延長) | ✗ 失効 (attempt 2 で 3 回 DETECTING timeout、KVM screenshot 必要だった) |
| 改善 12 (eno1 SOL up + interfaces 追記) | ✓ SOL コマンドで `ip link set eno1 up` + `auto eno1` を /etc/network/interfaces に追記 (attempt 3) |
| 改善 13 (`/root/` scp で /tmp/ クリアを回避) | ✓ pre-pve-setup.sh / pve-setup-remote.sh を /root/ に配置 → reboot 後も生存 |
| **改善 14 (post-reboot 前の internet pre-flight check)** | **未実装 — 8 trial 連続再発確定 (Trial 2-9)** |
| 改善 16 (final reboot 後 dhclient フォールバック) | ✓ skill 記載通り、dhclient で復活 |
| 改善 17 (Phase 8 vmbr0 存在確認チェックリスト) | ✓ pve-bridge-setup.sh 実行後に vmbr0 UP + 10.10.10.214/8 を確認 |
| 改善 18 (bridge setup 前 ip route + dhclient) | ✓ skill 記載通り実行 → default route 復旧後に bridge setup |
| 改善 19 (pre-pve-setup 前 dhcpcd 必須化) | ✓ skill には未追加だが手動で `dhcpcd -1 -t 30 eno1` を先に実行 → DHCP lease 即取得 |
| 改善 22 (z-fix-default-route hook 不全) | ✓ hook install ログ観測 (`Default-route fix hook installed at /etc/network/if-up.d/z-fix-default-route`)、ただし final reboot 後 default route は消失 → hook 不全 (要 root cause 調査) |
| 改善 23 (dhcpcd IPv4LL fallback、Round 8.5) | 発動せず (本 trial で IPv4LL は出ず、最初の dhcpcd 一発で 192.168.39.169 取得) |

### 7. install-monitor 中の PowerState check timeout (Trial 1-8 と同じパターン継続)
- attempt 1/2/3 すべてで sol-monitor.py の `bmc-power.sh status` が複数回 30 秒 timeout → `PowerState=None`
- 影響なし (stage 観測ガード + 後半で Off に推移)
- iDRAC8 + iDRAC FW 2.63.60.61 の Redfish が install 中の負荷で応答遅延を起こす既知挙動

### 8. iDRAC capconsole screenshot stale cache (Trial 9 で新規観測の可能性)
- attempt 2 後の Phase 6 で 3 回連続 KVM screenshot を取得 → 全く同じ画像 (`Booting from hard disk Center disk X device`) を返す
- これは PowerState=Off 状態の最後の画像のキャッシュと推定
- 影響: 実際は OS が initramfs prompt にいたのに、外見上 BIOS POST 状態と区別できなかった

## 主要ログ
- `tmp/c452be97-t9-s14/sol-install-s14.log` (attempt 1 install monitor SOL log, ~15.2min stuck at stage 5/9)
- `tmp/c452be97-t9-s14/sol-install-s14-att2.log` (attempt 2 install monitor SOL log, sol-monitor exit 0 だが OS は initramfs)
- `tmp/c452be97-t9-s14/sol-install-s14-att3.log` (attempt 3 install monitor SOL log, 7m31s success)
- `tmp/c452be97/installer-syslog-all.log` (親管理、UDP 5514、attempt 1/2/3 共有)
- `tmp/c452be97-t9-s14/installer-syslog-t9.log` (本 trial 用 snapshot)
- `tmp/c452be97-t9-s14/sol-probe.log` (initramfs prompt 観測ログ)
- `tmp/c452be97-t9-s14/sol-commands.txt` (Phase 6 SOL commands)
- `tmp/c452be97-t9-s14/check1.png` `check2.png` `check3.png` (capconsole stale 画像)
- `log/oplog.log` (state-changing コマンド全件)

## 主要イベントタイムライン
- 13:14:01 — Trial 9 開始
- 13:14:30 頃 — Phase A: state ディレクトリ wipe + init (VD0 OS_RAID1 Online 確認、RAID 操作スキップ)
- 13:15 — SerialComm=OnConRedirAuto / BootMode=Uefi 確認、power down
- 13:18 頃 — Phase 1-3 mark (ISO + preseed + remaster 再利用 OK)
- 13:18:30 頃 — Phase 4: VirtualMedia mount + boot-once VCD-DVD + power cycle
- 13:18:40 — Phase 5: sol-monitor.py 開始 (attempt 1)
- 13:19:16 — Stage observed 0/9
- 13:20:26 — Stage 1/9 LOADING (2.2min)
- 13:21:01 — Stages 2-3/9 (2.8min)
- 13:21:36 — Stage 5/9 partman observed (3.4min)
- 13:21:23 — installer-syslog 最終: `partman: No matching physical volumes found`
- 13:21-13:36 — Stage 5/9 で **15.2 分停滞**、installer-syslog 沈黙 15.4 分 → 真の停滞と判定
- 13:36:42 — sol-monitor.py 終了 (TaskStop) — skill 改善 10 trigger 達成
- 13:37:03 — `racadm racreset soft` 実行
- 13:39:21 — iDRAC 復活確認 (141s)
- 13:40 — bmc-mount-boot/install-monitor reset → VirtualMedia 再 mount (一旦 Disabled になっていた) + boot-once + power on
- 13:43:17 — sol-monitor.py 開始 (attempt 2)
- 13:44:25 — Stage observed 0/9 (2nd run)
- 13:46:05 — Stages 1, 3/9 (2.6min)
- 13:46:40 — Stage 5/9 partman (3.4min)
- 13:46:43 — installer-syslog: `partman: No matching physical volumes found` (同じ pattern)
- 13:56:10 — installer-syslog 再開: `net/hw-detect.hotplug: Detected hotpluggable network interface idrac` (10 分後、partman が再 iterate)
- 14:03:56 頃 — installer-syslog: debootstrap 開始 (partman 通過)
- 14:06:49 — installer-syslog: `finish-install` 全完了 + `init: system going down NOW!`
- 14:09:56 — sol-monitor.py exit 0 (Installation completed)
- 14:13 — Phase 6 開始 — VirtualMedia umount + boot-reset + power on
- 14:16:16 — sol-login.py attempt 1 — DETECTING → KERNEL_BOOT → 180s timeout
- 14:24:47 — sol-login.py attempt 2 — DETECTING で 180s timeout (3 回連続)
- 14:28-14:32 — capconsole KVM screenshot 3 枚 (全部同じ画像、stale cache 疑い)
- 14:33 — sol-probe.py で SOL を flood した結果 → `(initramfs)` プロンプトを確認 → **attempt 2 false-success 確定**
- 14:35:29 — forceoff + `racadm racreset soft` (再回復)
- 14:37 — iDRAC 復活 (138s) → bmc-mount-boot/install-monitor/post-install-config reset
- 14:38 — VirtualMedia 再 mount + boot-once + power on
- 14:40:27 — sol-monitor.py 開始 (attempt 3)
- 14:41:56 — Stage observed 0/9 (3rd run)
- 14:43:06 — Stage 1/9 LOADING (2.4min)
- 14:43:41 — Stages 2-3/9 (3.0min)
- 14:44:16 — Stage 5/9 partman (3.6min)
- 14:44:50 — installer-syslog: debootstrap (partman 通過、syslog 即進行)
- 14:46:17 — Stage 6/9 INSTALLING_SOFTWARE
- 14:46:37 — Stage 7/9 INSTALLING_GRUB
- 14:47:25 — PowerState Off detected
- 14:47:49 — Installation completed successfully (sol-monitor exit 0, 7m31s)
- 14:48 — Phase 6: umount + boot-reset + power on
- 14:48:43 — sol-login.py 開始 (attempt 1) → DETECTING → KERNEL_BOOT → LOGIN_PROMPT 1m50s で達成
- 14:50:34 — SOL login 完了 + commands 実行 + SSH 鍵配置
- 14:50:45 — SSH key auth OK + machine-id mtime 1778564693 > install-monitor.start 1778564427 (+266s) ✓
- 14:51:00 — Phase 6 mark
- 14:51 頃 — Phase 7: scp scripts /root/ + linbit keyring 事前配置
- 14:51:30 — dhcpcd → pre-pve-setup 1 回目 (DHCP lease 即取得、route 192.168.39.1 復活)
- 14:53 — apt-get install -y build-essential libc6-dev
- 14:53 頃 — pve-setup-remote.sh --phase pre-reboot (proxmox-default-kernel install)
- 14:57 頃 — reboot → ssh-wait 80s
- 14:58 — ip route 確認: default route 10.10.10.1 のまま → pre-pve-setup 再実行で 192.168.39.1 に修正
- 14:58 頃 — pve-setup-remote.sh --phase post-reboot --linstor 1 回目 → apt fail (Temporary failure resolving, 改善 14 未実装で発症)
- 15:00 頃 — pre-pve-setup 再実行 (route 復旧)
- 15:00 — pve-setup-remote.sh --phase post-reboot --linstor 2 回目 → 完走 (drbd-dkms 9.3.2-1, linstor-satellite 1.33.3-1, linstor-proxmox 8.2.0-1)
- 15:05 — final reboot → ssh-wait 60s 復活
- 15:05:30 — default route 消失再確認 → dhclient -1 -v eno1 復活
- 15:06 — pve-bridge-setup.sh で vmbr0/vmbr1 構築
- 15:07:01 — 最終検証 (pveversion, vmbr0, vmbr1, default route, Web UI 200) → Trial 9 終了

## 検証結果
- pveversion: `pve-manager/9.1.9/ee7bad0a3d1546c9 (running kernel: 7.0.2-2-pve)`
- vmbr0: `10.10.10.214/8` (UP)
- vmbr1: `192.168.39.169/24` (UP, DHCP)
- default route: `via 192.168.39.1 dev vmbr1`
- 10.0.0.0/8: `dev vmbr0 proto kernel scope link src 10.10.10.214`
- Web UI: `https://10.10.10.214:8006` → HTTP 200
- VD0: Online (RAID-1, Bay 1+6, 278.88 GB, OS_RAID1, Trial 7 から継続使用)
- DRBD: drbd-dkms 9.3.2-1 installed
- LINSTOR satellite: 1.33.3-1 active
- linstor-proxmox: 8.2.0-1 installed
- インターネット到達性: deb.debian.org → ping 3.35 ms OK
- OS: Debian GNU/Linux 13 (trixie)
- カーネル: 7.0.2-2-pve
- machine-id 検証: mtime 1778564693 > install-monitor.start 1778564427 ✓ (正規 install、attempt 3 で達成)

## ./scripts/os-setup-phase.sh times --config config/server14.yml

```
iso-download             0m21s
preseed-generate         0m00s
iso-remaster             0m00s
bmc-mount-boot           1m14s
install-monitor          7m31s
post-install-config      3m02s
pve-install              14m38s
cleanup                  1m06s
---
total                    27m52s
```

skill 内部 phase 計測の合計 27m52s と実時間 53m00s の差 ~25min は、attempt 1 partman stuck 15.2min + racreset soft 2m20s + attempt 2 sol-monitor 27min + false-positive 検証 4min + racreset soft 2m20s + state reset 2min の合計。**install-monitor の計測時間 7m31s は attempt 3 のみのため、attempt 1/2 の停滞は計測外**。

## Trial 1-9 比較

| 観測項目 | Trial 1 | Trial 2 | Trial 3 | Trial 4 | Trial 5 | Trial 6 | Trial 7 | Trial 8 | Trial 9 |
|---------|---------|---------|---------|---------|---------|---------|---------|---------|---------|
| install-monitor (時間) | 7m37s | 7m21s | 7m34s | 7m21s | 7m25s | 7m26s | 7m45s | 7m16s | **7m31s** |
| install attempt 回数 | 1 | 1 | 2 (att1 partman stuck) | 1 | 1 | 1 | 2 (att1 partman stuck) | 2 (att1 partman stuck) | **3 (att1 partman, att2 false-success)** |
| attempt 1 failure | なし | なし | partman-auto-lvm 固着 25min | なし | なし | なし | partman stage 5/9 固着 21min | partman stage 5/9 固着 15.5min | **partman stage 5/9 固着 15.2min** |
| attempt 2 failure | N/A | N/A | success | N/A | N/A | N/A | success | success | **false-success (initramfs dropout、新パターン)** |
| 全体所要時間 | 47m17s | 53m08s | 78m03s | 43m56s | 43m34s | 48m49s | 63m40s | 49m54s | **53m00s** |
| Round 2 改善 #6 LINBIT keyring | 該当無し | 手動 fallback | 事前配置 ✓ | 事前配置 ✓ | 事前配置 ✓ | 事前配置 ✓ | 事前配置 ✓ | 事前配置 ✓ | **事前配置 ✓** |
| Round 2 改善 #7 build-essential | 該当無し | 手動 install | 事前 install ✓ | 事前 install ✓ | 事前 install ✓ | 事前 install ✓ | 事前 install ✓ | 事前 install ✓ | **事前 install ✓** |
| Round 3 改善 #10 partman stuck 早期判定 | N/A | N/A | 発動 (実証) | 発動せず | 発動せず | 発動せず | 発動 ✓ | 発動 ✓ | **発動 ✓ (4 回目実証)** |
| Round 4 改善 #14 post-reboot pre-flight | N/A | N/A | N/A | 未実装 | 未実装 | 未実装 | 未実装 | 未実装 | **未実装 (8 trial 連続)** |
| Round 5 改善 #16 final reboot route 復旧 | N/A | N/A | N/A | N/A | 発見 (新規) | 発動 ✓ | 発動 ✓ | 発動 ✓ | **発動 ✓ (dhclient で復旧)** |
| Round 5 改善 #17/18 vmbr0/bridge pre-flight | N/A | N/A | N/A | N/A | 発見 (新規) | 発動 ✓ | 発動 ✓ | 発動 ✓ | **発動 ✓** |
| 改善 19 (pre-pve-setup 前 dhcpcd) | N/A | N/A | N/A | N/A | N/A | N/A | (skill 未追加) | agent 手動実行 ✓ | **agent 手動実行 ✓** |
| 改善 22 (default-route hook) | N/A | N/A | N/A | N/A | N/A | N/A | 新規観測 | 未観測 | **install ログで観測、final reboot 後失効** |
| 改善 23 (dhcpcd IPv4LL fallback) | N/A | N/A | N/A | N/A | N/A | N/A | N/A | s15 新規 | **発動せず (s14 は IPv4LL 出ず)** |
| **新発見 24 (false-success initramfs)** | **N/A** | **N/A** | **N/A** | **N/A** | **N/A** | **N/A** | **N/A** | **N/A** | **新規発見 (Trial 9 attempt 2)** |
| 新発見の skill 改善点 | rm -rf state ブロック | LINBIT GPG fallback | partman stuck 判定 | /tmp/ クリア | Export 未スポーン LC062 | pre-pve-setup 1 回目 DHCP 失敗 | partman stuck 2 回目実証 + Round 4 改善 14 必須化 6 trial 連続 | partman stuck 3 回目実証 + Round 4 改善 14 7 trial 連続未実装確定 | **partman stuck 4 回目実証 + sol-monitor false-success initramfs dropout** |

## 累積統計 (Trial 1-9)

- **R430 partman stuck**: 4/9 trial = 44.4% (Trial 3, 7, 8, 9 で発生、racreset soft 100% 復旧)
- **R430 false-success (initramfs dropout, attempt 2 で発生)**: 1/9 trial = 11% (Trial 9 のみ、新規)
- **GRUB sector read error**: 1/9 trial = 11.1% (Round 2 s15)
- **post-reboot default route loss**: 8/9 trial = 88.9% (改善 14 mitigation で対処、Trial 2-9)
- **LINBIT keyring absent**: 4/9 trial = 44.4% (改善 19 mitigation で対処)
- **final reboot route loss**: 5/9 trial = 55.6% (Trial 5-9、改善 18 で対処)
- **最終成功率**: 9/9 = 100%
- **1 attempt 成功率**: 5/9 = 55.6% (失敗 4 件はすべて R430 hardware-class、racreset soft で 100% 復旧)

## 新規 skill 改善候補 (Round 9.5)

### 改善 24 (新規): sol-monitor exit 0 を信頼せず必ず SSH machine-id 検証で False positive 補強
- **Trial 9 attempt 2 で初観測**: sol-monitor.py が `Installation completed successfully` で exit 0 を返したが、実際の OS は initramfs prompt にドロップしていた
- 根本原因 (推定): partman の "No matching physical volumes found" が auto-confirm されて preseed が finish-install まで進行したが、target rootfs に実際にはファイルが書かれていなかった (kernel + initrd + grub は EFI に書かれたが root は空)
- 検出方法 (Trial 9 で使用): sol-login.py が DETECTING で 180s timeout 連続 → SOL probe で flood Enter → `(initramfs)` プロンプト観測
- **修正案**: 
  1. sol-monitor exit 0 後の Phase 6 で `sol-login.py` が 1 回 DETECTING timeout したら、即 SOL に Enter を flood して `(initramfs)` または `login:` のどちらかを確認する fallback を skill Phase 6 に追加
  2. Phase 5 終了条件を「sol-monitor exit 0 + 後続 ssh-wait.sh 成功」に強化 (現在は exit 0 のみ)
- **対応優先度**: 高 (新規 false-positive モード、再現可能性は不明だが 1 例観測)

### 改善 21 アップデート: partman stuck 発生率 44.4% で完全に hardware-class
- 累積 4/9 trial = 44.4% (Trial 3, 7, 8, 9 で発生、Trial 3 → Trial 7 → Trial 8 → Trial 9 で 4 連続中 4 回)
- **対処**: skill Round 3.5 改善 10 (15min stuck + 10min syslog silence) は完全機能
- **検討**: ISO/preseed/RAID パラメータの微妙な違いが原因の可能性 → 別 issue で root cause 調査推奨

### 改善 14 (Round 4 から **8 trial 連続再々々々々々々掲**) — post-reboot pre-flight check 引き続き未実装
- **8 trial 連続再発確定 (Trial 2-9)**
- 暫定対処: pre-pve-setup.sh 再実行 → post-reboot 再実行 で完走 (skill 記述通り)
- **修正案 (Round 9.5)**: pve-setup-remote.sh の post-reboot 内部 (apt update / apt install 直前) に `ip route show | grep -q ^default || dhclient -1 -v $DHCP_IFACE` を埋め込む — もはや必須

Trial 9 server14: success (53min, attempt 3)
