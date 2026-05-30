# TX1320 RAID10 cdrom-detect 突破 + 通し再試行

## Context

前セッション (#6 p-effervescent-kahn, 2026-05-17 12:58) で SMB Virtual Media silent failure (空 user/pass) の真因確定 + 修正 (guest/guest 明示) により CD boot + kernel boot まで成功。 しかし Debian installer 起動直後の `[!!] Detect and mount installation media — No device for installation media was detected` で停止し、 partman/early_command の RAID10 作成までたどり着けていない (Issue #69 blocked)。

原因仮説: 現状の kernel cmdline (`scripts/remaster-debian-iso.sh` L100/L110/L173) は `auto=true priority=critical preseed/file=/cdrom/preseed.cfg ...` で、 `cdrom-detect/*` や `hw-detect/load_media` 系の追加 hint が無い。 iRMC Virtual Media が提示する USB CD は kernel boot 時点では認識されているが、 d-i の `cdrom-detect` ステップが USB CD を再走査せず "no device" 判定になる典型ケース。

ゴール: kernel cmdline に cdrom-detect hint を埋め込み + preseed にも対応 directive を追加 (belt-and-suspenders)。 ISO 再 remaster → deploy → SOL monitor で installer 通過確認 → install 完走 → SSH で RAID10 検証。

## 修正内容

### A. `scripts/remaster-debian-iso.sh` — kernel cmdline に cdrom-detect hint 追加 (3 箇所)

3 つの boot loader 設定で同じ kernel cmdline を生成しているので、 各箇所に `cdrom-detect/try-usb=true cdrom-detect/scan=true hw-detect/load_media=false` を追加する。

| 行 | 対象 | 修正方針 |
|---|---|---|
| L100 | GRUB legacy (`grub.cfg`) | `netcfg/choose_interface=auto` の直後に挿入 |
| L110 | ISOLINUX (`txt.cfg`, label `auto`) | 同上 |
| L173 | EFI grub-mkstandalone `embed.cfg` | 同上 |

差分例 (L100):
```
-    linux /install.amd/vmlinuz vga=normal nomodeset auto=true priority=critical preseed/file=/cdrom/preseed.cfg locale=en_US.UTF-8 keymap=us netcfg/choose_interface=auto console=tty0 console=ttyS${SERIAL_UNIT},115200n8 --- quiet
+    linux /install.amd/vmlinuz vga=normal nomodeset auto=true priority=critical preseed/file=/cdrom/preseed.cfg locale=en_US.UTF-8 keymap=us netcfg/choose_interface=auto cdrom-detect/try-usb=true cdrom-detect/scan=true hw-detect/load_media=false console=tty0 console=ttyS${SERIAL_UNIT},115200n8 --- quiet
```

理由: preseed.cfg 自体が `/cdrom/preseed.cfg` から load される構造のため、 cdrom-detect が通らなければ preseed 内の directive は適用されない (chicken-and-egg)。 kernel cmdline 経由でしか cdrom-detect ステップに先回りできない。

### B. `preseed/preseed.cfg.template` — d-i directive 追加 (belt-and-suspenders)

`### Kernel modules` セクション (L63-65) の直後に追加:

```
### Force USB CD-ROM scanning during installation media detection
### (kernel cmdline 経由で先回り済だが、 後段の hw-detect/load_media 抑制も兼ねる)
d-i cdrom-detect/try-usb boolean true
d-i cdrom-detect/scan boolean true
d-i hw-detect/load_media boolean false
```

(preseed が読まれた以降の hw-detect 再走査時に作動する保険)

### C. ISO 再 build → deploy → monitor → 検証

修正 (A)(B) で `tx1320-raid10-orchestrate.sh build` → 新 ISO 生成 → deploy → SOL monitor。

---

## 実行手順

### Phase 0: 準備 (read-only)

- セッション UUID → SID (先頭 8 文字) 確定、 `mkdir -p tmp/<SID>`
- `./issue.sh start 69 --owner <session>` で #69 を再 owner 取得
- iRMC PowerState 確認 (期待: Off — 前回 BIOS Setup に落ちて以降 ForceOff 済)
- 既存 ISO `/var/samba/public/debian-tx1320-raid10.iso` の存在確認 (流用ではなく上書き再 build 予定)

### Phase 1: スクリプト・テンプレート修正

1. `scripts/remaster-debian-iso.sh` の L100 / L110 / L173 を編集 (cdrom-detect hint 挿入)
2. `preseed/preseed.cfg.template` の L65 直後に d-i directive 3 行追加

### Phase 2: ISO 再 remaster

```sh
./oplog.sh ./scripts/tx1320-raid10-orchestrate.sh build config/training_tx1320.yml
```

- Phase 1 (storcli64.deb fetch): 既存ファイルあれば skip
- Phase 3 (generate-preseed): `--with-raid10-storcli` でテンプレ展開 → `tmp/training-tx1320-preseed-raid10.cfg` 生成
- Phase 4 (remaster ISO): Docker xorriso で `/var/samba/public/debian-tx1320-raid10.iso` を上書き出力

検証: build 完了後、 docker 内 grub.cfg / txt.cfg / preseed.cfg のいずれかを sanity check (`xorriso -indev .../debian-tx1320-raid10.iso -extract /boot/grub/grub.cfg ...` または `-extract /preseed.cfg ...`) して cdrom-detect hint が入っていることを確認 — Phase 4 sanity step として 1 回実行。

### Phase 3: USB redirector fresh attach + deploy

前回知見: PATCH 直後の attach は POST 中の USB enumeration とタイミングが噛み合わずに BIOS Setup へ落ちる可能性あり → DisconnectCD / ConnectCD を組み合わせた fresh attach が必要。

```sh
# 1. SMB config + boot-override + power cycle (orchestrate deploy)
./oplog.sh ./scripts/tx1320-raid10-orchestrate.sh deploy config/training_tx1320.yml

# 2. (もし BIOS Setup に落ちた場合のみ) USB redirector 再起動
./oplog.sh ./scripts/bmc-power.sh forceoff 10.254.254.9 claude Claude123
# DisconnectCD + ConnectCD は OEM Action (1 行コマンドにできないため shell script 化)
# tmp/<SID>/usb-redirector-cycle.sh に curl 2 連発を書き → sh tmp/<SID>/usb-redirector-cycle.sh
./oplog.sh ./scripts/bmc-power.sh on 10.254.254.9 claude Claude123
```

DisconnectCD / ConnectCD は HTTPS POST: `/redfish/v1/Systems/0/Actions/Oem/FTSComputerSystem.VirtualMedia` body `{"VirtualMediaAction":"DisconnectCD"}` / `"ConnectCD"` (PowerState=Off で有効)。

### Phase 4: SOL monitor で進行確認

```sh
./oplog.sh ./scripts/tx1320-raid10-orchestrate.sh monitor config/training_tx1320.yml
# (--timeout / --log は orchestrate L85 のバグで使えない — 本タスク scope 外、 default 2700s で OK)
```

期待される SOL ログ:

1. `Booting "Automated Install"` (CD boot)
2. `Loading kernel ...` → `SGX disabled or unsupported by BIOS.`
3. **`Detect and mount installation media` が通過** (この行が出ないまま次に進めば成功)
4. `partman/early_command: sh /cdrom/setup-raid10-storcli.sh /cdrom/storcli64.deb`
5. `setup-raid10-storcli: storcli64 /c0 add vd type=raid10 ... success`
6. `Installing the base system` → `Installing GRUB` → `Installation complete` → poweroff (`debian-installer/exit/poweroff boolean true` のため)

注意: 前回観察した KVM 経由 keystroke が installer dialog に届かない問題は本タスクで対処しない (cdrom-detect が通れば dialog 自体に到達しないはず)。

### Phase 5: 失敗時の判定とフォールバック

#### cdrom-detect が依然停止する場合:
- SOL ログで `Detect and mount installation media` 画面の詳細を確認
- preseed の effect を debconf-get で診断するためには installer shell (Alt+F2 相当) が必要だが SOL 経由では到達困難
- フォールバック候補 (本タスク scope 外、 次セッション):
  - `media-retriever/scan` (initrd 段階で USB を待つ) の cmdline 追加
  - `preseed/file=/cdrom/preseed.cfg` を initrd 注入に切替
  - PXE 経路 (TFTP + HTTP)

#### partman/early_command が失敗 (RAID 作成失敗):
- `/cdrom/setup-raid10-storcli.sh` が exit !=0 → SOL ログに失敗 step が出るはず
- 物理ディスク列挙が想定 (4 本) と異なる場合は手動介入

#### install 完了後 poweroff されたが SSH 不可:
- DHCP IP 確定が必要 — `arp -a` / Samba ログ / 別途 DHCP server ログ
- preseed `network_mode: dhcp` のため `192.168.33.0/24` 上で leasing

### Phase 6: install 完了後の検証

電源 Off → DisconnectCD で Virtual Media 解除 → power on (CD 同梱の startup.nsh が GRUB を呼ぶ) → DHCP IP 確定 → SSH:

```sh
ssh -F ssh/config root@<dhcp_ip> 'lsblk'
ssh -F ssh/config root@<dhcp_ip> 'sudo /usr/local/bin/storcli64 /c0/vall show all'
ssh -F ssh/config root@<dhcp_ip> 'cat /var/log/raid10-setup.log'
```

期待:
- `/dev/sda ~1.6 TiB` (RAID10 of 4 × 900GB SAS)
- storcli vall: `RAID-10 / State=Optl / 4 PD / pdperarray=2`
- raid10-setup.log: setup script 完了ログ + storcli add vd 成功記録

### Phase 7: ドキュメント・memory 更新

- `.claude/skills/irmc-bios-raid/SKILL.md`: cdrom-detect 突破策のセクション追記 (kernel cmdline + preseed 両 hint が必要)
- memory `training_tx1320.md`: 「### 9. cdrom-detect 未解決」 を解決済に書き換え (本セッション ID で更新)
- `report/2026-05-18_<時刻>_tx1320_raid10_install_complete.md` 作成 (または失敗時は `_cdrom_detect_persisted.md`)
- `issue.sh done 69` (成功時) / `issue.sh block 69 "..."` (失敗時)

---

## 重要な制約 (CLAUDE.md / training_tx1320 固有)

- **状態変更は `./oplog.sh` ラップ** (CLAUDE.md ルール)
- **scripts は `./` 付き相対パス**、 一時ファイルは `tmp/<SID>/` のみ
- **iRMC は HTTPS + `--ciphers DEFAULT@SECLEVEL=0` 必須** (`BMC_CURL_OPTS` 環境変数で渡す、 orchestrate.sh で設定済)
- **boot-override PATCH は If-Match ETag 必須** (`BMC_PATCH_REQUIRES_ETAG=1`、 orchestrate.sh で設定済)
- **`POWER_ON_RESET_TYPE=On`** (iRMC Off→On 用、 orchestrate.sh で設定済)
- **`ipmitool sol activate` の前に `sol payload enable 2 4`** (orchestrate.sh monitor 内で実施済)
- **KVM viewer 多重起動は避ける** (BMC hang 誘発、 本タスクでは原則 SOL のみ使用)
- **`./scripts/bmc-power.sh forceoff` は exit code を捨てる** (既に Off の場合の rc!=0 を吸収、 orchestrate.sh L134 で `|| true` 済)

---

## 関連ファイル

### 修正 (本セッション)

| ファイル | 行 | 修正内容 |
|---------|-----|---------|
| `scripts/remaster-debian-iso.sh` | L100 (grub.cfg) | kernel cmdline に `cdrom-detect/try-usb=true cdrom-detect/scan=true hw-detect/load_media=false` を `netcfg/choose_interface=auto` 直後に追加 |
| `scripts/remaster-debian-iso.sh` | L110 (txt.cfg) | 同上 (ISOLINUX `auto` label) |
| `scripts/remaster-debian-iso.sh` | L173 (embed.cfg) | 同上 (EFI grub-mkstandalone 用) |
| `preseed/preseed.cfg.template` | L65 直後 | `d-i cdrom-detect/try-usb boolean true` / `d-i cdrom-detect/scan boolean true` / `d-i hw-detect/load_media boolean false` 3 行追加 |
| (結果) `/var/samba/public/debian-tx1320-raid10.iso` | — | `tx1320-raid10-orchestrate.sh build` で再生成 |
| (新規) `report/2026-05-18_<時刻>_tx1320_raid10_*.md` | — | 結果レポート |

### 無修正 (再利用)

| ファイル | 用途 |
|---------|------|
| `config/training_tx1320.yml` | smb_user=guest / smb_pass=guest は前 #6 で追加済 |
| `scripts/tx1320-raid10-orchestrate.sh` | build / deploy / monitor 構造は前 #6 改修済 (monitor --timeout バグは本タスク scope 外) |
| `scripts/irmc-virtualmedia.sh` | guest/guest 引数 7-8 受け取り OK |
| `scripts/setup-raid10-storcli.sh` | partman/early_command で `/cdrom/setup-raid10-storcli.sh /cdrom/storcli64.deb` 経由実行、 cdrom-detect 通過後に走る |
| `scripts/bmc-power.sh` | forceoff / on / boot-override |
| `scripts/fetch-storcli-deb.sh` | storcli64.deb は既存ファイル流用 (SKIP_STORCLI_FETCH 不要、 ファイル存在で自動 skip) |

---

## 検証 (Verification)

### 修正の正しさ確認 (Phase 2 build 後)

```sh
# 新 ISO から preseed.cfg と grub.cfg を抽出して cdrom-detect 文字列が入っているか確認
# (xorriso は docker 内なので、 sh wrapper を tmp/<SID>/iso-sanity.sh に書く)
sh tmp/<SID>/iso-sanity.sh    # 期待: cdrom-detect/try-usb=true が grub.cfg と preseed.cfg の両方に出現
```

### Phase 4 (monitor) 成否判定

- 成功: SOL ログに `partman/early_command` 実行行が出る → install 続行
- 失敗 (cdrom-detect 依然停止): `[!!] Detect and mount installation media` 画面で停止 → Phase 5 フォールバックへ

### Phase 6 (SSH) 期待結果

- `lsblk`: `/dev/sda` size ~1.6 TiB
- `storcli64 /c0/vall show all`: `RAID-10 / State=Optl / 4 PD`
- `/var/log/raid10-setup.log`: setup-raid10-storcli.sh 完走ログ

### Issue クローズ条件

- 成功: SOL で installer 完走 + SSH 検証 OK → `./issue.sh done 69`
- 部分成功 (cdrom-detect 通過したが他で fail): `./issue.sh block 69 "..."` で次セッション引き継ぎ + 報告レポート作成
