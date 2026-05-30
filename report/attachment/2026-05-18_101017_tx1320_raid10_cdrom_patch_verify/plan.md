# TX1320 RAID10 install: BMC reboot → pvese-patch v1 (cdrom-detect) 実機検証 + RAID10 install 完走

## Context

前セッション (i-floofy-pretzel、 報告 `report/2026-05-18_080521_tx1320_raid10_cdrom_patch.md`) は以下の状態で blocked:

1. **HDImage license dead-end 確定** — OEM `HDImage.MaximumNumberOfDevices=0` (license 上 0 device)。 Priority #1 経路 (HD virtual media 配信) は技術的に不可能。 PATCH 試行は HTTP 200 で見かけ accept されるが実機への USB attach 起こらず。
2. **iRMC SMB silent failure 固着** — HDImage PATCH 試行の副作用で iRMC USB redirector の内部 state が破損。 「CDImage attached」と思い込んだまま実際は Members=0、 ConnectCD action は `ActionParameterValueNotInList` で reject。 → CD attach 不能で実機検証 blocked。
3. **pvese-patch v1 (cdrom-detect.postinst initrd 注入) は build 段階 sanity check pass、 実機未検証** — env-gate `PVESE_PATCH_CDROM_DETECT=1` で `/dev/sr1` を最優先試行する 9 行 block を `cdrom-detect.postinst` に awk in-place 注入する仕組み。 1 回目 deploy で 0.076s "SGX disabled" kernel hang が観測されたが、 直後の iRMC 不調により再現性確認不可。 patch のせいか偶発か未確定。

ユーザ指示: **「BMC を一度 reboot してから作業を実施」**。 これにより iRMC USB redirector の state がクリアされ、 CDImage attach + 実機検証が可能になる見込み。 Manager.Reset GracefulRestart (Redfish) は `scripts/irmc-bios-raid-setup.sh` S1 step で既に実装・実証済 (HTTP 204、 復帰 ~187s、 操作 cost は許容範囲)。

**Intended outcome**: BMC reset で SMB redirector 復旧 → patched ISO の deploy → SOL log で `pvese-patch: bypassed list-devices via /dev/sr1 direct mount` を確認 → cdrom-detect dialog 突破 → RAID10 install 完走。 patch のせいで 0.076s hang が再現する場合は initramfs unpack 周辺の debug に切り替え。

## 関連 Issue

- **#69 (status=blocked → 再開)**: TX1320 M3 RAID10 自動構成。 本セッションで unblock 試行 → 結果次第で resolved / 別 issue 分岐

## 影響範囲

- 修正は最小限。 既存 patch 実装 (`scripts/remaster-debian-iso.sh` の `PVESE_PATCH_CDROM_DETECT` env-gate) は変更しない
- patch が動作した場合は `config/training_tx1320.yml` または orchestrate スクリプトの default を `=1` 化検討 (本セッションの結果を見て scope を決める)

## 重要ファイル (本セッションで触れる可能性)

| ファイル | 役割 | 編集予定 |
|---------|------|---------|
| `scripts/irmc-virtualmedia.sh` | OEM VirtualMedia API ラッパ (`--type=CD\|HD\|FD`) | 編集なし (状態確認のみ) |
| `scripts/remaster-debian-iso.sh` | initrd injection 実装 (L73 env, L107-167 patch, L172-177 cpio build) | 編集なし (実機検証のみ) |
| `scripts/tx1320-raid10-orchestrate.sh` | build/deploy/monitor サブコマンド | 編集なし |
| `scripts/sol-monitor.py` | SOL passive monitor | 編集なし |
| `scripts/irmc-oem-screenshot.sh` | OEM FTSComputerSystem.Screenshot ラッパ | 編集なし |
| `scripts/bmc-power.sh` | 電源操作 (status/on/forceoff/cycle) | 編集なし |
| `config/training_tx1320.yml` | SMB share + BMC config | 編集なし (default の `=1` 化は最後に検討) |
| `issues/issues.yml` (#69) | 状態更新 | 結果に応じて status 更新 |
| `report/<timestamp>_…_followup.md` | 新規レポート作成 | 新規 |

## 実装方針

### Phase 1: BMC reboot で iRMC SMB redirector 復旧

ユーザ指示通り Manager.Reset GracefulRestart で iRMC を再起動して USB redirector の固着状態をクリア。

```sh
# pre-state 記録
./scripts/irmc-virtualmedia.sh --type=CD status 10.254.254.9 claude Claude123 > tmp/<sid>/pre-status.txt
./scripts/bmc-power.sh status 10.254.254.9 claude Claude123 > tmp/<sid>/pre-power.txt

# Manager.Reset 実行 (oplog 経由で記録)
./oplog.sh curl -sk --ciphers DEFAULT@SECLEVEL=0 -u claude:Claude123 \
    -X POST -H 'Content-Type: application/json' \
    -d '{"ResetType":"GracefulRestart"}' \
    -w 'HTTP %{http_code}\n' \
    'https://10.254.254.9/redfish/v1/Managers/iRMC/Actions/Manager.Reset'

# 30s 待機 → BMC 復帰 polling (max 240s)
sh tmp/<sid>/wait-bmc.sh   # /redfish/v1/ が HTTP 200 になるまで poll
```

期待結果: HTTP 204 → 待機 30s → polling 開始 → ~180-200s で BMC 復帰。

### Phase 2: SMB redirector 復旧確認

```sh
# Manager VirtualMedia Members count
curl -sk --ciphers DEFAULT@SECLEVEL=0 -u claude:Claude123 \
    'https://10.254.254.9/redfish/v1/Managers/iRMC/VirtualMedia' \
    | python3 -c "import sys, json; d=json.load(sys.stdin); print('Members@odata.count=', d.get('Members@odata.count'))"

# CDImage 状態 (Server/Share/Image, RemoteMountEnabled)
./scripts/irmc-virtualmedia.sh --type=CD status 10.254.254.9 claude Claude123

# System Action AllowableValues に ConnectCD が出るか
curl -sk --ciphers DEFAULT@SECLEVEL=0 -u claude:Claude123 \
    'https://10.254.254.9/redfish/v1/Systems/0' \
    | python3 -c "import sys,json,re; d=json.load(sys.stdin); a=d.get('Actions',{}).get('Oem',{}); print(json.dumps(a, indent=2))" \
    > tmp/<sid>/system-actions.json
```

**判定**:
- Members 数 ≥ 1 (CDImage が attached) → Phase 3 (re-attach) スキップして Phase 4 へ
- Members 数 = 0 + ConnectCD が AllowableValues に出る → Phase 3 で再 attach
- Members 数 = 0 + ConnectCD も出ない → **Manager.Reset 2 回目を ForceRestart で試行**。 それでも復旧しなければ blocked 報告でユーザに PSU 抜差し相談 (回数上限 2 回、 ユーザ承認方針)

### Phase 3: CDImage を再 attach (Phase 2 で Members=0 の場合のみ)

```sh
# patched ISO は前セッションで build 済 (/var/samba/public/debian-training-tx1320-raid10.iso 764MB) を継続利用
./scripts/irmc-virtualmedia.sh --type=CD config 10.254.254.9 claude Claude123 \
    --server=10.1.6.1 --share='\\public' --image=debian-training-tx1320-raid10.iso \
    --user=guest --pass='' --auto-attach

# ConnectCD action 発行
sh tmp/<sid>/connect-cd.sh   # OEM ConnectCD action POST

# Members 数を再確認 → ≥ 1 で OK
```

### Phase 4: 既存 patched ISO の sanity check (再利用方針、 rebuild 回避)

ユーザ方針: 既存を再利用 + sanity check のみ。 rebuild はスキップ。

前セッション build 済の `/var/samba/public/debian-training-tx1320-raid10.iso` (764 MB) を再利用。

```sh
sh report/attachment/2026-05-18_080521_tx1320_raid10_cdrom_patch/sanity-check.sh
```

**判定**:
- 4 項目 pass → Phase 5 へ
- fail (想定外、 ISO が消えた等) → ユーザに相談 (rebuild するか判断仰ぐ)

### Phase 5: Deploy (boot-override Cd UEFI + 電源 cycle)

```sh
./oplog.sh ./scripts/tx1320-raid10-orchestrate.sh deploy config/training_tx1320.yml
```

orchestrate deploy は内部で:
1. VirtualMedia config (Server/Share/Image 更新) — 既に Phase 3 で設定済なら no-op
2. ConnectCD action
3. boot-override Cd UEFI
4. ForceOff → 待機 → ResetType=On

### Phase 6: SOL monitor + screenshot で patch 動作確認

SOL monitor を background run。 5-10 分後に screenshot で kernel 進捗確認。

```sh
# background で sol-monitor 起動
.venv/bin/python ./scripts/sol-monitor.py \
    --bmc-ip 10.254.254.9 --bmc-user claude --bmc-pass Claude123 \
    --log-file tmp/<sid>/sol.log \
    --timeout 1800 \
    --powerstate-interval 30 \
    --installer-syslog tmp/<sid>/installer-syslog \
    --static-ip <dhcp 不明、 SOL のみで判定>

# 8-10 分後に screenshot
./scripts/irmc-oem-screenshot.sh 10.254.254.9 claude Claude123 tmp/<sid>/post-boot.jpg
```

**SOL log の確認ポイント** (`grep` で順次確認):

1. `Booting 'Automated Install'` — GRUB が ISO を読めた
2. `Linux version` — kernel boot 開始
3. `EFI stub` / `SGX disabled` — kernel early init
4. `Run /init` — initramfs 進入
5. **`pvese-patch: bypassed list-devices via /dev/sr1 direct mount`** ← patch hit の決定的証拠
6. `partman` / `setup-raid10-storcli.sh` — preseed early_command 実行
7. `Installing keyboard-configuration` — base install 開始

**分岐判定**:

| SOL ログ状態 | 解釈 | 次手 |
|------------|------|------|
| pvese-patch 行が出て partman に進む | ✅ patch 動作 + install 進行 | Phase 7 (install 完走確認) |
| pvese-patch 行は出るが install fail | patch OK だが別問題 (RAID/preseed) | partman log を別途 fetch して debug |
| 0.076s hang 再現 (Linux version も出ない) | patch 起因の kernel/initramfs 破損 | Phase 8 (debug, baseline と diff 比較) |
| pvese-patch 行が出ない (list-devices loop に入る) | injection 効いてない | sanity check 再実行 + cpio archive inspect |
| GRUB で "Booting 'Automated Install'" のまま hang | SMB attach 不十分 (Phase 2 戻し) | Phase 1 から再試行 (Manager.Reset 2回目) |

### Phase 7: Install 完走確認 (patch 動作した場合)

`sol-monitor.py` の終了を待つ (timeout 1800s)。 exit code:
- 0 = success (machine-id mtime + installer-syslog 整合)
- 1 = timeout (1800s で完走せず) → 別途 screenshot 確認
- 4 = false positive (PowerState Off だが stages なし)

完走後 (DHCP IP 不明なので静的 IP 設定なし、 SSH ログイン経路は別途確認必要):
- iRMC で SSH virtual media 不可、 シリアル経由で login → `lsblk`, `storcli64 /c0/vall show`
- DHCP リース取得を待つ場合は SOL log に `My IP address is …` を grep

### Phase 8: 0.076s hang 再現時の baseline 比較 (ユーザ方針)

ユーザ方針: baseline (=0) と比較して切り分け。 patch 撤回や別経路転換は本セッション scope 外。

```sh
# baseline (PVESE_PATCH_CDROM_DETECT=0) で rebuild → 別 ISO ファイル名で保存
PVESE_PATCH_CDROM_DETECT=0 ./oplog.sh ./scripts/tx1320-raid10-orchestrate.sh build \
    config/training_tx1320.yml /var/samba/public/debian-training-tx1320-baseline.iso

# baseline ISO に切り替えて deploy
./scripts/irmc-virtualmedia.sh --type=CD config 10.254.254.9 claude Claude123 \
    --server=10.1.6.1 --share='\\public' --image=debian-training-tx1320-baseline.iso \
    --user=guest --pass='' --auto-attach
./oplog.sh ./scripts/tx1320-raid10-orchestrate.sh deploy config/training_tx1320.yml
```

**判定**:
- baseline でも 0.076s hang → BMC/HW 起因 (patch 無罪)、 別 issue で深掘り、 本セッションは現状報告で終了
- baseline は進む / patched でのみ hang → patch 起因確定、 別 issue で debug 継続 (cpio directory entry / awk runtime / gzip boundary 等)、 本セッションは原因切り分け完了で報告

debug 候補 (次セッションへの引き継ぎ用):
- cpio archive の directory entry 構築不備 (`find . -mindepth 1 -print` で漏れ)
- awk patch が `sh -n` pass しても runtime semantics broken
- gzip 連結 stream の boundary mismatch
- patched cdrom-detect.postinst の `set_suite_and_codename` 呼び出しで未定義変数

### Phase 9: 報告 + issue 更新

結果に応じて:
- **完走**: #69 を `done` に変更、 patch を default `=1` 化を検討 (別 issue / 別セッション)
- **patch 動作だが install で別問題**: 該当原因を追求した上で別 issue に切り出し
- **patch 起因の hang**: 別 issue で debug 継続
- **BMC reset しても SMB silent failure 解消せず**: ユーザに PSU 抜差し依頼、 #69 は blocked 継続

レポートは `report/<timestamp>_tx1320_raid10_cdrom_patch_verify.md` で作成 (REPORT.md のフォーマット遵守、 attachment dir に SOL log + screenshot + 操作ログを格納)。

## 再利用する既存スクリプト・コマンド

- `scripts/irmc-bios-raid-setup.sh` の S1 step (Manager.Reset GracefulRestart + 240s polling) — そのまま直接呼ばず、 同等の curl + polling を shell スクリプトに書いて `oplog.sh` 経由実行
- `scripts/bmc-power.sh status/forceoff/on` — pre/post state 記録 + 電源操作
- `scripts/irmc-virtualmedia.sh --type=CD status/config` — Phase 2 状態確認 + Phase 3 設定
- `scripts/tx1320-raid10-orchestrate.sh build/deploy` — sanity check pass 後の deploy
- `scripts/sol-monitor.py` — Phase 6 install 進捗 + 完走判定
- `scripts/irmc-oem-screenshot.sh` — milestone screenshot (回数を絞る、 skill 注意事項準拠)
- `report/attachment/2026-05-18_080521_tx1320_raid10_cdrom_patch/sanity-check.sh` — Phase 4 で再実行

## Verification (e2e テスト)

1. **BMC 復旧確認**: Manager.Reset 後、 Members 数 ≥ 1 + ConnectCD/DisconnectCD AllowableValues 正常切替
2. **patch hit 確認**: SOL log に `pvese-patch: bypassed list-devices via /dev/sr1 direct mount` が出現
3. **install 進行確認**: SOL log に `partman` / `Installing keyboard-configuration` 出現
4. **完走確認**: sol-monitor exit code 0、 host が PVE OS で boot
5. **RAID 確認** (SSH ログイン経路成立後): `lsblk` で / が VD (~1.8TB) 上 + `storcli64 /c0/vall show` で RAID10 healthy

## リスク + 注意

- **Manager.Reset 後 ~200s BMC 無応答**: その間は他の curl も timeout。 polling で復帰確認してから次操作
- **OEM Screenshot は milestone のみ**: 連続呼び出しで BMC 60-90s 無応答。 各 deploy で 1-2 回に絞る
- **HDImage/FDImage への PATCH は厳禁**: 副作用で USB redirector 破損 (前セッションで確認済)。 `--type=CD` 固定で操作
- **sol-monitor は background 起動**: foreground で 1800s blocking は session 効率悪い、 必ず `run_in_background=true`
- **DHCP リース取得**: training-tx1320 は別拠点 (10.254.254.0/24 + 192.168.33.0/24)、 install 後の DHCP IP は SOL log でしか拾えない可能性
- **複合コマンド禁止**: パイプ・セミコロン・`&&` は CLAUDE.md 準拠で個別 Bash 呼び出しに分割。 `$()` を含む処理は `tmp/<sid>/*.sh` に書いて実行
