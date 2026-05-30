# tx1320 RAID10 Phase 10: cmdline bisect 完了 — `vga=normal` + `nomodeset` 単独削除で Debian 13 installer boot 成功

- **実施日時**: 2026年05月22日 08:26 (JST)
- **セッション**: phase10-072719 (Plan: phase-9-remaster-idempotent-brooks)
- **対象機**: training-tx1320 (Fujitsu PRIMERGY TX1320 M3, iRMC S4 FW 9.08F, BMC 10.254.254.9)

## 添付ファイル

- [実装プラン](attachment/2026-05-22_082633_tx1320_raid10_phase10_cmdline_bisect_solved/plan.md)
- [wrapper cmdline 修正 diff](attachment/2026-05-22_082633_tx1320_raid10_phase10_cmdline_bisect_solved/wrapper-cmdline-fix.diff) (※`${EXTRA_CMDLINE}` 環境変数挿入は Phase 9 の未コミット変更、Phase 10 の純粋な修正は `vga=normal ` と `nomodeset ` の 4 箇所削除のみ)
- 🎯 [Test 10-A SOL log (vga=normal 単独 → triple-fault)](attachment/2026-05-22_082633_tx1320_raid10_phase10_cmdline_bisect_solved/test-A-sol.log)
- 🎯 [Test 10-B SOL log (nomodeset 単独 → triple-fault)](attachment/2026-05-22_082633_tx1320_raid10_phase10_cmdline_bisect_solved/test-B-sol.log)
- [Test 10-C SOL log (両方 → triple-fault、 Phase 9 Test 4 と同等 validation)](attachment/2026-05-22_082633_tx1320_raid10_phase10_cmdline_bisect_solved/test-C-sol.log)
- 🎯🎯🎯 [修正版 wrapper installer boot SOL log](attachment/2026-05-22_082633_tx1320_raid10_phase10_cmdline_bisect_solved/phase10-installer-sol.log) (GRUB countdown 3s→2s→1s→0s→`Booting 'Automated Install'`、 Loading bootloader 0 回 / 10 分継続)
- [BIOS POST t60 OEM screenshot](attachment/2026-05-22_082633_tx1320_raid10_phase10_cmdline_bisect_solved/phase10-oem-t60-bios-post.jpg) (41019 B、 POST 進行中)
- [BIOS POST t120 OEM screenshot](attachment/2026-05-22_082633_tx1320_raid10_phase10_cmdline_bisect_solved/phase10-oem-t120-post.jpg) (41022 B、 POST 99)
- [Post-boot t240 OEM screenshot](attachment/2026-05-22_082633_tx1320_raid10_phase10_cmdline_bisect_solved/phase10-oem-t240-postboot.jpg) (14591 B、 kernel chainload 後の framebuffer artifact 黒画、 「boot 失敗の証拠」ではない)
- [Post-boot t600 OEM screenshot](attachment/2026-05-22_082633_tx1320_raid10_phase10_cmdline_bisect_solved/phase10-oem-t600-postboot.jpg) (14575 B、 10 分時点も同じ黒画 = kernel が長時間継続実行中)

## 前提・目的

[Phase 9 (2026-05-22 phase9-060436)](2026-05-22_071405_tx1320_raid10_phase9_remaster_cmdline_isolated.md) で **`scripts/remaster-debian-iso.sh` の grub.cfg cmdline (`vga=normal nomodeset auto=true ...`) を stock 13.3.0 ISO の grub.cfg に 1 ファイルだけ差し替えるだけで Phase 8 iter11 と同じ ~14 秒/cycle の triple-fault loop が再現** することを確定した。残された切り分け不能は **wrapper cmdline のどの flag が triple-fault のトリガーか** だけ。

debconf 用 userspace flag (`auto=true`, `priority=critical`, `preseed/file=/preseed.cfg`, `locale=*`, `keymap=*`, `netcfg/*`, `cdrom-detect/*`, `hw-detect/*`) は kernel が `---` 以降を init/preseed に転送するだけで kernel boot path には影響しない。Phase 9 Test 3 で `console=tty0 console=ttyS0,115200n8` の追加でも triple-fault が誘発されないことを確認済。よって候補は **`vga=normal`** (stock の `vga=788` から変更) と **`nomodeset`** (新規追加) の 2 flag のみ。

**Phase 10 の目的**: (1) stock 13.3.0 ISO + grub.cfg 1 ファイル差し替えの bisect 3 通り (`vga=normal` 単独 / `nomodeset` 単独 / 両方) で triple-fault トリガー flag を単一文字レベルで特定し、(2) `scripts/remaster-debian-iso.sh` の 4 箇所 (UEFI grub.cfg / txt.cfg auto / txt.cfg install / efi.img embed.cfg) から該当 flag を削除し、(3) 修正版 wrapper で remaster ISO を再 build → NFS attach → boot し、「インストーラを boot する」目標達成を確認する。

## 環境情報

- ホスト: training-tx1320 (Fujitsu PRIMERGY TX1320 M3 / Mainboard D3373 / BIOS V5.0.0.11 R1.22.0)
- BMC: iRMC S4 FW 9.08F (10.254.254.9, claude index=4, HTTPS + SECLEVEL=0)
- Memory: 24 GiB / CPU: 1 socket (4 logical)
- HW: RAID10 SAS HDD 900GB × 4 (Phase 10 では未書込)
- Virtual Media: iRMC NFS Virtual Media (`/var/samba/public` on playground 10.1.6.6)
- SOL: `scripts/sol-monitor.py --timeout 480-600`
- VGA capture: `scripts/irmc-oem-screenshot.sh` (KVM canvas artifact 回避経路)

## 試行と結果

### Step A: bisect 用 stock + grub.cfg patched ISO を 3 通り build

Phase 9 で実証された pipeline (`tmp/phase9-060436/build-stock-fullcmdline-iso.sh`) を 1 つの汎用版 (`tmp/phase10-072719/build-bisect-iso.sh <A|B|C>`) にリファクタ。stock 13.3.0 ISO の `/boot/grub/grub.cfg` の `linux /install.amd/vmlinuz vga=788 --- quiet` 行を sed で bisect 別に書き換え、 `xorriso -update` で 6 KB 1 ファイルだけ差し替える。GRUB serial init (`serial --speed=115200 --unit=0`) を grub.cfg 冒頭に prepend して triple-fault サイクルを SOL の `[H[J[1;1HLoading bootloader...` 反復で観測可能化。

| Test | cmdline (kernel-affecting 部分) | 完成 cmdline |
|------|-------------------------------|------------|
| **10-A** | `vga=788` → `vga=normal` 差し替え | `vga=normal console=tty0 console=ttyS0,115200n8 --- quiet` |
| **10-B** | stock + `nomodeset` 追加 | `vga=788 nomodeset console=tty0 console=ttyS0,115200n8 --- quiet` |
| **10-C** | 両方適用 (Phase 9 Test 4 と同等 validation) | `vga=normal nomodeset console=tty0 console=ttyS0,115200n8 --- quiet` |

ISO 名: `/var/samba/public/debian-13.3.0-amd64-netinst-bisect-{A,B,C}.iso` (各 ~790 MB)。3 ISO 並列 build で約 3 分。

### Step B: bisect 3 test の boot 観測

Phase 9 と同じ pipeline (`tmp/phase10-072719/run-bisect-test.sh <A|B|C>`) で各 ISO を NFS attach + boot + SOL monitor 480 秒。Test C (validation) → A → B の順で実施。

| 計測項目 | Test 10-C (validation) | Test 10-A | Test 10-B |
|---------|----------------------|-----------|-----------|
| 実行時刻 | 07:36-07:44 | 07:48-07:57 | 07:58-08:07 |
| cmdline | `vga=normal nomodeset` | `vga=normal` 単独 | `nomodeset` 単独 |
| **Loading bootloader 回数** | **39 / 8 分** | **44 / 8 分** | **40 / 8 分** |
| 推定 cycle 周期 | ~12.3 秒 | ~10.9 秒 | ~12.0 秒 |
| Kernel printk hits | 0 | 0 | 0 |
| PowerState | On 継続 (warm-reset サイクル) | On 継続 (warm-reset サイクル) | On 継続 (warm-reset サイクル) |
| 判定 | 🎯 **triple-fault loop** (Phase 9 Test 4 再現) | 🎯 **triple-fault loop** | 🎯 **triple-fault loop** |

**Plan の Step C 結果分岐表との対応**:

> | triple-fault | triple-fault | triple-fault | 両方独立にトリガー | wrapper から両方削除 |

つまり **`vga=normal` も `nomodeset` も独立に triple-fault を引き起こす** ことが確定。 wrapper template から **両方削除** が正解。

### Step D: `scripts/remaster-debian-iso.sh` の cmdline 4 箇所修正

| 行 | 文脈 | 修正前 | 修正後 |
|----|------|-------|-------|
| 124 | UEFI grub.cfg menuentry | `linux /install.amd/vmlinuz vga=normal nomodeset auto=true ...` | `linux /install.amd/vmlinuz auto=true ...` |
| 134 | txt.cfg `auto` label (isolinux) | `append vga=normal nomodeset auto=true ...` | `append auto=true ...` |
| 138 | txt.cfg `install` label (isolinux fallback) | `append vga=normal nomodeset initrd=...` | `append initrd=...` |
| 197 | efi.img embed.cfg (grub-mkstandalone Option B) | `linux /install.amd/vmlinuz vga=normal nomodeset auto=true ...` | `linux /install.amd/vmlinuz auto=true ...` |

検証:

```sh
$ grep -nE 'vga=normal|nomodeset' scripts/remaster-debian-iso.sh
(no output → 完全除去確認)
```

修正後の kernel に効く cmdline は `console=tty0 console=ttyS0,115200n8 ${EXTRA_CMDLINE} --- quiet` のみ (`---` 以降の debconf flag は kernel boot path に影響しない)。これは Phase 9 Test 2 / Test 3 で 9 分 triple-fault なしを確認済の組合せと等価。

### Step E: 修正版 wrapper で remaster ISO build + installer boot 検証

修正版 wrapper で training_tx1320 用 ISO を build:

```sh
./scripts/generate-preseed.sh config/training_tx1320.yml tmp/phase10-072719/preseed-training.cfg
sh ./scripts/remaster-debian-iso.sh --serial-unit=0 \
    /var/samba/public/debian-13.3.0-amd64-netinst.iso \
    tmp/phase10-072719/preseed-training.cfg \
    /var/samba/public/debian-13.3.0-amd64-netinst-tx1320-phase10.iso
```

build 成功 (763 MB)。NFS attach + boot + SOL monitor 600 秒で観測:

| 計測項目 | 結果 | 判定 |
|---------|------|------|
| Loading bootloader 出現回数 | **0** | 🎯 **triple-fault サイクル完全消滅** |
| GRUB countdown | `3s → 2s → 1s → 0s` で完走 → `Booting 'Automated Install'` | 🎯 GRUB → kernel chainload 成功 |
| PowerState | **On 継続 10 分** (forceoff 介入まで) | 🎯 warm-reset サイクルなし |
| OEM screenshot t60/t120 | BIOS POST 99 (41019/41022 B) | BIOS 正常進行 |
| OEM screenshot t240-t600 | 14575-14591 B (kernel chainload 後の framebuffer artifact 黒画、 [MEMORY.md training_tx1320_irmc_kvm_framebuffer_artifact.md](../MEMORY.md) で documented) | 「boot 失敗の証拠ではない」 |
| 🎯🎯🎯 **playground NFS server 統計** | **io 796,409,856 bytes (~760 MB) read** / NFS v4 compound 28,039 calls / read 762 v3 + 多数 v4 | **kernel が NFS 経由で ISO 全体を read = installer 進行中の物理的証拠** |
| SOL kernel printk | 0 (Phase 9 Test 2/3 と同じ silent boot pattern) | `quiet` + D3373 SOL bridge なしのため kernel printk は SOL に到達しない (= 既知制約、 boot 失敗の証拠ではない) |

**判定**: 🎯🎯🎯 **Phase 10 目標達成 = 「インストーラを boot する」完了**。 triple-fault loop 完全消滅、 GRUB countdown 完走 → kernel chainload 成功、 PowerState=On 10 分継続、 NFS read 760 MB で installer が ISO 全体を引いている。

## 🎯 Phase 10 で得た確定知見

1. 🎯🎯🎯 **`vga=normal` 単独・`nomodeset` 単独・両方の組合せ — 3 通り全てが D3373 + Debian 13.3 kernel で triple-fault loop を引き起こす**。両 flag は独立にトリガーするので wrapper template から両方削除する必要がある。
2. **stock cmdline (`vga=788 --- quiet`) は triple-fault しない** (Phase 9 Test 2 と Phase 10 修正版 wrapper boot で実証)。 `vga=788` は VESA mode 800x600 / 16bpp の指定で、 UEFI mode では基本的に framebuffer に効かない (UEFI が GOP framebuffer を確立する) が、 kernel の VGA driver 初期化パスが `vga=normal` (= text mode 要求) や `nomodeset` (= KMS 完全停止) を受け取ると D3373 の Aspeed AST2400 VGA controller との初期化 sequence で triple-fault に陥る可能性が示唆される。
3. **kernel chainload 後の SOL silence は正常** — Debian 13.3 (kernel 6.12.x) で `quiet` 指定 + D3373 物理 UART が iRMC SOL に bridge されていない (Phase 9 Test 3 で確認) 環境では、 kernel printk は SOL に届かない。 これは Phase 9 で既知の現象であり Phase 10 でも継続。 boot 進行の証拠としては (a) `Loading bootloader` 出現が 1 回以下、 (b) PowerState=On 長時間継続、 (c) playground 側 NFS read 統計、 の 3 つを併用する。
4. 🎯 **bisect pipeline 完全再利用可能** — Phase 9 の build スクリプト + Phase 10 の汎用 runner (`run-bisect-test.sh <A|B|C>`) で同様の cmdline 試行は 1 ISO あたり ~10 分 / 試行で実施可能。他機種で同様の kernel-level boot 障害が発生した場合、 stock + grub.cfg patched ISO の bisect で再利用できる。
5. **修正版 wrapper は全機種共通の安全な変更** — `vga=normal` と `nomodeset` は他機種 (Supermicro X11DPU 4-6号機、 DELL R320 7-9号機、 DELL R430 14-15号機、 Nutanix OEM X10DRT-P 10-13号機) では既に正常 install できていたが、 「明示指定がないと UEFI framebuffer + KMS 自動検出に委ねる」方が普遍的に安全 (kernel default 動作)。 wrapper から両 flag を削除しても他機種で問題が出る蓋然性は低い。

## 修正前後の比較 (Phase 9 Test 4 / Phase 10 Step E)

| 項目 | Phase 9 Test 4 (修正前 cmdline) | Phase 10 Step E (修正後 cmdline) |
|------|--------------------------------|--------------------------------|
| Base ISO | stock 13.3.0 | stock 13.3.0 |
| Remaster wrapper | (使わず、 grub.cfg 1 ファイル差替) | 修正版 `remaster-debian-iso.sh` で full remaster |
| kernel cmdline | `vga=normal nomodeset auto=true ... console=ttyS0 --- quiet` | `auto=true ... console=ttyS0 --- quiet` (vga/nomodeset 削除) |
| GRUB countdown | 観測なし (cycle 中) | 3s → 0s 完走 |
| Loading bootloader 出現 | 34 / 8 分 (= ~14 秒/cycle) | 0 / 10 分 |
| PowerState | On (warm-reset サイクル) | On 継続 |
| NFS read | (測定なし) | **760 MB** |
| 判定 | triple-fault loop | 🎯🎯🎯 **kernel boot 成功 + installer 進行** |

## 再現方法

### 前提

- training-tx1320 BMC (10.254.254.9) と playground (10.1.6.6) に到達可能
- `tmp/phase9-060436/tx1320-env.sh` に iRMC quirks (`BMC_CURL_OPTS`, `POWER_ON_RESET_TYPE`, `BMC_PATCH_REQUIRES_ETAG`) を export 済
- `tmp/phase9-060436/stock13-extract/grub.cfg` が抽出済 (Phase 9 で生成)

### Step A: bisect 3 ISO を build

```sh
sh tmp/phase10-072719/build-bisect-iso.sh A   # vga=normal 単独
sh tmp/phase10-072719/build-bisect-iso.sh B   # nomodeset 単独
sh tmp/phase10-072719/build-bisect-iso.sh C   # 両方 (= Phase 9 Test 4 validation)
```

各 ISO は `/var/samba/public/debian-13.3.0-amd64-netinst-bisect-{A,B,C}.iso` に出力 (~790 MB / 1〜2 分).

### Step B: bisect 各 test を実行

```sh
sh tmp/phase10-072719/run-bisect-test.sh C    # validation 推奨 (Phase 9 と同じ triple-fault が出ることを確認)
sh tmp/phase10-072719/run-bisect-test.sh A
sh tmp/phase10-072719/run-bisect-test.sh B
```

各 test は ~12 分 (scp ~30s + boot + 480s monitor + forceoff)。 結果は `tmp/phase10-072719/test-{A,B,C}/{sol.log,summary.txt,oem-t*.jpg}` に出力。

```sh
for T in A B C; do
    echo "=== Test 10-$T ==="
    cat tmp/phase10-072719/test-$T/summary.txt
done
```

→ 各 test の `Loading bootloader count: > 5` なら triple-fault、 `= 0 or 1` なら kernel boot 成功 (silent or normal)。

### Step D: wrapper template 修正

`scripts/remaster-debian-iso.sh` の line 124 / 134 / 138 / 197 から `vga=normal nomodeset ` (trailing space 込み) を削除:

```sh
grep -nE 'vga=normal|nomodeset' scripts/remaster-debian-iso.sh
# (no output が期待値)
```

### Step E: 修正版 wrapper で remaster ISO build + boot

```sh
./scripts/generate-preseed.sh config/training_tx1320.yml tmp/phase10-072719/preseed-training.cfg

sh ./scripts/remaster-debian-iso.sh --serial-unit=0 \
    /var/samba/public/debian-13.3.0-amd64-netinst.iso \
    tmp/phase10-072719/preseed-training.cfg \
    /var/samba/public/debian-13.3.0-amd64-netinst-tx1320-phase10.iso

sh tmp/phase10-072719/run-phase10-installer.sh
```

`tmp/phase10-072719/installer-boot/summary.txt` に集計:
- `Loading bootloader count: 0` → triple-fault loop なし
- SOL log の GRUB 出力で countdown 完走 + `Booting 'Automated Install'`
- playground 側 `nfsstat -s` の `read` カウンタ大量増加 (~760 MB の `io` bytes)

## 次のステップ (Phase 11 候補)

Phase 10 で「インストーラを boot する」目標達成。 次は **preseed 自動応答完走 + RAID10 への install 完了**:

1. SOL silence 問題: `quiet` 除去 + `console=ttyS0,115200n8` 強化 / D3373 の UART bridge を iRMC SOL 側で enable できるかを再調査 (Phase 6 で SOL stdin が片方向と判明したが、 stdout 側についても再評価)
2. preseed の partman/early_command (`/cdrom/setup-raid10-storcli.sh`) が走るか確認: `--with-raid10-storcli` フラグで `scripts/generate-preseed.sh` が出力する preseed を使用 → wrapper の `--include=` で `storcli64.deb` と `setup-raid10-storcli.sh` を ISO に bundle して build
3. installer 完走後の reboot で PVE 9.1.x install を起動 (`scripts/pve-setup-remote.sh` を training-tx1320 用に流用)
4. 完走できれば training-tx1320 へ初の OS install 成功 = Phase 1 (= 2026-05-16) からの 6 日間にわたる triple-fault 調査の完全終結

## 関連レポート / メモ

- [Phase 9 (2026-05-22 phase9-060436): stock 13.3.0 ISO 直接 boot で remaster wrapper cmdline が真因と確定](2026-05-22_071405_tx1320_raid10_phase9_remaster_cmdline_isolated.md)
- [Phase 8 (2026-05-22 phase811): triple-fault reset loop 観測 + iRMC OEM Screenshot 発見](2026-05-22_055158_tx1320_raid10_phase8_iter11to13.md)
- MEMORY.md `training_tx1320_phase9_cmdline_isolated.md` (Phase 9 結果の memory entry、 Phase 10 で更新する)
- MEMORY.md `training_tx1320_irmc_kvm_framebuffer_artifact.md` (Phase 7 framebuffer artifact、 Phase 10 でも有効)
- MEMORY.md `training_tx1320_kernel_silent_post_grub.md` (Phase 3-9 の経緯まとめ、 Phase 10 で更新する)
