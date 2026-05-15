# server7 trial 1 (2026-05-15)

- **結果**: ✓ success
- **wall**: 1h13m30s (07:46:54 start → 09:00:24 shutdown; total phase time 71m44s per os-setup-phase times)
- **attempts**: 1 (no retry, no racreset soft needed)
- **主要事象**: Phase 1-8 通しテスト 1 attempt で完走。R320 + iDRAC7 既存運用パターンの範囲内で進行。手動修正は通常運用に含まれる範囲(LINBIT keyring 事前配置 + post-reboot 中 route 復旧の 1回再実行)のみ。

## 修正の動作確認

- **preseed-server7.cfg (手動管理)** は不変 (sha256 = 6716953b70c8e7812e1fe63285775e7c0e4357964051b1b1b0ebcc3fd66544f4)。今回 generate-preseed.sh は触らない経路なので preseed regression の影響なし
- **build-essential install**: 成功 (修正の主要検証項目)
  - `dpkg -l build-essential` → `ii  build-essential 12.12  amd64`
  - `dkms status drbd` → `drbd/9.3.2-1, 7.0.2-2-pve, x86_64: installed (Original modules exist)`
  - `dpkg -l drbd-dkms` → `ii  drbd-dkms 9.3.2-1 all`
  - **trial-1-s8 で発火していた "stdio.h: No such file" 不在を確認**。build-essential が DRBD DKMS ビルド前に入っているため、DKMS が clean に通った。リビルド痕跡なし
- **sol-monitor 新フラグ**: stage 検出経路で正常完了
  - 渡したフラグ: `--installer-syslog tmp/e28df8d0/installer-syslog-s8-r3.log --static-ip 10.10.10.207 --ssh-config ssh/config --preseed-start-epoch 1778798814`
  - 結果: `[08:01:20] Installation completed successfully (PowerState Off, after 'Power down')` exit 0
  - 7 stages 観測 (LOADING_COMPONENTS → CONFIGURING_APT → INSTALLING_SOFTWARE → INSTALLING_GRUB → POWER_DOWN)
  - **フォールバック (installer-syslog scan / machine-id mtime SSH) は本ケースでは発火せず**。SOL 経路のみで完了。新フラグはコマンドラインで accept されたことを `--help` で確認済 (regression なし)
- **racreset soft 後 VirtualMedia 復旧手順**: 不発 (今回 racreset soft 不要)。trial 中に VirtualMedia 状態消失はなく、SKILL.md の新セクションは出番なし

## 詳細ログ抜粋

### SOL monitor 完了部 (tail)
```
[07:54:17] Stage: CONFIGURING_APT (3.9min)
[07:58:25] Stage observed: COUNT=5/9
[07:59:02] Stage: INSTALLING_SOFTWARE (8.6min)
[07:59:26] Stage: INSTALLING_GRUB (9.0min)
[07:59:26] Stage observed: COUNT=7/9
[08:00:43] Stage: POWER_DOWN (10.3min)
[08:00:43] Power down detected, waiting 30s for shutdown...
[08:01:20] PowerState after shutdown wait: Off
[08:01:20] Installation completed successfully (PowerState Off, after 'Power down')
```

### machine-id mtime 検証
```
install-monitor.start = 1778798966 (07:49:26 JST)
remote /etc/machine-id mtime = 1778799417 (07:56:57 JST)
→ 07:56:57 > 07:49:26 (OK: real reinstall confirmed, +7m31s)
```

### Phase 7 build-essential / DRBD DKMS
```
$ dpkg -l build-essential
ii  build-essential 12.12  amd64  Informational list of build-essential packages
$ dkms status drbd
drbd/9.3.2-1, 7.0.2-2-pve, x86_64: installed (Original modules exist)
$ dpkg -l drbd-dkms
ii  drbd-dkms 9.3.2-1  all  RAID 1 over TCP/IP for Linux module source
```

### Phase 8 cleanup 後 PVE 状態
- pve-manager/9.1.11/8eac2c86f015bdda (kernel 7.0.2-2-pve)
- Debian GNU/Linux 13 (trixie)
- vmbr0 = 10.10.10.207/8 (eno1), vmbr1 = 192.168.39.100/24 (eno2 dhcp)
- Web UI: `curl -k https://10.10.10.207:8006/` → HTTP 200
- pveproxy: active

### Phase 別所要時間
```
iso-download             0m10s
preseed-generate         0m00s
iso-remaster             0m12s
bmc-mount-boot           1m31s
install-monitor         12m25s
post-install-config     32m43s
pve-install             23m39s
cleanup                  1m04s
total                   71m44s
```

> post-install-config が 32m と長いのは、初回 sol-login.py が `DETECTING -> EOF` で 1 回失敗 (OS boot 前) し、25 分後の再試行で成功したため。OS 自体は 08:08 頃 boot 完了、SOL 再接続が成立したのは 08:34 だった。この間は ssh-wait.sh による polling と一時停止が続き、time accounting に乗っている。本来 OS up は 5-6 分。

## 失敗時の根本原因 (該当する場合)

該当なし。trial 1 success。

## 通常運用範囲内の手動操作 (regression ではない)

1. **post-reboot 中の default route 消失**: `pve-setup-remote.sh --phase post-reboot` の途中で proxmox-ve のインストールが ifupdown2 を再初期化し default route が落ちる事象 (SKILL.md 既知)。`pre-pve-setup.sh` の再実行 + `dhcpcd` で復旧、`pve-setup-remote.sh` を再実行 (冪等)。最終的に `--linstor` 経路通過
2. **LINBIT keyring 事前配置**: `pve-setup-remote.sh --linstor` 内の wget が 404 silent fail で空 keyring を残し、apt-get が `sqv` でエラー。SKILL.md 既知の `keyserver.ubuntu.com` 経由で取得して配置 → 成功 (1 回の手作業)
3. **pve-enterprise.sources 残存**: 過去 PVE インストール由来。手で削除して `apt-get update` 通過

これら 3 つは SKILL.md に既に記載されている既知事象で、build-essential / sol-monitor 修正の検証目的とは独立。今回の検証対象 (Phase 1 修正) は全て期待通り動作。
