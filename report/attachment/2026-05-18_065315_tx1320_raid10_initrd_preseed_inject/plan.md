# TX1320 RAID10 install: initrd preseed 注入 + early_command で自前 mount 突破

## Context

`report/2026-05-18_025914_tx1320_raid10_cdrom_detect_cmdline_failed.md` で `kernel cmdline (GRUB legacy / ISOLINUX / EFI 全 3 経路) + preseed.cfg.template の両方に `cdrom-detect/try-usb=true cdrom-detect/scan=true hw-detect/load_media=false`` を仕込む手は不発と判明。 同レポートが次セッション最優先候補として挙げた **「initrd preseed 注入 + `preseed/early_command` で自前 `mount /dev/sr0 /cdrom`」** を実装し、 `[!!] Detect and mount installation media` dialog の突破を試みる。

戦略の急所:
- 現状 `scripts/remaster-debian-iso.sh` L86 で「Skipping initrd modification」 — preseed.cfg は `/cdrom/preseed.cfg` から load される構造で **CDROM が見えない時点で preseed 自体が適用されない (chicken-and-egg)**
- initrd 内に `/preseed.cfg` を焼き込めば d-i `auto-install/enable=true` 経由で **cdrom-detect 起動前** に preseed が読まれ、 `preseed/early_command` が走る
- 同 early_command で `/dev/sr*`/`/dev/sg*` を能動探索 + mount し、 cdrom-detect の dialog 前に `/cdrom` を fake する
- 前セッション仮説「iRMC USB CDROM は Linux からは見えない」が真なら mount は失敗するが、 **診断 syslog を `10.1.6.1:5514` に飛ばすことで「Linux 視点でデバイスが存在するか」を確定** できる
  - 存在する → mount 成功して install 続行
  - 存在しない → 次セッション候補 #2 (iRMC HDImage 経由配信) に明確に pivot できる

期待される最終形:
1. cdrom-detect dialog を経由せず partman/early_command 到達
2. `setup-raid10-storcli.sh` 実行 → RAID10 VD 作成
3. install 完走 + SSH (192.168.33.0/24 DHCP IP 経由) 検証

万一 mount 失敗時も、 失敗ログから次の手を一義的に決定できる「実りある失敗」を担保する。

## 修正対象ファイル

| ファイル | 修正内容 |
|---------|---------|
| `scripts/remaster-debian-iso.sh` | initrd 修正ブロックを追加 — `install.amd/initrd.gz` を ISO から抽出 → `gunzip` → `echo preseed.cfg \| cpio -H newc -o -A -F initrd` で append → `gzip` → ISO 再書き込みで上書き。 docker container 内で実施 (既存処理と同じレイヤ)。 `LEGACY_ONLY` 関係なく常時有効 |
| `scripts/remaster-debian-iso.sh` (cmdline) | L100/L110/L173 の `preseed/file=/cdrom/preseed.cfg` を **削除**。 initrd 内 `/preseed.cfg` は d-i により自動 load される (auto=true) ため不要。 副次的に「cdrom-detect 失敗時も preseed が確実に読まれる」保証を得る。 `cdrom-detect/try-usb=true cdrom-detect/scan=true hw-detect/load_media=false` は前セッション証跡では効かなかったが残置 (実害なし、 万一の hit を期待) |
| `preseed/preseed.cfg.template` | `preseed/early_command` を拡張 — 既存の syslogd forward に加えて: (a) `lsblk -P -o NAME,TYPE,SIZE,MODEL,VENDOR,TRAN`, `ls -la /dev/sr* /dev/sg* /dev/disk/by-id/`, `udevadm info -e \| head -200` をすべて `logger` 経由で remote syslog に飛ばす、 (b) `for d in /dev/sr0 /dev/sr1 /dev/sr2 /dev/sg0; do [ -b "$d" ] && mount -t iso9660 -o ro "$d" /cdrom && break; done`、 (c) mount 成否を kmsg + logger に記録。 既存の VLAN / RAID 関連 directive はそのまま |
| (確認のみ) `scripts/tx1320-raid10-orchestrate.sh` | build → deploy → monitor フローはそのまま使う。 修正不要 |
| (確認のみ) `scripts/setup-raid10-storcli.sh` | partman/early_command 経由実行ロジックはそのまま。 修正不要 |

## 実装詳細

### A. `scripts/remaster-debian-iso.sh` 修正

L86 直後 (現在「Skipping initrd modification...」) に initrd 修正ブロックを挿入:

```sh
echo "--- Injecting /preseed.cfg into install.amd/initrd.gz ---"
xorriso -osirrox on -indev /input.iso \
    -extract /install.amd/initrd.gz "$WORK/irmod/initrd.gz" 2>&1 | tail -1
mkdir -p "$WORK/irmod/inject"
cp /preseed.cfg "$WORK/irmod/inject/preseed.cfg"
gunzip "$WORK/irmod/initrd.gz"
(
    cd "$WORK/irmod/inject"
    echo preseed.cfg | cpio -H newc -o -A -F "$WORK/irmod/initrd"
) 2>&1 | tail -3
gzip "$WORK/irmod/initrd"
INITRD_UPDATE_ARGS="-update $WORK/irmod/initrd.gz /install.amd/initrd.gz"
```

L216-226 の xorriso 引数列に `$INITRD_UPDATE_ARGS` を追加 (`$EFI_UPDATE_ARGS` と同じ位置)。

L100/L110/L173 の kernel cmdline から `preseed/file=/cdrom/preseed.cfg ` を削除 (3 箇所すべて)。 `cdrom-detect/try-usb=true cdrom-detect/scan=true hw-detect/load_media=false` は残す。

`-map "$WORK/mod/preseed.cfg" /preseed.cfg` (L224) の ISO root への preseed map も残す — initrd 注入と二重で問題ない (initrd path が優先)、 cdrom が後で mount できた場合の fallback。

### B. `preseed/preseed.cfg.template` 修正

L14-23 の現行 `preseed/early_command` を以下に置換:

```
d-i preseed/early_command string \
  kill $(cat /var/run/syslogd.pid 2>/dev/null) 2>/dev/null || true; \
  syslogd -R 10.1.6.1:5514 -L -O /var/log/syslog -S 2>/dev/null || true; \
  sleep 2; \
  echo "pvese: early_command start (%%HOSTNAME%%) — probing cdrom devices" > /dev/kmsg 2>/dev/null || true; \
  logger -t pvese-probe "lsblk:"; lsblk -P -o NAME,TYPE,SIZE,MODEL,VENDOR,TRAN 2>&1 | logger -t pvese-probe; \
  logger -t pvese-probe "ls /dev/sr* /dev/sg*:"; ls -la /dev/sr* /dev/sg* /dev/disk/by-id/ 2>&1 | logger -t pvese-probe; \
  logger -t pvese-probe "udevadm:"; udevadm info -e 2>&1 | head -200 | logger -t pvese-probe; \
  cdrom_mounted=0; \
  for d in /dev/sr0 /dev/sr1 /dev/sr2 /dev/sg0 /dev/sg1; do \
    if [ -b "$d" ] || [ -c "$d" ]; then \
      logger -t pvese-probe "trying mount $d -> /cdrom"; \
      mkdir -p /cdrom; \
      if mount -t iso9660 -o ro "$d" /cdrom 2>&1 | logger -t pvese-probe; then \
        if [ -f /cdrom/.disk/info ] || [ -f /cdrom/preseed.cfg ]; then \
          logger -t pvese-probe "mount $d OK, /cdrom contains ISO content"; \
          echo "pvese: cdrom mounted from $d" > /dev/kmsg 2>/dev/null || true; \
          cdrom_mounted=1; \
          break; \
        else \
          logger -t pvese-probe "mount $d OK but missing markers, unmounting"; \
          umount /cdrom 2>/dev/null || true; \
        fi; \
      fi; \
    fi; \
  done; \
  [ "$cdrom_mounted" = 1 ] || logger -t pvese-probe "FATAL: no cdrom device found; install will block on cdrom-detect"; \
  :
```

L67-75 の `d-i cdrom-detect/try-usb boolean true` etc 3 行はそのまま残す (前セッションで効かなかったが実害なし)。

### C. 追加コメント

`preseed/preseed.cfg.template` の `preseed/early_command` 直上に「**chicken-and-egg 解消: initrd 注入 + 自前 mount で cdrom-detect 前に /cdrom を準備する**」旨を 2-3 行コメント追記。 後セッションが意図を読み取れるよう、 該当レポートへの参照を入れる。

`scripts/remaster-debian-iso.sh` の initrd 修正ブロック直上にも同様コメント。

## 再利用する既存資産

| ファイル | 用途 |
|---------|------|
| `scripts/tx1320-raid10-orchestrate.sh` | build/deploy/monitor フローそのまま使う |
| `scripts/fetch-storcli-deb.sh` | storcli64.deb 取得 (既存) |
| `scripts/setup-raid10-storcli.sh` | partman/early_command から呼ばれる RAID10 作成 (既存、 dispatch 構造に変更なし) |
| `scripts/generate-preseed.sh` | --with-raid10-storcli 経由で partman/early_command を生成 (既存) |
| `scripts/irmc-virtualmedia.sh` | SMB CDImage attach (既存、 #6 で guest 明示済) |
| `scripts/bmc-power.sh` | forceoff / on (既存、 POWER_ON_RESET_TYPE=On で動作) |
| `scripts/sol-monitor.py` | SOL ログ収集 + early_command の `logger -t pvese-probe` 出力を `/var/log/syslog` 経由で見る (remote syslog 10.1.6.1:5514 が真の情報源) |
| `samba` (10.1.6.1) | ISO 配信 + syslog forward 受け先 (前セッションで動作確認済) |

## 検証手順 (end-to-end)

1. **ISO 再 build**:
   ```sh
   ./oplog.sh ./scripts/tx1320-raid10-orchestrate.sh build config/training_tx1320.yml
   ```
   生成物: `/var/samba/public/debian-training-tx1320-raid10.iso`

2. **Sanity check** (新規 ISO に preseed が initrd 内 + ISO root 両方に存在することを確認):
   ```sh
   xorriso -osirrox on -indev /var/samba/public/debian-training-tx1320-raid10.iso \
       -extract /install.amd/initrd.gz tmp/<sid>/initrd.gz
   gunzip tmp/<sid>/initrd.gz
   cpio -t -F tmp/<sid>/initrd | grep -E '^preseed\.cfg$'   # 1 行出力で OK
   ```
   さらに `preseed/file=/cdrom/preseed.cfg` 文字列が 3 つの bootloader から消えていることを `strings`/`grep` で確認。

3. **syslog 受け側を準備**: ローカル `10.1.6.1` (Claude Code 実行マシン ens19) で `udp/5514` が listen していることを確認 (前セッションで動作実績あり)。

4. **deploy** (SMB config + boot-override + power cycle):
   ```sh
   ./oplog.sh ./scripts/tx1320-raid10-orchestrate.sh deploy config/training_tx1320.yml
   ```
   - BIOS Setup に落ちた場合は前セッション手順の fresh attach (forceoff → DisconnectCD/ConnectCD → on) を実施

5. **monitor**:
   ```sh
   ./oplog.sh ./scripts/tx1320-raid10-orchestrate.sh monitor config/training_tx1320.yml
   ```
   並行で `/var/log/syslog` 等の syslog 受信ログを Bash background で tail。 `pvese-probe` tag の行が来ているか確認。

6. **判定**:
   - **早期確認 (Phase 1)**: SOL log に `pvese: early_command start` が出る → initrd preseed 注入成功 (= chicken-and-egg 解消)
   - **デバイス可視性 (Phase 2)**: remote syslog に `pvese-probe lsblk:` 等の行が来る → Linux 起動後の `/dev/sr*`/`/dev/sg*` 存在状況が確定
   - **mount 成否 (Phase 3)**:
     - 成功 → `pvese: cdrom mounted from /dev/srN` が SOL log に出て、 cdrom-detect dialog を経由せず partman → setup-raid10-storcli.sh 到達。 install 完走を待つ
     - 失敗 → `pvese-probe FATAL: no cdrom device found` が出る。 cdrom-detect dialog で再度停止するが、 syslog 出力から **「iRMC USB CDROM は Linux 不可視」が確定** し、 次セッションは候補 #2 (iRMC HDImage 経由配信) に確信を持って pivot 可能
   - **install 完走時**: DHCP IP を SOL log の `Configuring DHCP networking` 行から拾い、 SSH 経由で `lsblk` / `storcli64 /c0/vall show` / `cat /etc/debian_version` を確認

7. **失敗時の retry**: build 結果は決定的なので、 deploy のみ retry。 BIOS Setup 落ちは fresh attach で回復。 BMC web UI/Redfish が hang したら 60-90s 待機 (前セッション知見)。

## 完了条件

- [ ] `scripts/remaster-debian-iso.sh` に initrd 修正ブロック追加
- [ ] kernel cmdline 3 経路から `preseed/file=/cdrom/preseed.cfg` 削除
- [ ] `preseed/preseed.cfg.template` の `preseed/early_command` を診断 + mount 試行版に拡張
- [ ] 新 ISO build + sanity check (preseed.cfg が initrd 内に存在)
- [ ] deploy + monitor 実行
- [ ] 判定: install 完走 or `/dev/sr*` 不可視確定 (どちらでも「次の手」が明確になる)
- [ ] レポート作成 (`report/2026-05-18_<HHMMSS>_tx1320_raid10_initrd_preseed_inject.md`)、 結果に応じて `training_tx1320.md` メモリ更新

## 非対象 (scope 外)

- `tx1320-raid10-orchestrate.sh` monitor `--timeout` 引数バグ (持ち越し、 前セッション report 「未完了 #2」)
- `sol-monitor.py` SOL ring buffer リプレイのフィルタ (持ち越し、 前セッション report 「未完了 #3」)
- 候補 #2 以降 (HDImage / PXE / hd-media / Live ISO) — 本セッションが失敗した場合の次セッション課題
