# Phase 10: cmdline bisect — `vga=normal` / `nomodeset` / `quiet` の triple-fault トリガー単一特定 + wrapper template 修正

## Context

Phase 9 (`report/2026-05-22_071405_tx1320_raid10_phase9_remaster_cmdline_isolated.md`) で **`scripts/remaster-debian-iso.sh` が grub.cfg に書き込む cmdline (`vga=normal nomodeset auto=true priority=critical preseed/file=/preseed.cfg ...`) を stock 13.3.0 ISO の grub.cfg に 1 ファイルだけ差し替えるだけで Phase 8 iter11 と同じ 14 秒/cycle の triple-fault loop が再現** することを確定した。preseed cpio 注入や efi.img rebuild 等の重い改変は全て無罪。

Phase 9 の 4 つの test で残された切り分け不能箇所は **wrapper cmdline のどの flag が triple-fault のトリガーか** だけ。debconf 用 userspace flag (`auto=true`, `priority=critical`, `preseed/file=/preseed.cfg`, `locale=en_US.UTF-8`, `keymap=us`, `netcfg/choose_interface=auto`, `cdrom-detect/*`, `hw-detect/load_media=false`) は kernel が `---` 以降を init/preseed に転送するだけで kernel boot path には影響しない。よって候補は **`vga=normal`** (stock の `vga=788` から変更)、 **`nomodeset`** (新規追加)、および (低確率) **`console=tty0 console=ttyS0,115200n8`** (Phase 9 Test 3 で stock + console 追加で triple-fault しないことを既に確認 → ほぼ排除済) のいずれか。

Phase 10 の目的は (1) stock 13.3.0 ISO + grub.cfg 1 ファイル差し替えの bisect 3 通り (`vga=normal`単独 / `nomodeset`単独 / 両方) で triple-fault トリガー flag を単一文字レベルで特定し、(2) `scripts/remaster-debian-iso.sh` の 4 箇所 (UEFI grub.cfg / txt.cfg auto / txt.cfg install / efi.img embed.cfg) から該当 flag を削除し、(3) 修正版 wrapper で remaster ISO を再 build → NFS attach → boot し、SOL に Debian 13 installer の kernel printk が現れること (= 「インストーラを boot する」目標達成) を確認する。完了基準は `Kernel boot 成功まで` (preseed 完走は次フェーズ)。

## 設計

### Step A: bisect 用 stock+grub.cfg-patched ISO を 3 通り build

Phase 9 で実証された pipeline (`tmp/phase9-060436/build-stock-fullcmdline-iso.sh`) を再利用する。stock 13.3.0 ISO の `/boot/grub/grub.cfg` の `linux /install.amd/vmlinuz vga=788 --- quiet` 行を `sed` で書き換え、`xorriso -update` で 6 KB 1 ファイルだけ差し替える。 GRUB serial init (`serial --speed=115200 --unit=0`, `terminal_input serial console`) を grub.cfg 冒頭に prepend し、 triple-fault サイクルを SOL の `[H[J[1;1HLoading bootloader...` の繰り返しで観測できるようにする。

| Test | cmdline (kernel-affecting 部分のみ) | 期待 |
|------|-----------------------------------|------|
| **10-A** | `vga=normal --- quiet` (= stock cmdline の `vga=788` を `vga=normal` に変更しただけ) | これ単独で triple-fault するか? |
| **10-B** | `vga=788 nomodeset --- quiet` (= stock cmdline に `nomodeset` を追加しただけ) | これ単独で triple-fault するか? |
| **10-C** | `vga=normal nomodeset --- quiet` (両方適用、 debconf flag なし) | 両方で再現するか? |

`---` の前は kernel に作用、 `---` 以降 (`quiet`) は init/userspace に転送。各 test は GRUB に `console=tty0 console=ttyS0,115200n8` を kernel cmdline に追加 (Phase 9 Test 3 で triple-fault 無罪と既に確認、 kernel printk 観測のため)。完成 cmdline は例えば 10-A なら `vga=normal console=tty0 console=ttyS0,115200n8 --- quiet`。

ISO 名: `/var/samba/public/debian-13.3.0-amd64-netinst-bisect-{A,B,C}.iso` (playground 10.1.6.6 NFS export 上)。

### Step B: 各 ISO を NFS attach → boot → SOL + OEM screenshot で観測

Phase 9 の手順そのまま:
- `./scripts/irmc-virtualmedia.sh --share-type=NFS disconnect-cd ...` → `config` → `connect-cd` → `mount`
- `./scripts/bmc-power.sh boot-override 10.254.254.9 claude Claude123 Cd UEFI`
- `./scripts/bmc-power.sh on 10.254.254.9 claude Claude123` (PowerState=Off なら `On`; 既に On なら `./scripts/bmc-power.sh ForceOff` → 20 秒待機 → `on`)
- 背景で `python3 ./scripts/sol-monitor.py --timeout 480 --log-file tmp/<sid>/test{A,B,C}-sol.log`
- 並列で `./scripts/irmc-oem-screenshot.sh` を 30/60/120/180/240/300/360/420/480 秒で取得 (KVM canvas artifact 回避済の OEM Screenshot 経路)
- 各 test の完了後 `./scripts/bmc-power.sh ForceOff` で power off

判定基準:
- **triple-fault loop**: SOL log に `Loading bootloader...` が ~10-15 秒間隔で複数回出現 (Phase 9 Test 4 と同じ pattern、~14 秒/cycle で 8 分 = 30 回前後)
- **正常**: SOL log の `Loading bootloader...` は 1 回 (= GRUB chainload して kernel に jump、 PowerState=On 継続)、 kernel printk があれば installer 進行
- **silent hang**: `Loading bootloader...` 1 回 + kernel printk 0 行 + PowerState=On 継続 (Phase 9 Test 2/3 と同じ pattern、 kernel が printk 抑制中)

各 test は SOL monitor を 480 秒回せば十分判定可能 (Phase 9 Test 4 は 8 分で 34 cycles)。

### Step C: 結果分岐

| 10-A 結果 | 10-B 結果 | 10-C 結果 | 真因解釈 | 次の action |
|----------|----------|----------|---------|-------------|
| triple-fault | 正常/silent | triple-fault | `vga=normal` 単独 | wrapper から `vga=normal` だけ削除 (or `vga=788` に置換) |
| 正常/silent | triple-fault | triple-fault | `nomodeset` 単独 | wrapper から `nomodeset` だけ削除 |
| 正常/silent | 正常/silent | triple-fault | 組合せ必須 | wrapper から `vga=normal` と `nomodeset` の両方を削除 |
| triple-fault | triple-fault | triple-fault | 両方独立にトリガー | wrapper から両方削除 |
| 正常/silent | 正常/silent | 正常/silent | 想定外 → debconf flag が真因 | (補助) Step A2 で `auto=true priority=critical preseed/file=/preseed.cfg` だけ追加した 10-D を実行して subset bisect |

ベース cmdline (stock の `vga=788 --- quiet`) は Phase 9 Test 2 で 9 分 triple-fault なしを確認済。

### Step D: wrapper template 4 箇所から該当 flag を削除

修正対象は `scripts/remaster-debian-iso.sh` の以下 4 行 (全て kernel cmdline を含む):

| 行 | 文脈 | 現状 |
|----|------|------|
| **124** | UEFI grub.cfg menuentry | `linux /install.amd/vmlinuz vga=normal nomodeset auto=true ... console=ttyS${SERIAL_UNIT},115200n8 ${EXTRA_CMDLINE} --- quiet` |
| **134** | txt.cfg `auto` label (isolinux) | `append vga=normal nomodeset auto=true ... initrd=/install.amd/initrd.gz --- quiet` |
| **138** | txt.cfg `install` label (isolinux fallback) | `append vga=normal nomodeset initrd=/install.amd/initrd.gz --- quiet` |
| **197** | efi.img embed.cfg (grub-mkstandalone Option B) | `linux /install.amd/vmlinuz vga=normal nomodeset auto=true ... --- quiet` |

`vga=normal` のみが真因なら 4 箇所から `vga=normal ` (trailing space 込み) を削除。 `nomodeset` のみが真因なら 4 箇所から `nomodeset ` を削除。両方が真因なら両 token を削除し、kernel default の VGA 設定 + KMS で起動させる。

txt.cfg の `install` label (行 138) は手動 install fallback で `auto=true` 系を含まず `vga=normal nomodeset` のみだが、 同じ kernel 引数経路なので同一処置を施す。

### Step E: 修正版 wrapper で remaster ISO を build + boot 検証

修正後の `scripts/remaster-debian-iso.sh` を使って training-tx1320 用 ISO を build:

```sh
sh ./scripts/remaster-debian-iso.sh \
    -i /var/samba/public/debian-13.3.0-amd64-netinst.iso \
    -o /var/samba/public/debian-13.3.0-amd64-netinst-tx1320-phase10.iso \
    -p tmp/<sid>/preseed.cfg
```

preseed.cfg は `scripts/generate-preseed.sh` で training_tx1320 用に生成 (Phase 9 で使ったものを再利用、 storcli RAID detect + console=ttyS0 + USB attach + nfs root 対応)。 boot path:

```sh
./scripts/irmc-virtualmedia.sh --share-type=NFS config ... debian-13.3.0-amd64-netinst-tx1320-phase10.iso
./scripts/irmc-virtualmedia.sh --share-type=NFS connect-cd ...
./scripts/irmc-virtualmedia.sh --share-type=NFS mount ...
./scripts/bmc-power.sh boot-override 10.254.254.9 claude Claude123 Cd UEFI
./scripts/bmc-power.sh on 10.254.254.9 claude Claude123
python3 ./scripts/sol-monitor.py --bmc-ip 10.254.254.9 --bmc-user claude --bmc-pass Claude123 \
    --log-file tmp/<sid>/phase10-installer-sol.log --timeout 600
```

完了基準 (= 「インストーラを boot する」目標達成):
- SOL log に `Loading bootloader...` が **1 回のみ** (= GRUB → kernel chainload 後 triple-fault しない)
- SOL log に Debian installer の kernel printk が現れる (例: `[ 0.000000] Linux version` / `Booting kernel` / `cdrom-detect`系の Debian installer 出力)
- 望ましくは `INSTALLER_STAGES` (`scripts/sol-monitor.py` 内) のいずれかに match (例: `cdrom-detect`, `partman`, `base-installer`, `tasksel`, `grub-installer`)
- PowerState=On 継続 (warm-reset サイクルなし)

OEM screenshot で Debian installer の `Select a language` 画面 (or text-mode equivalent) が capture できれば確実。

## 主要ファイル

### 既存ファイル (修正対象)

| パス | 修正 | 内容 |
|------|------|------|
| `scripts/remaster-debian-iso.sh:124` | edit | UEFI grub.cfg cmdline から triple-fault flag 除去 |
| `scripts/remaster-debian-iso.sh:134` | edit | txt.cfg `auto` label cmdline から flag 除去 |
| `scripts/remaster-debian-iso.sh:138` | edit | txt.cfg `install` label cmdline から flag 除去 |
| `scripts/remaster-debian-iso.sh:197` | edit | efi.img embed.cfg cmdline から flag 除去 |

### 既存ファイル (再利用、 修正なし)

| パス | 用途 |
|------|------|
| `tmp/phase9-060436/build-stock-fullcmdline-iso.sh` | bisect ISO build テンプレ (sed で linux 行を書き換え + xorriso -update) |
| `tmp/phase9-060436/step1e-fullcmdline-prep.sh` | NFS attach + boot-override + power on の手順 |
| `tmp/phase9-060436/step1e-sol-monitor.sh` | sol-monitor 起動 |
| `tmp/phase9-060436/step1e-cap-loop.sh` | OEM screenshot loop |
| `tmp/phase9-060436/stock13-extract/grub.cfg` | stock 13.3.0 ISO から抽出済の grub.cfg (sed のベース) |
| `scripts/irmc-virtualmedia.sh` | NFS attach フロー (`--share-type=NFS`) |
| `scripts/bmc-power.sh` | boot-override / on / ForceOff / status |
| `scripts/irmc-oem-screenshot.sh` | iRMC OEM Screenshot (KVM canvas artifact 回避) |
| `scripts/sol-monitor.py` | SOL monitor (`INSTALLER_STAGES` 検出) |
| `config/training_tx1320.yml` | BMC IP / NFS host / serial_unit 等の定数 |

### 新規作成ファイル

`tmp/<sid>/` 配下に bisect 3 通り分:
- `build-bisect-A-iso.sh` (cmdline = `vga=normal --- quiet`)
- `build-bisect-B-iso.sh` (cmdline = `vga=788 nomodeset --- quiet`)
- `build-bisect-C-iso.sh` (cmdline = `vga=normal nomodeset --- quiet`)
- `attach-and-boot-bisect.sh <A|B|C>` (NFS attach + boot-override + power on のラッパ)
- `bisect-summary.md` (3 test の SOL log + OEM screenshot 集計)

Phase 9 の `build-stock-fullcmdline-iso.sh` (line 17 の `FULL_CMDLINE` 行) を copy & sed の置換 pattern を bisect 別に変更して作る。

## 検証

各 step ごとに以下を確認:

### Step A の検証 (bisect ISO build)

```sh
ls -la /var/samba/public/debian-13.3.0-amd64-netinst-bisect-{A,B,C}.iso
docker run --rm -v /var/samba/public/debian-13.3.0-amd64-netinst-bisect-A.iso:/in.iso:ro \
    debian:trixie sh -c 'apt-get update -qq && apt-get install -y -qq xorriso > /dev/null && xorriso -indev /in.iso -find /boot/grub/grub.cfg 2>&1 | head -3 && xorriso -osirrox on -indev /in.iso -extract /boot/grub/grub.cfg /tmp/g.cfg 2>&1 | tail -1 && grep linux /tmp/g.cfg'
```

→ linux 行に意図通りの cmdline が入っていることを確認。

### Step B/C の検証 (bisect 各 test の結果)

```sh
grep -c "Loading bootloader" tmp/<sid>/test{A,B,C}-sol.log
```

→ count > 5 なら triple-fault loop、 = 1 なら kernel jump 成功 (silent hang or normal boot)、 = 0 なら GRUB に到達せず (= 別の問題)。

```sh
grep -E "Linux version|cdrom-detect|partman|base-installer" tmp/<sid>/test{A,B,C}-sol.log
```

→ kernel printk が現れたら正常 boot。

### Step D の検証 (wrapper 修正)

```sh
grep -nE "vga=normal|nomodeset" scripts/remaster-debian-iso.sh
```

→ 修正方針に沿って該当 token が消えていること。 関連 4 行 (124/134/138/197) すべて整合していること。

### Step E の検証 (final installer boot)

```sh
grep -c "Loading bootloader" tmp/<sid>/phase10-installer-sol.log
grep -E "Linux version|cdrom-detect|partman|base-installer|tasksel|grub-installer" tmp/<sid>/phase10-installer-sol.log
```

→ `Loading bootloader` = 1, installer stage match >= 1 で 「installer boot 成功」 = Phase 10 目標達成。

OEM screenshot を 300/420/540 秒で取得し、Debian installer の text-mode menu (`Select a language` 等) または D-I curses UI が visible なら確実。

### レポート作成

`report/2026-05-22_<時刻>_tx1320_raid10_phase10_cmdline_bisect.md` を作成。 `REPORT.md` のフォーマットに従い:
- 添付: bisect 3 test の SOL log + OEM screenshot, 修正前後の `scripts/remaster-debian-iso.sh` diff, phase10 final ISO の SOL log + installer screenshot
- 知見セクション: 真因 flag (vga=normal / nomodeset / 組合せ) の最終確定、 D3373 + Debian 13.3 kernel 6.12.x との非互換性メカニズム (推測: D3373 の Aspeed VGA + Linux KMS 無効化 + framebuffer の組合せが triple-fault 誘発、 or vga=normal が UEFI framebuffer を有効に維持できない)
- Phase 10 で更新したメモリ entry: `MEMORY.md` 末尾の Phase 9 行の次に Phase 10 結果を追記。 必要なら `training_tx1320_phase10_cmdline_flag.md` を新規作成 (真因 flag を絞り込めた根拠 + 修正後の wrapper 状態 + installer boot 成功の根拠)。
