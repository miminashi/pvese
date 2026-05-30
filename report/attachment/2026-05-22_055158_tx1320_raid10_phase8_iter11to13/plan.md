# Phase 8: iter11 (default cmdline + 実 VGA 観測) から始める決定的切り分け

## Context

Phase 7 (2026-05-22 04:11) で 2 つの大きな結果が出た:

1. **iter6 (`acpi=off noapic`) は kernel triple-fault reboot loop**。SOL に GRUB countdown が 10 秒周期で 33 回繰り返し、kernel printk は 1 行も出ない。kernel は確かに動いて (jump して) いるが reset を繰り返す。
2. **iRMC KVM viewer (canvas / locator 両方) は framebuffer mode 変更後 capture に失敗する**。Memtest86+ native UEFI は実 VGA monitor で UI 表示成功している (user 観測) のに iRMC KVM canvas は 2724 B 黒画のまま。

(2) の発見は **Phase 3-5 の「kernel jump 後 KVM 黒画 = silent hang」解釈を直接無効化**する。Phase 3-5 で残った信頼可能な証拠は SOL kernel printk = 0 と NFS READ = 0 のみ。これらは「kernel が serial init を完了していない」「kernel が cdrom-detect に到達していない」を意味するが、kernel 自体が hang しているとは限らない (Debian 13 installer が serial console を尊重していないだけ等の可能性が出てくる)。

**Phase 8 の目的**: Phase 3-5 の「silent hang」前提自体が正しかったかを実 VGA 観測で確定し、その結果に応じて次の探索方向を確定する。実 VGA は Phase 7 で Memtest86+ 観測に user が成功した実績ある手段で、KVM artifact を完全に bypass できる。

## Goal

iter11 で **Phase 3-5 default cmdline ISO の boot 挙動を実 VGA monitor で観測**し、kernel が本当に hang していたか、それとも KVM artifact による誤診だったかを **1 回の観測で確定**する。

## Step 1 (今 session の核): iter11 = default cmdline + 実 VGA

### 構築
- `EXTRA_CMDLINE=""` (空、 = Phase 3 iter0 と等価) で ISO build
- 名前: `debian-training-tx1320-iter11.iso`
- preseed は既存 (`tmp/training-tx1320-preseed-raid10.cfg`) を流用

### 配信
- playground (10.1.6.6, ubuntu user) の `/var/samba/public/` に scp + mv
- iRMC NFS Virtual Media で attach

### 実行
- SOL を bg capture (`sol-monitor.py --timeout 360`) で開始
- `bmc-power.sh boot-override Cd UEFI` + `bmc-power.sh on`
- KVM screenshot を t60, t120, t180, t240, t300 で `--capture-mode=locator` 撮影 (KVM は補助情報、 artifact 警戒)
- **user に物理 VGA monitor 観測を依頼** (Phase 7 と同じ方式)
  - t0 直後の BIOS POST 表示有無
  - GRUB countdown / menu 表示有無
  - GRUB boot 後の画面 (installer / 黒 / panic 等)
  - 5 分時点の最終画面
- 5 分後 `bmc-power.sh forceoff`

### 結果分岐

#### Outcome A: VGA で installer / kernel boot 出力が見える
**意味**: Phase 3-5 の「kernel silent hang」前提は **誤診**。KVM artifact によるもの。kernel は実際には動いていた。

**残る謎**: なぜ SOL kernel printk = 0 と NFS READ = 0 になるか。
- 仮説: D3373 BIOS が serial UART を init していない / Debian 13 kernel が ttyS0 を見つけられない
- 仮説: NFS Virtual Media が GRUB→kernel 引き継ぎ時に detach されている (HDImage 経路の MaxDev=0 とは別の機序)
- 仮説: installer (debian-installer) が graphical mode で起動して serial を出していない

**次アクション** (今 session 中に時間が余れば):
- `EXTRA_CMDLINE="console=ttyS0,115200n8 console=tty0"` で再 build (iter11b)
- VGA 観測で installer の動きを確認 + SOL に出力が出始めるか確認

#### Outcome B: VGA が黒 / freeze / panic 表示
**意味**: kernel は本当に hang している。Phase 3-5 解釈は KVM 単体では誤りだったが結論 (kernel hang) は正しかった。

**次アクション** (今 session 中、時間が余れば):
- iter7 (`pci=noacpi nolapic`) を SOL + KVM のみで実施
- iter13 (`acpi=off noapic initcall_debug loglevel=8 debug earlyprintk=efi,keep`) を SOL のみで実施
- 出力差で triple-fault や hang の発生位置を絞る

### Verification

| 証拠 | 取得方法 | 信頼度 |
|------|---------|--------|
| 実 VGA 観測 | user 報告 | **最高 (一次情報)** |
| SOL kernel printk | `tmp/<sid>/iter11/sol.log` の最終行・行数 | 高 (kernel init 後の唯一の serial 経路) |
| NFS READ packet 数 | playground 側 `tcpdump`、 NFS server 側 stat (もし可能なら) | 中 (kernel 内部から NFS mount 完了の証拠) |
| KVM screenshot (locator) | `irmc-kvm-interact.py --capture-mode=locator` | **低 (artifact 警戒、参考のみ)** |

## Step 2 (今 session で時間が余れば、 outcome により分岐)

### Outcome A 分岐 (KVM artifact 誤診だった)
- iter11b: `EXTRA_CMDLINE="console=ttyS0,115200n8 console=tty0"` (serial console を強制) → SOL に kernel printk が出るか確認
- 出れば: Debian 13 installer 自体は動いていた、 deploy 経路を見直す phase へ
- 出なければ: D3373 UART 物理初期化の問題、 BIOS 設定 (serial redirection、 console port type) の見直しが必要

### Outcome B 分岐 (本当に hang していた)
- iter7: `EXTRA_CMDLINE="pci=noacpi nolapic"` (user 提案 a)
- iter13: `EXTRA_CMDLINE="acpi=off noapic initcall_debug loglevel=8 debug earlyprintk=efi,keep"` (user 提案 b、 iter6 + max debug)
- iter15: `EXTRA_CMDLINE="acpi=off"` only (`noapic` 無し、 ACPI 単独 disable のサブ反証)
- 各 iter で SOL log 全行確認 → kernel printk 出力位置の差分から triple-fault 原因絞り込み

### 別 OS 試行 (user 提案 c) — Step 3 以降に保留
今 session ではスコープ外。iter11 で原因が大きく絞れたら、必要に応じて次 session で:
- Debian 12.11 stock UEFI (kernel 6.1 LTS) で同じ振る舞いか確認
- Ubuntu 24.04 LTS stock UEFI (kernel 6.8) で確認

これらは preseed なしの stock boot で十分。serial 出力なしのため VGA 観測が必須になるが、 iter11 で 1 回しか VGA 依頼しない方針なので別 session に分ける方が user 負担が小さい。

## Critical files (流用、 修正不要)

- `scripts/remaster-debian-iso.sh` — `EXTRA_CMDLINE` 環境変数で `--- quiet` 直前に挿入する仕組みが Phase 7 で実装済
- `scripts/irmc-virtualmedia.sh` — `--share-type=NFS` + config / connect-cd / disconnect-cd / mount が Phase 7 で対応済
- `scripts/sol-monitor.py` — `--log-file` + `--timeout` で bg capture
- `scripts/bmc-power.sh` — `on` / `forceoff` / `boot-override Cd UEFI`
- `scripts/irmc-kvm-interact.py` — `--capture-mode=locator` (補助のみ、 artifact 警戒)

## 既存 ISO の扱い

- playground 上の `/var/samba/public/debian-training-tx1320-iter6.iso` (Phase 7) は残す (iter7 / iter13 のとき再利用予定なし、 新規 ISO build)
- `/var/samba/public/debian-training-tx1320-iter0.iso` (Phase 3 default cmdline) は存在の可能性あるが、 確実性のため iter11 として新規 build
- ISO build は ~30 秒で完了するので毎回 build する方が確実

## メモリ更新予定 (iter11 終了後)

- `training_tx1320_kernel_silent_post_grub.md`: iter11 結果を Phase 8 セクションとして追記、 「silent hang」前提の真偽を確定
- `training_tx1320_irmc_kvm_framebuffer_artifact.md`: iter11 で再確認した KVM artifact の挙動 (もし観測が一致するなら) を追記
- (Outcome A の場合) 新規 `training_tx1320_serial_console_mystery.md`: D3373 UART / Debian 13 installer の serial 取扱いに関する仮説と検証メモ

## Out of scope (今 session)

- Debian 12 / Ubuntu 24.04 boot 試行 (Step 3 以降、 別 session)
- preseed 改善 / setup-raid10-storcli.sh の修正 (kernel boot が成功したあと)
- iRMC FW update / BIOS update (eLCM ライセンスなしで手段なし、 別問題)
- 本機の RAID 構成変更 (HW RAID10 既存をそのまま使う)

## Report (今 session 終了時)

- `report/2026-05-22_<HHMMSS>_tx1320_raid10_phase8_iter11.md`
- 内容: iter11 build / 配信 / boot / 実 VGA 観測結果 / Outcome A or B 判定 / Step 2 で時間内に追加実施した内容 / 次セッション継続事項
- 添付: SOL log、 KVM screenshot 5 枚、 plan.md コピー
