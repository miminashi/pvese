# Trial 6 / 10 — server14 (R430)
- 開始: 2026-05-12 10:17:15 JST (1778548635)
- 終了: 2026-05-12 11:06:04 JST (1778551564)
- 所要時間: 48m49s (実時間)
- 結果: success
- install-monitor attempt 回数: 1 (1 回で成功、7m09s で PowerState=Off)
- 失敗時の原因: なし (install attempt 一発成功)

## 観測された問題 / Round 5 改善検証

### 1. /root/ scp は Round 4 改善 13 で完全に動作 (Trial 5 から継続)
- 適用: pre-pve-setup.sh / pve-setup-remote.sh を `/root/` に scp
- 結果: post-reboot 後も両スクリプト survive、再 scp 不要

### 2. **post-reboot 中の default route 消失再発 (Round 4 改善 14 未実装)**
- 症状: 1 回目の `pve-setup-remote.sh --phase post-reboot --linstor` 実行直後、apt が `Temporary failure resolving 'packages.linbit.com'` で失敗。`drbd-dkms` 等が `Unable to locate package`
- 回復: `dhclient -1 -v eno1` で route 再取得 → post-reboot 再実行で完走
- 5 trial 連続再発 → **R430 + Debian 13 + PVE 9 の hardware-class 問題で確定**
- **改善案 (Round 4 から 5 trial 連続未実装)**: pve-setup-remote.sh の post-reboot 内部 (apt update / apt install 直前) に `ip route show | grep -q ^default || dhclient -1 -v $DHCP_IFACE` を埋め込む。または skill Phase 7 ステップ 4 を「post-reboot 失敗時は **必ず** dhclient で route 復旧 → 再実行」と Recovery 必須化

### 3. **pre-pve-setup.sh 1 回目で DHCP 取得失敗 (新規)**
- 症状: post-install 後の最初の `sh /root/pre-pve-setup.sh ...` 実行で `dhcpcd -1 -t 30 eno1` または内部 fallback の DHCP 取得が成功せず、apt が `Temporary failure resolving 'deb.debian.org'` で fail。`wget`, `ca-certificates`, `isc-dhcp-client` パッケージ取得不能
- 観測: SOL コマンドで `ifup eno1` を実行したものの DHCP lease を取れていなかった (`ip -brief addr` で eno1 UP だが IP 無し)
- 回復: 別途 `dhcpcd -1 -t 30 eno1` を手動実行 → 192.168.39.165 lease → default route via 192.168.39.1 → pre-pve-setup 再実行で成功
- **改善案**: SKILL.md Phase 7 step 0 で「**`pre-pve-setup.sh` 実行前に `ssh ... dhcpcd -1 -t 30 <dhcp_iface>` を必ず一度回す**」を明文化。pre-pve-setup.sh 内部の DHCP retry ロジックは初回ブート直後の eno1 状態で確実には機能しない (Round 5 で言及済の Debian 13 minimal の isc-dhcp-client 不在問題)

### 4. final reboot 後の default route 消失 (Round 5 改善 16 と同じ)
- 症状: `final reboot` 後の SSH 復帰時、`ip route show` から default route が消失
- 回復: `dhclient -1 -v eno1` で eno1 経由 DHCP → default route 復活
- その後 `pve-bridge-setup.sh` 実行 → vmbr1 が DHCP で default route 保持
- **5 trial 連続再発**: Round 5 改善 16 (Phase 8 step 5 で「`ip route` 確認 → 必要なら dhclient -1 -v <dhcp_iface>」) は SKILL.md に文字列で書かれているが **agent が読み飛ばすことがある** ため、`pve-bridge-setup.sh` 自体に pre-flight check を埋め込むのが望ましい

### 5. Trial 5 比較: VD0 BGI 挙動の違い
- Trial 5: VD0 createvd 直後に State=Online + OperationalState=Not applicable (BGI スキップ)
- Trial 6: VD0 createvd 後 State=Online + OperationalState=Background Initialization (BGI 走行中)
- 同じ Bay 1+6 (ST9300653SS) でも BGI のスキップ判定がジョブの内部状態で変動する
- 影響なし (State=Online なら install は問題なく走る)

### 6. Round 2-5 改善の検証結果 (Trial 6 で適用)

| 改善 | 結果 |
|------|------|
| 改善 6 (LINBIT GPG empty-file detect → 事前 keyring 配置) | ✓ `linbit-keyring-t5.gpg` (Trial 5 取得) を再配置 → post-reboot 一発成功 |
| 改善 7 (build-essential / libc6-dev を `--linstor` 前に install) | ✓ pre-pve-setup 完了直後に `apt-get install -y build-essential libc6-dev` → DKMS build 一発成功 (drbd-dkms 9.3.2-1 Setting up OK) |
| 改善 8 (SCP Export job 完了待ち) | ✓ resetconfig 後 jobqueue view で Export job (SYS057 10%) 観測 → createvd LC062 reject 1 回 → 20s 後 STOR094 成功 |
| 改善 9 (`printf > /file` の "Command may have failed" は誤検知) | ✓ SOL `printf > /etc/network/interfaces`, `ifup eno1` で WARN 出たが実際は成功 |
| 改善 10 (partman stuck 早期判定 + racreset soft) | (発動せず) Trial 6 first attempt で stage 5/9 → 1 分以内に Stage 6 移行 |
| 改善 11 (sol-login.py DETECTING timeout 延長) | (発動せず) DETECTING → 即 LOGIN_PROMPT (boot 完了が早かった) |
| 改善 12 (eno1 SOL up + interfaces 追記) | ✓ SOL コマンドで `ip link set eno1 up` + `auto eno1` を /etc/network/interfaces に追記 |
| 改善 13 (`/root/` scp で /tmp/ クリアを回避) | ✓ pre-pve-setup.sh / pve-setup-remote.sh を /root/ に配置 → reboot 後も生存 |
| 改善 14 (post-reboot 前の internet pre-flight check) | **未実装** — post-reboot 1 回目で route 消失 + apt fail を再現 (Round 4-6 連続) |
| 改善 15 (Export job 未スポーン LC062 retry loop) | ✓ Trial 6 では Export job が見えた状態で createvd → LC062 1 回 reject → 20s sleep → 成功 |
| 改善 16 (final reboot 後 dhclient フォールバック) | ✓ skill に記載あり、agent が SKILL.md を読んで dhclient 実行 → 成功 |
| 改善 17 (Phase 8 vmbr0 存在確認チェックリスト) | ✓ pve-bridge-setup.sh 実行後に vmbr0 UP + 10.10.10.214/8 を確認 |
| 改善 18 (bridge setup 前 ip route + dhclient) | ✓ skill 記載通り実行 → default route 復旧後に bridge setup |

### 7. install-monitor 中の PowerState check timeout (Trial 1-5 と同じパターン継続)
- install-monitor の sol-monitor.py で `bmc-power.sh status` が 4 回連続 30 秒 timeout → `PowerState=None`
- 影響なし (stage 観測ガード + 後半で Off に推移して正常完了)
- iDRAC8 + iDRAC FW 2.63.60.61 の Redfish が install 中の負荷で応答遅延を起こす既知挙動

## 主要ログ
- `tmp/c452be97-t6-s14/sol-install-s14.log` (install monitor SOL log)
- `tmp/c452be97/installer-syslog-all.log` (親管理、UDP 5514)
- `tmp/c452be97/linbit-keyring-t5.gpg` (Trial 5 から再利用)
- `tmp/c452be97-t6-s14/poll-reset.sh`, `createvd-retry.sh` (Phase A poll scripts)
- `tmp/c452be97-t6-s14/sol-commands.txt` (Phase 6 SOL commands)
- `tmp/c452be97-t6-s14/place-key.py` (pexpect SSH key 配置)
- `log/oplog.log` (state-changing コマンド全件)

## 主要イベントタイムライン
- 10:17:15 — Trial 6 開始
- 10:19 — Phase A: bmc-power forceoff → racadm jobqueue delete --all (RAC1032)
- 10:19:30 — racadm raid resetconfig:RAID.Integrated.1-1 (RAC1040)
- 10:19:45 — jobqueue create pwrcycle (JID_785163949670)
- 10:23:30 — Configure job Completed (100, ~3.7 min)
- 10:24:04 — createvd retry 1: LC062 (Export job running)
- 10:24:40 — createvd retry 2: STOR094 (success after 20s)
- 10:25:08 — jobqueue create pwrcycle (JID_785166941763)
- 10:28:34 — Configure job Completed (100, ~3.4 min) — VD0 OS_RAID1 Online (RAID-1, Bay 1+6, 278.88 GB, BGI 走行中)
- 10:30:00 頃 — Phase 1-3 mark (ISO 再利用 OK)
- 10:30:30 頃 — VirtualMedia mount (idrac14)
- 10:31:00 頃 — boot-once VCD-DVD + power cycle
- 10:32:01 — Phase 5: sol-monitor.py 開始
- 10:33:08 — Stage observed (0/9)
- 10:34:48 — Stages 1-3/9 (LOADING_COMPONENTS / DETECTING_NETWORK / CONFIGURING_APT, 2.7min)
- 10:35:23 — Stage 5/9 partman observed (2.7min) — 一発通過
- 10:38:00 — Stage 6/9 INSTALLING_SOFTWARE (5.9min)
- 10:38:26 — Stage 7/9 INSTALLING_GRUB (6.3min)
- 10:38:47 — PowerState Off (6.4min, stages=7)
- 10:39:13 — Installation completed (sol-monitor exit 0, 7m09s)
- 10:39:30 頃 — Phase 6: umount + boot-reset + Power On (already On)
- 10:46 頃 — ssh-wait timeout 360s → SOL login + pexpect SSH key 配置
- 10:46:55 — sol-login.py で PermitRootLogin/PasswordAuth + sudoers + eno1 up
- 10:47:00 頃 — pexpect SSH (password) で authorized_keys 配置
- 10:47:30 頃 — SSH key auth OK + machine-id 検証 OK (1778549776 > 1778549516)
- 10:48 頃 — Phase 7: scp scripts /root/ + linbit keyring 事前配置
- 10:50 頃 — pre-pve-setup 1 回目: DHCP 取得失敗 → 手動 dhcpcd → pre-pve-setup 2 回目成功
- 10:51 頃 — apt-get install -y build-essential libc6-dev
- 10:52 頃 — pve-setup-remote.sh --phase pre-reboot 実行 (proxmox-default-kernel install)
- 10:58 頃 — reboot → ssh-wait 60s 復活
- 10:59 頃 — ip route 確認: default route 消失 → dhclient -1 -v eno1 復旧
- 10:59 — pre-pve-setup 再実行 (idempotent OK)
- 11:00 頃 — pve-setup-remote.sh --phase post-reboot --linstor 1 回目 → apt fail (default route 消失)
- 11:01 — dhclient -1 -v eno1 復旧
- 11:01 — pve-setup-remote.sh --phase post-reboot --linstor 2 回目 → 完走 (drbd-dkms 9.3.2-1, linstor-satellite 1.33.3-1, linstor-proxmox 8.2.0-1)
- 11:04 — final reboot → ssh-wait 60s 復活
- 11:05 — default route 消失再確認 → dhclient -1 -v eno1 復活
- 11:05 — pve-bridge-setup.sh で vmbr0/vmbr1 構築
- 11:06 — 最終検証 (pveversion, vmbr0, vmbr1, default route, Web UI 200, VD0 Online)
- 11:06:04 — Trial 6 終了

## 検証結果
- pveversion: `pve-manager/9.1.9/ee7bad0a3d1546c9 (running kernel: 7.0.2-2-pve)`
- vmbr0: `10.10.10.214/8` (UP)
- vmbr1: `192.168.39.165/24` (UP, DHCP)
- default route: `via 192.168.39.1 dev vmbr1`
- 10.0.0.0/8: `dev vmbr0 proto kernel scope link src 10.10.10.214`
- Web UI: `https://10.10.10.214:8006` → HTTP 200
- VD0: Online (RAID-1, Bay 1+6, 278.88 GB, OS_RAID1, OperationalState=Background Initialization)
- DRBD: drbd-dkms 9.3.2-1 installed
- LINSTOR satellite: 1.33.3-1 enabled
- linstor-proxmox: 8.2.0-1 installed
- インターネット到達性: deb.debian.org → ping 3.16 ms OK

## ./scripts/os-setup-phase.sh times --config config/server14.yml

```
iso-download             0m20s
preseed-generate         0m06s
iso-remaster             0m14s
bmc-mount-boot           2m00s
install-monitor          7m26s
post-install-config      8m17s
pve-install              17m50s
cleanup                  0m31s
---
total                    36m44s
```

skill 内部 phase 計測の合計 36m44s と実時間 48m49s の差 12m05s は、Phase A の RAID 操作 (jobqueue delete + resetconfig commit job 3.7min + createvd LC062 retry + createvd commit job 3.4min) が phase 計測対象外で ~10 min、final reboot 後の dhclient 再取得 + bridge setup が ~2 min 消費されたため。

## Trial 1-6 比較
| 観測項目 | Trial 1 | Trial 2 | Trial 3 | Trial 4 | Trial 5 | Trial 6 |
|---------|---------|---------|---------|---------|---------|---------|
| install-monitor (時間) | 7m37s | 7m21s | 7m34s | 7m21s | 7m25s | **7m26s** |
| install attempt 回数 | 1 | 1 | 2 (attempt 1 partman stuck) | 1 | 1 | **1** |
| attempt 1 failure | なし | なし | partman-auto-lvm 固着 25min | なし | なし | **なし** |
| 全体所要時間 | 47m17s | 53m08s | 78m03s | 43m56s | 43m34s | **48m49s** |
| Round 2 改善 #6 LINBIT keyring | 該当無し | 手動 fallback | 事前配置 ✓ | 事前配置 ✓ | 事前配置 ✓ | **事前配置 ✓** |
| Round 2 改善 #7 build-essential | 該当無し | 手動 install | 事前 install ✓ | 事前 install ✓ | 事前 install ✓ | **事前 install ✓** |
| Round 2 改善 #8 SCP Export 待ち | 該当無し | 観測ガード | poll 明示 ✓ | poll 明示 ✓ | Export 未スポーン (poll 不発) | **Export 観測 + LC062 retry 1 回** |
| Round 3 改善 #10 partman stuck 早期判定 | N/A | N/A | 発動 (実証) | 発動せず | 発動せず | **発動せず (R430 partman 安定)** |
| Round 3 改善 #11 sol-login DETECTING 延長 | N/A | N/A | 発動 | 発動せず | 発動せず | **発動せず** |
| Round 3 改善 #12 eno1 SOL 設定 | N/A | N/A | 発動 ✓ | 発動 ✓ | 発動 ✓ | **発動 ✓** |
| Round 4 改善 #13 /root/ scp | N/A | N/A | N/A | 未適用 (/tmp/ で失敗) | 適用 ✓ | **適用 ✓** |
| Round 4 改善 #14 post-reboot pre-flight | N/A | N/A | N/A | 未実装 | 未実装 | **未実装 (post-reboot 1 回 fail 再現)** |
| Round 5 改善 #16 final reboot route 復旧 | N/A | N/A | N/A | N/A | 発見 (新規) | **発動 ✓ (dhclient で復旧)** |
| Round 5 改善 #17/18 vmbr0/bridge pre-flight | N/A | N/A | N/A | N/A | 発見 (新規) | **発動 ✓** |
| 新発見の skill 改善点 | rm -rf state ブロック | LINBIT GPG fallback | partman stuck 判定 | /tmp/ クリア | Export 未スポーン LC062 | **pre-pve-setup 1 回目 DHCP 失敗 → dhcpcd 事前必須** |

## 新規 skill 改善候補 (Round 6.5)

### 改善 19: pre-pve-setup.sh 実行前の DHCP 取得を必須化
- **問題**: post-install 直後の初回 `pre-pve-setup.sh` で DHCP 取得が成立せず、apt fetch fail
- **修正案**: SKILL.md Phase 7 step 0 で「**`pre-pve-setup.sh` 実行前に `ssh ... dhcpcd -1 -t 30 <dhcp_iface>` を必ず一度回す** (or pre-pve-setup.sh 自体に retry loop)」を明文化
- 既存記述 (`> ⚠️ DHCP 取得が timeout する場合 (Debian 13 minimal で観測)`) は問題発生 *後* の対処として書かれており、agent は一度失敗してから読みに行く。**事前必須** に格上げするのが効果的

### 改善 14 (Round 4 再々掲) — post-reboot pre-flight check は引き続き未実装
- **5 trial 連続再発確定**: Round 4 から 5 trial、すべて post-reboot 1 回目で default route 消失 + apt fail。dhclient 再取得 → post-reboot 再実行で完走
- **修正案 (推奨)**: pve-setup-remote.sh の post-reboot 内部 (apt update / apt install 直前) に `ip route show | grep -q ^default || dhclient -1 -v $DHCP_IFACE` を埋め込む
- これにより post-reboot 一発成功 → 全体所要時間 5 分短縮見込み

### 改善 20: pve-bridge-setup.sh 内蔵 pre-flight route check
- **問題**: final reboot 後の default route 消失は 2 trial 連続 (Trial 5/6) で再発。skill 記載はあるが agent 読み飛ばしリスク
- **修正案**: `pve-bridge-setup.sh` の冒頭 (--apply 前) に `ip route show | grep -q ^default || (echo "WARN: no default route, attempting dhclient $DHCP_IFACE"; dhclient -1 -v $DHCP_IFACE)` を埋め込む

Trial 6 server14: success (49min, attempt 1)
