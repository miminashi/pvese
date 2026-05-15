# server14 trial 5 (2026-05-15)

- **結果**: ✓ success (2 回目 attempt で完走)
- **wall**: ~107 分 (10:44 trial 5 開始 → 12:32 全フェーズ done) ※ 中間 5a 失敗を含む
- **attempts**: 2 (5a partman "No root file system" 失敗 → 5b 完走)

## preflight 確認結果

- preseed-server14.cfg mirror セクション: **CD-only 確認済** (trial 4 と同じ)
- PERC PD 状態 (trial 4 と同じ): Bay 0 Ready / 1+6 Online / 2-5,7 Ready
- Bay 0 converttoraid 実行: 不要 (Ready 維持)

## 修正の動作確認

### ✓ preseed 完全 CD-only 化で choose-mirror dialog 回避: yes (trial 4 と同じく動作)

### ✓ Bay 0 Ready 状態維持で partman duplicate VG 回避: yes (trial 4 と同じく)

### ✓ pkgsel/include から curl 削除で tasksel 失敗回避: yes ← trial 4 失敗からの新規 fix

trial 4 で確定したように `curl` は netinst CD に存在しないため除去した。trial 5b では tasksel "Select and install software" が **6:54 で完走**、`Cleaning up` 後すぐに INSTALLING_GRUB → POWER_DOWN へ進行。

### ✓ partman early_command で disk wipe — partman "No root file system" 回避: yes ← trial 5a 失敗からの新規 fix

trial 5a で発生した **"No root file system is defined"** dialog の原因は trial 4 install で sda に残った GPT + LVM 署名。`partman/early_command` で `wipefs -a /dev/sda` + `dd if=/dev/zero of=/dev/sda bs=1M count=10` + 末尾 GPT backup zero を追加して解消。trial 5b では partman 1 回成功 (vg `ayase-web-service-14-vg` + root LV 262.9GB + swap_1 LV 14.1GB)。

### ✓ build-essential install (trial 1-4 で未検証): 成功

`apt-get install -y build-essential` 完走 (12.12)。Phase 7 post-reboot 前に install しておくことで pve-setup-remote.sh 内の DKMS build 依存に備えた (今回は --linstor 未指定のため DKMS 自体は走らず)。

```
$ ssh pve14 dpkg -l build-essential | grep ^ii
ii  build-essential 12.12        amd64        Informational list of build-essential packages
```

### ✓ sol-monitor 新フラグ動作: 全 9 stages 検出 + Power down 検出で正常 exit 0

stage 検出ベースで installation 完了を捉えた。fallback (machine-id mtime / installer-syslog scan) は発火せず — Power down が SOL に明示出力されたため。

```
[11:14:24] Stage: LOADING_COMPONENTS (2.5min)
[11:14:24] Stage: DETECTING_NETWORK (2.5min)
[11:14:24] Stage: CONFIGURING_APT (2.5min)
[11:13:45] Stage: INSTALLING_SOFTWARE (5.6min)
[11:14:34] Stage: INSTALLING_GRUB (6.5min)
[11:14:55] Stage: POWER_DOWN (6.8min)
[11:14:55] Power down detected, waiting 30s for shutdown...
[11:15:33] PowerState after shutdown wait: Off
[11:15:33] Installation completed successfully (PowerState Off, after 'Power down')
```

## 全フェーズタイムライン (trial 5b、成功した attempt)

| Phase | 開始 | 終了 | 所要 |
|-------|------|------|------|
| iso-download | (済) | (済) | (再利用) |
| preseed-generate | (済) | (済) | - |
| iso-remaster | 11:05 | 11:06 | 1 min |
| bmc-mount-boot | 11:06 | 11:07 | 1 min |
| install-monitor | 11:08 | 11:15:33 | **6:54** ← 完走 |
| post-install-config (SSH 鍵配置・network) | 11:15 | 11:20 | 5 min |
| pve-install (pre-reboot + reboot + post-reboot + final reboot) | 11:20 | 12:25 | 65 min |
| cleanup (VM unmount + bridge setup) | 12:25 | 12:32 | 7 min |

合計 trial 5b: ~85 分

## 最終検証

```
$ ssh pve14 pveversion
pve-manager/9.1.11/8eac2c86f015bdda (running kernel: 7.0.2-2-pve)

$ ssh pve14 uname -r
7.0.2-2-pve

$ ssh pve14 ip route show default
default via 192.168.39.1 dev vmbr1

$ ssh pve14 ip -brief addr show vmbr0
vmbr0            UP             10.10.10.214/8 fe80::1a66:daff:fe61:807/64

$ ssh pve14 ip -brief addr show vmbr1
vmbr1            UP             192.168.39.159/24 fe80::1a66:daff:fe61:806/64

$ ssh pve14 systemctl is-active pveproxy
active

$ curl -ksk -o /dev/null -w '%{http_code}' https://10.10.10.214:8006/
200
```

## 詳細ログ抜粋

### partman early_command (新規追加)

```preseed
d-i partman/early_command string \
  wipefs -a /dev/sda 2>/dev/null || true; \
  dd if=/dev/zero of=/dev/sda bs=1M count=10 2>/dev/null || true; \
  dd if=/dev/zero of=/dev/sda bs=1M seek=$(($(blockdev --getsz /dev/sda) / 2048 - 10)) count=10 2>/dev/null || true; \
  partprobe /dev/sda 2>/dev/null || true; \
  :
```

これにより trial 5a で発生した "No root file system" dialog を **未然防止**。原因は trial 4 残留 GPT/LVM metadata が `partman-lvm/device_remove_lvm boolean true` で完全には消されなかったため。

### 親に戻すべき修正項目 (preseed-server14.cfg)

```diff
- d-i debian-installer/add-kernel-opts string console=tty0 console=ttyS1,115200n8
+ d-i debian-installer/add-kernel-opts string console=tty0 console=ttyS0,115200n8

+ d-i partman/early_command string \
+   wipefs -a /dev/sda 2>/dev/null || true; \
+   dd if=/dev/zero of=/dev/sda bs=1M count=10 2>/dev/null || true; \
+   dd if=/dev/zero of=/dev/sda bs=1M seek=$(($(blockdev --getsz /dev/sda) / 2048 - 10)) count=10 2>/dev/null || true; \
+   partprobe /dev/sda 2>/dev/null || true; \
+   :

- d-i pkgsel/include string openssh-server sudo curl wget gnupg
+ d-i pkgsel/include string openssh-server sudo wget gnupg

- d-i pkgsel/upgrade select full-upgrade
+ d-i pkgsel/upgrade select none
```

**preseed-server15.cfg にも同 4 件の修正を推奨**。15 号機は同じ R430 + PERC H730 + iDRAC8 のため同じ罠を踏む可能性が高い。

### SKILL.md (`os-setup`) への追記推奨

- `### R430 (PERC H730/H730P) 通しテスト前の preflight` セクションに `#### 3. preseed-server14/15.cfg の pkgsel/include は curl を含めない`
- 同セクションに `#### 4. preseed-server14/15.cfg は partman/early_command で disk wipe を行う` を追記推奨

## サマリ

trial 5b で全フェーズ完走。preseed mirror 修正 (trial 1-3 の確定 fix)、Bay 0 preflight (trial 3 の確定 fix)、pkgsel/include curl 削除 (trial 4 で新規発見)、partman early_command (trial 5a で新規発見) — **計 4 件の修正を経て R430 + iDRAC8 のフルセットアップが安定動作**することを確認した。
