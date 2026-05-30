# TX1320 M3 RAID10 preseed + storcli 経路実装、 iRMC SMB attach blocker で実機検証未完

- **実施日時**: 2026年5月17日 11:00 〜 11:36 (JST、 約 36 分)
- **担当**: d-eager-island
- **Issue**: #69 (継続中、 owner d-eager-island、 status: 設計完了・実機 SMB blocker で blocked へ更新予定)
- **対象**: training-tx1320 (10.254.254.9, Fujitsu PRIMERGY TX1320 M3, iRMC S4 FW 9.08F)
- **親レポート**: [2026-05-17_101536_tx1320_raid10_dead_end.md](2026-05-17_101536_tx1320_raid10_dead_end.md) (a-goofy-graham、 KVM HII 経路 dead-end 確定)
- **方針転換のきっかけ**: ユーザから web 版 Claude のアドバイス共有 — 「MegaRAID は RAID 10 を RAID 1 + Span 2 として実装、 Profile-Based に RAID 10 が無いのは仕様、 **StorCLI が最も確実**」

## 添付ファイル

- [実装プラン](attachment/2026-05-17_113642_tx1320_raid10_preseed_storcli_blocked_smb/plan.md)
- [preseed --with-raid10-storcli 生成結果](attachment/2026-05-17_113642_tx1320_raid10_preseed_storcli_blocked_smb/preseed-with-raid.cfg)
- [preseed (control、 RAID なし)](attachment/2026-05-17_113642_tx1320_raid10_preseed_storcli_blocked_smb/preseed-without-raid.cfg)
- [CD boot 失敗後の BIOS Setup スクリーンショット](attachment/2026-05-17_113642_tx1320_raid10_preseed_storcli_blocked_smb/bios-setup-after-cd-boot.jpg)

## 前提・目的

前セッション (a-goofy-graham) で iRMC KVM 経由の AVAGO HII (Aptio Setup Utility) 自動化が **dead end 確定**:
- Create Virtual Drive form の "Select RAID Level" (y=128) に Aptio navigation で到達不可 (ArrowUp/Down/Tab/Click/End/PageUp/PageDown の全 9 経路失敗)
- Profile-Based VD には Generic RAID 0/1/5/6 のみで RAID 10 不在
- Aptio HII canvas は Tab/Click を一切解さない

web 版 Claude のアドバイスを踏まえて方針転換:
- MegaRAID は RAID 10 を「RAID 1 + Span 2」として実装 (基本 level: 0/1/5/6 + spans: 10/50/60)
- HII Profile-Based に RAID 10 が無いのは仕様 (シンプルウィザード保護)
- **StorCLI (`storcli /c0 add vd type=raid10 ... pdperarray=2`) が業界標準の一発作成**

新方針: **Debian preseed `partman/early_command` で storcli64 を実行して RAID10 を作成 → そのまま OS install へ続行**。 KVM 自動化を放棄し、 storcli64 + setup script + preseed を ISO に同梱して 1 ISO・1 boot で完結させる。

ユーザ選定方針 (plan mode 中の AskUserQuestion 経由):
- storcli 取得: **ローカルマシンで事前取得 → ISO に同梱** (internet wget 経路は DHCP/DNS/Broadcom URL 安定性の 3 重依存のため除外)
- rescue 操作: **シリアル + preseed で自動進入** ≒ preseed の partman/early_command で RAID 作成 + 通常 install 続行

## 実施内容と結果

### Phase 1: storcli64.deb をローカル取得 ✅ 完了

`tmp/sprightly/install-storcli.sh` のロジックを `scripts/fetch-storcli-deb.sh` に整理。 Broadcom 公式 zip → unzip (ネスト ZIP) → Ubuntu deb 抽出 → `/var/samba/public/storcli64.deb` に永続配置。

実装上の落とし穴 (新規発見):
- **Broadcom URL が完全リニューアル**: 旧 URL `https://docs.broadcom.com/docs-and-downloads/raid-controllers/raid-controllers-common-files/Unified_storcli_all_os_007.2309.0000.0000.zip` は 404
- **新しい SPA 化された URL** `https://docs.broadcom.com/docs/Unified_storcli_all_os_7.2309.0000.0000.zip` は HEAD 200 だが、 GET は JS 必須の HTML を返す (46 KB の SPA ローダー、 本物の ZIP ではない)
- **実際に動く URL** `https://docs.broadcom.com/docs-and-downloads/007.2705.0000.0000_storcli_rel.zip` (35 MB、 直接ダウンロード可)
- ZIP の中身は **ネスト構造**: `storcli_rel/Unified_storcli_all_os.zip` 内に `Ubuntu/storcli_007.2705.0000.0000_all.deb` (2 MB) がある → スクリプトで 2 段階 unzip 必須
- フォールバック candidate: `https://downloadmirror.intel.com/685225/StorCLI_007.1704.0000.0000.zip` (Intel mirror、 旧バージョン 007.1704)

結果: `/var/samba/public/storcli64.deb` 2 MB 配置成功。

### Phase 2: setup-raid10-storcli.sh 作成 ✅ 完了

`scripts/setup-raid10-storcli.sh` を新規作成。 POSIX sh、 ISO 内 `/cdrom/setup-raid10-storcli.sh` として preseed `partman/early_command` から呼出される。

処理フロー:
1. `dpkg -i $DEB` (失敗時は `in-target` 経由、 さらに失敗時は `dpkg-deb -x` で `/usr/local/bin/storcli64` 直接配置)
2. `storcli64 /c0 show` で controller 認識確認
3. `storcli64 /c0/vall delete force` で既存 VD クリア (失敗無視)
4. `storcli64 /c0/eall/sall show` で物理ドライブ列挙 → `awk '/HDD|SSD/ {print $1}'` で先頭 4 本の EID:Slot を抽出
5. `storcli64 /c0 add vd type=raid10 size=all drives=$EID:0,$EID:1,$EID:2,$EID:3 pdperarray=2 wb ra direct strip=256`
6. `storcli64 /c0/vall show | grep RAID-?10` で assert

終了コードで失敗内訳識別 (4=deb missing、 5=storcli not installed、 6=EID parse fail、 7=RAID10 not created)。 全ログを `/var/log/raid10-setup.log` に蓄積。

### Phase 3: generate-preseed.sh 拡張 ✅ 完了

`scripts/generate-preseed.sh` に `--with-raid10-storcli` フラグ追加。 セット時に preseed.cfg へ 1 行 directive 挿入:

```
d-i partman/early_command string sh /cdrom/setup-raid10-storcli.sh /cdrom/storcli64.deb
```

`preseed/preseed.cfg.template` に `%%PARTMAN_EARLY_COMMAND%%` プレースホルダ追加 (Partitioning section 直前)。 awk gsub に新プレースホルダ対応行追加。

検証: `--with-raid10-storcli` ON/OFF 両 preseed を生成して diff:
```
76c76
< 
---
> d-i partman/early_command string sh /cdrom/setup-raid10-storcli.sh /cdrom/storcli64.deb
```
他項目は完全に同じ、 directive 追加のみであることを確認。

### Phase 3.5: remaster-debian-iso.sh 拡張 ✅ 完了

`scripts/remaster-debian-iso.sh` に `--include=FILE` フラグ追加 (複数指定可)。 Docker 内の xorriso で `-map /include/<basename> /<basename>` を実行して ISO ルートに任意ファイルを同梱。

実機検証: `debian-13.3.0-amd64-netinst.iso` を base に preseed + storcli64.deb + setup-raid10-storcli.sh を同梱した 764 MB ISO 生成成功 (`/var/samba/public/debian-tx1320-raid10.iso`)。

### Phase 4: tx1320-raid10-orchestrate.sh + 実機 boot ⚠️ 部分完了 (orchestrate 完成、 実機 boot 失敗)

`scripts/tx1320-raid10-orchestrate.sh` を新規作成。 `build` / `deploy` / `monitor` / `apply` サブコマンドで Phase 1-6 全体を wrap。

実機操作実行:
1. ✅ `irmc-virtualmedia.sh config` で OEM Redfish に CDImage 設定書込成功 (HTTP 200、 ETag 通る、 PATCH 確認)
2. ✅ `bmc-power.sh boot-override Cd UEFI` 設定成功
3. ✅ `bmc-power.sh forceoff` + `on` でハードリブート実行
4. ❌ **CD boot 失敗**: 7 分後 OEM screenshot で BIOS Setup が開いている (=boot media 不在)
5. ❌ **`/redfish/v1/Managers/iRMC/VirtualMedia/Members@odata.count` が 0 のまま**: iRMC が SMB CDImage を実際に attach していない
6. ❌ **Samba 側ログにも接続痕跡なし** (`/var/log/samba/log.smbd` の最終接続が 2026-05-13 のまま)
7. ❌ `ConnectCD` OEM action (`POST /redfish/v1/Systems/0/Actions/Oem/FTSComputerSystem.VirtualMedia` `{"VirtualMediaAction":"ConnectCD"}`) 発行も無効
8. ❌ guest/guest 明示認証、 `\` 付き ImageName 等も silent failure 解消せず

ネットワーク分析:
- iRMC 10.254.254.9/8、 default gateway null (DHCP)、 NameServers 空
- ローカル 10.1.6.1/8 (ens19)
- ARP で 10.254.254.9 が ens19 経由 REACHABLE と判明 → 両 IP は **同じ L2 broadcast domain** (おそらく拠点間 L2 ブリッジ/VPN)
- にもかかわらず iRMC は SMB 接続を一切送出していない

仮説:
- iRMC ファームウェア (S4 9.08F) の SMB Virtual Media は **NetBIOS 名解決を試行** → 失敗で諦めている可能性
- もしくは iRMC 側 firewall (iRMC ⇄ 同 subnet で SMB 制限) の可能性
- 真因は ipmitool/Redfish では特定不可、 iRMC web UI の Virtual Media タブで詳細エラーが見える可能性 (今回未確認)

clean up: VM umount + boot-override → None で実機を boot 待機 idle 状態に戻した。

### Phase 5: 検証 ⏸️ 未実行 (Phase 4 blocker のため到達不可)

予定していた検証 (SSH + storcli + lsblk) は実行不可能。 設計は orchestrate `monitor` サブコマンドおよび SKILL.md「RAID10 storcli + preseed 経路」セクションに記載済。

### Phase 6: ドキュメント更新 + DEPRECATED マーキング ✅ 完了

更新:
- `.claude/skills/irmc-bios-raid/SKILL.md`:
  - `raid create-r10` セルを「⚠️ 設計・スクリプト完成、 実機 boot 段階で iRMC SMB attach が silent failure」に更新
  - 「RAID10 storcli + preseed 経路」セクション追加 (使い方、 setup script 仕様、 失敗フォールバック表、 2026-05-17 #5 実機検証結果)
- `.claude/skills/os-setup/SKILL.md`: TX1320 用事前手順「Phase 0: RAID10 構成」を追記
- `config/training_tx1320.yml`: `raid_setup` セクションを「KVM HII 経路は dead-end、 storcli + preseed 経路で構成」コメントへ書き換え

DEPRECATED マーキング:
- `scripts/irmc-raid10-create.py` — ヘッダーに「DEPRECATED 2026-05-17 #5 d-eager-island: KVM HII path is a confirmed dead-end...」追記

## 完了事項 (技術成果)

- [x] `scripts/fetch-storcli-deb.sh` — Broadcom 公式 zip → Ubuntu deb 抽出 wrapper (ネスト zip 対応、 storcli 007.2705 正常取得)
- [x] `scripts/setup-raid10-storcli.sh` — ISO 同梱用 RAID10 作成スクリプト (失敗内訳明示 exit code、 dpkg/in-target/dpkg-deb 3 段フォールバック)
- [x] `scripts/generate-preseed.sh` — `--with-raid10-storcli` フラグ追加 (1 行 directive 挿入、 ON/OFF diff 検証済)
- [x] `scripts/remaster-debian-iso.sh` — `--include=FILE` フラグ追加 (xorriso `-map` で ISO ルート同梱)
- [x] `scripts/tx1320-raid10-orchestrate.sh` — build/deploy/monitor/apply サブコマンド (Phase 1-6 全体 wrapper)
- [x] `preseed/preseed.cfg.template` — `%%PARTMAN_EARLY_COMMAND%%` プレースホルダ追加
- [x] `/var/samba/public/storcli64.deb` — Broadcom 公式 Ubuntu deb 配置 (2 MB)
- [x] `/var/samba/public/debian-tx1320-raid10.iso` — 同梱済 ISO 生成 (764 MB)
- [x] config + 2 つの SKILL.md ドキュメント更新
- [x] 旧 KVM 経路 (`scripts/irmc-raid10-create.py`) DEPRECATED マーキング

## 未完了 / 次セッション課題

### 1. iRMC SMB Virtual Media silent failure 解消 (最優先 blocker)

現状: 全 Redfish API + ConnectCD OEM action を発行しても iRMC が SMB CDImage を attach しない。 Samba 側にも接続痕跡なし。

次セッションで試す候補 (優先順):

1. **iRMC web UI manual テスト** (~ 10 min): ユーザに iRMC web UI でブラウザから Virtual Media → SMB 設定 → Connect を手動操作してもらい、 詳細エラー (DNS/auth/timeout/permission) を確認。 これが真因特定の最速ルート
2. **HTML5 KVM Local Image upload** (~ 60-120 min): `scripts/irmc-kvm-interact.py` を拡張して Virtual Media タブの "Local Image" upload を Playwright 自動化。 SMB を経由せず WebSocket でブラウザから直接 ISO ストリーミング。 iRMC firmware の API 制限を完全に回避
3. **PXE boot 経路** (~ 60 min): training-tx1320 と同セグメント (10.254.254.0/24) で TFTP server + HTTP server を立て、 PXE で netinst を boot。 preseed は HTTP 経由で取得。 iRMC の Virtual Media を一切使わない
4. **iRMC reachable な SMB server 設置** (~ 30 min): 10.254.254.0/24 内 (training-tx1320 と同物理セグメント) に SMB server を別途用意。 ハードウェアコスト発生

推奨: **1 (web UI 手動テスト) を最初に実施して真因特定 → 2 or 3 を実装**。

### 2. (1) 解決後の Phase 5 検証

orchestrate `apply` 実行 → SOL で installer 進行確認 → SSH で `lsblk` + `storcli64 /c0/vall show all` で RAID-10 / Optl / ~1.6 TiB を assert。 設計は完成、 実機 reach 待ち。

### 3. (副次) generate-preseed.sh の現状互換性確認

新規 `%%PARTMAN_EARLY_COMMAND%%` プレースホルダ追加により、 他サーバ (server4-15) の preseed 生成にも影響する可能性。 ただし `--with-raid10-storcli` 未指定時は空文字列に展開されるため**無害**。 他サーバの preseed 生成テストで 退行ゼロを確認 (今回未実施、 副次タスク)。

## 再現方法

### 全体実行 (新規ホスト向け)

```sh
./scripts/tx1320-raid10-orchestrate.sh apply config/training_tx1320.yml
./scripts/tx1320-raid10-orchestrate.sh monitor config/training_tx1320.yml --timeout 1800
```

### 個別 phase 再実行

```sh
# Phase 1: storcli 取得 (idempotent)
./scripts/fetch-storcli-deb.sh /var/samba/public/storcli64.deb

# Phase 2-3: preseed 生成
./scripts/generate-preseed.sh --with-raid10-storcli config/training_tx1320.yml \
  tmp/<sid>/preseed-with-raid.cfg

# Phase 3.5: ISO remaster
./scripts/remaster-debian-iso.sh --serial-unit=0 \
  --include=/var/samba/public/storcli64.deb \
  --include=scripts/setup-raid10-storcli.sh \
  /var/samba/public/debian-13.3.0-amd64-netinst.iso \
  tmp/<sid>/preseed-with-raid.cfg \
  /var/samba/public/debian-tx1320-raid10.iso

# Phase 4: VM mount + boot-override + cycle (ここで SMB attach 失敗 blocker)
BMC_CURL_OPTS="--ciphers DEFAULT@SECLEVEL=0" \
  ./scripts/irmc-virtualmedia.sh config 10.254.254.9 claude Claude123 \
  10.1.6.1 public debian-tx1320-raid10.iso

BMC_CURL_OPTS="--ciphers DEFAULT@SECLEVEL=0" BMC_PATCH_REQUIRES_ETAG=1 \
  BMC_BOOT_OVERRIDE_NO_DISABLED=1 \
  ./scripts/bmc-power.sh boot-override 10.254.254.9 claude Claude123 Cd UEFI

BMC_CURL_OPTS="--ciphers DEFAULT@SECLEVEL=0" BMC_PATCH_REQUIRES_ETAG=1 \
  ./oplog.sh ./scripts/bmc-power.sh forceoff 10.254.254.9 claude Claude123
BMC_CURL_OPTS="--ciphers DEFAULT@SECLEVEL=0" POWER_ON_RESET_TYPE=On \
  ./oplog.sh ./scripts/bmc-power.sh on 10.254.254.9 claude Claude123

# blocker 確認: 30s 後に attach 状態確認
curl -sk --ciphers DEFAULT@SECLEVEL=0 -u claude:Claude123 \
  https://10.254.254.9/redfish/v1/Managers/iRMC/VirtualMedia
# → "Members@odata.count":0 が出れば silent failure 確定
```

## 環境情報

- **対象機**: training-tx1320 (Fujitsu PRIMERGY TX1320 M3, Serial MABK035229)
- **BMC**: iRMC S4 FW 9.08F (10.254.254.9, HTTPS + SECLEVEL=0 必須, claude/Claude123)
- **iRMC ネットワーク**: 10.254.254.9/8 (DHCP)、 Gateway null、 NameServers 空
- **CPU/RAM**: D3373 mainboard, 24 GiB RAM
- **HW RAID controller**: AVAGO MegaRAID (LSI SAS3008 系)、 SAS HDD 900GB × 4
- **BIOS**: V5.0.0.11 R1.22.0 for D3373-B1x (Aptio Setup Utility 2.18.1263、 UEFI 2.4 PI 1.3)
- **SMB server**: 10.1.6.1 (= 本 Claude Code 実行マシンの ens19 / 10.1.6.1/8)、 Samba 4.19.5、 [public] share、 guest ok=yes、 NT1/NTLMv1 互換
- **本セッションの BMC 操作**: PowerCycle x2、 boot-override Cd UEFI / None UEFI x2、 VM config x3 (空 user → guest/guest → 空 user 戻し)、 ConnectCD OEM action x3

## 関連 Issue

- **#69 (継続中)** — owner d-eager-island、 status `block` (現状の `active` から更新予定)、 blocker: iRMC SMB Virtual Media silent failure
  - 前々セッション (golden-dongarra): cursor_y adaptive nav 確立
  - 前セッション (partitioned-beaver): detect_active_cursor_row 追加、 NumpadAdd 動作確認、 ArrowDown 2-row jump 発見、 form 内 cursor 位置検出が `[RAID0]` cluster 誤検出で確立できず
  - 直前セッション (a-goofy-graham): KVM HII 経路の **全 9 経路 + Profile-Based も RAID 10 不在を確認**、 dead-end 確定、 引き継ぎ
  - **本セッション (d-eager-island)**: 設計・スクリプト・ISO remaster まで完成。 iRMC SMB attach silent failure で実機検証 blocked、 次セッションへ
  - **次セッション推奨手順** (優先順):
    1. **iRMC web UI でユーザが手動 Virtual Media テスト** (~ 10 min): SMB 接続の詳細エラーログ確認
    2. **Playwright で HTML5 KVM Local Image upload 自動化** (~ 60-120 min): SMB 完全回避経路
    3. **PXE boot 経路** (~ 60 min): training-tx1320 同セグメント TFTP+HTTP server で代替

## 関連ファイル

### 新規作成 (本セッション)

- `scripts/fetch-storcli-deb.sh` — Broadcom 公式 storcli ZIP → Ubuntu deb 抽出
- `scripts/setup-raid10-storcli.sh` — ISO 同梱用 RAID10 作成スクリプト (preseed `partman/early_command` から呼出)
- `scripts/tx1320-raid10-orchestrate.sh` — build/deploy/monitor/apply 全体 wrapper
- `/var/samba/public/storcli64.deb` — Broadcom 公式 Ubuntu deb (2 MB、 永続)
- `/var/samba/public/debian-tx1320-raid10.iso` — preseed + storcli + setup script 同梱 ISO (764 MB)
- `tmp/d-eagerisland/` — セッション一時ファイル群 (preseed-with-raid.cfg, preseed-without-raid.cfg, oem-01.jpg, sol.log)

### 修正 (本セッション)

- `scripts/generate-preseed.sh` — `--with-raid10-storcli` フラグ + `%%PARTMAN_EARLY_COMMAND%%` プレースホルダ awk gsub
- `scripts/remaster-debian-iso.sh` — `--include=FILE` フラグ追加 (xorriso `-map` で ISO ルート同梱)
- `preseed/preseed.cfg.template` — `%%PARTMAN_EARLY_COMMAND%%` 行追加
- `config/training_tx1320.yml` — `raid_setup` セクション書き換え (DEPRECATED コメント化、 新経路への案内)
- `.claude/skills/irmc-bios-raid/SKILL.md` — `raid create-r10` セル更新、 「RAID10 storcli + preseed 経路」セクション追加 (使い方/setup script/フォールバック表/実機検証結果)
- `.claude/skills/os-setup/SKILL.md` — 事前準備に TX1320 用 Phase 0 (RAID10 構成) 追記

### DEPRECATED マーキング

- `scripts/irmc-raid10-create.py` — ヘッダーに DEPRECATED コメント追加 (KVM HII 経路前提のため使用不可)

### 触らない (次セッション以降の判断保留)

- `tmp/iter/iter_*.py` — KVM 探索試行群 (dead-end report で言及)、 削除はせず知見として残す
- `tmp/iter/_util.py` の `CURSOR_Y_CREATE_VD_FORM` map — KVM 経路用、 storcli 経路では使用しないが削除は副次タスク

## 重要な教訓 (次セッションへの引き継ぎ)

1. **Broadcom storcli URL は完全リニューアル済**: 旧 `Unified_storcli_all_os_007.2309.0000.0000.zip` パターンは全滅。 新 URL は `https://docs.broadcom.com/docs-and-downloads/007.2705.0000.0000_storcli_rel.zip` (2-stage nested zip、 Ubuntu deb は内側 zip の `Ubuntu/` 配下)
2. **iRMC S4 OEM Virtual Media は silent failure する**: ConnectCD POST が HTTP 204 を返しても実際は attach されない場合がある。 `/redfish/v1/Managers/iRMC/VirtualMedia/Members@odata.count` で実際の attach 状態を verify せよ
3. **ARP L2 reachable ≠ SMB reachable**: 同一 broadcast domain でも iRMC firmware の Virtual Media subsystem が SMB 接続を試行しないケースがある (今回の training-tx1320 で実証)
4. **preseed `partman/early_command` の 1 行 directive 設計**: 複雑なロジックは ISO 同梱の sh script に閉じ込め、 preseed には呼び出し 1 行のみにすると堅牢 + デバッグ容易
5. **remaster-debian-iso.sh `--include` 拡張は再利用性高い**: 他のセットアップ用 binary/script の ISO 同梱にも汎用利用可能
