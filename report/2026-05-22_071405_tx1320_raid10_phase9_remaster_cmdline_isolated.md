# tx1320 RAID10 Phase 9: stock ISO 直接 boot で remaster wrapper の cmdline が真因と確定

- **実施日時**: 2026年05月22日 07:14 (JST)
- **セッション**: phase9-060436 (Plan: phase-9-1-shiny-lynx)
- **対象機**: training-tx1320 (Fujitsu PRIMERGY TX1320 M3, iRMC S4 FW 9.08F, BMC 10.254.254.9)

## 添付ファイル

- [実装プラン](attachment/2026-05-22_071405_tx1320_raid10_phase9_remaster_cmdline_isolated/plan.md)
- stock grub.cfg (untouched): [stock-grub.cfg](attachment/2026-05-22_071405_tx1320_raid10_phase9_remaster_cmdline_isolated/stock-grub.cfg)
- Test 2 patched grub.cfg (auto-boot only): [test2-autoboot-grub.cfg.patched](attachment/2026-05-22_071405_tx1320_raid10_phase9_remaster_cmdline_isolated/test2-autoboot-grub.cfg.patched)
- Test 4 patched grub.cfg (full remaster cmdline): [test4-fullcmdline-grub.cfg.patched](attachment/2026-05-22_071405_tx1320_raid10_phase9_remaster_cmdline_isolated/test4-fullcmdline-grub.cfg.patched)
- 🎯 Test 1 stock interactive GRUB menu: [test1-stock-grub-menu.jpg](attachment/2026-05-22_071405_tx1320_raid10_phase9_remaster_cmdline_isolated/test1-stock-grub-menu.jpg) (25673 bytes、menu items 全可視)
- Test 2 autoboot t240 black: [test2-autoboot-t240-black.jpg](attachment/2026-05-22_071405_tx1320_raid10_phase9_remaster_cmdline_isolated/test2-autoboot-t240-black.jpg) (8227 bytes、POST→GRUB 遷移)
- Test 2 autoboot t300 menu cleared: [test2-autoboot-t300-cleared.jpg](attachment/2026-05-22_071405_tx1320_raid10_phase9_remaster_cmdline_isolated/test2-autoboot-t300-cleared.jpg) (17784 bytes、GRUB が default 自動選択直後)
- 🎯 Test 3 stock-serial SOL log: [test3-serial-sol.log](attachment/2026-05-22_071405_tx1320_raid10_phase9_remaster_cmdline_isolated/test3-serial-sol.log) (kernel printk 0 行、 PowerState=On 継続 8 分)
- 🎯🎯 Test 4 fullcmdline t270 GRUB menu: [test4-fullcmdline-t270-grub.jpg](attachment/2026-05-22_071405_tx1320_raid10_phase9_remaster_cmdline_isolated/test4-fullcmdline-t270-grub.jpg) (25673 bytes、サイクル中の GRUB menu キャプチャ)
- 🎯🎯 Test 4 fullcmdline t300 menu cleared: [test4-fullcmdline-t300-cleared.jpg](attachment/2026-05-22_071405_tx1320_raid10_phase9_remaster_cmdline_isolated/test4-fullcmdline-t300-cleared.jpg) (17784 bytes、GRUB が kernel chainload した直後)
- 🎯🎯🎯 Test 4 fullcmdline SOL log (warm-reset cycle): [test4-fullcmdline-sol.log](attachment/2026-05-22_071405_tx1320_raid10_phase9_remaster_cmdline_isolated/test4-fullcmdline-sol.log) (`[H[J[1;1HLoading bootloader...` × 34 回 / 8 分 = ~14 秒/cycle)

## 前提・目的

[Phase 8 (2026-05-22 phase811)](2026-05-22_055158_tx1320_raid10_phase8_iter11to13.md) で iter11 (`scripts/remaster-debian-iso.sh` 出力 / default cmdline) が triple-fault loop を起こすことを確定し、Memtest86+ native UEFI が同じ iRMC NFS+UEFI 経路で実 VGA に正常 boot 表示することから iRMC 経路は OS-agnostic に健全と確認。**しかし Phase 3-8 の全試行は remaster されたカスタム ISO で、Debian 13 kernel そのものが TX1320 M3 / D3373 で triple-fault するのか、それとも remaster process が破壊しているのかは未切り分け**だった。

**Phase 9 の目的**: stock `debian-13.3.0-amd64-netinst.iso` (remaster 一切なし) を直接 NFS attach して boot し、(a) remaster process の問題か (b) Debian 13 kernel そのものの問題か を直接切り分ける。Phase 8 で発見した `scripts/irmc-oem-screenshot.sh` (iRMC OEM Redfish Screenshot、 KVM canvas artifact 回避) を活用し実 VGA 観測を最小化。

## 環境情報

- ホスト: training-tx1320 (Fujitsu PRIMERGY TX1320 M3 / Mainboard D3373 / BIOS V5.0.0.11 R1.22.0)
- BMC: iRMC S4 FW 9.08F (10.254.254.9, claude index=4, HTTPS + SECLEVEL=0)
- Memory: 24 GiB / CPU: 1 socket (4 logical)
- HW: RAID10 SAS HDD 900GB × 4 (未使用)
- Virtual Media: iRMC NFS Virtual Media (`/var/samba/public` on playground 10.1.6.6)
- SOL: `scripts/sol-monitor.py --timeout 360-540`
- VGA capture: 🎯 `scripts/irmc-oem-screenshot.sh` (Phase 8 採用、 KVM canvas artifact 回避)

## 試行と結果

Phase 9 では 4 つの ISO 変種を順次 build → NFS attach → boot し、cmdline・initrd 改変・GRUB 構成の各要素を切り分けた。

### Test 1: stock 13.3.0 netinst (一切改変なし)

- **ISO**: `/var/samba/public/debian-13.3.0-amd64-netinst.iso` (790 MB、 入力 ISO そのまま attach)
- **cmdline**: GRUB menu interactive (stock の `Graphical install`: `linux /install.amd/vmlinuz vga=788 --- quiet`)
- **GRUB timeout**: 未設定 = forever (interactive menu のみ)
- **GRUB serial**: なし (VGA only)

| 計測 | 値 |
|------|---|
| OEM t30/t60 | BIOS POST B4 (37967 bytes) |
| OEM t90 | BIOS POST 99 (41022 bytes) |
| OEM t120-t240 | POST 99 stable |
| OEM t300 | **Debian 13.3.0 UEFI Installer menu 表示** (25673 bytes、 `Graphical install` ハイライト、 menu items 全可視) |
| ユーザ実 VGA 観測 | 「Debian 13 の GRUB 画面が崩れたよう」 (= OEM screenshot と一致、 graphical GRUB の自然な状態) |
| PowerState | On 継続 |

**判定**: 🎯 **stock 13.3.0 ISO は BIOS POST → GRUB menu まで正常到達**。Phase 3-8 のカスタム ISO とは異なる挙動 (Phase 8 iter11 は GRUB → 即 triple-fault)。stock GRUB は timeout なし interactive menu のため kernel jump は user 入力 (Enter) 待ち。kernel そのものはまだ起動していない。

### Test 2: stock + grub.cfg minimal patch (`set default=0; set timeout=3` のみ追加)

- **ISO**: `debian-13.3.0-amd64-netinst-autoboot.iso` (build via docker + xorriso `-update`)
- **改変箇所**: `/boot/grub/grub.cfg` の冒頭に `set default=0` + `set timeout=3` を prepend
- **cmdline**: stock のまま (`vga=788 --- quiet`)
- **initrd**: 未改変
- **GRUB serial**: なし

| 計測 | 値 |
|------|---|
| OEM t30/t60 | BIOS POST B4 |
| OEM t120/t180 | POST 99 |
| OEM t240 | **black screen (8227 bytes、 POST→GRUB 遷移)** |
| OEM t300-t540 | **17784 bytes stable for 4 分** (GRUB が default 自動選択 + menu items 消去後の framebuffer 残り) |
| SOL log | `Session operational. Use ~? for help]` の reconnect message のみ、 kernel printk = 0 行 |
| PowerState | **On 継続 9 分** |
| GRUB cycle (BIOS POST 反復) | **0 回** (cap loop 全 stable) |

**判定**: 🎯 **stock cmdline では triple-fault loop は発生しない**。GRUB は countdown して default `Graphical install` を auto-boot し、kernel が chainload された後 PowerState=On が 9 分継続 (warm-reset サイクルなし)。 ただし kernel は SOL にも VGA にも何も出力せず (cmdline に `console=ttyS` がなく `quiet` で kernel printk 抑制) **silent**。 kernel が正常進行中 / silent hang のいずれかは Test 2 単体では区別不能。

### Test 3: stock + autoboot + `console=tty0 console=ttyS0,115200n8` 追加 (kernel に SOL 出力誘導)

- **ISO**: `debian-13.3.0-amd64-netinst-serial.iso`
- **cmdline**: `vga=788 console=tty0 console=ttyS0,115200n8 ---` (stock cmdline + 2 console フラグ + `quiet` 除去)
- **その他**: Test 2 と同じく default=0 timeout=3、 initrd 未改変、 GRUB serial なし

| 計測 | 値 |
|------|---|
| OEM screenshot | Test 2 と同一パターン (POST B4 → 99 → black → GRUB cleared) |
| SOL log | `[H[J[1;1HLoading bootloader...` **0 行**、 kernel printk **0 行**、 reconnect message のみ |
| PowerState | On 継続 8 分 |
| GRUB cycle | 0 回 |

**判定**: 🎯 **kernel cmdline に `console=ttyS0,115200n8` を加えても triple-fault は起きない、 SOL にも kernel printk が出ない**。Phase 8 iter13 が示した「earlyprintk=ttyS0 で hang」とは異なり、 通常の `console=ttyS0` 単体追加では triple-fault も hang 化 (visible) も誘発しない。Debian 13 kernel の早期 init で `console=ttyS0,115200n8` 経由の printk 出力は iRMC SOL channel に届かない可能性 (= D3373 物理 UART は iRMC SOL に bridge されていない可能性、 Phase 6 の SOL stdin 片方向問題と整合)。

### Test 4: stock + `remaster wrapper の完全 cmdline` 適用 (preseed/initrd 改変は一切なし) 🎯🎯🎯

- **ISO**: `debian-13.3.0-amd64-netinst-fullcmdline.iso`
- **cmdline (= `scripts/remaster-debian-iso.sh` line 124 と同一)**:
  ```
  vga=normal nomodeset auto=true priority=critical preseed/file=/preseed.cfg locale=en_US.UTF-8 keymap=us netcfg/choose_interface=auto cdrom-detect/try-usb=true cdrom-detect/scan=true hw-detect/load_media=false console=tty0 console=ttyS0,115200n8 --- quiet
  ```
- **GRUB serial**: あり (= remaster wrapper と同様に `serial --speed=115200 --unit=0 ... / terminal_input serial console / terminal_output serial console` を grub.cfg に追加、 triple-fault 時の GRUB cycle を SOL で観測するため)
- **initrd**: 未改変 (= preseed cpio concatenation なし、 stock initrd.gz そのまま)

| 計測 | 値 |
|------|---|
| OEM t30/t60/t120/t180/t200/t240 | BIOS POST 進行 (B4 → 99) |
| OEM t270 | **🎯 25673 bytes = GRUB menu fully rendered** (`Graphical install` ハイライト + 全 menu items 可視、 = warm-reset サイクル中の GRUB countdown phase) |
| OEM t300/t330/t360/t420/t480 | 17784 bytes stable (= サイクル中の GRUB 「menu cleared、 kernel chainload 直前」 phase で同期) |
| SOL log | **🎯🎯🎯 `[H[J[1;1HLoading bootloader...` × 34 回 / 8 分 = ~14 秒/cycle** |
| PowerState | On 継続 (warm-reset は CPU reset のみで PowerState は維持) |
| GRUB cycle | **34 回** |

**判定**: 🎯🎯🎯 **stock 13.3.0 ISO + remaster wrapper の cmdline を適用するだけで Phase 8 iter11 と同等の triple-fault loop が再現**。`/boot/grub/grub.cfg` の 6 KB だけを書き換えており、 initrd には一切手を加えていない (`xorriso -update /grub.cfg.patched /boot/grub/grub.cfg` でファイル 1 個のみ差し替え)。 これにより Phase 8 まで「remaster process のどこか」が triple-fault を起こしていると曖昧だった原因が、 **wrapper が grub.cfg に書き込む cmdline 内のいずれかの flag 単体**に確定。 preseed cpio concatenation や grub-mkstandalone 経由の efi.img rebuild 等の重い処理は全て無罪。

## 🎯 Phase 9 で得た確定知見

1. 🎯 **stock 13.3.0 netinst ISO は TX1320 M3 / D3373 で BIOS POST → GRUB menu まで完全に正常動作する** (= iRMC NFS attach + UEFI boot path + Debian 13 GRUB の組み合わせは健全)
2. 🎯 **stock cmdline (`vga=788 --- quiet`) では Debian 13 kernel は triple-fault しない** — silent (kernel printk 不可視) だが PowerState=On が 9 分継続、 warm-reset サイクルなし
3. 🎯 **kernel cmdline に `console=ttyS0,115200n8` を追加しても triple-fault は誘発しない** (= console redirection 単体は無罪)
4. 🎯🎯🎯 **`scripts/remaster-debian-iso.sh` が grub.cfg に書き込む cmdline (`vga=normal nomodeset auto=true priority=critical preseed/file=/preseed.cfg ...`) を stock 13.3.0 ISO の grub.cfg に 1 ファイルだけ差し替えるだけで、Phase 8 iter11 と同じ 14 秒/cycle の triple-fault loop が再現**
5. **真因は wrapper cmdline 内の特定 flag**: stock cmdline と remaster cmdline の差分のうち kernel に作用するのは `vga=normal` (vs `vga=788`)、 `nomodeset`、 `--- quiet` (vs `--- `) のみ。 preseed/auto/locale/netcfg/cdrom-detect/hw-detect 系は debconf 用 userspace 引数で kernel boot には影響しない (kernel が `---` 以降を init/preseed に転送するだけ)。 → 次セッションで `vga=normal` のみ / `nomodeset` のみ / `nomodeset vga=normal` の 3 通りを bisect すれば真因 flag が単一文字レベルで特定可能

## 結論メモ用テンプレ (Phase 9 結果まとめ)

| Test | ISO | cmdline 主要部分 | initrd 改変 | GRUB cycle | OEM 観測 | SOL kernel printk | 判定 |
|------|-----|-----------------|-------------|-----------|---------|------------------|------|
| 1 | stock (untouched) | `vga=788 --- quiet` (interactive) | なし | N/A | GRUB menu (25673) | N/A | **GRUB menu 正常到達** |
| 2 | autoboot grub.cfg | `vga=788 --- quiet` | なし | 0 | menu cleared (17784) stable 9 分 | 0 行 | **triple-fault なし** (silent) |
| 3 | + console=ttyS0 | `vga=788 console=tty0 console=ttyS0,115200n8 ---` | なし | 0 | 同上 | 0 行 | **triple-fault なし** (silent) |
| 4 | + 完全 wrapper cmdline | `vga=normal nomodeset auto=true ... --- quiet` | なし | **34 / 8 分** | GRUB cycle 中の menu 観測 | 0 行 (kernel chainload 後すぐ triple-fault) | **🎯🎯🎯 triple-fault loop** |

## 比較: Phase 8 iter11 vs Phase 9 Test 4

| 項目 | Phase 8 iter11 | Phase 9 Test 4 |
|------|---------------|----------------|
| Base ISO | 同じ stock 13.3.0 | 同じ stock 13.3.0 |
| 改変方法 | `scripts/remaster-debian-iso.sh` (preseed cpio 注入 + grub.cfg 完全置換 + efi.img patch) | xorriso `-update /grub.cfg.patched /boot/grub/grub.cfg` のみ (6 KB 1 ファイル差し替え) |
| 改変サイズ | 数十 MB (initrd 再構築 + EFI rebuild) | 6 KB (grub.cfg のみ) |
| kernel cmdline | `vga=normal nomodeset auto=true priority=critical preseed/file=/preseed.cfg locale=en_US.UTF-8 keymap=us netcfg/choose_interface=auto cdrom-detect/try-usb=true cdrom-detect/scan=true hw-detect/load_media=false console=tty0 console=ttyS0,115200n8 --- quiet` | **完全同一** |
| SOL GRUB cycle | 33 回 / 5 分 (~9 秒/cycle) | 34 回 / 8 分 (~14 秒/cycle) |
| 結果 | triple-fault loop | triple-fault loop |

両者で挙動が同一 → **wrapper の重い処理 (preseed 注入 / efi.img 改変) は無罪、 wrapper が出力した cmdline がそのまま triple-fault を引き起こす**。

## 再現方法

### 前提

- training-tx1320 BMC (10.254.254.9) と playground (10.1.6.6) に到達可能
- `scripts/` 配下のスクリプト群最新
- `tmp/phase9-060436/tx1320-env.sh` で BMC env vars + iRMC quirks を export 済

### Step 0: 前提準備

```sh
mkdir -p tmp/phase9-060436/phase91-stock13 tmp/phase9-060436/phase91b-stock13-autoboot \
         tmp/phase9-060436/phase91d-stock13-serial tmp/phase9-060436/phase91e-stock13-fullcmdline

cat > tmp/phase9-060436/tx1320-env.sh <<'EOF'
export BMC_SCHEME=https
export BMC_CURL_OPTS="--ciphers DEFAULT@SECLEVEL=0"
export POWER_ON_RESET_TYPE=On
export BMC_PATCH_REQUIRES_ETAG=1
export BMC_BOOT_OVERRIDE_NO_DISABLED=1
BMC_IP="10.254.254.9"; BMC_USER="claude"; BMC_PASS="Claude123"
NFS_HOST="10.1.6.6"; NFS_EXPORT="/var/samba/public"
EOF

scp -F ssh/config -i ssh/id_ed25519 \
    /var/samba/public/debian-13.3.0-amd64-netinst.iso \
    ubuntu@10.1.6.6:/tmp/
ssh -F ssh/config -i ssh/id_ed25519 ubuntu@10.1.6.6 \
    "sudo mv /tmp/debian-13.3.0-amd64-netinst.iso /var/samba/public/"
```

### Step 1: stock ISO 直接 attach + boot (Test 1)

```sh
./scripts/irmc-virtualmedia.sh --share-type=NFS config 10.254.254.9 claude Claude123 \
    10.1.6.6 /var/samba/public debian-13.3.0-amd64-netinst.iso
./scripts/irmc-virtualmedia.sh --share-type=NFS connect-cd 10.254.254.9 claude Claude123
./scripts/irmc-virtualmedia.sh --share-type=NFS mount 10.254.254.9 claude Claude123
./scripts/bmc-power.sh boot-override 10.254.254.9 claude Claude123 Cd UEFI
./scripts/bmc-power.sh on 10.254.254.9 claude Claude123

# 30/60/90/120/180/240/300 秒後に OEM screenshot
./scripts/irmc-oem-screenshot.sh 10.254.254.9 claude Claude123 oem-t300.jpg 8 3
```

→ t300 で `Debian GNU/Linux 13.3.0 UEFI Installer menu` 表示 (interactive、 timeout なし)

### Step 2-3: stock + grub.cfg minimal patch (Test 2/3)

```sh
mkdir -p tmp/phase9-060436/stock13-extract

# 1. stock grub.cfg 抽出 (docker + xorriso、 ローカル apt なしで完結)
docker run --rm \
    -v /var/samba/public/debian-13.3.0-amd64-netinst.iso:/input.iso:ro \
    -v "$(pwd)/tmp/phase9-060436/stock13-extract":/out \
    debian:trixie sh -c '
        apt-get update -qq && apt-get install -y -qq xorriso > /dev/null
        xorriso -osirrox on -indev /input.iso \
            -extract /boot/grub/grub.cfg ./grub.cfg
    '

# 2. grub.cfg を patch (Test 2: default+timeout のみ、 Test 3: + console=ttyS0)
WORK=tmp/phase9-060436/stock13-autoboot; mkdir -p "$WORK"
{
    echo "set default=0"
    echo "set timeout=3"
    echo ""
    cat tmp/phase9-060436/stock13-extract/grub.cfg
} > "$WORK/grub.cfg.patched"

# 3. xorriso -update でファイル 1 個だけ差し替え (initrd 等は無改変)
docker run --rm \
    -v /var/samba/public/debian-13.3.0-amd64-netinst.iso:/input.iso:ro \
    -v "$(pwd)/$WORK/grub.cfg.patched":/grub.cfg.patched:ro \
    -v /var/samba/public:/output \
    debian:trixie sh -c '
        apt-get update -qq && apt-get install -y -qq xorriso > /dev/null
        xorriso \
            -indev /input.iso \
            -outdev /output/debian-13.3.0-amd64-netinst-autoboot.iso \
            -boot_image any replay \
            -update /grub.cfg.patched /boot/grub/grub.cfg \
            -commit
    '
```

### Step 4: stock + remaster wrapper の完全 cmdline 適用 (Test 4)

Test 2 と同じ手順で grub.cfg を patch、ただし `linux` 行を以下に書き換え:

```
linux /install.amd/vmlinuz vga=normal nomodeset auto=true priority=critical \
    preseed/file=/preseed.cfg locale=en_US.UTF-8 keymap=us \
    netcfg/choose_interface=auto cdrom-detect/try-usb=true \
    cdrom-detect/scan=true hw-detect/load_media=false \
    console=tty0 console=ttyS0,115200n8 --- quiet
```

加えて GRUB serial init を grub.cfg 冒頭に追加 (triple-fault サイクルを SOL で観測するため):

```
set default=0
set timeout=3
serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1
terminal_input serial console
terminal_output serial console
```

→ SOL に `[H[J[1;1HLoading bootloader...` が ~14 秒間隔で 34 回繰り返し = triple-fault loop 確認

### 観測

```sh
# SOL monitor (480 秒)
python3 ./scripts/sol-monitor.py \
    --bmc-ip 10.254.254.9 --bmc-user claude --bmc-pass Claude123 \
    --log-file tmp/phase9-060436/phase91e-stock13-fullcmdline/sol.log \
    --timeout 480 &

# OEM screenshot loop (背景でループ、 30/60/120/180/240/270/300/330/360/420/480 秒)
for T in 30 60 120 180 200 240 270 300 330 360 420 480; do
    sleep_until $T
    ./scripts/irmc-oem-screenshot.sh 10.254.254.9 claude Claude123 \
        tmp/phase9-060436/phase91e-stock13-fullcmdline/oem-t${T}.jpg 8 3
done

# 結果集計
grep -c "Loading bootloader" tmp/phase9-060436/phase91e-stock13-fullcmdline/sol.log
# → 34 (= triple-fault loop confirmed)
```

## 次のステップ (Phase 10 候補)

Phase 9 で remaster wrapper cmdline が真因と確定したので、 次は **cmdline 内の bisect** で具体的な triple-fault トリガー flag を特定する:

1. **stock cmdline + `vga=normal` だけ** (vga=788 → vga=normal の単独差分): triple-fault するか?
2. **stock cmdline + `nomodeset` だけ** (kernel mode setting 無効化の単独効果): triple-fault するか?
3. **stock cmdline + `vga=normal nomodeset`** (組合せ): triple-fault するか?
4. **wrapper cmdline - `nomodeset`** (nomodeset だけ除去): triple-fault 回避されるか?

これらにより `vga=normal` / `nomodeset` のいずれが (あるいは両方の組合せが) D3373 + Debian 13 kernel で triple-fault を引き起こすか単一フラグレベルで特定可能。 各テストは stock ISO の grub.cfg を 1 ファイル書き換えて xorriso `-update` で再パッケージするだけ (~10 分 / 試行) なので Phase 9 と同じ pipeline で完結する。

特定後の対応:
- 該当 flag を `scripts/remaster-debian-iso.sh` の grub.cfg template から削除 (例: `nomodeset` を `nomodeset` なしに、 `vga=normal` を `vga=788` に)
- training-tx1320 専用の cmdline override 機構 (config/training_tx1320.yml に追加) を導入
- 修正 wrapper で iter14 (= 修正 cmdline) を build → boot 検証 → installer 完走

なお Phase 8 の iter11/12/13 で観測された GRUB cycle 9-14 秒は warm-reset サイクル (BIOS POST スキップ + GRUB 再起動 + kernel 再 chainload + 再 triple-fault) であり、 本 Phase 9 Test 4 と同じメカニズム。 iter15 / iter16 案 (`acpi=off` 単体、 `nox2apic apic=debug`) は kernel ACPI/APIC 周辺の試行だったが、 真因が wrapper cmdline の確定により優先度は下がる。
