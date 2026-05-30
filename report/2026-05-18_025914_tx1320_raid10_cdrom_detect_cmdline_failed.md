# TX1320 RAID10 cdrom-detect 突破試行: kernel cmdline + preseed 両方注入は無効と判明

- **実施日時**: 2026年5月18日 02:21 〜 03:00 (JST、 約 39 分)
- **担当**: s-peaceful-hinton
- **Issue**: #69 (継続中、 blocked)
- **対象**: training-tx1320 (10.254.254.9, Fujitsu PRIMERGY TX1320 M3, iRMC S4 FW 9.08F)
- **親レポート**: [2026-05-17_125823_tx1320_raid10_smb_attach_solved.md](2026-05-17_125823_tx1320_raid10_smb_attach_solved.md) (p-effervescent-kahn、 SMB attach 真因確定 + 改修済、 cdrom-detect で blocked)
- **方針**: 前セッションが提示した cdrom-detect 突破策の最優先候補 (preseed + GRUB cmdline 両方に `cdrom-detect/try-usb=true` 等を仕込む) を実装して通し再試行

## 添付ファイル

- [実装プラン](attachment/2026-05-18_025914_tx1320_raid10_cdrom_detect_cmdline_failed/plan.md)
- [OEM screenshot: BIOS POST → CD boot 遷移](attachment/2026-05-18_025914_tx1320_raid10_cdrom_detect_cmdline_failed/oem-04-after-cycle.jpg) — fresh attach + power on 後の BIOS POST F12 prompt
- [OEM screenshot: Booting Automated Install (CD boot 成功)](attachment/2026-05-18_025914_tx1320_raid10_cdrom_detect_cmdline_failed/oem-05-around-2min.jpg)
- [OEM screenshot: Booting Automated Install 継続 (kernel ロード中)](attachment/2026-05-18_025914_tx1320_raid10_cdrom_detect_cmdline_failed/oem-06-grub-loop.jpg)
- [SOL ログ全文 (kernel boot + cdrom-detect 失敗 + dialog 待機)](attachment/2026-05-18_025914_tx1320_raid10_cdrom_detect_cmdline_failed/sol.log)
- [USB redirector cycle helper script](attachment/2026-05-18_025914_tx1320_raid10_cdrom_detect_cmdline_failed/usb-redirector-cycle.sh)

## 前提・目的

前セッション #6 (p-effervescent-kahn) で SMB silent failure (空 user/pass) 真因確定 + 修正により CD boot + kernel boot まで成功したが、 `[!!] Detect and mount installation media — No device for installation media was detected` で停止していた。 同レポートで提示された突破策候補:

1. preseed に `hw-detect`/`cdrom-detect/try-usb=true` 系を追加 (~ 30 min)
2. GRUB cmdline へ `cdrom-detect/try-usb=true` / `cdrom-detect/scan=true` を追加 (~ 60 min)

ユーザ確認の上 (1)+(2) belt-and-suspenders で実装することを決定。 chicken-and-egg 問題 (preseed.cfg は `/cdrom/preseed.cfg` から load されるため cdrom-detect が通らないと preseed 自体が適用されない) があるので、 **kernel cmdline 側が本命** で preseed 側は保険という方針。

ゴール:
1. cdrom-detect が iRMC USB CD を認識して installer 続行
2. partman/early_command で setup-raid10-storcli.sh による RAID10 作成
3. install 完走 + SSH 検証

## 実施内容と結果

### Phase 1: スクリプト・テンプレート修正 ✅

`scripts/remaster-debian-iso.sh` の kernel cmdline 3 箇所 (L100 GRUB legacy / L110 ISOLINUX `txt.cfg` auto / L173 EFI grub-mkstandalone embed.cfg) に以下を `netcfg/choose_interface=auto` 直後に追加:

```
cdrom-detect/try-usb=true cdrom-detect/scan=true hw-detect/load_media=false
```

`preseed/preseed.cfg.template` L65 (`anna/no_kernel_modules` 直後) に同等の d-i directive 3 行追加 (保険):

```
d-i cdrom-detect/try-usb boolean true
d-i cdrom-detect/scan boolean true
d-i hw-detect/load_media boolean false
```

### Phase 2: ISO 再 remaster ✅

```sh
./oplog.sh ./scripts/tx1320-raid10-orchestrate.sh build config/training_tx1320.yml
```

新 ISO 出力: `/var/samba/public/debian-training-tx1320-raid10.iso` (764 MB、 ホスト名 `training-tx1320` から派生で前 ISO とファイル名が異なる)。

Sanity check で 3 つの boot loader 全てに `cdrom-detect/try-usb=true cdrom-detect/scan=true hw-detect/load_media=false` 文字列が含まれることを確認:

- `/boot/grub/grub.cfg` (BIOS GRUB) ✓
- `/isolinux/txt.cfg` (ISOLINUX `auto` label) ✓
- `/boot/grub/efi.img` 内 `EFI/boot/bootx64.efi` (UEFI grub-mkstandalone 経由、 `strings` で確認) ✓
- ISO root `preseed.cfg` の d-i directive 3 行 ✓

### Phase 3: deploy + USB redirector fresh attach ✅

`./scripts/tx1320-raid10-orchestrate.sh deploy` で:

- Phase 5a: SMB config PATCH (guest/guest 明示、 ImageName=`debian-training-tx1320-raid10.iso`) → HTTP 200
- Phase 5b: boot-override Cd UEFI 設定
- Phase 5c: ForceOff (PowerState=Off 状態なので ResetType=ForceOff は AllowableValues 不一致で reject、 `|| true` で吸収) → Power On

1 回目の Power On 後 OEM screenshot で BIOS Setup (Aptio Main 画面) に落ちることを確認 — 前セッションでも観察された「PATCH 直後 attach は POST 中 USB enumeration とタイミングが合わない」症状。 対策として fresh attach 手順を実施:

```sh
./oplog.sh ./scripts/bmc-power.sh forceoff 10.254.254.9 ...
sh tmp/peaceful/usb-redirector-cycle.sh  # DisconnectCD → reject (既に disconnected), ConnectCD → HTTP 204
./oplog.sh ./scripts/bmc-power.sh on 10.254.254.9 ...  # POWER_ON_RESET_TYPE=On
```

備考: 電源 Off 状態では DisconnectCD は AllowableValues から外れて HTTP 400 reject (currently disconnected)、 ConnectCD は HTTP 204 成功。 前セッション報告の「PowerState=Off でも DisconnectCD / ConnectCD は両方 HTTP 204」 は **接続状態に依存** であり、 PowerState 単独では決まらないことを補強。 状態遷移は: PATCH 直後 → Disconnected (内部状態) → BIOS 起動完了で AutoAttach → Connected ... のように非同期。 結局のところ「Connected なら DisconnectCD のみ可」「Disconnected なら ConnectCD のみ可」が唯一の判定基準。

### Phase 4: CD boot + kernel boot 成功 ✅

Fresh attach + Power On 後の OEM screenshot で `Booting "Automated Install"` 表示確認。 SOL ログから `[ 0.076171] x86/cpu: SGX disabled or unsupported by BIOS.` で kernel boot 開始も確認。

ただし `Booting "Automated Install"` 表示後の VGA 画面は static (kernel が console=ttyS0 に移行)、 以降の installer 出力は SOL log のみで観測可能。

### Phase 5: installer 起動 → ⚠️ cdrom-detect 依然失敗 (cmdline 注入は無効)

SOL ログから cdrom-detect の dialog が前セッションと**完全同一**で停止していることを確認:

```
[!!] Detect and mount installation media

No device for installation media was detected.

You may need to load additional drivers from removable media, such as
a driver floppy or a USB stick. If you have these available now,
insert the media, and continue. Otherwise, you will be given the
option to manually select some modules.

Load drivers from removable media?  <Yes>  <No>
```

SOL log の installer status bar に表示される d-i 内部時刻 (`May 18 3:09 → 3:10 → 3:11`) が連続して進んでいるため reboot loop ではなく**確かに同じ dialog で停止**。

#### 確認できたこと

- `cdrom-detect/try-usb=true` / `cdrom-detect/scan=true` を kernel cmdline で渡しても、 iRMC OEM Virtual Media の USB CD は installer kernel から認識されない (= installer の cdrom-detect 内部 udev ルールにマッチしない)
- kernel cmdline `hw-detect/load_media=false` も dialog の auto-No 化に効かなかった (dialog は通常通り表示されて入力待ち)
- preseed の同等 directive は preseed.cfg が `/cdrom/preseed.cfg` から load される設計のため、 cdrom-detect 失敗の時点で**そもそも適用されない** (chicken-and-egg)

#### SOL ログ観察上の注意 (誤読防止)

- ログ中 `Booting "Automated Install"` および `GNU GRUB version 2.1-9+deb13u2` の繰り返し出現 (16 回) は **reboot loop ではない**: SOL session reconnect 時 / sol-monitor.py 再起動時に IPMI が SOL ring buffer をリプレイした結果。 installer 内部時刻が単調増加するか、 PowerState polling が安定 On であるかを判定基準にすること
- `Eied` の文字列は `Verified` (UEFI Secure Boot 検証) の先頭文字 `V`/`e`/`r` が SOL の char-drop で欠落した残り (`V[e]rified` → `[V]e[r]i[f]ied` → 表示で `Eied` に見える)

### Phase 6: クリーンアップ ✅

`./scripts/bmc-power.sh forceoff` で host を Off に戻し、 sol-monitor.py と Monitor task を停止。

## 完了事項

- [x] kernel cmdline に cdrom-detect hint を埋め込み (GRUB legacy / ISOLINUX / EFI 全 3 経路)
- [x] preseed.cfg.template に d-i directive 追加
- [x] 改修 ISO 再 remaster + sanity check で 3 経路全て + preseed に hint が埋まっていることを確認
- [x] deploy + fresh attach (forceoff → DisconnectCD/ConnectCD → on) で CD boot + kernel boot 成功
- [x] installer 起動 (cdrom-detect dialog 到達)
- [x] **cdrom-detect は kernel cmdline 注入では突破できない**ことを確定
- [x] SOL ログ観察上の誤読パターン (reboot loop に見える reconnect リプレイ、 Verified が Eied に見える) を文書化
- [x] DisconnectCD/ConnectCD は接続状態依存で AllowableValues 制御されることを再確認

## 未完了 / 次セッション課題

### 1. cdrom-detect 突破策の次の候補 (最優先 blocker)

kernel cmdline 注入が無効と判明したので、 別アプローチを試す必要あり。 候補 (優先順):

1. **initrd preseed 注入 + preseed/early_command で `mount /dev/sr0 /cdrom`** (~ 60 min): preseed.cfg を initrd に焼き込み、 cdrom-detect 失敗後に自前で device mount を試みる。 `cdrom-detect/cdrom_device=/dev/sr0` 等を combined で渡す
2. **iRMC HD Image (USB Mass Storage) 経由配信** (~ 90 min): OEM `VirtualMedia` の CDImage ではなく HDImage で ISO を提供すると `/dev/sdX` として認識される可能性。 install ISO は ISO9660 で読める block device があれば installer が hd-media mode で動作する場合がある
3. **PXE / netboot 経路** (~ 120 min): TFTP で kernel + initrd を配信、 installer は HTTP で `install/url=` 指定の ISO を直接 fetch。 USB CD 経路完全廃止
4. **debian-installer の hd-media モード使用** (~ 60 min): `vmlinuz-hd-media` + `initrd-hd-media.gz` をブートし、 ISO はファイルとして HD 上に置く。 ただし HD があらかじめ必要 → USB stick / iRMC HDImage 経由
5. **Live ISO + 手動 storcli** (~ 60-90 min): Debian Live ISO で boot → SSH 経由 storcli RAID10 作成 → 別 deb 配信で OS install (preseed なし)。 RAID10 作成だけを優先する pivot

### 2. orchestrate.sh monitor `--timeout` 引数バグ (副次、 持ち越し)

`scripts/tx1320-raid10-orchestrate.sh` L56/L85 で monitor サブコマンド時に `$3 = --timeout` を OUTPUT_ISO として扱い、 `basename --timeout` で失敗するバグは未修正。 monitor は引数なし default で動かす。

### 3. SOL ログの reconnect リプレイ判定 (副次)

sol-monitor.py 起動時に IPMI SOL ring buffer が再送されて、 ログ上で kernel boot が複数回起きたように見える誤読が発生する。 解析時は installer 内部時刻 / PowerState 推移を真の進行指標として使う。 sol-monitor.py 側で「ring buffer リプレイ部分」 を初期スキップする改良も可 (副次タスク)。

## 再現方法

```sh
# 改修済 (本セッションで commit 予定):
#   scripts/remaster-debian-iso.sh L100/L110/L173 に cdrom-detect/try-usb=true ...
#   preseed/preseed.cfg.template L65 直後に d-i cdrom-detect/try-usb=true 等

# 1. ISO 再 build (既に新 ISO 生成済、 再実行する場合):
./oplog.sh ./scripts/tx1320-raid10-orchestrate.sh build config/training_tx1320.yml

# 2. deploy (SMB config + boot-override + power cycle):
./oplog.sh ./scripts/tx1320-raid10-orchestrate.sh deploy config/training_tx1320.yml

# 3. (もし BIOS Setup に落ちたら) fresh attach:
BMC_SCHEME=https BMC_CURL_OPTS='--ciphers DEFAULT@SECLEVEL=0' \
    ./oplog.sh ./scripts/bmc-power.sh forceoff 10.254.254.9 claude Claude123
sh tmp/<SID>/usb-redirector-cycle.sh   # DisconnectCD + ConnectCD
BMC_SCHEME=https BMC_CURL_OPTS='--ciphers DEFAULT@SECLEVEL=0' POWER_ON_RESET_TYPE=On \
    ./oplog.sh ./scripts/bmc-power.sh on 10.254.254.9 claude Claude123

# 4. monitor (default 2700s):
./oplog.sh ./scripts/tx1320-raid10-orchestrate.sh monitor config/training_tx1320.yml

# 5. 観察される結果 (本セッション再現):
#   - SOL log に kernel boot ([ 0.076171] SGX disabled)
#   - SOL log 末尾に cdrom-detect dialog (Load drivers from removable media? <Yes> <No>)
#   - installer 内部時刻 (May 18 H:MM) 単調増加 = dialog で input 待ち
#   - cdrom-detect 失敗、 partman/early_command 未到達
```

## 環境情報

- **対象機**: training-tx1320 (Fujitsu PRIMERGY TX1320 M3, Serial MABK035229)
- **BMC**: iRMC S4 FW 9.08F (10.254.254.9, HTTPS + SECLEVEL=0 必須, claude/Claude123)
- **CPU/RAM**: D3373 mainboard, 24 GiB RAM
- **HW**: AVAGO MegaRAID (LSI SAS3008 系)、 SAS HDD 900GB × 4 (RAID10 未構成)
- **BIOS**: V5.0.0.11 R1.22.0 for D3373-B1x
- **SMB server**: 10.1.6.1 (ローカル Claude Code 実行マシン ens19)、 Samba 4.19.5
- **ISO**: `/var/samba/public/debian-training-tx1320-raid10.iso` (764 MB、 本セッションで新規生成)
- **本セッションの BMC 操作**: PATCH OEM VirtualMedia (guest 明示), boot-override Cd UEFI, ForceOff x2, On x2, ConnectCD x1 (DisconnectCD は AllowableValues 外で reject), OEM Screenshot x6

## 関連 Issue

- **#69 (継続、 status=block)** — owner s-peaceful-hinton (引き継ぎ後)、 blocker は cdrom-detect 突破に kernel cmdline 注入では足りない点
  - 前々セッション #5 (d-eager-island): preseed + storcli 設計完成、 SMB silent failure で blocked
  - 前セッション #6 (p-effervescent-kahn): SMB silent failure 真因確定 + 改修。 CD boot → installer 起動まで到達、 cdrom-detect で blocked
  - **本セッション #7 (s-peaceful-hinton)**: kernel cmdline + preseed 両方に cdrom-detect/try-usb=true 系を仕込んで通し再試行 → 効かず (iRMC USB CD は installer 内部 udev でマッチしない)
  - **次セッション推奨手順** (優先順):
    1. initrd preseed 注入 + early_command で自前 mount (一番速い、 既存スクリプト改造で済む)
    2. iRMC HDImage 経由配信 (もし CDImage が USB Mass Storage CD-ROM emulation で installer 環境で識別できないなら、 HDImage の方が確実)
    3. Live ISO + 手動 storcli pivot (preseed 完全自動化を諦める)

## 関連ファイル

### 修正 (本セッション)

| ファイル | 行 | 修正内容 |
|---------|-----|---------|
| `scripts/remaster-debian-iso.sh` | L100, L110, L173 | kernel cmdline に `cdrom-detect/try-usb=true cdrom-detect/scan=true hw-detect/load_media=false` を `netcfg/choose_interface=auto` 直後に追加 (3 経路) |
| `preseed/preseed.cfg.template` | L65 直後 | `d-i cdrom-detect/try-usb boolean true` / `d-i cdrom-detect/scan boolean true` / `d-i hw-detect/load_media boolean false` 3 行追加 + コメント |
| `/var/samba/public/debian-training-tx1320-raid10.iso` | — | 上記改修を反映した新 ISO (764 MB)。 ホスト名 `training-tx1320` 経由で前 ISO `debian-tx1320-raid10.iso` とはファイル名が異なる |
| `.claude/skills/irmc-bios-raid/SKILL.md` | (後段で追記) | cdrom-detect kernel cmdline 注入では iRMC USB CD は認識できない知見 + 次の候補一覧 |
| `/home/ubuntu/.claude/projects/-home-ubuntu-projects-pvese/memory/training_tx1320.md` | 「### 9. cdrom-detect」 | 「kernel cmdline cdrom-detect/try-usb=true は iRMC では効かない」 という結論を追記 |

### 無修正 (確認のみ)

- `config/training_tx1320.yml` — smb_user=guest / smb_pass=guest は #6 で追加済
- `scripts/tx1320-raid10-orchestrate.sh` — build / deploy / monitor 構造は流用 (monitor `--timeout` バグは scope 外)
- `scripts/irmc-virtualmedia.sh` — guest/guest 引数 7-8 受け取り対応済
- `scripts/setup-raid10-storcli.sh` — partman/early_command 経由実行、 本セッションでは未到達

## 重要な教訓 (次セッションへの引き継ぎ)

1. **iRMC OEM CDImage は installer kernel から USB CD device として見えない**: kernel cmdline `cdrom-detect/try-usb=true` `cdrom-detect/scan=true` `hw-detect/load_media=false` を渡しても installer の cdrom-detect 内部 udev/sysfs ルールにマッチしない。 GRUB レベルでは普通に CD として読めるため kernel + initrd は load できるが、 Linux 起動後の cdrom-detect が認識しない (BIOS USB CD-ROM emulation と Linux USB Mass Storage class の境目で消失)
2. **chicken-and-egg**: preseed.cfg を `/cdrom/preseed.cfg` 経由で load する設計上、 cdrom-detect が通らないと preseed 自体が適用されない。 preseed 側の cdrom-detect 突破 directive は belt-and-suspenders にもならない (適用される頃には既に手遅れ)
3. **fresh attach 手順は依然有効**: forceoff → DisconnectCD/ConnectCD (接続状態によりどちらかが reject、 もう一方が通る) → power on で BIOS POST 開始時から CD device を見える状態を作れる
4. **SOL ログ reconnect リプレイの誤読**: sol-monitor.py 再起動時に SOL ring buffer がリプレイされ、 同じ kernel boot を複数回見たように錯覚する。 真の進行指標は installer 内部時刻の単調増加と PowerState polling
5. **AllowableValues は接続状態依存 (PowerState 単独ではない)**: `VirtualMediaAction@Redfish.AllowableValues` は Connected → `["DisconnectCD"]`、 Disconnected → `["ConnectCD"]`、 BIOS Setup 中 → `[]` の動的遷移。 reject されたら状態を読み直す
6. **`hw-detect/load_media=false` は kernel cmdline からは dialog 抑制に効かない**: priority=critical でも cdrom-detect 失敗時の "Load drivers?" は手動入力前提で表示される
7. **次に試すべき候補は initrd preseed 注入 + 自前 mount, あるいは iRMC HDImage 経由配信**: kernel cmdline 経由の修正は本機で打ち止め。 別レイヤーでの突破が必要
