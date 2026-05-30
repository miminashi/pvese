# Phase 15: TX1320 RAID10 OS install — cdrom-detect.postinst patch 再実装 + 実機検証 + install 完遂

## Context

Phase 14 (2026-05-22 linear-mountain) で kernel boot + d-i screen UI + preseed/early_command 完走まで到達。 ただし **d-i cdrom-detect が「No device for installation media was detected」dialog で停止**。 原因:

- 物理 DVD drive (内蔵) が `/dev/sr0` として enumerate されるが media なし → `Can't open blockdev` で skip
- iRMC OEM NFS Virtual CDROM は `/dev/sr1` (`Fujitsu Virtual CDROM1`) で enumerate
- d-i `list-devices cd` が **/dev/sr1 を CD として返さない** (udev `removable=` または SCSI ID filter による suspected exclusion) ため `for device in $devices` が空ループになり main scan loop が devices=empty で `<Yes>/<No>` dialog に到達

この問題は 2026-05-18 c-curried-puddle / i-floofy-pretzel session で発見済で、 **cdrom-detect.postinst patch (pvese-patch v1)** が `scripts/remaster-debian-iso.sh` 上に実装され build-time sanity 4 項目 pass まで確認されている。 ただし当時は iRMC SMB silent failure (= 後に WAN latency 558ms が真因と判明) で実機検証 blocked、 patch は **commit されないまま放棄**。 現在の `scripts/remaster-debian-iso.sh` には patch は存在しない。

Phase 14 で NFS attach 経路に切替 → SMB blocker は解消 → Phase 15 は 2026-05-18 の patch を **再実装 → sanity → 実機検証 → install 完遂** の経路。 Phase 14 で確立した build → deploy → kernel boot 確実な経路と Manager.Reset 後 240s 待機の手順は再利用する。

最終目標: preseed 完走 + RAID10 install + SSH login (`ssh -F ssh/config training-tx1320` または DHCP 取得 IP)。

## Approach

`scripts/remaster-debian-iso.sh` の initrd 注入ブロック (L98-110) を拡張し、 env `PVESE_PATCH_CDROM_DETECT=1` が set のときに `var/lib/dpkg/info/cdrom-detect.postinst` を抽出 → awk で in-place 注入 → 同じ concatenated cpio stream に追加する。 `scripts/tx1320-raid10-orchestrate.sh` の build phase で env を export し、 tx1320 ISO build 時は常に enable する。

### Patch v1 設計 (cdrom-detect.postinst 確認結果反映)

抽出した postinst (287 行、 6738 bytes、 Debian 13.3.0 netinst の install.amd/initrd.gz 内) の構造:

- L7-15: `log()` / `fail()` 関数定義
- L17-40: `try_mount()` 関数 (mount → /.disk/info チェック → db_set → ret 0/1)
- L45-58: `set_suite_and_codename()` 関数
- L60-81: OS 判定 + `CDFS=iso9660`、 `OPTIONS=ro,exec` set
- L84: 既存早期 exit hook `mount | grep -q 'on /cdrom' && set_suite_and_codename && exit 0`
- L100-110: USB scan 完了待ち (10 iters、 list-devices が空ならば 1s sleep)
- **L112: `while true; do`** (← patch 挿入点)
- L227-285: ループ後処理 (pool scan、 set_suite_and_codename、 anna-install)

Patch (B シェル 11 行、 marker `pvese-patch v1`):

```sh
# pvese-patch v1 - TX1320 /dev/sr1 priority
# /dev/sr0 = physical empty DVD (always fails "Can't open blockdev")
# /dev/sr1 = iRMC OEM Virtual CDROM with the installer ISO
# Safe no-op when /dev/sr1 does not exist (other hardware).
if [ "$OS" = "linux" ]; then
    for count in 1 2 3 4 5; do
        [ -b /dev/sr1 ] && break
        sleep 1
    done
    if [ -b /dev/sr1 ] && try_mount /dev/sr1 $CDFS; then
        set_suite_and_codename
        log "pvese-patch v1: bypassed list-devices via /dev/sr1 direct mount"
        pvese_skip_main_loop=1
    fi
fi
while true; do
    [ "${pvese_skip_main_loop:-0}" = 1 ] && break  # pvese-patch v1
    ...  (元 logic そのまま)
done
```

挿入点:
- L112 `while true; do` の **直前** に 11 行 block (try_mount succeeds → set_suite_and_codename → log → pvese_skip_main_loop=1)
- L112 `while true; do` の **直後** に 1 行短絡 break (`[ "${pvese_skip_main_loop:-0}" = 1 ] && break`)

設計根拠 (2026-05-18 design からの改善):
- 5s wait loop を追加 → /dev/sr1 enumerate race を防ぐ (元の 9 行設計には wait なし)
- ループ後処理 (L227-285) は patch では skip しない → pool scan + anna-install が走り、 partman/apt-cdrom-setup 等の依存パッケージが正しく install される
- patch が no-op の場合 (sr1 不在、 他機種) は元の logic にそのまま fall through、 副作用なし

### Sanity check (build 時、 2026-05-18 の 4 項目 + 1 追加)

`tmp/<sid>/sanity-check.sh` を実行:

1. (a) 復号 cpio に `TRAILER!!!` が 2 個 (concatenated stream 確認)
2. (b) stream #2 に `preseed.cfg` + `var/lib/dpkg/info/cdrom-detect.postinst` 各 1 entry
3. (c) initrd 中に `pvese-patch v1` marker が >=1 回出現
4. (d) initrd 中に `/dev/sr1` 文字列が >=1 回出現
5. **追加**: stream #2 の postinst を取り出し `sh -n` でシンタックス OK (build 時 awk patch 失敗を早期検出)

### 文字列伝播経路

- `scripts/tx1320-raid10-orchestrate.sh` → `export PVESE_PATCH_CDROM_DETECT=1` (build phase) → `scripts/remaster-debian-iso.sh` env → docker container env (`-e PVESE_PATCH_CDROM_DETECT=$PVESE_PATCH_CDROM_DETECT`) → container 内で env-gate 判定

## Critical files to modify

| ファイル | 変更内容 |
|---------|---------|
| `scripts/remaster-debian-iso.sh` | (1) `-e PVESE_PATCH_CDROM_DETECT=$PVESE_PATCH_CDROM_DETECT` を docker run に追加、 (2) container 内の initrd 注入ブロック (L98-110) を拡張: `PVESE_PATCH_CDROM_DETECT=1` のとき docker container 内で `cpio -idmv var/lib/dpkg/info/cdrom-detect.postinst` で部分抽出 → awk script で in-place patch → `sh -n` syntax check → `inject/` dir に配置、 (3) cpio 作成を `find . -mindepth 1 -print` 方式に変更 (directory entry 込み、 postinst dir hierarchy 維持) |
| `scripts/tx1320-raid10-orchestrate.sh` | (1) build() 冒頭で `export PVESE_PATCH_CDROM_DETECT=1` 追加、 (2) build log に `[orchestrate] Phase 4 (cdrom-detect patch enabled)` を表示 |

副次変更 (optional、 Phase 15 scope 内に含める):

| ファイル | 変更内容 |
|---------|---------|
| `scripts/tx1320-raid10-orchestrate.sh` | `monitor()` 引数解析 bug 修正 (Phase 12 引き継ぎ #6 + Phase 14 再確認): `shift 2` を `shift; shift` または `shift 2 \|\| true` を `case "$#" in 2\|...) ;; *) shift 2 ;;` に置換し `--timeout` を `OUTPUT_ISO=$3` に渡らないよう case で先に parse する |

## 実装手順 (Phase 15 サブ Phase)

### Sub-Phase A: patch 再実装 + build sanity (実機操作なし、 失敗時は trivial revert)

1. `scripts/remaster-debian-iso.sh` の docker run env に `PVESE_PATCH_CDROM_DETECT` 伝播追加
2. container 内 initrd 注入ブロックに patch logic 追加 (awk script for in-place insert)
3. `scripts/tx1320-raid10-orchestrate.sh` の build() で `export PVESE_PATCH_CDROM_DETECT=1` 追加
4. `tmp/<sid>/sanity-check.sh` 作成 (5 項目)、 build → sanity 全 pass 確認

### Sub-Phase B: iRMC state 復旧 + deploy + 実機検証

1. iRMC state 復旧 (Phase 14 で確立した手順を再現):
   - ForceOff + sol deactivate + DisconnectCD
   - `curl -X POST .../Manager.Reset GracefulRestart`
   - ping 復活 + Redfish /redfish/v1/Systems/0 復活確認 + 余裕 30s
2. `./pve-lock.sh run ./oplog.sh ./scripts/tx1320-raid10-orchestrate.sh deploy config/training_tx1320.yml`
3. `.venv/bin/python scripts/sol-monitor.py ... --timeout 1800` を background で起動 (orchestrate monitor wrapper bug を回避)
4. SOL log で次の marker を順に確認:
   - `Linux version 6.12.63` (kernel boot)
   - `pvese: preseed/early_command start/end` (preseed 動作)
   - `pvese-patch v1: bypassed list-devices via /dev/sr1 direct mount` ← **Phase 15 の決定的 marker**
   - `pvese: partman/early_command start/end (rc=0)` (RAID10 setup OK)
   - `pvese: raid10-setup OK: RAID10 created` (storcli64 動作)
   - `Installation complete` (preseed 完走)
5. SSH login 確認 (DHCP IP は SOL log の `Configuring DHCP networking` から取得、 または 192.168.33.0/24 で arp)

### Sub-Phase C: 失敗時の調査 fork

- patch marker は出るが install 進まない → ループ後処理 (pool scan/anna-install) が想定外に失敗 → SOL log の anna-install エラーを確認
- patch marker が出ない → /dev/sr1 not present at cdrom-detect 時 → wait loop を 10s に延長 or list-devices ソース調査
- kernel boot しない → Phase 14 で確立した iRMC state 復旧手順を再実施 (Manager.Reset + 240s 待機)
- 別 issue が emerge → 該当 Phase 15 sub-report 作成

## 既存利用するもの (Phase 14 引き継ぎ済 ready)

- `scripts/irmc-virtualmedia.sh` NFS 対応 (Phase 14 で動作確認)
- `scripts/sol-monitor.py` (orchestrate wrapper bug 回避で直接呼び出し)
- `scripts/setup-raid10-storcli.sh` storcli64.bin path に対応済 (Phase 14)
- `scripts/generate-preseed.sh` console=tty0 削除済 (Phase 14)
- `config/training_tx1320.yml` static_ip 10.254.254.250 (Phase 14)
- `report/attachment/2026-05-18_080521_tx1320_raid10_cdrom_patch/sanity-check.sh` (4 項目、 Phase 15 用に 5 項目目を加えて流用)
- `report/attachment/2026-05-18_080521_tx1320_raid10_cdrom_patch/list-cpio-streams.py` (concatenated cpio stream lister、 sanity check 内で使用)

## 関連レポート

- [Phase 14 (2026-05-22 linear-mountain): 4 課題 a/b/c/d 完了 + kernel boot 成功 + cdrom-detect block](../../projects/pvese/report/2026-05-22_154033_tx1320_raid10_phase14_install_completed.md)
- [Phase 13 (2026-05-22 silly-rocket): console=tty0 削除で kernel boot 成功確定](../../projects/pvese/report/2026-05-22_150310_tx1320_raid10_phase13_console_tty0_fix.md)
- [2026-05-18 i-floofy-pretzel: cdrom-detect.postinst pvese-patch v1 設計 + sanity pass、 実機 blocked](../../projects/pvese/report/2026-05-18_080521_tx1320_raid10_cdrom_patch.md)
- [2026-05-18 c-frolicking-starlight: 上記 patch 実機検証は WAN latency で blocked](../../projects/pvese/report/2026-05-18_101017_tx1320_raid10_cdrom_patch_verify.md)
- memory `training-tx1320-phase14-kernel-boot-and-cdrom-block`
- memory `training-tx1320-nfs-solved`

## Verification

### Build-time

```sh
PVESE_PATCH_CDROM_DETECT=1 SKIP_STORCLI_FETCH=1 \
    ./scripts/tx1320-raid10-orchestrate.sh build config/training_tx1320.yml

sh tmp/<sid>/sanity-check.sh
# Expected output:
# TRAILER!!! count: 2 (expected: 2)
# Stream 2 preseed.cfg entries: 1 (expected: 1)
# Stream 2 cdrom-detect.postinst entries: 1 (expected: 1)
# pvese-patch v1 marker count: 2 (expected: >=1)
# /dev/sr1 reference count: >=8 (expected: >=1)
# patched postinst sh -n: OK
# === ALL SANITY CHECKS PASSED ===
```

### Deploy + install 完遂

```sh
# iRMC state 復旧 (Phase 14 確立手順)
./scripts/bmc-power.sh forceoff 10.254.254.9 claude Claude123
ipmitool -I lanplus -H 10.254.254.9 -U claude -P Claude123 sol deactivate
BMC_CURL_OPTS='--ciphers DEFAULT@SECLEVEL=0' BMC_PATCH_REQUIRES_ETAG=1 \
    ./scripts/irmc-virtualmedia.sh disconnect-cd 10.254.254.9 claude Claude123
curl -ksS --ciphers DEFAULT@SECLEVEL=0 -u claude:Claude123 \
    -X POST -H 'Content-Type: application/json' \
    -d '{"ResetType":"GracefulRestart"}' \
    'https://10.254.254.9/redfish/v1/Managers/iRMC/Actions/Manager.Reset'
# wait for ping + Redfish + 30s pad

# deploy + monitor
./pve-lock.sh run ./oplog.sh ./scripts/tx1320-raid10-orchestrate.sh deploy config/training_tx1320.yml
.venv/bin/python scripts/sol-monitor.py \
    --bmc-ip 10.254.254.9 --bmc-user claude --bmc-pass Claude123 \
    --log-file tmp/<sid>/install.log --timeout 1800 --powerstate-interval 60

# install 進行判定
grep -ac "pvese-patch v1: bypassed list-devices via /dev/sr1 direct mount" tmp/<sid>/install.log  # >=1
grep -ac "pvese: partman/early_command end (rc=0)"                                                 # >=1
grep -ac "pvese: raid10-setup OK: RAID10 created"                                                  # >=1
grep -ac "Installation complete"                                                                   # >=1

# SSH login 確認 (DHCP IP は SOL log から)
ssh -F ssh/config -o StrictHostKeyChecking=accept-new root@<dhcp-ip> \
    'storcli64 /c0/vall show; lsblk; uname -a'
```

完遂条件 (all required):
- patch marker line 出力
- partman/early_command rc=0
- `Installation complete` 出力
- SSH login + RAID10 healthy + Debian 13.3 booted from /dev/sda

## 非 scope

- iRMC OEM Virtual CDROM の list-devices 不検出問題自体の真因究明 (udev rules / SCSI removable flag / iRMC FW 9.08F の Virtual Media identification 詳細) — patch で bypass するため Phase 15 では追わない
- training-tx1320 を LINSTOR/PVE クラスタに参加させる (= 一時設置・クラスタ非参加が設計、 別 issue)
- Phase 14 まで持ち越された `tx1320-raid10-orchestrate.sh monitor --timeout` 引数 bug の修正は副次変更扱い、 deploy 動作不能なら scope に戻す
- 他機種 (4-15号機) への patch 適用 — `[ -b /dev/sr1 ]` 偽で no-op、 影響なしのため検証不要
