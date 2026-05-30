# tx1320 RAID10 Phase 12: cmdline から `quiet` 削除 + `earlyprintk` + `ignore_loglevel` 投入で SOL silence 真因観測 — **kernel printk ゼロ + VGA も silent が確定**

- **実施日時**: 2026年05月22日 11:16-11:35 (JST)
- **セッション**: phase12-111602

## 添付ファイル

- [実装プラン](attachment/2026-05-22_113557_tx1320_raid10_phase12_sol_silence_confirmed/plan.md)
- 🎯 [Phase 12 ISO Boot SOL log (600s, 2.1 MB)](attachment/2026-05-22_113557_tx1320_raid10_phase12_sol_silence_confirmed/sol.log)
- 🎯 [OEM screenshots t=60s..540s (BIOS→GRUB→Booting freeze の timeline)](attachment/2026-05-22_113557_tx1320_raid10_phase12_sol_silence_confirmed/screenshots/)
- [Phase 12 ISO 内 grub.cfg (UEFI auto cmdline)](attachment/2026-05-22_113557_tx1320_raid10_phase12_sol_silence_confirmed/grub.cfg)
- [Phase 12 ISO 内 isolinux txt.cfg (BIOS cmdline)](attachment/2026-05-22_113557_tx1320_raid10_phase12_sol_silence_confirmed/txt.cfg)

## 対象機

- **training-tx1320** (Fujitsu PRIMERGY TX1320 M3 / Mainboard D3373 / BIOS V5.0.0.11 R1.22.0 / iRMC S4 FW 9.08F / BMC 10.254.254.9)
- HW: RAID10 SAS HDD 900GB × 4 (未書込み、 storcli setup 未到達)
- Virtual Media: iRMC NFS Virtual Media (`/var/samba/public` on playground 10.1.6.6)

## 前提・目的

[Phase 11 (2026-05-22 phase11-084821)](2026-05-22_093747_tx1320_raid10_phase11_phase10_misjudgment_revealed.md) で「Phase 10 の `vga=normal nomodeset` 削除は GRUB stage triple-fault のみ治しただけで、 kernel boot 後の別の reset 原因が残存」が判明し、 `Booting 'Automated Install'` が SOL log に 51-99 回出現する reset loop が継続していた。

Phase 12 は **SOL silence を打破して kernel boot 後 reset の真因を観測** することが最優先目標。 具体的には:

1. `scripts/remaster-debian-iso.sh` の 4 箇所 (L124/L134/L138/L197) の cmdline 末尾 `--- quiet` を `earlyprintk=ttyS${SERIAL_UNIT},115200n8 loglevel=8 ignore_loglevel ---` に置換
2. 新 ISO を build → deploy → boot → SOL kernel printk を観測
3. kernel printk が出れば panic / oops / その他 fault の root cause が直接確認可能
4. 出なければ D3373 SOL UART bridge が UEFI runtime services で機能しない hardware 制約の可能性が確定し、 別の観測手段 (Phase 8 で発見した iRMC OEM Screenshot 経由で kernel BUG message 等を読む) に切替

最終目標は OS インストール完了 (preseed 完走 + RAID10 install + SSH login)。

## 環境情報

- Source ISO: `/var/samba/public/debian-13.3.0-amd64-netinst.iso` (stock Debian 13.3.0)
- 本番 ISO: `/var/samba/public/debian-training-tx1320-raid10.iso` (Phase 12 build、 800391168 B → 764 MiB)
- preseed: `tmp/training-tx1320-preseed-raid10.cfg` (`--with-raid10-storcli`)
- config: `config/training_tx1320.yml` (SERIAL_UNIT=**0**、 ttyS0 = COM1、 これは Phase 11 plan で `serial_unit: 1` と書いた誤りを訂正)

## 試行と結果

### Step 1: `scripts/remaster-debian-iso.sh` の cmdline 4 箇所を編集

| 行 | 場所 | 前 | 後 |
|----|------|-----|----|
| L124 | grub.cfg auto menuentry (UEFI primary path) | `... ${EXTRA_CMDLINE} --- quiet` | `... earlyprintk=ttyS${SERIAL_UNIT},115200n8 loglevel=8 ignore_loglevel ${EXTRA_CMDLINE} ---` |
| L134 | isolinux txt.cfg auto label (BIOS) | 同 (auto path) | 同 |
| L138 | isolinux txt.cfg install label (BIOS 手動) | `... --- quiet` | `... earlyprintk=ttyS${SERIAL_UNIT},115200n8 loglevel=8 ignore_loglevel ---` |
| L197 | grub-mkstandalone embed.cfg (Option B EFI rebuild) | 同 (auto path) | 同 |

副作用として Phase 10 で未コミットだった `vga=normal nomodeset` 削除も同じファイルに含まれていたので、 一緒にコミット範囲に入る (issue #18 系の改善)。

### Step 2: 本番 ISO build

```sh
SKIP_STORCLI_FETCH=1 ./scripts/tx1320-raid10-orchestrate.sh build config/training_tx1320.yml
```

- 出力: `/var/samba/public/debian-training-tx1320-raid10.iso` 800391168 B (764 MiB)
- ISO 内 grub.cfg actual cmdline:
  ```
  linux /install.amd/vmlinuz auto=true priority=critical preseed/file=/preseed.cfg locale=en_US.UTF-8 keymap=us netcfg/choose_interface=auto cdrom-detect/try-usb=true cdrom-detect/scan=true hw-detect/load_media=false console=tty0 console=ttyS0,115200n8 earlyprintk=ttyS0,115200n8 loglevel=8 ignore_loglevel  ---
  ```
- ISO 内 isolinux/txt.cfg、 embed.cfg も同様に置換確認

### Step 3: deploy + 観測 (SOL monitor 600s + OEM screenshot loop 9 回)

```sh
./scripts/tx1320-raid10-orchestrate.sh deploy config/training_tx1320.yml
ipmitool ... sol payload enable 2 4   # 事前必須
.venv/bin/python scripts/sol-monitor.py --bmc-ip 10.254.254.9 --bmc-user claude --bmc-pass Claude123 \
    --log-file tmp/phase12-111602/sol.log --timeout 600 --powerstate-interval 30
# 並行で sh tmp/phase12-111602/screenshot-loop.sh (t=60,120,180,240,300,360,420,480,540s で OEM screenshot)
```

> ⚠️ `./scripts/tx1320-raid10-orchestrate.sh monitor ... --timeout 600 --log ...` は wrapper bug で動かない (`$3` を OUTPUT_ISO として `basename` してしまう)。 `sol-monitor.py` を直接起動して回避。

### Step 4: OEM Screenshot timeline 観察 — GRUB countdown 300s 完走 + kernel jump 後完全 freeze

| 時刻 | サイズ | 内容 |
|------|--------|------|
| t=60s | 41022 B | BIOS POST 画面 (Fujitsu/American Megatrends ロゴ + iRMC FW 9.08F) |
| t=120s | 34357 B | GNU GRUB 2.12-9+deb13u2 menu、 *Automated Install 選択、 countdown **246s** |
| t=180s | 34351 B | (未参照、 countdown 186s 想定) |
| t=240s | 34347 B | (未参照、 countdown 126s 想定) |
| t=300s | 34271 B | GRUB menu、 countdown **68s** |
| t=360s | 34175 B | GRUB menu、 countdown **7s** |
| t=420s | 14591 B | **"Booting 'Automated Install'" + 左上にカーソル** (kernel chainload 完了) |
| t=480s | 14575 B | 同上 (画面変化なし) |
| t=540s | 14591 B | 同上 (画面変化なし) |

GRUB countdown は **300s** から開始し、 ほぼ 1s/s で減算 (Phase 11 で「謎」と書いた 300s 観測を今回も再現)。 wrapper の embed.cfg / grub.cfg は `set timeout=3` のはずなのに actual は 300s — **build と関係なく出現する未解明挙動だが、 本 Phase 目標とは無関係なので一旦保留**。

t=420s で **GRUB が kernel chainload に成功し "Booting 'Automated Install'" を画面に表示**、 t=540s まで **VGA 画面は同じまま (kernel printk が一切 VGA に書かれない)**。 OEM Screenshot は Phase 8 で「真の VGA capture」と確認済みなので、 これは framebuffer artifact ではなく **kernel が VGA console (tty0) に何も書いていない事の物理的観測** である。

### Step 5: SOL log 解析 — kernel printk もゼロ、 ただし Booting は 43 回出現

```
=== sol.log size ===   2204985 bytes (2.1 MB)
=== Booting 'Automated Install': 43 ===  (>1 = kernel-stage triple-fault)
=== Loading bootloader:          0 ===   (>1 = GRUB-stage triple-fault、 ゼロでよい)
=== Session reconnects ===       114      (ipmitool sol activate が 114 回再接続)
=== GRUB countdown range ===     144s..300s (157 distinct values 観測)
```

**kernel printk シグネチャ (出現すべき):**

| signature | count |
|-----------|-------|
| `Linux version` | **0** |
| `BIOS-e820` | **0** |
| `Command line:` | **0** |
| `ACPI:` | **0** |
| `CPU0:` | **0** |
| `Booting paravirtualized` | **0** |
| `DMI:` | **0** |
| `Detected` | **0** |
| `smpboot:` | **0** |

**panic / oops / fault シグネチャ:**

| signature | count |
|-----------|-------|
| `Kernel panic` | **0** |
| `BUG:` | **0** |
| `Oops:` | **0** |
| `Unable to handle` | **0** |
| `Call Trace` | **0** |
| `RIP:` | **0** |
| `general protection fault` | **0** |
| `page fault` | **0** |
| `triple fault` | **0** |
| `MCE:` | **0** |

**Installer / preseed シグネチャ:**

| signature | count |
|-----------|-------|
| `Configuring DHCP` | **0** |
| `Starting up the partitioner` | **0** |
| `preseed/early_command` | **0** |
| `pvese:` (early_command エコー) | **0** |

ANSI escape sequence 除去後の plain text 1.85 MB のうち、 「Linux」「kernel」「panic」「fault」「error」全て 0 件、 唯一意味のある unique non-noise line は GRUB menu の枠線描画行のみ。 つまり **600 秒間の boot 試行を通じて、 kernel から SOL ttyS0 に届いた printk は 1 文字もない**。

### Step 6: cycle 構造の再構成

- **初回 cold boot** (~t=0 → t=420s): BIOS POST (~60s) + GRUB countdown 300s + kernel chainload → 1 回目の `Booting` 出現
- **以降の warm-reset loop** (~t=420 → t=600s = 180s): 43 - 1 = 42 cycles 残り → 180 / 42 = **~4.3s/cycle**
- 各 warm-reset cycle で BIOS は短縮 POST → GRUB は countdown を skip して即 default boot → kernel chainload (= `Booting` 再出現) → ExitBootServices 直後に reset

114 回の SOL session reconnect / 600s = 5.3s/cycle で warm-reset cycle 周期と整合 (reset の度に SOL UART が切れて ipmitool が再接続している)。

## 🎯 Phase 12 で得た確定知見

### 1. 🎯🎯🎯 SOL UART は kernel jump 直後に完全沈黙する — `earlyprintk` + `ignore_loglevel` でも 1 文字も出ない

cmdline 末尾の `quiet` を取り除き `earlyprintk=ttyS0,115200n8 loglevel=8 ignore_loglevel` を追加した状態で、 SOL log には kernel から由来する printk が **一切観測されない**。 これは Phase 11 まで「`quiet` flag が原因かもしれない」と仮定していた経路を **完全に反証** する。

可能性:
- (a) kernel が console init より前 (= early printk subsystem init 前) で panic / triple-fault
- (b) D3373 BIOS が UEFI ExitBootServices で SOL UART bridge を detach (kernel の MMIO/I/O port アクセスを iRMC が forward しなくなる)
- (c) kernel は printk 出力しているが iRMC SOL の baud rate / port mapping mismatch で受信側に届かない

### 2. 🎯🎯 VGA framebuffer も kernel jump 後完全 freeze — `console=tty0` 設定でも VGA 書き込みなし

OEM Screenshot を t=420s/480s/540s で取得すると、 全て **「Booting 'Automated Install'」 + 左上カーソル** の同一画面で停止。 これは GRUB が kernel に控制を渡す直前の最後の出力で、 以降 kernel は VGA framebuffer に何も書いていない。

Phase 8 で確定した「OEM Screenshot = 真の VGA capture」が前提なので、 これは framebuffer artifact ではなく **物理的に VGA RAM 内容が変わっていない**。 console=tty0 が cmdline にあるのに **両方の console が同時に沈黙** している事実は、 仮説 (a) [kernel が printk init 前で panic] を強く支持する。

### 3. ⚠️ Phase 11 で「謎」だった GRUB countdown 300s は Phase 12 でも再現 — wrapper config と不一致

`scripts/remaster-debian-iso.sh` L113-127 (grub.cfg)、 L186-200 (embed.cfg) の両方で `set timeout=3` を生成しているのに、 actual の GRUB countdown は 300s。 ISO 内 `/boot/grub/grub.cfg` を抽出して確認した内容も `set timeout=3` 一致。

仮説:
- iRMC NFS Virtual Media 経由で boot する際、 iRMC 側が独自の boot config を上書き挿入する
- BIOS POST の Boot Manager が GRUB をスキップして別 path から boot する
- ISO 内に **私たちが認識していない** `set timeout=300` を含む別の grub.cfg がある

本 Phase の目標とは独立しているので Phase 13 でも保留。 ただし debug 時に GRUB countdown の長さが boot 速度に影響するので、 真因特定後は適切な timeout に強制する手段を見つける必要あり。

### 4. ✅ orchestrate `monitor` サブコマンド bug を発見

`./scripts/tx1320-raid10-orchestrate.sh monitor <config> --timeout 600 --log <path>` を実行すると `basename: unrecognized option '--timeout'` で死ぬ。 原因: orchestrate.sh L86-88 が `$3` を `OUTPUT_ISO` として無条件に `basename` するため、 `monitor` サブコマンドで `$3=--timeout` だと basename が失敗する。

回避策: `sol-monitor.py` を直接起動。 Phase 13 以降は orchestrate.sh の修正を別 issue で対応。

## 📌 Phase 13 への引き継ぎ事項

| # | タスク | 優先度 | 補足 |
|---|--------|--------|------|
| 1 | **`console=tty0` を cmdline から削除して `console=ttyS0,115200n8` のみで再 boot** | 最高 | VGA console init が原因で kernel panic している可能性の検証。 console=tty0 が無ければ kernel は efifb/vga16fb 等の framebuffer driver を load しない |
| 2 | **stock Debian 13.3.0 netinst ISO を wrapper 経由せず直接 NFS attach + boot** | 最高 | wrapper の問題か kernel/HW の問題かの最終切り分け。 Phase 9 ではこれをやって「OK」と判定したが、 Phase 10-11 の誤判定リスクを念頭に、 「Linux version 出現を厳密判定」する |
| 3 | **Debian 12 (bookworm) netinst ISO を attach + boot で base ISO 互換性検証** | 高 | Debian 13 kernel + D3373 BIOS の互換性問題なら 12 (kernel 6.1.x) で動く可能性。 これが動けば真因が「Linux 6.12 kernel × D3373 BIOS UEFI ExitBootServices」と確定 |
| 4 | **Memtest86+ baseline 再確認** | 中 | Phase 7 で boot 成功 + UI 表示確認した実績がある (iRMC NFS+UEFI 経路は OS-agnostic 健全) を Phase 13 開始時に再確認、 iRMC give-up state でない事を担保 |
| 5 | `cmdline` に `noefi` `efi=runtime` `pci=noacpi` 等を試行 | 中 | UEFI runtime services 関連の panic 経路を一つずつ反証 |
| 6 | `scripts/tx1320-raid10-orchestrate.sh monitor` bug 修正 | 中 | OUTPUT_ISO の parse を monitor サブコマンドでスキップする。 issue 化 |
| 7 | GRUB countdown 300s の root cause 究明 | 低 | 真因究明とは独立、 デバッグ効率改善のため |
| 8 | MEMORY.md `training_tx1320_kernel_silent_post_grub.md` を Phase 12 知見で更新 | 高 | (a)(b)(c) 三仮説 + earlyprintk 無効が確定した旨を追記 |
| 9 | sol-monitor.py の `Booting` count シグネチャ採用 | 低 | Phase 11 引継ぎ事項。 本 Phase 観測では手動 grep で対応したので緊急度低 |

## 関連レポート / メモ

- [Phase 11 (2026-05-22 phase11-084821): Phase 10 「installer boot 成功」判定が誤りだった事を発見](2026-05-22_093747_tx1320_raid10_phase11_phase10_misjudgment_revealed.md)
- [Phase 10 (2026-05-22 phase10-072719): cmdline bisect 完了 — 誤判定 (Phase 11 で訂正)](2026-05-22_082633_tx1320_raid10_phase10_cmdline_bisect_solved.md)
- [Phase 9 (2026-05-22 phase9-060436): stock 13.3.0 ISO 直接 boot で remaster wrapper cmdline が真因と確定](2026-05-22_071405_tx1320_raid10_phase9_remaster_cmdline_isolated.md)
- [Phase 8 (2026-05-22 phase811): triple-fault reset loop 観測 + iRMC OEM Screenshot 発見](2026-05-22_055158_tx1320_raid10_phase8_iter11to13.md)
- MEMORY.md `training_tx1320_kernel_silent_post_grub.md` (Phase 3-9 経緯まとめ — Phase 12 知見で更新予定)
- MEMORY.md `training_tx1320_irmc_kvm_framebuffer_artifact.md` (KVM 黒画 framebuffer artifact、 OEM Screenshot は影響を受けない)
