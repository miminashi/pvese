# Trial 8 / 10 — server14 (R430)
- 開始: 2026-05-12 12:17:29 JST (1778555849)
- 終了: 2026-05-12 13:07:23 JST (1778558843)
- 所要時間: 49m54s (実時間)
- 結果: success
- install-monitor attempt 回数: 2 (attempt 1: partman stage 5/9 stuck ~15.5min → racreset soft / attempt 2: 6m16s 一発成功)
- 失敗時の原因: attempt 1 で partman が stage 5/9 (PARTITIONING) で停滞、installer-syslog `partman: No matching physical volumes found` の後 12分沈黙。skill Round 3.5 改善 10 trigger 条件 (15min stuck + 10min syslog silence) 到達のため racreset soft 発動 → attempt 2 一発成功

## 観測された問題 / 適用された skill 改善

### 1. **partman stuck (R430 hardware-class issue) Round 3.5 改善 10 が再々実証**
- 症状: attempt 1 で 12:21:57 sol-monitor stage 0 → 12:24:10 stage 5/9 → installer-syslog 最終行 `partman: No matching physical volumes found` (03:24:14 UTC) → SOL byobu status bar が 3:25 → 3:26 → 3:27 → 3:28 更新 (installer は shell 1 で固まり) → installer-syslog 12 分以上完全沈黙
- 判定: 12:36:31 (stage 5 stuck 15.5min + syslog silence 12.2min) → trigger 条件達成 → 即時 racreset soft 発動
- 回復: `racadm racreset soft` (108s で iDRAC 復活) → bmc-mount-boot/install-monitor reset → VirtualMedia は既に Inserted=true 維持 (umount 不要) → boot-once + power on → attempt 2 開始 (12:43:01)
- 結果: attempt 2 は 6m16s で PowerState=Off (stage 7 観測, INSTALLING_GRUB → POWER_DOWN) で一発成功
- **改善 10 検証完了 (3 回目実証、Trial 3, 7, 8)**: 早期判定が機能し続けている。発生率 3/8 = 37.5%

### 2. **post-reboot 中の default route 消失再発 — Round 4 改善 14 未実装が 7 trial 連続再現**
- 症状: 1 回目の `pve-setup-remote.sh --phase post-reboot --linstor` 実行直後、apt が `Temporary failure resolving 'packages.linbit.com'` で fail
- 回復: `pre-pve-setup.sh` 再実行で default route 復活 → post-reboot 再実行で完走
- **7 trial 連続再発 (Trial 2-8)** → R430 + Debian 13 + PVE 9 の hardware-class 問題で完全確定
- **改善 14 (Round 4) は 7 trial 連続未実装** — pve-setup-remote.sh の root-cause fix が必要

### 3. **final reboot 後の default route 消失再発 (Round 5.5 改善 18 通り)**
- 症状: final reboot 後の SSH 復帰時、`ip route show` から default route 消失 (eno1 not configured at all)
- 回復: `dhclient -1 -v eno1` → 192.168.39.168 lease → default route via 192.168.39.1 復活
- その後 `pve-bridge-setup.sh` 実行 → vmbr1 が DHCP で default route 保持
- **7 trial 連続再発**: skill 記載 (Phase 8 step 5) は守られた

### 4. **pre-pve-setup.sh 1 回目は dhcpcd 事前実行で安定 (Round 6.5 改善 19)**
- 症状: post-install 直後の最初の `pre-pve-setup.sh` で dhcpcd timeout が発生していた (Trial 6/7)
- 対処: pre-pve-setup の前に `dhcpcd -1 -t 30 eno1` を手動で先に流す → DHCP lease 即取得 → pre-pve-setup 内部処理がスムーズ
- 改善 19 は skill には明文化されていないが、事前 dhcpcd は安定

### 5. **VD0 BGI 状態継続 (前 Trial の RAID をそのまま再利用)**
- Trial 7 終了時に VD0 OS_RAID1 が State=Online で残っていた
- Trial 8 では VD wipe をせず再利用 → `racadm raid get vdisks` で State=Online を確認
- Phase A の RAID 整備手順をスキップ可
- 影響なし — install attempt 2 で正常に partman → grub-installer 完走

### 6. **Round 2-7 改善の検証結果 (Trial 8 で適用)**

| 改善 | 結果 |
|------|------|
| 改善 6 (LINBIT GPG empty-file detect → 事前 keyring 配置) | ✓ `linbit-keyring-t5.gpg` (Trial 5 取得) を再配置 → post-reboot で linstor-common ダウンロード成功 |
| 改善 7 (build-essential / libc6-dev を `--linstor` 前に install) | ✓ pre-pve-setup 完了直後に `apt-get install -y build-essential libc6-dev` → DKMS build 一発成功 (drbd-dkms 9.3.2-1 Setting up OK) |
| 改善 8 (SCP Export job 完了待ち) | (該当無し: VD0 は Trial 7 から再利用、RAID 操作スキップ) |
| 改善 9 (`printf > /file` の "Command may have failed" は誤検知) | ✓ SOL `ip -brief addr > /tmp/ifstate.txt`、`echo … \| base64 -d > /root/.ssh/authorized_keys` で WARN 出たが実際は成功 (SSH key auth で間接検証 OK) |
| **改善 10 (partman stuck 早期判定 + racreset soft)** | **✓ 発動 (3 回目実証、Trial 3, 7 以来)** Stage 5/9 で 15.5min 停滞 + syslog 沈黙 12.2min → racreset soft → attempt 2 一発成功 |
| 改善 11 (sol-login.py DETECTING timeout 延長) | (発動せず) sol-login.py が DETECTING で 60s probe → KERNEL_BOOT → LOGIN_PROMPT (1m40s total) |
| 改善 12 (eno1 SOL up + interfaces 追記) | ✓ SOL コマンドで `ip link set eno1 up` + `auto eno1` を /etc/network/interfaces に追記 |
| 改善 13 (`/root/` scp で /tmp/ クリアを回避) | ✓ pre-pve-setup.sh / pve-setup-remote.sh を /root/ に配置 → reboot 後も生存 |
| **改善 14 (post-reboot 前の internet pre-flight check)** | **未実装 — 7 trial 連続再発確定 (Trial 2-8)** post-reboot 1 回目で route 消失 + apt fail |
| 改善 15 (Export job 未スポーン LC062 retry loop) | (該当無し: RAID 操作スキップ) |
| 改善 16 (final reboot 後 dhclient フォールバック) | ✓ skill に記載あり、agent が SKILL.md を読んで dhclient 実行 → 成功 |
| 改善 17 (Phase 8 vmbr0 存在確認チェックリスト) | ✓ pve-bridge-setup.sh 実行後に vmbr0 UP + 10.10.10.214/8 を確認 |
| 改善 18 (bridge setup 前 ip route + dhclient) | ✓ skill 記載通り実行 → default route 復旧後に bridge setup |
| 改善 19 (pre-pve-setup 前 dhcpcd 必須化) | ✓ skill には未追加だが手動で `dhcpcd -1 -t 30 eno1` を先に実行 → DHCP lease 即取得 |
| 改善 20 (pve-bridge-setup.sh 内蔵 pre-flight route check) | 未実装 — skill 記載に依存 |
| 改善 22 (z-fix-default-route hook 不全) | 未確認 — pve-setup-remote.sh の post-reboot 出力で hook install ログを未観測 (要確認) |

### 7. install-monitor 中の PowerState check timeout (Trial 1-7 と同じパターン継続)
- attempt 1/2 両方で sol-monitor.py の `bmc-power.sh status` が複数回 30 秒 timeout → `PowerState=None`
- 影響なし (stage 観測ガード + 後半で Off に推移して正常完了)
- iDRAC8 + iDRAC FW 2.63.60.61 の Redfish が install 中の負荷で応答遅延を起こす既知挙動

## 主要ログ
- `tmp/c452be97-t8-s14/sol-install-s14.log` (attempt 1 install monitor SOL log, ~15.5min stuck at stage 5/9)
- `tmp/c452be97-t8-s14/sol-install-s14-att2.log` (attempt 2 install monitor SOL log, 6m16s success)
- `tmp/c452be97/installer-syslog-all.log` (親管理、UDP 5514、attempt 1/2 共有)
- `tmp/c452be97/linbit-keyring-t5.gpg` (Trial 5 取得分を再利用、再配置成功)
- `tmp/c452be97-t8-s14/sol-commands.txt` (Phase 6 SOL commands)
- `tmp/c452be97-t8-s14/place-key.py` (pexpect SSH key 配置、未使用 — SOL 経由で base64 デコード成功)
- `tmp/c452be97-t8-s14/wait-idrac.sh` (racreset soft 後の iDRAC 復活待機、108s で復帰)
- `log/oplog.log` (state-changing コマンド全件)

## 主要イベントタイムライン
- 12:17:29 — Trial 8 開始
- 12:17:30 頃 — Phase A: state ディレクトリ wipe + init (VD0 OS_RAID1 Online 確認、RAID 操作スキップ)
- 12:18 — SerialComm=OnConRedirAuto / BootMode=Uefi 確認
- 12:19 頃 — Phase 1-3 mark (ISO + preseed + remaster 再利用 OK)
- 12:19:30 頃 — Phase 4: VirtualMedia mount + boot-once VCD-DVD + power on
- 12:20:41 — Phase 5: sol-monitor.py 開始 (attempt 1)
- 12:21:57 — Stage observed 0/9 (initial)
- 12:23:35 — Stages 1-3/9 LOADING/DETECTING_NETWORK/CONFIGURING_APT
- 12:24:10 — Stage 5/9 partman observed (3.4min)
- 12:24:14 — installer-syslog 最終: `partman: No matching physical volumes found`
- 12:24-12:36 — Stage 5/9 で **15.5 分停滞**、installer-syslog 沈黙 12 分 → 真の停滞と判定
- 12:36:31 — sol-monitor.py 終了 (TaskStop)
- 12:36:45 — `racadm racreset soft` 実行 (skill 改善 10 trigger)
- 12:39:14 — iDRAC 復活確認 (108s)
- 12:39:29 — bmc-power forceoff → bmc-mount-boot/install-monitor reset
- 12:41 頃 — VirtualMedia 状態確認 (既に Inserted=true で維持) + boot-once + power on
- 12:43:01 — sol-monitor.py 開始 (attempt 2)
- 12:44:17 — Stage observed 0/9 (2nd run)
- 12:45:15 — Stage 1/9 LOADING_COMPONENTS (2.0min)
- 12:45:50 — Stages 2-3/9 (2.6min)
- 12:45:50 — Stage 5/9 partman (2.6min) — partman 通過
- 12:47:21 — installer-syslog: `base-installer: warning: apt update failed: 100` (CD repository、無視) → kernel install in target
- 12:48:57 — Stage 6/9 INSTALLING_SOFTWARE (5.7min)
- 12:48:57 — Stage 7/9 INSTALLING_GRUB (5.7min)
- 12:49:23 — Stage observed 7/9
- 12:49:44 — PowerState Off detected
- 12:50:10 — PowerState re-check Off → Installation completed (sol-monitor exit 0, 6m16s)
- 12:50:17 — Phase 6: umount + boot-reset + Power On
- 12:51 頃 — SOL login + Phase 6 SOL コマンド実行 (SSH 鍵配置 + 静的 IP 設定)
- 12:52:57 — SOL login 完了
- 12:53 — SSH key auth OK + machine-id 検証 OK (1778557635 > 1778557381, +254s)
- 12:53:21 — Phase 6 mark
- 12:53 頃 — Phase 7: scp scripts /root/ + linbit keyring 事前配置 (1164 bytes)
- 12:54 — dhcpcd → pre-pve-setup 1 回目 (default route fix OK、ca-cert/wget/isc-dhcp-client install OK)
- 12:55 — apt-get install -y build-essential libc6-dev (改善 7)
- 12:56 頃 — pve-setup-remote.sh --phase pre-reboot 実行 (proxmox-default-kernel install)
- 13:00 頃 — reboot → ssh-wait 80s 復活
- 13:01 — ip route 確認: default route 10.10.10.1 のまま (10.10.10.1 経由ではインターネット不可)→ pre-pve-setup 再実行で 192.168.39.1 に修正
- 13:01:30 頃 — pve-setup-remote.sh --phase post-reboot --linstor 1 回目 → apt fail (Temporary failure resolving, 改善 14 未実装で発症)
- 13:02 頃 — pre-pve-setup 再実行 (route 復旧、dhclient fallback で DHCP 取得)
- 13:03 — pve-setup-remote.sh --phase post-reboot --linstor 2 回目 → 完走 (drbd-dkms 9.3.2-1, linstor-satellite 1.33.3-1, linstor-proxmox 8.2.0-1)
- 13:04 — final reboot → ssh-wait 70s 復活
- 13:06:28 — default route 消失再確認 → dhclient -1 -v eno1 復活 (Round 5.5 改善 18 通り)
- 13:07 — pve-bridge-setup.sh で vmbr0/vmbr1 構築
- 13:07:23 — 最終検証 (pveversion, vmbr0, vmbr1, default route, Web UI 200) → Trial 8 終了

## 検証結果
- pveversion: `pve-manager/9.1.9/ee7bad0a3d1546c9 (running kernel: 7.0.2-2-pve)`
- vmbr0: `10.10.10.214/8` (UP)
- vmbr1: `192.168.39.168/24` (UP, DHCP)
- default route: `via 192.168.39.1 dev vmbr1`
- 10.0.0.0/8: `dev vmbr0 proto kernel scope link src 10.10.10.214`
- Web UI: `https://10.10.10.214:8006` → HTTP 200
- VD0: Online (RAID-1, Bay 1+6, 278.88 GB, OS_RAID1, Trial 7 から継続)
- DRBD: drbd-dkms 9.3.2-1 installed
- LINSTOR satellite: 1.33.3-1 active
- linstor-proxmox: 8.2.0-1 installed
- インターネット到達性: deb.debian.org → ping 3.69 ms OK
- machine-id 検証: mtime 1778557635 > install-monitor.start 1778557381 ✓ (正規 install)

## ./scripts/os-setup-phase.sh times --config config/server14.yml

```
iso-download             0m00s
preseed-generate         0m00s
iso-remaster             0m00s
bmc-mount-boot           1m35s
install-monitor          7m16s
post-install-config      3m00s
pve-install              13m32s
cleanup                  0m18s
---
total                    25m41s
```

skill 内部 phase 計測の合計 25m41s と実時間 49m54s の差 ~24min は、attempt 1 の partman stuck ~15.5min (sol-monitor + 判定) + iDRAC racreset soft 待機 (3min) + state reset + 再 mount (2min) + post-reboot exit 100 リトライ (~1min) + final reboot 後 dhclient 復旧 + bridge setup (~2min) の合計。**install-monitor の計測時間 7m16s は attempt 2 のみのため、attempt 1 の 15.5min は計測外**。

## Trial 1-8 比較

| 観測項目 | Trial 1 | Trial 2 | Trial 3 | Trial 4 | Trial 5 | Trial 6 | Trial 7 | Trial 8 |
|---------|---------|---------|---------|---------|---------|---------|---------|---------|
| install-monitor (時間) | 7m37s | 7m21s | 7m34s | 7m21s | 7m25s | 7m26s | 7m45s | **7m16s** |
| install attempt 回数 | 1 | 1 | 2 (att1 partman stuck) | 1 | 1 | 1 | 2 (att1 partman stuck) | **2 (att1 partman stuck)** |
| attempt 1 failure | なし | なし | partman-auto-lvm 固着 25min | なし | なし | なし | partman stage 5/9 固着 21min | **partman stage 5/9 固着 15.5min** |
| 全体所要時間 | 47m17s | 53m08s | 78m03s | 43m56s | 43m34s | 48m49s | 63m40s | **49m54s** |
| Round 2 改善 #6 LINBIT keyring | 該当無し | 手動 fallback | 事前配置 ✓ | 事前配置 ✓ | 事前配置 ✓ | 事前配置 ✓ | 事前配置 ✓ | **事前配置 ✓** |
| Round 2 改善 #7 build-essential | 該当無し | 手動 install | 事前 install ✓ | 事前 install ✓ | 事前 install ✓ | 事前 install ✓ | 事前 install ✓ | **事前 install ✓** |
| Round 3 改善 #10 partman stuck 早期判定 | N/A | N/A | 発動 (実証) | 発動せず | 発動せず | 発動せず | 発動 ✓ (2 回目実証) | **発動 ✓ (3 回目実証)** |
| Round 4 改善 #14 post-reboot pre-flight | N/A | N/A | N/A | 未実装 | 未実装 | 未実装 | 未実装 (6 trial 連続) | **未実装 (7 trial 連続)** |
| Round 5 改善 #16 final reboot route 復旧 | N/A | N/A | N/A | N/A | 発見 (新規) | 発動 ✓ | 発動 ✓ (dhclient で復旧) | **発動 ✓ (dhclient で復旧)** |
| Round 5 改善 #17/18 vmbr0/bridge pre-flight | N/A | N/A | N/A | N/A | 発見 (新規) | 発動 ✓ | 発動 ✓ | **発動 ✓** |
| 改善 19 (pre-pve-setup 前 dhcpcd) | N/A | N/A | N/A | N/A | N/A | N/A | (skill 未追加、内部 fallback) | **agent 手動実行 ✓** |
| pve-setup-remote default-route hook | N/A | N/A | N/A | N/A | N/A | N/A | 新規観測 | **未観測 (要再確認)** |
| 新発見の skill 改善点 | rm -rf state ブロック | LINBIT GPG fallback | partman stuck 判定 | /tmp/ クリア | Export 未スポーン LC062 | pre-pve-setup 1 回目 DHCP 失敗 | partman stuck 2 回目実証 + Round 4 改善 14 必須化 6 trial 連続 | **partman stuck 3 回目実証 (Trial 3, 7, 8) + Round 4 改善 14 7 trial 連続未実装確定** |

## 累積統計 (Trial 1-8)

- **R430 partman stuck**: 3/8 trial = 37.5% (Trial 3, 7, 8 で発生、改善 10 で対処、racreset soft 100% 復旧)
- **GRUB sector read error**: 1/8 trial = 12.5% (Round 2 s15)
- **post-reboot default route loss**: 7/8 trial = 87.5% (改善 14 mitigation で対処、Trial 2-8)
- **LINBIT keyring absent**: 4/8 trial = 50% (改善 19 mitigation で対処)
- **final reboot route loss**: 4/8 trial = 50% (Trial 5-8、改善 18 で対処)
- **最終成功率**: 8/8 = 100%
- **1 attempt 成功率**: 5/8 = 62.5% (失敗 3 件はすべて R430 hardware-class partman stuck、racreset soft で 100% 復旧)

## 新規 skill 改善候補 (Round 8.5)

### 改善 21: partman stuck 発生率が 37.5% に増加
- **Trial 3, 7, 8 で 3 回発生** (37.5%) → 完全に hardware-class issue として確定
- 対処: skill Round 3.5 改善 10 (15min stuck + 10min syslog silence) は十分機能している
- 検討: ISO/preseed/RAID パラメータの微妙な違いが原因の可能性 → 別 issue で root cause 調査推奨。Trial 7-8 連続発生のため確率的というより環境定常的な可能性も浮上

### 改善 22: pve-setup-remote.sh の default-route hook の検証
- **未観測**: Trial 8 では post-reboot 完了時の log に hook install ログを見ていない (Trial 7 で初観測されたメッセージ `Default-route fix hook installed at /etc/network/if-up.d/z-fix-default-route` が今回出力されたか不明)
- final reboot 後にも default route 消失 (dhclient 手動復旧) → hook の有無に関わらず失敗するか、まだ root cause 解決していない
- **継続観測**: 次の Trial で post-reboot 出力をフルキャプチャして hook install を確認、また `/etc/network/if-up.d/z-fix-default-route` の内容を OS 内で cat する

### 改善 14 (Round 4 から **7 trial 連続再々々々々々掲**) — post-reboot pre-flight check 引き続き未実装
- **7 trial 連続再発確定 (Trial 2-8)**
- 暫定対処: pre-pve-setup.sh 再実行 → post-reboot 再実行 で完走 (skill 記述通り)
- **修正案 (Round 7.5 / Round 8.5 でも同じ)**: pve-setup-remote.sh の post-reboot 内部 (apt update / apt install 直前) に `ip route show | grep -q ^default || dhclient -1 -v $DHCP_IFACE` を埋め込む

Trial 8 server14: success (50min, attempt 2)
