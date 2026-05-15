# Trial 2 / 10 — server14 (R430)
- 開始: 2026-05-12 05:30:10 JST
- 終了: 2026-05-12 06:23:18 JST
- 所要時間: 53m08s (実時間: 05:30:10 → 06:23:18)
- 結果: success
- install-monitor attempt 回数: 1 (1 回で成功)
- 失敗時の原因: なし (install-monitor は first attempt で 7m21s で完了)

## 観測された新規問題 / skill 改善候補

### 1. LINBIT GPG キー fetch が pve-setup-remote.sh 内蔵フォールバックでも失敗 (Trial 2 で再現)
- `phase_post_reboot` の `wget -qO /usr/share/keyrings/linbit-keyring.gpg https://packages.linbit.com/package-signing-pubkey.gpg` は 404 を返し、空ファイルになる
- スクリプト内蔵の `keyserver.ubuntu.com` フォールバック (gpg --recv-keys) も `gnupg dirmngr` を先に install する処理だが、apt update 直前に呼ばれないため**初回 apt update で `Error: Failed to parse keyring "/usr/share/keyrings/linbit-keyring.gpg"` (No such file or directory) になり後続が空のままになる**
- 結果: post-reboot 初回は exit code 100 で apt update が失敗 → keyring を手動取得して scp → 再実行で成功 (skill のフォールバック手順通り)
- skill 改善案: `pve-setup-remote.sh` の LINBIT GPG fetch ロジックを「`wget` 直接取得が失敗・空なら即時 `keyserver.ubuntu.com` から `gpg --recv-keys` で取得」と二段フォールバックに修正し、404 で空ファイルが残らないようにする。または skill SOP に「LINBIT GPG 取得は事前にローカルで `keyserver.ubuntu.com` から取得して scp する」を**デフォルト手順**として記載する (現状は fallback 扱い)

### 2. DRBD DKMS が `stdio.h` 不在で fail (build-essential 未 install)
- `pve-setup-remote.sh --linstor` は `gcc proxmox-headers-* drbd-dkms drbd-utils ...` を install するが、**build-essential / libc6-dev は install しない**
- DKMS が gen_patch_names.c (host gcc) を compile しようとして `stdio.h: No such file or directory` で fail → `dkms autoinstall` が exit 10
- 結果: `drbd-dkms` の dpkg status が `iF` (installed but post-install trigger failed) になり、post-reboot 全体の exit code が 100 になる
- 復旧: `apt-get install build-essential libc6-dev` → `dkms autoinstall` → installed (Original modules exist)
- skill 改善案: `pve-setup-remote.sh --linstor` の install リストに `build-essential` を追加 (`gcc` だけでは不十分。`libc6-dev` も明示)
- 補足: trial 1 では post-reboot を**別 agent が実行した**ため、別 agent の環境差で発覚しなかった可能性が高い。trial 2 が単独実行で初めて踏んだ

### 3. preseed install 後の最初の SSH は publickey-only で permission denied
- preseed install 完了直後、SSH は到達するが authorized_keys 未配置のため `Permission denied (publickey,password)` (BatchMode 環境)
- SKILL の Phase 6 step 3 の流れは「SOL で PermitRootLogin yes → password SSH で authorized_keys 配置」だが、現状 sol-login.py で「ip -brief addr」等の確認コマンド出力が**全くキャプチャされない** (sol-login.py の run_commands_file は stdout を log に書くだけで stderr の status 表示にしか出ない)
- 結果: 確認に pexpect 経由でローカル SOL session を立てる必要があり、デバッグに余計に時間がかかる
- skill 改善案: `sol-login.py` に `--echo-output` / `--log-file` フラグを追加し、各コマンドの実出力を stderr に flush する。または、Phase 6 step 3 の sol-commands に「最後に `> /tmp/state.txt` でファイル化し、後続 SSH で `cat /tmp/state.txt` を実行する」フローを skill に明記する

### 4. install-monitor 完了直後の最初の SSH は接続失敗を 4 分繰り返した
- post-install-config の Power On 直後、`ssh-wait.sh --timeout 240` で 24 回 (4 分) failed retry を出して終了
- 原因: 本拠点 R430 + Debian 13 minimal は systemd boot + sshd 起動完了まで 90 秒 + α かかる。最初の `ssh-wait` 開始 (05:59:10) と SSH 実際成功 (06:04:18) の間に 5 分以上経過
- ただし、その後 SOL login + restart sshd で速やかに復活 (現状の skill 通りで動作)
- skill 改善案: なし (skill は SOL login をフォールバックとして指定済み。本拠点 R430 では minimum boot time が長いことを既知知見として記載)

### 5. PowerState check timeout (PowerState=None) 多発 — trial 1 と同じ
- install-monitor 中に `bmc-power.sh status` (Redfish) が 4 回 timeout → "PowerState check failed"
- 影響なし (stage 観測ガード + 後半で PowerState=On→Off に推移して正常完了)
- skill 改善案: なし (現状のリカバリーで十分。trial 1 と同じ観測)

## 主要ログ
- tmp/c452be97/sol-install-trial2-s14.log
- tmp/c452be97/sol-capture-iface.log (Phase 6 デバッグで採取)
- tmp/c452be97/sol-capture-sshd.log
- tmp/c452be97/linbit-keyring-trial2.gpg (Trial 2 で取得した LINBIT 鍵)
- /var/log/oplog.log (state-changing コマンド全件)

## 主要イベントタイムライン
- 05:30:10 — Phase A 開始 (jobqueue delete + RAID resetconfig)
- 05:35:25 — RAID resetconfig + pwrcycle 完了 (Reboot Completed)
- 05:42:46 — createvd job スケジュール → 05:44:47 Running 34% → 05:45:25 Completed
- 05:47頃 — Phase A 終了 (state/VirtualMedia reset, known_hosts cleanup)
- 05:47:24 — Phase 1-3 マーク (ISO 再利用 + preseed ハッシュ一致でリマスター skip)
- 05:48頃 — Phase 4 bmc-mount-boot 完了 (mount + boot-once + cycle)
- 05:49:39 — install-monitor.start (Phase 5)
- 05:50:59 — Stage observed (0/9 — installer 起動)
- 05:52:02 — Stage 1/9 (LOADING_COMPONENTS, 2.1min)
- 05:52:37 — Stage 2-3 (DETECTING_NETWORK, CONFIGURING_APT)
- 05:53:12 — Stage 5/9 (partman 終了)
- 05:55:18 — Stage 6/9 (INSTALLING_SOFTWARE, 5.4min)
- 05:55:44 — Stage 7/9 (INSTALLING_GRUB, 5.8min)
- 05:56:29 — PowerState Off detected (6.4min)
- 05:56:54 — Installation completed successfully
- 05:57:01 — Phase 6 開始 (umount + boot-reset + power on)
- 06:03:51 — Power On 後 4 分以上待っても SSH 不到達 → SOL login で PermitRootLogin 有効化
- 06:04:18 — SOL login 完了 (sshd restart, sudoers)
- 06:05頃 — SSH password でも認証 fail (key 未配置)
- 06:08:14 — pexpect password SSH で authorized_keys 配置 → SSH key auth 成功
- 06:08頃 — machine-id 検証 OK (1778532834 > 1778532579) → post-install-config done
- 06:09:00 — Phase 7 pre-pve-setup.sh (DHCP + apt + ca-certificates) 完了
- 06:11頃 — Phase 7 pre-reboot (proxmox-default-kernel install) 完了
- 06:13頃 — reboot + ssh-wait 80s で復活
- 06:13頃 — pre-pve-setup 再実行 (default route fix)
- 06:14頃 — post-reboot 開始 (proxmox-ve install)
- 06:15頃 — LINBIT GPG keyring 取得 fail (404) → 手動 fetch + scp
- 06:17:18 — keyring 配置 + 再 post-reboot → DKMS build fail (libc6-dev 不在)
- 06:19頃 — apt install build-essential libc6-dev → dkms autoinstall 成功 (drbd module installed)
- 06:19:50 — Phase 7 完了 (linstor-satellite enable, final reboot)
- 06:21頃 — final reboot 後 ssh-wait 50s で復活
- 06:22:30 — Phase 8 cleanup + pve-bridge-setup → vmbr0/vmbr1 構築
- 06:23:18 — Trial 2 終了

## 検証結果
- pveversion: `pve-manager/9.1.9/ee7bad0a3d1546c9 (running kernel: 7.0.2-2-pve)`
- vmbr0: `10.10.10.214/8` (UP)
- vmbr1: `192.168.39.161/24` (UP, DHCP)
- default route: `via 192.168.39.1 dev vmbr1`
- Web UI: `https://10.10.10.214:8006` → HTTP 200
- VD0: Online (RAID-1, Bay 1+6, 278.88GB, OS_RAID1)
- DRBD: drbd/9.3.2-1 installed via DKMS
- LINSTOR satellite: enabled

## ./scripts/os-setup-phase.sh times --config config/server14.yml

```
iso-download             0m11s
preseed-generate         0m09s
iso-remaster             0m04s
bmc-mount-boot           2m53s
install-monitor          7m21s
post-install-config      11m17s
pve-install              14m05s
cleanup                  0m31s
---
total                    36m31s
```

(skill 内部 phase 計測の合計 36m31s と実時間 53m08s の差 16m37s は、Phase 7 で LINBIT keyring を**手動取得 (curl + dearmor + scp)** + DKMS build (build-essential install) の 2 度の追加リカバリ作業時間が phase クロック外で消費されたため。trial 1 のような並列セッション競合は無く、純粋に単独実行で踏んだ追加リカバリのコスト)

## Trial 1 との比較
| 観測項目 | Trial 1 | Trial 2 |
|---------|---------|---------|
| install-monitor | 7m37s | 7m21s (-16s) |
| 全体所要時間 | 47m17s | 53m08s (+5m51s) |
| 競合の有無 | 並列 agent dpkg 競合 | 無 (単独実行) |
| 新発見の skill 改善点 | state ディレクトリの rm -rf, SerialComm Auto 互換 | LINBIT GPG fallback 強化, build-essential 追加 |
| install-monitor attempt 数 | 1 | 1 |
| machine-id 検証 | (Phase 7 が別 agent で混在) | 直接実施 OK |

Trial 2 server14: success (53min, attempt 1)
