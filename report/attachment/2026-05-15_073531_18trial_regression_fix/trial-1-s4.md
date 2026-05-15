# server4 trial 1 (2026-05-15)

- **結果**: ✓ success
- **wall**: 41m10s (07:45:42 → 08:27:00 JST)
- **attempts**: 1 (no retry)
- **主要事象**: Phase 1〜8 を手動修正なしで完走。`find-boot-entry "ATEN Virtual CDROM"` は 4号機 X11DPU で再度失敗したが、SKILL.md 新セクション通り `boot-override Cd UEFI` フォールバックで即時成功。SOL monitor 新フラグ (`--installer-syslog`, `--static-ip`, `--preseed-start-epoch`) は stage 7 まで観測しフォールバック不要で exit 0。DRBD DKMS は build-essential 上で stdio.h なしビルド完走、drbd 9.3.2-1 のモジュールが署名済みで `/lib/modules/7.0.2-2-pve/updates/dkms/drbd.ko` に配置された。

## 修正の動作確認

- **preseed-generated-s4.cfg 再生成**: ✓ 現状ファイルと sha256 完全一致 (`e414d764…3754d3`)。`./scripts/generate-preseed.sh config/server4.yml preseed/preseed-generated-s4.cfg` で再生成しても差分なし → Phase 1 修正は committed file と整合。
- **choose_interface=auto / mirror=true で installer 進行**: ✓ yes。`d-i netcfg/choose_interface select auto` / `d-i apt-setup/use_mirror boolean true` / `d-i apt-setup/no_mirror boolean false` が preseed に展開済。Debian installer は eno2np1 を選び (link up + DHCP failed → 静的に切替) 10.10.10.204/8 を late_command で書き込み。SOL stage 進行 LOADING_COMPONENTS → CONFIGURING_APT → INSTALLING_SOFTWARE → INSTALLING_GRUB → POWER_DOWN。
- **build-essential install**: ✓ 成功。`scripts/pve-setup-remote.sh` の post-reboot 段階で `build-essential 12.12` が drbd-dkms より先にインストール (順 33 → 55)。続く drbd-dkms 9.3.2-1 のビルドが `stdio.h` 不在エラーなく完了、`drbd.ko` 等 4 モジュール署名・インストール完了。
- **sol-monitor 新フラグ**: ✓ stage 検出のみで成功。`--installer-syslog`、`--static-ip 10.10.10.204`、`--preseed-start-epoch 1778798742` 全部受領。Stages 7 (LOADING_COMPONENTS / CONFIGURING_APT / INSTALLING_SOFTWARE / INSTALLING_GRUB / POWER_DOWN 等) を観測、PowerState=Off 検出時に「Installation completed successfully (PowerState Off, after 'Power down')」で exit 0。machine-id mtime fallback は使われていないが、フラグの受信・パースは正常。

## 詳細ログ抜粋

### SOL stage list

```
[07:54:39] Stage: LOADING_COMPONENTS (1.4min)
[07:54:54] Stage: CONFIGURING_APT (1.7min)
[07:57:58] Stage: INSTALLING_SOFTWARE (4.8min)
[07:58:42] Stage: INSTALLING_GRUB (5.5min)
[07:59:27] Stage: POWER_DOWN (6.2min)
[07:59:27] Power down detected, waiting 30s for shutdown...
[07:59:57] PowerState after shutdown wait: Off
[07:59:57] Installation completed successfully (PowerState Off, after 'Power down')
```

### machine-id mtime 検証

```
trial-1 start epoch    : 1778798742 (2026-05-15 07:45:42 JST)
remote /etc/machine-id : 1778799390 (2026-05-15 07:56:30 JST)
diff                   : +648s
verdict                : FRESH OK (>= start)
```

### Phase times

```
iso-download             0m11s
preseed-generate         0m23s
iso-remaster             0m10s   (reused: preseed sha256 matched)
bmc-mount-boot           5m36s   (find-boot-entry retry 3 + boot-override Cd UEFI fallback)
install-monitor          7m32s
post-install-config      7m02s
pve-install             19m47s   (apt + proxmox-ve + linstor + DRBD DKMS)
cleanup                  0m29s
total                   41m10s
```

### DRBD DKMS build (build-essential 修正の決定的証拠)

```
Get:36 http://deb.debian.org/debian trixie/main amd64 build-essential amd64 12.12 [4,624 B]
...
Selecting previously unselected package build-essential.
Preparing to unpack .../33-build-essential_12.12_amd64.deb ...
...
Selecting previously unselected package drbd-dkms.
Preparing to unpack .../55-drbd-dkms_9.3.2-1_all.deb ...
Unpacking drbd-dkms (9.3.2-1) ...
Setting up drbd-dkms (9.3.2-1) ...
Building initial module drbd/9.3.2-1 for 7.0.2-2-pve
Signing module /var/lib/dkms/drbd/9.3.2-1/build/./src/drbd/build-current/drbd.ko
Signing module /var/lib/dkms/drbd/9.3.2-1/build/./src/drbd/build-current/drbd_transport_tcp.ko
Signing module /var/lib/dkms/drbd/9.3.2-1/build/./src/drbd/build-current/drbd_transport_lb-tcp.ko
Signing module /var/lib/dkms/drbd/9.3.2-1/build/./src/drbd/build-current/drbd_transport_rdma.ko
Installing /lib/modules/7.0.2-2-pve/updates/dkms/drbd.ko
```

### find-boot-entry フォールバック (SKILL.md 新セクション検証)

```
$ ./scripts/bmc-power.sh find-boot-entry 10.10.10.24 claude Claude123 "ATEN Virtual CDROM"
Boot entry 'ATEN Virtual CDROM' not found, retry 1/3 in 15s...
Boot entry 'ATEN Virtual CDROM' not found, retry 2/3 in 15s...
ERROR: No boot entry matching 'ATEN Virtual CDROM' after 3 attempts

$ ./pve-lock.sh wait ./oplog.sh ./scripts/bmc-power.sh boot-override 10.10.10.24 claude Claude123 Cd UEFI
Boot override set: target=Cd mode=UEFI (once)
→ 電源 cycle → UEFI CD ブート成立 → Debian installer 開始
```

## 失敗時の根本原因 (該当する場合)

該当なし。1 trial で素直に通った。

## 親に戻すべき修正項目

該当なし。全 4 件の修正が動作確認済み:

1. `scripts/generate-preseed.sh` 非VLAN ブロック修正 — preseed 再生成で差分ゼロ、installer 進行 OK
2. `preseed/preseed-generated-s4.cfg` — re-gen で sha256 一致、installer 完走
3. `scripts/pve-setup-remote.sh` gcc → build-essential — drbd-dkms ビルド成功
4. `scripts/sol-monitor.py` 新フラグ — stage 検出のみで exit 0、フラグ受信正常
5. SKILL.md 新セクション (find-boot-entry フォールバック) — `boot-override Cd UEFI` で機能

## 補足観測

- `ssh-wait.sh` が SSH 復旧を検出できないケースが 2 回発生 (post-install 後、final reboot 後)。直接 `ssh -F ssh/config pve4 echo ok` は成功するため、SSH 認証/接続自体は問題ない。`ssh-wait.sh` 内部の判定ロジックに改善余地がある可能性 (タイミング・再試行間隔・初回失敗カウント等)。本 trial では手動 SSH 確認で先に進めたため致命的影響なし。要観察。
