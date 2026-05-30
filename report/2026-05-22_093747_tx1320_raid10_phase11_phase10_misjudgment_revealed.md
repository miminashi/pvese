# tx1320 RAID10 Phase 11: **Phase 10「installer boot 成功」判定が誤りだった事を発見** — triple-fault loop は cmdline 削除では治っていなかった

- **実施日時**: 2026年05月22日 08:48-09:37 (JST)
- **セッション**: phase11-084821
- **対象機**: training-tx1320 (Fujitsu PRIMERGY TX1320 M3, iRMC S4 FW 9.08F, BMC 10.254.254.9)

## 添付ファイル

- [実装プラン](../.claude/plans/phase-10-installer-witty-gray.md)
- 🎯🎯🎯 [Phase 11 ISO Boot SOL log (deploy 直後、 cycle ~4.7s)](attachment/2026-05-22_093747_tx1320_raid10_phase11_phase10_misjudgment_revealed/sol-phase11iso.log) (132 KB / 5 min、 Booting 51 回)
- 🎯 [Phase 10 ISO 再 deploy SOL log (cycle ~6.1s)](attachment/2026-05-22_093747_tx1320_raid10_phase11_phase10_misjudgment_revealed/sol-phase10iso-bisect.log) (267 KB / 10 min、 Booting 99 回)
- 🎯 [Cold Cycle 後 SOL log (cycle ~17s、 countdown 300s 観測)](attachment/2026-05-22_093747_tx1320_raid10_phase11_phase10_misjudgment_revealed/sol-coldcycle.log) (1.94 MB / 10 min、 Booting 35 回)
- [Phase 11 ISO build log](attachment/2026-05-22_093747_tx1320_raid10_phase11_phase10_misjudgment_revealed/build.log)
- [Phase 11 ISO + Phase 10 ISO の grub.cfg diff (= 同一)](attachment/2026-05-22_093747_tx1320_raid10_phase11_phase10_misjudgment_revealed/grub.cfg.both.txt)
- [OEM screenshots t=60s/120s/180s/240s/300s/360s (全て黒画 framebuffer artifact)](attachment/2026-05-22_093747_tx1320_raid10_phase11_phase10_misjudgment_revealed/)

## 前提・目的

[Phase 10 (2026-05-22 phase10-072719)](2026-05-22_082633_tx1320_raid10_phase10_cmdline_bisect_solved.md) で「`scripts/remaster-debian-iso.sh` から `vga=normal` と `nomodeset` を削除して triple-fault loop を完全消滅、 GRUB countdown 完走 + kernel boot 成功 + NFS read 760 MB で installer 進行確認」と結論。 Phase 11 はこれを前提に、 **preseed + storcli + setup-raid10-storcli.sh を bundle した本番 ISO で installer を完走させ、 RAID10 上に Debian 13.3 を install して SSH login + RAID10 verify まで到達** する目標で開始。

実装プランは:
1. `tx1320-raid10-orchestrate.sh build` で `--with-raid10-storcli` + `--include=storcli64.deb` 込みの本番 ISO 生成
2. orchestrate `deploy` で iRMC NFS Virtual Media attach + boot
3. 多重観測 (sol-monitor.py の INSTALLER_STAGES + `--installer-syslog` fallback + `irmc-oem-screenshot.sh` 周期取得)
4. preseed 自動応答完走 → poweroff → SSH login + storcli verify

## 環境情報

- ホスト: training-tx1320 (Fujitsu PRIMERGY TX1320 M3 / Mainboard D3373 / BIOS V5.0.0.11 R1.22.0)
- BMC: iRMC S4 FW 9.08F (10.254.254.9, claude index=4, HTTPS + SECLEVEL=0)
- HW: RAID10 SAS HDD 900GB × 4 (未書込み、 storcli setup 未到達)
- Virtual Media: iRMC NFS Virtual Media (`/var/samba/public` on playground 10.1.6.6)
- ISO build: `./scripts/tx1320-raid10-orchestrate.sh build config/training_tx1320.yml`
- preseed: `tmp/training-tx1320-preseed-raid10.cfg` (`--with-raid10-storcli` + `partman/early_command sh /cdrom/setup-raid10-storcli.sh /cdrom/storcli64.deb`)
- 出力 ISO: `/var/samba/public/debian-training-tx1320-raid10.iso` (800391168 B = 800 MB)

## 試行と結果

### Step 1: 本番 ISO build (Phase 11 ISO)

`tx1320-raid10-orchestrate.sh build` で fetch-storcli → generate-preseed `--with-raid10-storcli` → remaster-debian-iso build を実行。 build 成功:

- 出力: `/var/samba/public/debian-training-tx1320-raid10.iso` 800391168 B
- ISO 内 同梱物: `/preseed.cfg` (10415 B、 `partman/early_command` 含む)、 `/storcli64.deb` (2 MB)、 `/setup-raid10-storcli.sh` (2775 B)
- initrd.gz: 24221603 B (= stock initrd 24217472 B + preseed cpio 4131 B 連結)
- cmdline: `auto=true priority=critical preseed/file=/preseed.cfg locale=en_US.UTF-8 keymap=us netcfg/choose_interface=auto cdrom-detect/try-usb=true cdrom-detect/scan=true hw-detect/load_media=false console=tty0 console=ttyS0,115200n8  --- quiet`

### Step 2: Phase 11 ISO deploy + 観測 (5 分)

`orchestrate deploy config/training_tx1320.yml` で NFS Virtual Media config + AllowableValues=DisconnectCD 確認 (NFS attach 成立) + boot-override Cd UEFI + PowerOn 成功。 sol-monitor.py + syslog-receiver + irmc-oem-screenshot loop を background 起動して 5 分観測:

- SOL log: 132826 B / 5 分
- "Booting `Automated Install'" 出現: **51 回** (cycle 周期 ~4.7 秒)
- "Loading bootloader" 出現: 0 (= Phase 9-10 で確定した triple-fault シグネチャは出ない)
- INSTALLER_STAGES 検出: 0/9 (= 1 stage も観測されず)
- installer-syslog.log: **0 bytes** (= preseed early_command の `syslogd -R 10.1.6.1:5514` まで到達せず)
- OEM screenshot t=60s: 41019 B (BIOS POST)、 t=120s 以降: 14575-16070 B (kernel chainload 後の framebuffer artifact 黒画、 Phase 8 で documented)
- PowerState: 全 polling で `None` (sol-monitor は Redfish ポーリングを失敗、 ただし手動 curl では `On`)

→ 解釈: kernel boot 後の reset loop。 GRUB countdown 完走 → kernel jump → 即 reset → BIOS POST → GRUB 再起動 ループ。

### Step 3: Bisect — Phase 10 ISO (= 「boot 成功」と判定された ISO) を再 deploy + 観測 (10 分)

「Phase 11 ISO 固有の問題か、 host state 問題か」を切り分けるため、 Phase 10 で「kernel boot 成功」と判定した ISO `/var/samba/public/debian-13.3.0-amd64-netinst-tx1320-phase10.iso` (799342592 B) を NFS Virtual Media に切り替えて deploy + 10 分観測:

- SOL log: 267 KB / 10 分
- "Booting `Automated Install'" 出現: **99 回** (cycle 周期 ~6.1 秒)
- "Loading bootloader" 出現: 0
- 他 metrics は Phase 11 ISO と質的に同じ

→ **重大発見**: Phase 10 で「boot 成功」と判定した ISO でも triple-fault loop が同じ症状で再現。 ISO 固有の問題ではない。

### Step 4: Phase 10 attachment 検証 — `tmp/phase10-072719/installer-boot/sol.log` と `summary.txt` の精査

Phase 10 SOL log の `Booting Automated Install` 出現数を確認:
- Phase 10 SOL log (134234 B / 10 分): **"Booting `Automated Install'" 56 回**
- Phase 10 summary.txt: `Kernel/installer printk hits: 56` ← この 56 を「kernel printk」と誤判定していたが、 actual には GRUB が kernel を chainload する直前のメッセージで、 **kernel printk ではない**

→ 🎯🎯🎯 **Phase 10 で「installer boot 成功」と判定したのは誤り**。 「Loading bootloader 0 回 + PowerState On 継続 + NFS read 760 MB」を判定基準にしたが、 actual には:

- Loading bootloader 0 = GRUB stage の triple-fault は治っているが、 kernel boot 後の別の reset 原因が残存
- PowerState On 継続 = warm-reset サイクル中も On (BIOS POST → GRUB → kernel jump → fault → warm-reset は外から見ると On 継続)
- NFS read 760 MB = cycle 毎の ISO read を 56 cycle 累積したもの (cycle 周期 ~10.7 秒、 1 cycle あたり ~13.5 MB read)

つまり Phase 9-10 で `vga=normal` `nomodeset` を削除して GRUB stage の triple-fault は治ったが、 **kernel boot 後の別の reset 原因が残存** していた事実が見落とされていた。

### Step 5: Cold cycle (BMC reset 相当) 試行 + 観測 (10 分)

iRMC give-up state の可能性を疑い、 host を完全な cold cycle (ForceOff → DisconnectCD → 20s wait → 再 config → ConnectCD → boot-override → PowerOn) で再 boot。 sol-monitor 10 分観測:

- SOL log: **1.94 MB / 10 分** (前回の 7 倍)
- "Booting `Automated Install'" 出現: **35 回** (cycle 周期 ~17 秒、 前回より遅く)
- "Loading bootloader" 出現: 0
- GRUB countdown: **300 秒** から開始 (cycle 毎に countdown 進む秒数が増える — cycle 1: 300→296、 cycle 2: 300→290、 cycle 3: 300→285、 ..., final cycle: 300→0 で完走 → Booting)
- INSTALLER_STAGES: 0/9
- installer-syslog: 0 bytes

→ cold cycle で cycle 周期は ~4.7s → ~17s に伸びたが、 triple-fault 自体は **継続**。 cycle が遅くなった理由は不明 (BIOS POST 時間が cycle 毎に変動?)。

### Step 6: GRUB countdown 300s の謎

cold cycle 後の SOL log では GRUB countdown が **300 秒** から開始することを発見。 ところが:
- `scripts/remaster-debian-iso.sh` L113-127 が生成する `/boot/grub/grub.cfg`: `set timeout=3`
- `scripts/remaster-debian-iso.sh` L186-200 が生成する efi.img 内 embed.cfg: `set timeout=3`
- ISO 内に展開した actual `/boot/grub/grub.cfg`: `set timeout=3` (確認済)
- ISOLINUX `isolinux.cfg`: `timeout 30` (= 3 秒、 syslinux は 0.1 秒単位)

すべての config で timeout=3 のはずなのに、 actual GRUB serial console で 300s countdown。 矛盾。 SOL log の `automatically in N s.` の N 値は 0〜300 まで連続 (= unique 301 値)。 表示誤読ではなく真に 300s。

仮説:
- Phase 11 ISO build 直後 (1st deploy) の SOL log では 3s countdown (推定、 strings 抽出未確認)。 Phase 10 ISO bisect + cold cycle 後の SOL log で 300s countdown。 build と関係なく BIOS / iRMC 側で何かが変わった?
- Cold cycle で iRMC が異なる boot path を選択 (例: PXE-like NFS boot mode で別の grub.cfg を fetch)
- 私たちが認識していない `set timeout=300` を含む別の grub.cfg が ISO 内に存在?

未解明 — 次セッションで切り分け必要。

## 🎯 Phase 11 で得た確定知見

1. 🎯🎯🎯 **Phase 10 の「installer boot 成功」結論は誤り**。 Phase 10 SOL log にも `Booting Automated Install` が 56 回出現 (= triple-fault cycle)。 「Loading bootloader 0」だけを判定基準にしたため見逃された。 真の判定基準は **`Booting Automated Install` が 1 回のみ + 長時間継続** (= kernel boot 成功) vs **複数回出現** (= triple-fault loop)。

2. **`vga=normal` + `nomodeset` 削除は GRUB stage triple-fault のみ治った**。 kernel boot 後の別の reset 原因が残存。 真因究明には別の cmdline (`earlyprintk` + `quiet` 削除) や別の base ISO 試行が必要。

3. **`Loading bootloader 0` シグネチャの寿命**: Phase 9 で確定した triple-fault signature 「Loading bootloader 反復」は **GRUB stage triple-fault のみに該当**。 kernel boot 後の reset loop ではこのメッセージは出ないので、 別シグネチャが必要。 提案: `Booting <menuentry>` の重複出現数。

4. **cold cycle で症状は質的に変わらない**。 host state / iRMC give-up state 問題ではない (もしくは cold cycle 程度では復旧しない深い state)。

5. **GRUB countdown 300s 観測**: wrapper 設定は timeout=3 だが actual で 300s countdown。 build と関係なく出現条件が変わる挙動。 root cause 未解明。

6. **Phase 11 plan の Phase 11.5 5d (`quiet` 削除版 ISO で SOL kernel printk 強制出力)** は次セッション最優先。 ただし D3373 物理 UART が iRMC SOL に bridge されていない問題 ([training_tx1320_kernel_silent_post_grub.md](../MEMORY.md)) が立ちはだかる可能性。

## Phase 9-10 で見逃された signature の修正提案

```sh
SOL_LOG=tmp/<sid>/sol.log
BOOTING=$(grep -c "Booting \`" "$SOL_LOG")
LOADING_BL=$(grep -c "Loading bootloader" "$SOL_LOG")
STAGES=$(grep -c "INSTALLER_STAGES" tmp/<sid>/sol-monitor.log)

if [ "$BOOTING" -gt 5 ]; then
    echo "🚨 triple-fault loop (kernel boot 後 reset): Booting=$BOOTING / Loading=$LOADING_BL"
elif [ "$LOADING_BL" -gt 5 ]; then
    echo "🚨 triple-fault loop (GRUB stage reset, Phase 9-10 type): Loading=$LOADING_BL"
elif [ "$BOOTING" -eq 1 ] && [ "$STAGES" -ge 1 ]; then
    echo "✅ installer 進行 (stage 観測)"
elif [ "$BOOTING" -eq 1 ]; then
    echo "⚠️  kernel jump 成功 (silent boot) — stage 観測なし、 long-run NFS read で間接判定"
else
    echo "未到達 (BIOS POST stage)"
fi
```

## Phase 12 への引き継ぎ事項

| # | タスク | 優先度 | 補足 |
|---|--------|--------|------|
| 1 | wrapper を改造して cmdline に `earlyprintk=ttyS0,115200n8 loglevel=8 ignore_loglevel` 追加 + `quiet` 削除 | 最高 | SOL に kernel printk が出れば fault 原因 (panic / oops) 直接確認可能 |
| 2 | stock 13.3.0 ISO を **wrapper 経由せず** 直接 NFS attach + boot で baseline 取得 | 高 | wrapper の問題か kernel/HW の問題かの切り分け |
| 3 | Debian 12 (bookworm) ISO を attach + boot で base ISO 互換性確認 | 高 | Debian 13 kernel + D3373 の互換性問題なら 12 で動く可能性 |
| 4 | GRUB countdown 300s の root cause 究明 | 中 | actual に effective な grub.cfg がどれかを確定 |
| 5 | sol-monitor.py の PowerState polling が常に `None` を返す bug 調査 | 中 | 切り分け中の補助 metric として | 
| 6 | MEMORY.md `training_tx1320_phase10_cmdline_bisect_solved` entry を「誤判定」記述で更新 | 高 | 以後の試行で同じ誤判定を繰り返さないため |
| 7 | Phase 10 attachment の `summary.txt` で `Kernel/installer printk hits` を「Booting cycles (= triple-fault count)」に renamename | 低 | ドキュメント整合性 |

## 関連レポート / メモ

- [Phase 10 (2026-05-22 phase10-072719): cmdline bisect 完了 — 誤判定 (本レポートで訂正)](2026-05-22_082633_tx1320_raid10_phase10_cmdline_bisect_solved.md)
- [Phase 9 (2026-05-22 phase9-060436): stock 13.3.0 ISO 直接 boot で remaster wrapper cmdline が真因と確定](2026-05-22_071405_tx1320_raid10_phase9_remaster_cmdline_isolated.md)
- [Phase 8 (2026-05-22 phase811): triple-fault reset loop 観測 + iRMC OEM Screenshot 発見](2026-05-22_055158_tx1320_raid10_phase8_iter11to13.md)
- MEMORY.md `training_tx1320_phase10_cmdline_bisect_solved.md` (Phase 10 結果の memory entry、 本セッションで誤判定として訂正)
- MEMORY.md `training_tx1320_kernel_silent_post_grub.md` (Phase 3-9 経緯まとめ)
- MEMORY.md `training_tx1320_irmc_kvm_framebuffer_artifact.md` (KVM 黒画 framebuffer artifact)
