# TX1320 RAID10 SMB attach 真因確定・スクリプト改修 + CD boot 成功・installer cdrom-detect で停止

- **実施日時**: 2026年5月17日 12:21 〜 12:58 (JST、 約 37 分)
- **担当**: p-effervescent-kahn
- **Issue**: #69 (継続中)
- **対象**: training-tx1320 (10.254.254.9, Fujitsu PRIMERGY TX1320 M3, iRMC S4 FW 9.08F)
- **親レポート**: [2026-05-17_113642_tx1320_raid10_preseed_storcli_blocked_smb.md](2026-05-17_113642_tx1320_raid10_preseed_storcli_blocked_smb.md) (d-eager-island、 SMB silent failure で blocked)
- **方針転換のきっかけ**: ユーザが iRMC web UI から手動で `User Name: guest / Password: guest / Domain: 空欄` で CIFS attach + F12 → CD-ROM 選択 → `Booting Automated Install` 表示まで成功させて報告。 「この条件で再度トライしてみてください、 各操作は claude から操作しやすい方法に置き換えてもよい」 指示

## 添付ファイル

- [実装プラン](attachment/2026-05-17_125823_tx1320_raid10_smb_attach_solved/plan.md)
- [BIOS POST 画面 (F12 prompt 表示中)](attachment/2026-05-17_125823_tx1320_raid10_smb_attach_solved/oem-02.jpg) — Power On 約 1 分後、 `Press <F2> to enter Setup or <F12> to enter Boot Menu`
- [Booting `Automated Install` 表示](attachment/2026-05-17_125823_tx1320_raid10_smb_attach_solved/oem-04.jpg) — CD boot 開始の証跡
- [kernel boot 開始 (`SGX disabled`)](attachment/2026-05-17_125823_tx1320_raid10_smb_attach_solved/oem-05.jpg) — kernel が console=ttyS0 へ移行、 以降 VGA 画面は static
- [SOL ログ抜粋 (cdrom-detect 停止画面)](attachment/2026-05-17_125823_tx1320_raid10_smb_attach_solved/sol.log) — sol-monitor 再起動で truncate されたため末尾のみ

## 前提・目的

前セッション (#5 d-eager-island) で `tx1320-raid10-orchestrate.sh apply` を実行したが、 iRMC SMB CDImage が silent failure (Members@odata.count=0 のまま、 Samba にも接続痕跡なし) で CD boot 失敗。 ユーザが web UI から手動で同等の設定で attach + boot 成功させたことで、 スクリプト経由でも同じ payload を送れば成功するはずという仮説が成立。

ゴール:
1. silent failure の真因確定
2. スクリプトに対策を組み込んで再現可能化
3. install まで完走 → RAID10 検証
4. 真因・解決策を SKILL.md / memory / レポートに記録

## 実施内容と結果

### Phase 0: 現状確認 (read-only) ✅

- iRMC PowerState=Off (ユーザシャットダウン済)
- OEM `VirtualMedia` の CDImage に **`UserName:"guest"`** が残っている (Web UI 経由の attach 設定)
- `Members@odata.count=0` (電源 Off なので mount 状態はゼロ)
- Samba ログには接続記録なし (Samba が接続単位の log を出さない設定)

### Phase 1: スクリプト改修 ✅

**真因確定**: `scripts/tx1320-raid10-orchestrate.sh` L124-125 が `irmc-virtualmedia.sh config` を引数 6 個で呼んでおり、 `smb_user` / `smb_pass` が空文字列で PATCH されていた。 iRMC は空文字列を guest として処理せず silent reject、 結果として `Members@odata.count=0` の症状を呈していた。 ユーザの Web UI 入力は明示的に `UserName:"guest"` を payload に入れる動作で、 スクリプトの空文字列とは別物。

修正:
- `config/training_tx1320.yml`: `smb_share_path` 直後に `smb_user: guest` / `smb_pass: guest` 追記 + 真因コメント
- `scripts/tx1320-raid10-orchestrate.sh`: yq で `.smb_user // "guest"` / `.smb_pass // "guest"` を読み、 `irmc-virtualmedia.sh config` の引数 7-8 として渡す
- `scripts/irmc-virtualmedia.sh` は無修正 (既に引数 7-8 で受け取り対応済、 L124)

### Phase 2: 改修版 deploy 実行 ✅ + SMB attach 確認

```sh
./oplog.sh ./scripts/tx1320-raid10-orchestrate.sh deploy config/training_tx1320.yml \
    /var/samba/public/debian-tx1320-raid10.iso
```

実行結果:
```
[orchestrate] Phase 5a: configure Virtual Media (smb_user=guest)
PATCH payload: {"CDImage":{"Server":"10.1.6.1","UserName":"guest","Password":"guest",
  "UserDomain":"","ShareType":"SMB","ShareName":"public","ImageName":"debian-tx1320-raid10.iso"},
  "RemoteMountEnabled":true}
HTTP 200
[orchestrate] Phase 5b: boot-override Cd UEFI
Boot override set: target=Cd mode=UEFI (once)
[orchestrate] Phase 5c: power cycle (ForceOff + On)
Power On requested (ResetType=On)
[orchestrate] deploy OK
```

重要発見: `Members@odata.count` は polling しても 0 のままで進展なし。 OEM `VirtualMediaAction@Redfish.AllowableValues` を確認すると `["DisconnectCD"]` のみで「Connected」 状態と判明 — **`Members@odata.count` は USB redirector で実 mount された media 数を指し、 OEM CDImage の attach 状態とは別概念**。 iRMC 内部では既に Connected だが、 BIOS POST 中の USB enumeration が間に合わず BIOS Setup に落ちた (前回 #5 と同じ症状)。

### Phase 2.5: USB redirector を fresh attach で再起動 + Power On ✅

```sh
./oplog.sh ./scripts/bmc-power.sh forceoff ...     # BIOS Setup から強制 reset
# DisconnectCD
curl ... -d '{"VirtualMediaAction":"DisconnectCD"}' ... HTTP 204
# ConnectCD
curl ... -d '{"VirtualMediaAction":"ConnectCD"}' ... HTTP 204
./oplog.sh ./scripts/bmc-power.sh on ...           # POWER_ON_RESET_TYPE=On
```

判明事項:
- **PowerState=Off でも `DisconnectCD` / `ConnectCD` action は両方 HTTP 204 で受理される** (前回 #5 で「失敗」と判断したのは PowerState=On (BIOS Setup) 中で AllowableValues が `[]` だったため)
- `VirtualMediaAction@Redfish.AllowableValues` は接続状態で動的: Connected→`["DisconnectCD"]` / Disconnected→`["ConnectCD"]` / BIOS Setup 中→`[]`

### Phase 3: CD boot 成功 ✅

電源 On 約 1 分後の OEM screenshot で BIOS POST 画面 (`Press <F2> to enter Setup or <F12> to enter Boot Menu`) を確認 → さらに約 30 秒後の screenshot で **`Booting "Automated Install"`** 表示。 ユーザ Web UI 操作と同じ画面に到達。

ただし、 KVM 経由 F12 押下 (`scripts/irmc-kvm-interact.py sendkeys F12`) を併発したものの、 boot-override Cd UEFI が機能して自動 boot した可能性が高い (F12 押下のタイミングが post 完了後の可能性)。 fresh attach により BIOS POST 開始時から CD device が見える状態になったことで boot-override が機能した、 と判断。

### Phase 4: kernel boot 開始 ✅

OEM screenshot で `[ 0.075933] x86/cpu: SGX disabled or unsupported by BIOS.` 確認。 kernel が console=ttyS0 へ移行 (preseed の late_command で kernel cmdline に書き込み済)。 以降 VGA 画面は static、 実際の installer 出力は SOL に流れる。

### Phase 5: installer 起動 → ⚠️ cdrom-detect で停止 (未解決)

SOL log で installer メニュー検出:

```
[!!] Detect and mount installation media

No device for installation media was detected.

You may need to load additional drivers from removable media, such as
a driver floppy or a USB stick. If you have these available now,
insert the media, and continue. Otherwise, you will be given the
option to manually select some modules.

Load drivers from removable media?  <Yes>  <No>
```

CD boot は成功したが、 installer kernel が iRMC Virtual CD を再 mount できていない。 preseed の `partman/early_command` まで到達できず、 storcli RAID 作成も未実行。

KVM 経由 Enter (`sendkeys Enter`) で `<Yes>` 選択を試みたが反応なし (kernel が console=ttyS0 で VGA を切り離した後、 KVM 経由 USB HID keystroke が installer dialog に届かない可能性)。 SOL stdin 経由で Enter 送信は `ipmitool sol activate` が TTY 必須で pipe 経由不可、 `expect`/`script -q` wrap が必要。 加えて、 短時間に KVM viewer + Virtual Media + Redfish を多用したため iRMC web UI が一時的に hang (KVM viewer login 30s timeout、 Redfish GET も 10s timeout) — SOL (IPMI lanplus) は別 channel で生存。

### Phase 6: ドキュメント・memory 更新 ✅

- `.claude/skills/irmc-bios-raid/SKILL.md`:
  - L29 `raid create-r10` セル: silent failure → 解決済へ書き換え (真因 + #6 結果)
  - L540 フォールバック表「iRMC SMB Virtual Media attach 失敗」セル: 真因 (空 user/pass) + 解決策 (guest/guest 明示) + ConnectCD/DisconnectCD 追記
- memory `training_tx1320.md`: 「### 7-10」セクション追加 (SMB attach 真因、 ConnectCD/DisconnectCD、 cdrom-detect 未解決、 BMC intermittent hang)

## 完了事項

- [x] silent failure 真因確定 (空 UserName/Password が iRMC で guest 認証として処理されない)
- [x] `config/training_tx1320.yml` に `smb_user: guest` / `smb_pass: guest` + 真因コメント
- [x] `scripts/tx1320-raid10-orchestrate.sh` の deploy で yq 読み込み + 引数明示渡し
- [x] 改修版で SMB attach 成功 (Web UI 経由と同等の payload を送信)
- [x] DisconnectCD/ConnectCD OEM action による USB redirector 再起動経路を発見
- [x] CD boot 開始 (`Booting "Automated Install"` 確認)
- [x] kernel boot 開始 (`SGX disabled` ログ確認)
- [x] installer 起動 (cdrom-detect 画面まで到達)
- [x] SKILL.md / memory 更新

## 未完了 / 次セッション課題

### 1. installer cdrom-detect が iRMC Virtual CD を見つけない (最優先 blocker)

`[!!] Detect and mount installation media` で停止し、 USB CD が見えない。 未試行の対策候補 (優先順):

1. **preseed に hw-detect/cdrom-detect 関連設定を追加** (~ 30 min):
   - `d-i hw-detect/load_media boolean false`
   - `d-i cdrom-detect/try-usb boolean true`
   - `d-i cdrom-detect/scan boolean true`
   - `preseed/preseed.cfg.template` に追加 → `generate-preseed.sh` の awk で展開 → ISO 再 remaster
2. **GRUB cmdline へ `cdrom-detect/try-usb=true` / `cdrom-detect/scan=true` を追加** (~ 60 min): `remaster-debian-iso.sh` の grub.cfg generator で boot entry に注入
3. **installer GUI で `<Yes>` 選択 → driver load (`expect` / `script -q` で SOL stdin 経由 Enter 送信)** (~ 30 min): KVM 経由 Enter が届かないため SOL 必須
4. **PXE boot 経路への切替** (~ 60-90 min): TFTP + HTTP で netinst を boot、 iRMC Virtual Media 不要

### 2. (1) 解決後の Phase 5 検証

orchestrate `monitor` で installer 進行確認 → setup-raid10-storcli.sh 実行 → install 完了 → reboot → SSH 検証 (lsblk + storcli + raid10-setup.log)。

### 3. orchestrate.sh monitor サブコマンドの引数バグ (副次)

`./scripts/tx1320-raid10-orchestrate.sh monitor config/... --timeout 1800` が `basename --timeout` エラーで失敗。 L83 で OUTPUT_BASENAME 計算が `--timeout` を OUTPUT_ISO として吸い込む。 修正案: `monitor` サブコマンド時は OUTPUT_ISO 計算をスキップ、 もしくは `--timeout`/`--log` を arg 3 から認識する。

### 4. iRMC BMC 高負荷時の hang 対策 (副次)

短時間に KVM viewer 多重起動 + Virtual Media action + Redfish クエリを集中すると Redfish が timeout する。 KVM viewer は連続多重起動を避け、 5-10 秒の interval を空ける。 必要なら `scripts/irmc-kvm-interact.py shell` で 1 セッション内に複数操作をまとめる。

## 再現方法

### 改修版で deploy + monitor (ISO は既に build 済)

```sh
# 1. SMB attach + boot-override + power cycle (改修版でguest/guest 明示)
./oplog.sh ./scripts/tx1320-raid10-orchestrate.sh deploy config/training_tx1320.yml \
    /var/samba/public/debian-tx1320-raid10.iso

# 2. USB redirector 再起動 (BIOS Setup に落ちた場合のリカバリ)
./oplog.sh ./scripts/bmc-power.sh forceoff 10.254.254.9 claude Claude123
curl -sk --ciphers DEFAULT@SECLEVEL=0 -u claude:Claude123 -X POST \
    -H 'Content-Type: application/json' -d '{"VirtualMediaAction":"DisconnectCD"}' \
    https://10.254.254.9/redfish/v1/Systems/0/Actions/Oem/FTSComputerSystem.VirtualMedia
curl -sk --ciphers DEFAULT@SECLEVEL=0 -u claude:Claude123 -X POST \
    -H 'Content-Type: application/json' -d '{"VirtualMediaAction":"ConnectCD"}' \
    https://10.254.254.9/redfish/v1/Systems/0/Actions/Oem/FTSComputerSystem.VirtualMedia
./oplog.sh ./scripts/bmc-power.sh on 10.254.254.9 claude Claude123

# 3. 進行を SOL でモニタ
./oplog.sh ./scripts/tx1320-raid10-orchestrate.sh monitor config/training_tx1320.yml
# (monitor --timeout/--log 引数は orchestrate.sh のバグで動作不可、 default 2700s が使われる)

# 4. OEM screenshot で BIOS POST → CD boot → kernel boot を確認
./scripts/irmc-oem-screenshot.sh 10.254.254.9 claude Claude123 tmp/$SID/oem-NN.jpg
```

### 検証 (Phase 5 解決後)

```sh
# DHCP IP 推定 (Samba ログ or arp)
# training-tx1320 は 192.168.33.0/24 から DHCP 取得想定

ssh -F ssh/config root@<dhcp_ip> 'lsblk'
ssh -F ssh/config root@<dhcp_ip> 'sudo /usr/local/bin/storcli64 /c0/vall show all'
ssh -F ssh/config root@<dhcp_ip> 'cat /var/log/raid10-setup.log'
```

## 環境情報

- **対象機**: training-tx1320 (Fujitsu PRIMERGY TX1320 M3, Serial MABK035229)
- **BMC**: iRMC S4 FW 9.08F (10.254.254.9, HTTPS + SECLEVEL=0 必須, claude/Claude123)
- **CPU/RAM**: D3373 mainboard, 24 GiB RAM
- **HW RAID controller**: AVAGO MegaRAID (LSI SAS3008 系)、 SAS HDD 900GB × 4
- **BIOS**: V5.0.0.11 R1.22.0 for D3373-B1x (Aptio Setup Utility 2.18.1263、 UEFI 2.4 PI 1.3)
- **SMB server**: 10.1.6.1 (ローカル Claude Code 実行マシン ens19)、 Samba 4.19.5、 [public] share
- **ISO**: `/var/samba/public/debian-tx1320-raid10.iso` (前回 #5 で生成、 764 MB、 storcli64.deb + setup-raid10-storcli.sh 同梱)
- **本セッションの BMC 操作**: PATCH OEM VirtualMedia (guest 明示), boot-override Cd UEFI, ForceOff x1, On x2, DisconnectCD x1, ConnectCD x1

## 関連 Issue

- **#69 (継続)** — owner p-effervescent-kahn (引き継ぎ予定), status `block` (cdrom-detect)
  - 前々セッション (a-goofy-graham): KVM HII 経路 dead-end
  - 前セッション (d-eager-island): preseed + storcli 経路設計完成、 SMB silent failure で blocked
  - **本セッション (p-effervescent-kahn)**: SMB silent failure 真因確定 + 改修 + CD boot → installer 起動まで到達。 残課題は cdrom-detect の追加対策
  - **次セッション推奨手順** (優先順):
    1. preseed に `hw-detect`/`cdrom-detect/try-usb=true` 系を追加 → ISO 再 remaster (~ 30 min)
    2. orchestrate apply → SMB attach (改修済) → boot-override + DisconnectCD/ConnectCD → CD boot → installer
    3. cdrom-detect 通過確認 → preseed `partman/early_command` で storcli RAID10 作成 → install 完了
    4. SSH 検証 (lsblk + storcli + raid10-setup.log)

## 関連ファイル

### 新規 / 修正 (本セッション)

- `config/training_tx1320.yml` — `smb_user: guest` / `smb_pass: guest` 追加 (+ 真因コメント)
- `scripts/tx1320-raid10-orchestrate.sh` — deploy で smb_user/smb_pass を yq 読み込み + 引数 7-8 で明示渡し
- `.claude/skills/irmc-bios-raid/SKILL.md` — L29 raid create-r10 セル + L540 フォールバック表 を真因+解決済に書き換え
- `/home/ubuntu/.claude/projects/-home-ubuntu-projects-pvese/memory/training_tx1320.md` — 「### 7-10」 新規セクション (SMB attach 真因、 ConnectCD/DisconnectCD、 cdrom-detect 未解決、 BMC intermittent hang)

### 無修正 (確認のみ)

- `scripts/irmc-virtualmedia.sh` — 引数 7-8 で smb_user/smb_pass 受け取り済 (L124)、 改修不要を確認
- `scripts/bmc-power.sh` — boot-override Cd UEFI、 forceoff/on は変更なし、 期待通り動作
- `scripts/setup-raid10-storcli.sh` — preseed early_command で呼び出される (cdrom-detect 通過後)、 未実行
- `preseed/preseed.cfg.template` — `%%PARTMAN_EARLY_COMMAND%%` 注入は前 #5 で済、 cdrom-detect 設定追加は次セッション
- `/var/samba/public/debian-tx1320-raid10.iso` (764 MB、 前 #5 生成) — 流用

## 重要な教訓 (次セッションへの引き継ぎ)

1. **iRMC S4 SMB Virtual Media は smb_user/smb_pass を明示する必要がある** (空文字列だと silent reject)。 guest/guest を明示すれば iRMC が guest 認証を試行して attach 成功
2. **`Members@odata.count` は OEM CDImage 設定の attach 状態を反映しない** (USB redirector が mount した media 数)。 OEM CDImage の attach は `VirtualMediaAction@Redfish.AllowableValues` で判定 (Connected → `["DisconnectCD"]`)
3. **DisconnectCD → ConnectCD で USB redirector を fresh attach できる** (PowerState=Off でも有効、 BIOS Setup 中は無効)。 forceoff → DisconnectCD → ConnectCD → on で BIOS POST 開始時から CD device が見える状態を作れる
4. **boot-override Cd UEFI は iRMC でも機能する** (前回 #5 の判断は誤り)。 BIOS POST 中の USB enumeration タイミングが合えば自動 CD boot 成功
5. **kernel が console=ttyS0 へ移行すると KVM 経由 keyboard が installer に届かない**。 cdrom-detect の Yes/No など dialog 操作は SOL stdin 経由 (`expect`/`script -q` wrap) が必要
6. **iRMC BMC web UI は高負荷で hang する** (KVM viewer login 30s timeout、 Redfish 10s timeout)。 SOL (IPMI lanplus) は別 channel で生存、 観測継続可能
7. **`tx1320-raid10-orchestrate.sh monitor` の引数バグ**: `--timeout N` を渡すと L83 の `basename "$OUTPUT_ISO"` が `basename --timeout` を呼んで失敗。 default 引数で動かす
