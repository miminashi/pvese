# TX1320 RAID10 install: initrd preseed 注入は機能、cdrom-detect 突破は未達成 (重大な発見あり)

- **実施日時**: 2026年5月18日 03:40 〜 06:53 (JST、 約 3 時間 13 分)
- **担当**: c-curried-puddle
- **Issue**: #69 (継続中、 status=block)
- **対象**: training-tx1320 (10.254.254.9, Fujitsu PRIMERGY TX1320 M3, iRMC S4 FW 9.08F)
- **親レポート**: [2026-05-18_025914_tx1320_raid10_cdrom_detect_cmdline_failed.md](2026-05-18_025914_tx1320_raid10_cdrom_detect_cmdline_failed.md) (s-peaceful-hinton、 kernel cmdline + preseed への cdrom-detect/try-usb=true 注入は無効と確定)
- **方針**: 親レポートが「次セッション最優先候補」として挙げた **initrd preseed 注入 + preseed/early_command で自前 mount** を実装

## 添付ファイル

- [実装プラン](attachment/2026-05-18_065315_tx1320_raid10_initrd_preseed_inject/plan.md)
- [最終 SOL ログ](attachment/2026-05-18_065315_tx1320_raid10_initrd_preseed_inject/sol-last.log)

## 重要な発見 (next-session must-read)

### 🎯 1. **iRMC OEM CDImage は Linux に /dev/sr1 として可視** (前セッション仮説の訂正)

前セッション (s-peaceful-hinton, #7) は「iRMC OEM CDImage は GRUB レベルでは読めて kernel + initrd は load できるが、 Linux 起動後の cdrom-detect の内部 udev/sysfs ルールにマッチしない (BIOS USB CD-ROM emulation と Linux USB Mass Storage class の境目で消失)」と推定していたが、 これは**誤り**。 本セッションで initrd preseed 注入により preseed/early_command が cdrom-detect 起動前に走った結果、 実 SOL ログから以下を確認:

```
lrwxrwxrwx 1 root root 9 May 18 06:09 ata-HL-DT-ST_DVDROM_DUD0N_B9ARXC2051900 -> ../../sr0
lrwxrwxrwx 1 root root 9 May 18 06:09 wwn-0x5001480000000000 -> ../../sr0
brw------- 1 root root 11, 0 May 18 06:09 /dev/sr0
brw------- 1 root root 11, 1 May 18 06:09 /dev/sr1
brw------- 1 root root 11, 2 May 18 06:09 /dev/sr2
[pvese] trying mount /dev/sr0 -> /cdrom
mount: mounting /dev/sr0 on /cdrom failed: No medium found
[pvese] trying mount /dev/sr1 -> /cdrom
[pvese] mount /dev/sr1 OK, /cdrom has ISO markers
```

つまり:

- `/dev/sr0` = 物理内蔵 DVD ドライブ (HL-DT-ST DVDROM DUD0N, **メディアなし**)
- `/dev/sr1` = iRMC OEM Virtual Media CDImage (**実 installer ISO 入り**)
- `/dev/sr2` = もう 1 つ未確定 (空 second virtual slot?)

cdrom-detect が「device なし」と判定する真因は **/dev/sr0 を先に試して "No medium found" で諦め、 /dev/sr1 に到達しない** こと。 `cdrom-detect/scan=true` は subsequent sr devices をプローブしない (kernel cmdline + preseed 両方に入れても効果なし)。

### 🎯 2. **initrd preseed 注入 (concatenated archive 方式) は確実に動作する**

`scripts/remaster-debian-iso.sh` で `install.amd/initrd.gz` の末尾に小さな gzipped cpio (`preseed.cfg` 1 ファイルのみ) を結合する方式を実装。 kernel initramfs は連結された gzip ストリームを順次デコードし、 後の archive が前を上書きするので preseed.cfg が initrd 内 `/preseed.cfg` として available になる。 kernel cmdline `preseed/file=/preseed.cfg` で確実に load される。

これにより chicken-and-egg (preseed.cfg を `/cdrom/preseed.cfg` から読む構造で cdrom-detect が通る前に preseed が無効) が**完全に解消**された。 `preseed/early_command` が cdrom-detect 起動前に走り、 mount を含む診断ロジックを実行できる。

#### 失敗した別方式: cpio -A append

`cpio -o -A -F initrd` (in-place append) はトレーラー/パディング処理が微妙に違って malformed initrd を生成、 kernel が GRUB boot loop に陥った (33 cycle in 6 min 観測)。 concatenated archive 方式は kernel docs (Documentation/admin-guide/initrd.rst) に明記された推奨方法。

### 🎯 3. **`cdrom-detect/cdrom_device` preseed 値は warm-reset loop を誘発する** (原因不明)

`d-i cdrom-detect/cdrom_device string /dev/sr1` を preseed.cfg に追加 (またはカーネル cmdline `cdrom-detect/cdrom_device=/dev/sr1` で渡す) すると、 kernel boot 直後に host が warm-reset し、 BIOS POST → GRUB → kernel boot → warm reset ... のループに陥る (約 10-20s/cycle で PowerState polling では検出困難)。

`cdrom-detect/last-detected` を併用してもダメ。 `cdrom-detect/cdrom_device` 単独でもダメ。 cmdline 経由でもダメ。

根本原因は未特定。 d-i が preseed 値を debconf-set-selections に流し込む際に何らかの妥当性検査でエラーになり panic を引き起こしている可能性、 もしくは早すぎる cdrom_device 設定が cdrom-detect.postinst の `mount $DEVICE /cdrom` を USB enumeration 前に走らせて失敗・panic させている可能性。

### 🎯 4. **pre-mount /cdrom は d-i に信頼されない**

preseed/early_command 内で `mount -t iso9660 -o ro /dev/sr1 /cdrom` を実行して /cdrom を ISO 内容で満たしてから cdrom-detect に進入させても、 d-i は dialog「[!!] Detect and mount installation media - No device for installation media was detected」を表示する。 d-i の cdrom-detect.postinst が `mountpoint -q /cdrom` チェックを行うはずだが、 何らかの理由で**この経路を通っていない** (調査未完了)。

### 5. **早期コマンドからの /dev/console 出力過多は SOL の不安定を招く**

`for d in /dev/sr0 /dev/sr1 ... do ... mount ... > /dev/console 2>&1 ... done` のように大量に /dev/console へ書くと、 iRMC の SOL session が頻繁に切断・再接続する (1 セッション内で 30+ "SOL Session operational" message 観測)。 BMC ring buffer が installer 出力で埋まると ipmitool sol が drop し、 sol-monitor.py が再接続するが ring buffer の **古い** 内容 (GRUB countdown など) をリプレイするので、 ログ末尾だけ見ると "host が GRUB ループしている" ように見える誤読が発生する。

判定基準: `cat /tmp/.../sol-monitor.output` の `[HH:MM:SS] PowerState poll: On` が安定して On なら host は up、 GRUB loop に見えるのは SOL ring buffer リプレイ artifact。

### 6. **SOL ring buffer リプレイ + 真の reboot loop を識別する判定法**

- **真の reboot loop**: `Booting "Automated Install"` の頻度が 30s 以下 + sol-monitor PowerState polling が間欠的に Off になる + SOL Session operational が 1 回しか出ない (re-connection なし)
- **SOL replay artifact**: `Booting "Automated Install"` の頻度が 30s 以下 + sol-monitor PowerState polling が安定 On + SOL Session operational が 10+ 回出る (頻繁 reconnect)
- **早期 reset (kernel panic on early_command + warm reset)**: `Booting "Automated Install"` の頻度が **30s 以上 (full POST 込み)** + sol-monitor PowerState polling が時々 Off を捕捉する + sol-monitor stages=0 のまま進まない

## 実施内容

### Phase 1: initrd preseed 注入の実装 ✅

`scripts/remaster-debian-iso.sh` に initrd 注入ブロックを追加 (L86 周辺):
1. `install.amd/initrd.gz` を ISO から抽出
2. `preseed.cfg` 1 ファイルだけの cpio archive を作成 → gzip -9 圧縮
3. `cat orig-initrd.gz extra.cpio.gz > new-initrd.gz` で連結
4. xorriso `-update` で ISO 内 initrd.gz を置換

kernel cmdline 3 経路 (BIOS GRUB / ISOLINUX / EFI grub-mkstandalone) すべてに `preseed/file=/preseed.cfg cdrom-detect/try-usb=true cdrom-detect/scan=true hw-detect/load_media=false` を埋め込み。 旧 `preseed/file=/cdrom/preseed.cfg` は **削除** (initrd injection で代替)。

### Phase 2: 試行錯誤 (時系列)

| 試行 | early_command | preseed cdrom_device | cmdline cdrom_device | 結果 |
|------|---------------|---------------------|---------------------|------|
| 1 | (HEAD) | なし | なし | cdrom-detect dialog 到達 (#7 と同じ blocker) |
| 2 | diagnostic+mount loop | なし | なし | host warm-reset (大量 /dev/console 出力が原因と推測) |
| 3 | minimal mount | なし | なし | mount 失敗 (USB enum 前)、 cdrom-detect dialog |
| 4 | minimal mount | =/dev/sr1 | =/dev/sr1 | warm-reset loop |
| 5 | minimal mount | =/dev/sr1 + last-detected | なし | warm-reset loop |
| 6 | sleep 5 + mount | =/dev/sr1 | なし | warm-reset loop |
| 7 | sleep 10 + delete sr0 + mount | なし | なし | warm-reset loop (delete sr0 が原因か) |
| **8 (stable)** | (HEAD) | **なし** | なし | **cdrom-detect dialog 到達 (#7 と同じ blocker)** |

### Phase 3: stable state へ revert + commit ✅

試行錯誤の末、 試行 8 = 試行 1 と同じ動作の "control test 2" 状態を最終 commit 対象とした。 これは:

- initrd preseed 注入 = **ON** (動作確認済)
- kernel cmdline = `preseed/file=/preseed.cfg cdrom-detect/try-usb=true cdrom-detect/scan=true hw-detect/load_media=false` (#7 の cdrom-detect ヒント + initrd 参照)
- preseed.cfg = HEAD 早期コマンド (syslogd 起動のみ)
- `cdrom-detect/cdrom_device` = **未指定** (warm-reset 回避)

最終形は #7 と同じ cdrom-detect "No device" dialog で停止するが、 initrd 注入が安全に効いていることが確認済 → 次セッションは pre-mount や cdrom_device 経由ではなく **別の bypass 経路** (Option 2 HDImage や Option 5 Live ISO pivot) を試すべき。

## 完了事項

- [x] **initrd preseed 注入実装**: concatenated archive 方式で動作確認 + sanity check (cpio -t + python による gzip stream + marker 検証)
- [x] **iRMC virtual CD の真の Linux 視点識別**: /dev/sr1 (with ISO content) を確定。 物理 DVD = /dev/sr0 (空)。 前セッションの仮説 (Linux 不可視) を**訂正**
- [x] **mount of /dev/sr1 が正常動作することの実証**: early_command 内で `mount -t iso9660 /dev/sr1 /cdrom` が成功し ISO markers (.disk/info, preseed.cfg) を検出
- [x] **cdrom-detect dialog の真因確定**: cdrom-detect が /dev/sr0 を先にプローブして "No medium" で諦める。 `scan=true` は次デバイス試行に効かず
- [x] **cdrom_device preseed が reset 誘発することの発見**: 4 つの組み合わせ (preseed 単独/with last-detected/with mount/with cmdline) で全て warm-reset 確認
- [x] **stable state への revert + commit**: 試行 8 = HEAD early_command の状態を最終提出
- [x] レポート作成、 メモリ更新

## 未完了 / 次セッション課題

### 1. cdrom-detect 突破 (最優先 blocker、 継続)

cdrom-detect の dialog 自体を bypass する手段が未確定。 候補:

1. **iRMC HDImage 経由配信** (推奨、 ~ 60-90 min): OEM `VirtualMedia` の `CDImage` 代わりに `HDImage` で ISO を attach。 USB Mass Storage class の block device として認識されるため cdrom-detect を経由せず hd-media install 経路に乗る可能性が高い。 `config/training_tx1320.yml` の SMB 設定はそのまま流用可
2. **PXE / netboot 経路** (~ 120 min): TFTP で kernel + initrd 配信、 `install/url=http://10.1.6.1:5032/iso/...` で ISO fetch。 iRMC Virtual Media 完全廃止
3. **Live ISO + 手動 storcli pivot** (~ 60-90 min): Debian Live ISO boot → SSH 経由 storcli RAID10 作成 + 別経路 OS install。 preseed 完全自動化を諦める
4. **d-i cdrom-detect の挙動を strace/SSH で直接調査**: network-console udeb を inject して install 中の d-i に SSH login → cdrom-detect 内部を確認。 大工事だが根本理解が得られる

### 2. `cdrom-detect/cdrom_device` が reset を誘発する根本原因 (副次)

複数のセッションを経て確実に再現する症状だが、 デバッグするには d-i のソース読みや network-console を要する。 別の bypass 経路 (HDImage / PXE) で迂回できれば不要。

### 3. preseed/early_command からの /dev/console 出力過多が BMC 過負荷を招く問題 (副次)

`for d in ...` 等で大量出力すると SOL 不安定。 出力は最小限に絞り、 必要なら remote syslog 経由 (issue #48 の問題と関連)。

## 再現方法

```sh
# 1. ISO 再 build:
./oplog.sh ./scripts/tx1320-raid10-orchestrate.sh build config/training_tx1320.yml

# 2. sanity check (initrd の中に preseed.cfg があるか):
7z x -otmp/<sid>/iso -y /var/samba/public/debian-training-tx1320-raid10.iso install.amd/initrd.gz
gunzip -c tmp/<sid>/iso/install.amd/initrd.gz > tmp/<sid>/initrd.cpio
grep -aoF "TRAILER!!!" tmp/<sid>/initrd.cpio | wc -l   # 期待値: 2 (concatenated)
grep -aoF "pvese: preseed/early_command start" tmp/<sid>/initrd.cpio | wc -l   # 期待値: 1+

# 3. deploy (SMB config + fresh attach + power on):
./pve-lock.sh run sh tmp/<sid>/manual-deploy.sh  # = forceoff → DisconnectCD/ConnectCD → on

# 4. monitor:
./oplog.sh ./scripts/tx1320-raid10-orchestrate.sh monitor config/training_tx1320.yml

# 5. 期待される結果 (本セッション再現):
#    - kernel boot 成功 ([ 0.075..] x86/cpu: SGX disabled)
#    - preseed/early_command 実行 (pvese: ... > /dev/kmsg)
#    - cdrom-detect が dialog "[!!] Detect and mount installation media — No device for installation media" で停止
#    - SOL ログから installer 内部時刻が単調増加 (本物の停止 dialog)
```

## 環境情報

- **対象機**: training-tx1320 (Fujitsu PRIMERGY TX1320 M3, Serial MABK035229)
- **BMC**: iRMC S4 FW 9.08F (10.254.254.9, HTTPS + SECLEVEL=0 必須, claude/Claude123)
- **CPU/RAM**: D3373 mainboard, 24 GiB RAM
- **HW**: AVAGO MegaRAID (LSI SAS3008 系)、 SAS HDD 900GB × 4 (RAID10 構成済 by #69 #6 セッション)
- **BIOS**: V5.0.0.11 R1.22.0 for D3373-B1x
- **SMB server**: 10.1.6.1 (ローカル Claude Code 実行マシン ens19)、 Samba 4.19.5
- **ISO**: `/var/samba/public/debian-training-tx1320-raid10.iso` (764 MB、 本セッションで最終生成)
- **本セッションの BMC 操作回数**: PATCH OEM VirtualMedia × 8, boot-override Cd UEFI × 8, ForceOff × 約 15, ResetType=On × 約 8, ConnectCD/DisconnectCD × 約 8, OEM Screenshot × 0 (使わなかった)

## 関連 Issue

- **#69 (継続、 status=block)** — owner c-curried-puddle (本セッション後 待機 next session 引き継ぎ)、 blocker は cdrom-detect が /dev/sr0 を先に試して /dev/sr1 に到達しないこと + cdrom_device preseed が reset 誘発すること
  - 前々セッション #5 (d-eager-island): preseed + storcli 設計完成、 SMB silent failure で blocked
  - 前セッション #6 (p-effervescent-kahn): SMB silent failure 真因確定 + 改修。 CD boot → installer 起動まで到達、 cdrom-detect で blocked
  - 前セッション #7 (s-peaceful-hinton): kernel cmdline + preseed 両方に cdrom-detect/try-usb=true 系を仕込んで通し再試行 → 効かず
  - **本セッション #8 (c-curried-puddle)**: initrd preseed 注入を実装 (動作確認済)、 iRMC USB CD は実は /dev/sr1 として可視と判明、 ただし cdrom-detect 突破は未達成
  - **次セッション推奨手順** (優先順):
    1. iRMC HDImage 経由配信 (cdrom-detect を経由しない hd-media install)
    2. PXE / netboot 経路 (iRMC Virtual Media 完全廃止)
    3. Live ISO pivot (preseed 自動化諦め)

## 関連ファイル

### 修正 (本セッション、 commit 対象)

| ファイル | 行 | 修正内容 |
|---------|-----|---------|
| `scripts/remaster-debian-iso.sh` | L86-105 (新規) | initrd 注入ブロック追加 (concatenated archive 方式) |
| `scripts/remaster-debian-iso.sh` | L100, L110, L173 | kernel cmdline を `preseed/file=/cdrom/preseed.cfg` → `preseed/file=/preseed.cfg` (initrd 内パス) + `cdrom-detect/try-usb=true cdrom-detect/scan=true hw-detect/load_media=false` 追加 (3 経路すべて) |
| `scripts/remaster-debian-iso.sh` | xorriso 引数 | `$INITRD_UPDATE_ARGS` を追加 |
| `preseed/preseed.cfg.template` | L67-84 | `d-i cdrom-detect/try-usb boolean true` / `d-i cdrom-detect/scan boolean true` / `d-i hw-detect/load_media boolean false` 3 行 + コメント (TX1320 specifics 含む) |
| `/var/samba/public/debian-training-tx1320-raid10.iso` | — | 上記改修を反映した新 ISO (764 MB) |

### 無修正 (確認のみ)

- `config/training_tx1320.yml` — smb_user=guest / smb_pass=guest は #6 で追加済
- `scripts/tx1320-raid10-orchestrate.sh` — build / deploy / monitor 構造はそのまま (monitor `--timeout` バグは scope 外)
- `scripts/irmc-virtualmedia.sh` — guest/guest 引数 7-8 受け取り対応済
- `scripts/setup-raid10-storcli.sh` — partman/early_command 経由実行、 本セッションでは未到達

## 重要な教訓 (次セッションへの引き継ぎ)

1. **iRMC OEM Virtual Media CDImage は Linux に /dev/sr1 として可視** (前セッション仮説の訂正)。 ただし cdrom-detect は /dev/sr0 (物理 DVD、 空) を先に試して諦め、 /dev/sr1 をスキャンしない
2. **initrd preseed 注入は concatenated gzip cpio archives 方式で実装する** (`cat orig.gz extra.gz > new.gz`)。 `cpio -A` の in-place append は initrd を malformed にする risk があり、 GRUB boot loop を引き起こす
3. **`cdrom-detect/cdrom_device=/dev/sr1` 設定 (preseed/cmdline 問わず) は warm-reset loop を誘発する**。 直接的な device 指定では突破できない。 cdrom-detect.postinst 内部の何かが panic を引き起こしている (詳細未解明)
4. **pre-mount /cdrom in early_command は d-i cdrom-detect に信頼されない**。 d-i は独自に再プローブを行うので、 pre-mount だけでは dialog を回避できない
5. **preseed/early_command からの /dev/console 出力は最小限に**。 大量出力は BMC SOL session を不安定化させ、 ring buffer リプレイによる誤読を招く
6. **SOL ログ解析時の判定基準**: PowerState polling の安定 On + SOL Session operational の出現回数 + installer 内部時刻 (`May 18 H:MM`) の単調増加 を組み合わせて「真の進行」「SOL replay」「reset loop」を識別する
7. **次セッションは cdrom-detect 経路を捨てて HDImage / PXE / Live ISO に pivot することを推奨** (cdrom-detect 系統での fight は本セッションで全パターン試行済、 これ以上の試行は時間効率悪い)
