# server14 trial 3 (2026-05-15)

- **結果**: ❌ failure (3 trial 連続失敗 → giveup)
- **wall**: ~42 分 (09:08 boot → 09:51 sol-monitor timeout)
- **attempts**: 1 (sol-monitor timeout 2700s 上限到達)
- **主要事象**:
  - Bay 0 を Non-Raid → Ready に converttoraid 済 (controller 視点で disk passthrough 隠蔽)
  - SOL に POST → kernel → installer 順調
  - installer-syslog: partman が **2 回成功** (00:04 と 00:10、同じ ayase-web-service-14-vg を /dev/sda3 上で作成)
  - in-target apt install (linux-image, lvm2 等) 成功
  - **再び apt-setup で "Bad archive mirror"**:
    ```
    <13>May 15 00:12:31 load-install-cd: W: Failed to mount '/dev/sr1'
    <15>May 15 00:12:31 choose-mirror[30610]: DEBUG: command: wget ... deb.debian.org
    <12>May 15 00:12:31 choose-mirror[30610]: WARNING **: mirror does not support ...
    ```
  - **trial 2 で `apt-setup/use_mirror=false` に変更したのに choose-mirror が依然 run**: preseed の `mirror/country string manual` + `mirror/http/hostname string deb.debian.org` の **mirror/\* 行が `apt-setup/use_mirror=false` を override** している
  - sol-monitor stages=5 で 30 分連続 stuck → 2700s タイムアウトで exit 1

## 修正の動作確認 (リグレッション検出)

- Bay 0 converttoraid で **partman duplicate VG 問題解決** (これは新規 fix、preseed ではない)
- preseed-server14.cfg の `mirror/*` 行が `apt-setup/use_mirror=false` を override する debconf 仕様により、CD-only 化が **不完全** だった (trial 2 修正は不十分)
- 完全修正には server7.cfg のように **mirror/\* 行を全削除** + `apt-setup/non-free-firmware true` 追加が必要 (trial 3 終了後に preseed 適用済、ISO 未 remaster)
- LVM Bay 1+6: partman 動作確認済 (VG/LV 作成成功 x2)
- build-essential: 未検証 (Phase 7 到達せず)
- sol-monitor 新フラグ: `--installer-syslog`, `--static-ip`, `--preseed-start-epoch`, `--ssh-config` 全て受理されたが stages=5 から進まず timeout (machine-id mtime fallback は SSH 不到達のため呼ばれず)

## 前回 20 trial training との挙動差分

- 前回も同じ "Bad archive mirror" を踏んだはず (preseed が同じ regression を保持)
- 前回どう成功したか不明 — DHCP 経由で internet 到達できた偶然か、preseed が違ったか
- Bay 0 passthrough 問題は今回新規 (HBA mode 切替 + RAID mode 復旧の副作用、issue #64 由来)

## 詳細ログ抜粋

```
<13>May 15 00:04:15 partman-lvm:   Labels on physical volume "/dev/sda3" successfully wiped.
<13>May 15 00:04:19 partman-lvm:   Volume group "ayase-web-service-14-vg" successfully created
<13>May 15 00:10:23 partman-lvm:   Logical volume "root" successfully removed.  (← partman 2 回目、auto-confirm 動作)
<13>May 15 00:10:27 partman-lvm:   Physical volume "/dev/sda3" successfully created.
<13>May 15 00:10:28 partman-lvm:   Logical volume "root" created.
<13>May 15 00:11:17 in-target: ...debian-kernel-handbook grub-pc | grub-efi-amd64 | extlinux
<13>May 15 00:12:31 load-install-cd: W: Failed to mount '/dev/sr1' to '/media/cdrom/'
<12>May 15 00:12:31 choose-mirror[30610]: WARNING **: mirror does not support the specified release (trixie)
... (沈黙、30 分の byobu status bar 進行のみ)
[09:51:21] Timeout reached (2699.999979496002s) — sol-monitor exit 1
```

## Giveup 報告

3 trial 連続失敗:
1. trial-1: preseed `apt-setup/use_mirror=true` の mgmt-only NIC で mirror 到達不可 → Bad archive mirror dialog
2. trial-2: trial-1 残留の LVM が Bay 0 passthrough (`/dev/sdb`) で expose、partman で同名 VG duplicate stuck
3. trial-3: `apt-setup/use_mirror=false` に変更したが preseed の `mirror/*` 行が依然 choose-mirror を trigger、再び Bad archive mirror dialog

## 提案 (parent への引き継ぎ)

preseed-server14.cfg は完全 CD-only にする必要がある (server7-9 と同等):
1. **`d-i mirror/country`, `d-i mirror/http/*` 行を全削除** (trial 3 終了後に適用済、要 ISO remaster)
2. **`d-i apt-setup/cdrom/set-next boolean false`** (`true` だと next CD を待つ)
3. **`d-i apt-setup/non-free-firmware boolean true`** 追加 (Debian 13 で重要)
4. **Bay 0 を Ready 状態に維持** (Non-Raid passthrough にしない)

これらを適用して 4 回目を実行すれば成功する見込み。本タスクの 3-trial 上限内では検証できなかった。
