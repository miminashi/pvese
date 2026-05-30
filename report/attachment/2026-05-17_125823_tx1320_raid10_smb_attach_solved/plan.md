# TX1320 RAID10 SMB attach 真因確定・スクリプト改修 + 改修版で再実行

## Context

前回セッション (2026-05-17 11:36, d-eager-island) で `tx1320-raid10-orchestrate.sh apply` を実行したが、
**iRMC SMB CDImage が silent failure** (`/redfish/v1/Managers/iRMC/VirtualMedia/Members@odata.count=0` のまま、 Samba 側にも接続痕跡なし) で実機 boot 失敗。

ユーザが iRMC web UI から手動で以下の条件で attach + boot 成功させ、 画面に `Booting "Automated Install"` 表示まで確認:

- Share Type: CIFS
- Server: 10.1.6.1
- Share Name: public
- Image Name: debian-tx1320-raid10.iso
- **User Name: guest**
- **Password: guest**
- Domain: (空欄)
- F12 → Boot Menu → CD-ROM 選択
- イメージロード 5 分程度

その後ユーザがサーバを **シャットダウン済** (これは検証用なので一度切って改修版スクリプトで一から流すことになる)。

### 真因 (Explore 調査で確定)

`scripts/irmc-virtualmedia.sh` の `config` サブコマンドは引数 7-8 で `smb_user` / `smb_pass` を受け取れる (L124、 省略時は空文字列)。 一方で `scripts/tx1320-raid10-orchestrate.sh` L124-125 は引数 6 個 (`$OUTPUT_BASENAME` まで) で呼び出していたため、
**空 UserName/Password が PATCH 送信されていた** → iRMC が guest 認証として処理せず silent reject していた。

ユーザの Web UI 入力 (`UserName: guest, Password: guest`) は payload に明示的に文字列 `guest` を入れる動作で、 スクリプトの空文字列とは別物。 これが silent failure の真因。

### ゴール

1. **スクリプトに guest/guest 明示を組み込む**
2. **改修版で apply を実行し、 ユーザ手動操作と同一の挙動を再現**
3. **install 完了 + RAID10 検証**
4. **真因と修正を SKILL.md / レポートに記録**

---

## 改修内容

### A. config/training_tx1320.yml に SMB 認証情報を追加

現状 (L97-98):
```yaml
smb_host: 10.1.6.1
smb_share_path: \public
```

直後に追加:
```yaml
smb_user: guest
smb_pass: guest
```

理由: スクリプト経由の自動化でもユーザ手動操作と完全同一の payload を送るため。

### B. scripts/tx1320-raid10-orchestrate.sh の deploy 改修

L124-125 付近:

現状:
```sh
"${SCRIPT_DIR}/irmc-virtualmedia.sh" config "$BMC_IP" "$BMC_USER" "$BMC_PASS" \
    "$SMB_HOST" "$SMB_SHARE_BARE" "$OUTPUT_BASENAME"
```

改修後 (yq で SMB 認証を読み込み + 明示渡し):
```sh
SMB_USER=$("${YQ}" '.smb_user // "guest"' "$CONFIG")
SMB_PASS=$("${YQ}" '.smb_pass // "guest"' "$CONFIG")
"${SCRIPT_DIR}/irmc-virtualmedia.sh" config "$BMC_IP" "$BMC_USER" "$BMC_PASS" \
    "$SMB_HOST" "$SMB_SHARE_BARE" "$OUTPUT_BASENAME" "$SMB_USER" "$SMB_PASS"
```

- `$YQ` は orchestrate 内既存 yq 変数名を流用 (なければ `"${SCRIPT_DIR}/../bin/yq"`)
- `// "guest"` フォールバックで yml に未記載でも guest が入る (後方互換)

`scripts/irmc-virtualmedia.sh` 本体は無修正で OK (既に引数 7-8 受け取り対応済)。

### C. F12 vs boot-override

ユーザは「F12 → Boot Menu → CD-ROM 選択」で boot させた。 スクリプト側は `bmc-power.sh boot-override Cd UEFI` で UEFI Boot Override を使う設計で、 これは F12 押下と機能的に等価 (BIOS Setup を skip して直接 CD から boot)。

前回 (silent failure 時) も boot-override 設定自体は成功 (HTTP 200) しており、 boot 失敗の原因は CD attach 不在のみだった。 SMB attach さえ正常なら boot-override 経路で CD boot 可能と想定 → 追加変更不要。

もし boot-override + power on で BIOS Setup に落ちる (= boot-override が効かない) ことが判明したら、 fallback として:

- `scripts/irmc-kvm-interact.py sendkeys F12` (実装済) で KVM 経由 F12 押下
- Boot Menu 表示後 ArrowDown 数回 + Enter で CD-ROM 選択

これは boot-override 経路を試して失敗した場合のみ実装 (今回 scope 外、 次セッション課題)。

---

## 実行手順 (改修後)

### Phase 0: 現状確認 (read-only)

```sh
SID=$(<セッション UUID 先頭 8 文字>)
mkdir -p tmp/$SID

# iRMC 電源・VM 状態確認 (read-only)
BMC_CURL_OPTS="--ciphers DEFAULT@SECLEVEL=0" \
  ./scripts/bmc-power.sh status 10.254.254.9 claude Claude123

BMC_CURL_OPTS="--ciphers DEFAULT@SECLEVEL=0" \
  ./scripts/irmc-virtualmedia.sh status 10.254.254.9 claude Claude123

# Samba 接続記録の最新確認
Read /var/log/samba/log.smbd
```

期待:
- PowerState=Off (ユーザがシャットダウン済)
- CDImage は前回ユーザが Web UI で設定した値が残っているか確認 (User=guest なら好都合)
- Samba ログに 10.254.254.9 からの guest 接続記録あれば「Web UI からの attach は実際に SMB 接続を生んだ」ことの証跡

### Phase 1: スクリプト改修

1. `config/training_tx1320.yml` に `smb_user: guest` / `smb_pass: guest` 追加
2. `scripts/tx1320-raid10-orchestrate.sh` の deploy で yq 読み込み + 引数 7-8 で渡す

### Phase 2: 改修版で apply 実行

```sh
# build は前回作成済 ISO (debian-tx1320-raid10.iso 764 MB) が /var/samba/public/ にある前提
# 必要なら build から:
./scripts/tx1320-raid10-orchestrate.sh build config/training_tx1320.yml

# deploy + power cycle (オペレーションは ./oplog.sh ラップ)
./oplog.sh ./scripts/tx1320-raid10-orchestrate.sh apply config/training_tx1320.yml
```

apply は以下を順次実行:
1. `irmc-virtualmedia.sh umount` (既存設定クリア、 任意)
2. `irmc-virtualmedia.sh config ... guest guest` (新規 attach)
3. **検証**: `Members@odata.count=1` 確認 (前回失敗時はここで 0 のまま)
4. `bmc-power.sh boot-override Cd UEFI`
5. `bmc-power.sh forceoff` (シャットダウン済なのでスキップ可、 念のため)
6. `bmc-power.sh on` (POWER_ON_RESET_TYPE=On)

### Phase 3: 監視

```sh
./scripts/tx1320-raid10-orchestrate.sh monitor config/training_tx1320.yml --timeout 1800
```

monitor は SOL log と OEM screenshot を周期的に取得。 期待される出力:
- `Booting "Automated Install"` (ユーザ報告と同じ画面)
- `Loading kernel ...`
- `partman/early_command: sh /cdrom/setup-raid10-storcli.sh ...`
- `setup-raid10-storcli: storcli64 /c0 add vd type=raid10 ... success`
- `Installing the base system`、 `Installing GRUB`、 `Installation complete`、 reboot

ロード遅延 (ユーザ報告 5 分) を見越して timeout 1800 秒 (30 分) で監視。

### Phase 4: 検証

install 完了後 (reboot で GRUB → Linux → DHCP):

```sh
# DHCP IP 推定 (Samba ログ or arp)
# training-tx1320 は 192.168.33.0/24 から DHCP 取得想定

# SSH (preseed の SSH 設定とユーザに依存)
ssh -F ssh/config root@<dhcp_ip> 'lsblk'
ssh -F ssh/config root@<dhcp_ip> 'sudo /usr/local/bin/storcli64 /c0/vall show all'
ssh -F ssh/config root@<dhcp_ip> 'cat /var/log/raid10-setup.log'
```

期待:
- `/dev/sda` が ~1.6 TiB (RAID10 spanning 4 SAS 900GB)
- `storcli64 /c0/vall show all` で `State=Optl, RAID-10, 4 PD, pdperarray=2`
- `/var/log/raid10-setup.log` に setup script 完了ログ

### Phase 5: ドキュメント更新

- `.claude/skills/irmc-bios-raid/SKILL.md`:
  - L29-30 `raid create-r10` セル: silent failure → 解決済へ
  - L540 付近フォールバック表: 真因 (空 user/pass) + 解決策 (guest/guest 明示) に書き換え、 (a)-(d) は不要に
- `.claude/skills/os-setup/SKILL.md`: Phase 0 (RAID10 構成) の使い方を明確化
- 新規レポート `report/2026-05-17_<時刻>_tx1320_raid10_smb_attach_solved.md` 作成 ([REPORT.md](../../projects/pvese/REPORT.md) ルール):
  - 親レポート: `2026-05-17_113642_tx1320_raid10_preseed_storcli_blocked_smb.md`
  - 真因確定 + 修正 diff + 検証結果 + 添付 (SOL ログ、 OEM screenshot、 lsblk/storcli 出力、 raid10-setup.log)
- `issue.sh` #69 更新: `done` (install + RAID10 検証成功時) or `block` (失敗時)

---

## 重要な制約

- **状態変更操作は `./oplog.sh` ラップ** (CLAUDE.md ルール)
- **scripts は `./` 付き相対パス** (`./scripts/...`)
- **一時ファイルは `tmp/$SID/` のみ** (`/tmp/` 禁止)
- **SOL 起動前に `ipmitool ... sol payload enable 2 4` が必要** (training_tx1320 固有、 [config/training_tx1320.yml](../../projects/pvese/config/training_tx1320.yml) 注記)
- **iRMC は HTTPS + `--ciphers DEFAULT@SECLEVEL=0` 必須** (`BMC_CURL_OPTS` 環境変数で渡す)
- **boot-override は PATCH 時 If-Match ETag 必須** (`BMC_PATCH_REQUIRES_ETAG=1`)

---

## 関連ファイル

### 修正 (本セッション)

| ファイル | 行 | 修正内容 |
|---------|-----|---------|
| `config/training_tx1320.yml` | L98 直後 | `smb_user: guest` / `smb_pass: guest` 2 行追加 |
| `scripts/tx1320-raid10-orchestrate.sh` | L120-125 付近 | yq で smb_user/smb_pass を読み、 `irmc-virtualmedia.sh config` 引数 7-8 として渡す |
| `.claude/skills/irmc-bios-raid/SKILL.md` | L29-30, L540 付近 | silent failure 真因 + 解決策を反映 |
| `report/2026-05-17_<時刻>_tx1320_raid10_smb_attach_solved.md` | 新規 | 真因 + 検証結果レポート |

### 無修正 (確認のみ)

| ファイル | 確認内容 |
|---------|---------|
| `scripts/irmc-virtualmedia.sh` | 引数 7-8 で smb_user/smb_pass 受け取り済 (L124、 改修不要) |
| `scripts/bmc-power.sh` | boot-override Cd UEFI、 forceoff/on の流れ |
| `scripts/setup-raid10-storcli.sh` | ISO 同梱、 preseed early_command で実行される |
| `preseed/preseed.cfg.template` | `%%PARTMAN_EARLY_COMMAND%%` プレースホルダで RAID 経路 ON |
| `/var/samba/public/debian-tx1320-raid10.iso` | 既存 (764 MB)、 build skip 可能 |
| `/var/samba/public/storcli64.deb` | 既存 (2 MB)、 ISO 同梱済 |

---

## 検証 (Verification)

### 期待結果 (改修が正しい場合)

- **Phase 2 (apply) 時点**: Samba ログに 10.254.254.9 からの guest 認証成功 + `Members@odata.count=1`
- **Phase 3 (monitor)**: SOL に `Booting "Automated Install"` 表示 (5 分前後)、 続いて kernel boot → installer → `setup-raid10-storcli` 実行成功ログ
- **Phase 4 (検証)**: `/dev/sda ~1.6 TiB`、 `storcli64 /c0/vall show all` で `RAID-10 / State=Optl / 4 PD`、 `raid10-setup.log` に成功記録

### 失敗時の対応

- **SMB attach 再失敗** (`Members@odata.count=0`): 改修が効いていない → smb_user/smb_pass が yml/orchestrate のどこで欠落しているか追跡。 `payload` を echo で出力するデバッグログを追加
- **attach 成功 + boot-override が効かず BIOS Setup へ落ちる**: KVM 経由 F12 fallback を実装 (次セッション課題)
- **install 途中で hang**: SOL ログから failed step を特定。 RAID 作成失敗なら `raid10-setup.log` を確認

---

## 次セッション課題

1. install が完了しなかった場合の対処
2. boot-override 経路が効かない場合の F12 KVM fallback 実装
3. `--with-raid10-storcli` の他サーバ preseed 生成への退行ゼロ確認 (副次)
4. memory に `training_tx1320.md` を新規作成し、 「SMB attach は guest/guest 明示が必須」を記録
