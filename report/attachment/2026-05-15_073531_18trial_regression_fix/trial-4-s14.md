# server14 trial 4 (2026-05-15)

- **結果**: ❌ failure
- **wall**: ~40 分 (09:58 boot → 10:39 abort)
- **attempts**: 1 (tasksel "Select and install software" 失敗 → 30 分間ループ → abort)

## preflight 確認結果

- preseed-server14.cfg mirror セクション: **CD-only 確認済** (`grep -n "mirror/" preseed/preseed-server14.cfg` → コメント行のみ、mirror/* 直接設定なし)
- PERC PD 状態 (Bay 0-7):
  - Bay 0: Ready (Raid mode、Non-Raid passthrough ではない、good)
  - Bay 1, 6: Online (OS_RAID1 VD0 メンバー、good)
  - Bay 2, 3, 4, 5, 7: Ready (good)
- Bay 0 converttoraid 実行: 不要 (既に Ready)

## 修正の動作確認

### ✓ preseed 完全 CD-only 化で choose-mirror dialog 回避: yes (Phase 1-2 通過)

trial 3 と異なり "Bad archive mirror" dialog は表示されず、apt-cdrom-setup, partman, ベースシステムインストールまで進行した。**preseed mirror 修正は完全動作**。

### ✓ Bay 0 Ready 状態維持で partman duplicate VG 回避: yes

partman は trial 4 で **1 回成功** (trial 3 は 2 回実行)。LVM vg `ayase-web-service-14-vg` + root LV + swap LV 構成で問題なく formatting 完了 → 「Partitions formatting」プログレスバー停止なし。

### ❌ build-essential install (trial 1-3 で未検証): 失敗 (Phase 7 到達せず)

tasksel "Select and install software" 段階で失敗ループに陥り、Phase 7 へ進めなかった。dkms status drbd は未取得。

### ✗ sol-monitor 新フラグ動作: stages=6 で 30 分連続 stuck、fallback 機能発火せず

`--installer-syslog`, `--static-ip`, `--ssh-config`, `--preseed-start-epoch` フラグ全て受理されたが、tasksel 失敗ループ中は machine-id mtime 取得 (SSH 不到達) も installer-syslog scan (UDP 5514 メッセージ受信なし) も結果を出さなかった。Stage progression が止まると fallback で前進できない。

## 失敗の根本原因 (新規発見)

**preseed `pkgsel/include` に `curl` が含まれているが、`curl` は Debian 13.3 netinst CD に存在しない**:

```sh
$ 7z l debian-13.3.0-amd64-netinst.iso | grep -E "/curl[/_]"
(空)

$ grep "pkgsel/include" preseed/preseed-server*.cfg
preseed-server7.cfg:  d-i pkgsel/include string openssh-server
preseed-server9.cfg:  d-i pkgsel/include string openssh-server
preseed-server14.cfg: d-i pkgsel/include string openssh-server sudo curl wget gnupg  ← curl 不在
preseed-server15.cfg: d-i pkgsel/include string openssh-server sudo curl wget gnupg
```

mirror=false の CD-only 環境で curl が見つからないと tasksel が `Installation step failed: Select and install software` ダイアログを表示し、**入力待ちで永久 stuck**。SOL ログには `[!!] Select and install software` ダイアログが byobu status bar 1:12 → 1:40 と 28 分間継続表示された後、何らかの reset で BIOS POST 再起動 (Virtual CD から GRUB ロード)。**reboot loop** で 198 回 `Configuring linux-image-6.12.63+deb13-amd64` が記録された。

副次的に `pkgsel/upgrade=full-upgrade` も mirror なし環境で問題化する可能性あり (server7-9 は `none`)。

## 適用した修正 (trial 5 で検証)

```diff
- d-i pkgsel/include string openssh-server sudo curl wget gnupg
+ d-i pkgsel/include string openssh-server sudo wget gnupg
- d-i pkgsel/upgrade select full-upgrade
+ d-i pkgsel/upgrade select none
```

同時に preseed の post-install kernel cmdline も serial_unit=0 と整合させた:
```diff
- d-i debian-installer/add-kernel-opts string console=tty0 console=ttyS1,115200n8
+ d-i debian-installer/add-kernel-opts string console=tty0 console=ttyS0,115200n8
```

## 詳細ログ抜粋

- partman 成功 (single pass):
  ```
  partman-lvm: PV /dev/sda3 → VG ayase-web-service-14-vg → root LV + swap_1 LV
  Partitions formatting 100% complete
  ```
- baseinstall + 大量パッケージ installed (linux-image-6.12.63+deb13-amd64 etc.) OK
- tasksel "standard" task 開始 → laptop-detect, save-logs まで成功 → 「Cleaning up」表示
- **エラー dialog** (byobu time 1:12 - 1:40):
  ```
  lqqqqqqqqqqqqqqqu [!!] Select and install software tqqqqqqqqqqqqqqqqk
  x Installation step failed                                                x
  x An installation step failed. You can try to run the failing item        x
  x again from the menu, or skip it and choose something else. The          x
  x failing step is: Select and install software                            x
  x                            <Continue>                                   x
  mqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqj
  ```
- 30 分後 BIOS POST 再起動 → GRUB 「Automated Install」を timer で再選択 → 再 install
- sol-monitor は stages=6 のまま 33 分間ポーリング (timeout 45 分到達せず手動 abort)

## 提案 (trial 5)

- preseed の `curl` 削除 + `pkgsel/upgrade=none` 適用済 (上記 diff)
- ISO 再 remaster + boot once VCD-DVD + sol-monitor 起動で trial 5 開始予定
