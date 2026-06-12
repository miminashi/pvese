# TX1320 RAID 初期化 → PVE インストール 通しセットアップ

## Context

ユーザ依頼: training-tx1320 (Fujitsu PRIMERGY TX1320 M3 / iRMC S4 FW 9.69F、別拠点 10.254.254.9) の
**RAID を一度初期化してから PVE インストールまで** 通しで実行する。

これは確立済みの標準経路 (3/3 実証 + sonnet 自律 10/10 成功、issue #74/#75)。RAID 初期化方式は
ユーザ選択により **BIOS HII KVM での明示的 RAID Clear (標準経路)** を採用する。install 中の preseed
`partman/early_command` で storcli が RAID10 を delete+create 再構築するため、最終的な RAID10 は install が作る。

成果物 (期待): Debian 13 + HW RAID10 (sda 1.6T 単一 VD + LVM) + **PVE 9.2.3** (web UI HTTP 200)、
eno2 dark-net IP で物理操作なし SSH 到達。

### Preflight (確認済み)
- iRMC 10.254.254.9 疎通 OK (loss 0%, ~50ms) / playground 10.1.6.6 疎通 OK (loss 0%)
- playground 上に deploy アセット配置済み:
  - `/var/samba/public/ipxe-tx1320.iso` (5.7MB, NFS export = iRMC が読む場所)
  - `/var/www/html/preseed/training-tx1320.cfg` (12KB)
  - `/var/www/html/firmware/storcli64.bin` (8MB)

## 固定パラメータ

| 項目 | 値 |
|------|-----|
| config | `config/training_tx1320.yml` |
| iRMC | `10.254.254.9` / `claude` / `Claude123` |
| deploy ISO basename | `ipxe-tx1320.iso` (既定 `ipxe-<hostname>.iso` ではなく**明示指定**) |
| playground | `10.1.6.6` (nginx + NFS export) |
| eno2 MAC (dark-net, SSH 用) | `4c:52:62:14:de:f0` |
| storcli64 取得元 | `http://10.1.6.6/firmware/storcli64.bin` |

## 実行手順

### Step 0: セッション準備 + BMC env export
- `mkdir -p tmp/<sid>` (`<sid>` = セッション UUID 先頭8桁、Glob で transcripts から取得)
- iRMC TLS に必須の env を export (未 export だと bmc-power.sh rc=52、落とし穴 #10):
  ```
  export BMC_SCHEME=https BMC_CURL_OPTS="--ciphers DEFAULT@SECLEVEL=0"
  export BMC_PATCH_REQUIRES_ETAG=1 BMC_BOOT_OVERRIDE_NO_DISABLED=1 POWER_ON_RESET_TYPE=On
  ```

### Step 1: BIOS HII KVM で RAID Clear (opus 実施 — 唯一の脆弱リンク)
標準経路の「**検証付き Clear**」を使う (単一ファイル blind recipe は先頭 ArrowRight ドロップに脆弱)。
- 必要なら `./scripts/irmc-kvm-recover.sh config/training_tx1320.yml` で BIOS Setup 到達 (host ForceOff
  → Manager.Reset → boot-override BiosSetup + on → POST 待ち → OEM で BIOS 確認)
- `scripts/irmc-kvm/server.py` の永続セッションを起動し `=== KVM server READY ===` を待つ
- 検証付き Clear (各遷移を `shot` で確認、ドロップ時リトライ):
  1. Main → Advanced タブ切替 → `shot tab.png` で着地確認 (Advanced = size≈17919 / caret_y=102)
  2. `navy 393 caret 25 1500` + `shot avago_row.png` で AVAGO 行へ adaptive 着地
  3. `Enter`×3 → Config Mgmt → `Clear Configuration` 行を右ヘルプ "Deletes all existing
     configurations" で確認 (行位置は VD 数で変動するのでテキストで同定)
  4. modal を開いたら `mouse 512 384` で実クリックしフォーカス再確立 → Confirm/Yes commit (1ファイル集約)
  5. Main Menu → **Virtual Drive Management** で `shot vdm.png` → size=**9758** = "no Virtual Drives
     currently available" = Clear 成功 (dashboard カウントは stale なので VDM で最終判定)
- KVM 操作の各 shot は per-key サブエージェントで画像分析 (行テキスト + 右ヘルプ + カーソル反転を読む)。
- 失敗が連鎖したら `irmc-kvm-recover.sh` で KVM pipeline 健全化 → 再ナビ。RAID は NVRAM 永続なので無影響。

### Step 2: iPXE-CD deploy
```
./oplog.sh ./scripts/irmc-ipxe-cd-deploy.sh config/training_tx1320.yml ipxe-tx1320.iso
```
DisconnectCD → CDImage(NFS)設定 → VirtualMediaServiceRestart (USB redirector 劣化リセット) → On →
ConnectCD (204 まで検証+リトライ、ダメなら abort) → ForceOff → boot-override Cd UEFI (Off で設定) → On。
deploy が `ConnectCD did not return 204` で abort したら Step 2 を再実行。

### Step 3: install 監視 (foreground ブロッキング)
```
.venv/bin/python scripts/sol-monitor.py --bmc-ip 10.254.254.9 --bmc-user claude \
    --bmc-pass Claude123 --log-file tmp/<sid>/install.log --timeout 2400 --powerstate-interval 30
```
- **完遂 = rc=0 (POWER_DOWN → PowerState Off 二重確認)** が正典。進捗一次情報は sol-monitor の d-i stage
  (DETECTING_NETWORK → CONFIGURING_APT → INSTALLING_SOFTWARE → INSTALLING_GRUB → POWER_DOWN)。
- 🚨 **#15 netcfg stuck エスケープ**: deploy(電源On)から合計 ~10min 経っても CONFIGURING_APT に進まず
  DETECTING_NETWORK 等で停滞なら `./scripts/bmc-power.sh forceoff 10.254.254.9 claude Claude123` → Step 2
  から再 deploy (2回目は +3〜4min で解消)。ForceOff した deploy の sol-monitor は rc=4 false positive で
  返るが異常ではない。#15 判定時以外は手動 ForceOff を撃たない (finish-install の sync を壊す)。
- install 所要は 10〜25min (cross-site link 速度依存)。nginx access.log は当てにしない。

### Step 4: disk boot
```
./oplog.sh ./scripts/bmc-power.sh boot-override 10.254.254.9 claude Claude123 Hdd UEFI
./oplog.sh ./scripts/bmc-power.sh on 10.254.254.9 claude Claude123
```

### Step 5: eno2 dark-net IP 特定 (毎回変動、ping-sweep で neigh 充填してから grep)
`tmp/<sid>/find-ip.sh` を Write (パイプ/`$()` 分割禁止のためスクリプト化):
```sh
#!/bin/sh
j=1; while [ "$j" -lt 255 ]; do ping -c1 -W1 "10.254.254.${j}" >/dev/null 2>&1 & j=$((j+1)); done; wait
ip neigh | grep -i '4c:52:62:14:de:f0' | awk '{print $1}' | grep -E '^10\.254\.254\.' | head -1
```
disk boot 後 eno2 DHCP は +2〜4min で取得。出なければ 1〜2分待って再実行。

### Step 6: PVE 通しセットアップ (1 コマンド)
```
./oplog.sh ./scripts/tx1320-pve-setup.sh config/training_tx1320.yml <ip>
```
SSH待ち → live hostname (`tx1320`) を /etc/hosts 採用 → pre-reboot(PVE repo+kernel) → reboot →
post-reboot(proxmox-ve) → reboot → 検証。eno2 lease が reboot で変わっても `discover_by_mac` で追従。
- ⚠️ **出力は巨大化しうる** (`W: Tried to start delayed item` が百万行、無害)。全 Read 禁止、grep/tail で
  `DONE. Final reachable IP` 行と検証ブロックだけ確認。known_hosts は `UserKnownHostsFile=/dev/null` で対処済。
- 所要 ~15-55min (pve-firmware 231MB + PVE kernel 131MB の取得が支配的、cross-site link 速度で変動)。

## 検証 (すべて満たして成功)
dark-net IP は使い回され known_hosts に stale key が残るため、検証 ssh も
`-o UserKnownHostsFile=/dev/null` を付ける (`StrictHostKeyChecking=no` だけでは鍵 MISMATCH を拒否)。
```
ssh -F ssh/config -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@<ip> pveversion   # PVE 9.x
ssh -F ssh/config -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@<ip> systemctl is-active pveproxy pvedaemon pve-cluster  # 全 active
curl -sk --max-time 15 https://<ip>:8006 -o /dev/null -w '%{http_code}\n'         # 200
```
- RAID10 直読: `tx1320-pve-setup.sh` の検証ステップが storcli64 を playground から自動取得し
  `/c0/vall show` を出力 → `RAID10 ... Optl ... 1.6xx TB` を確認。傍証: `lsblk` で sda 1.6T 単一 + LVM。

## 実行上の制約 (重要)
- `sol-monitor.py` は foreground (ブロッキング) で実行し、完遂 (rc=0/POWER_DOWN) まで待ち切る。harness が
  自動 background 化した場合は出力を Read でポーリング。
- 状態変更操作は `./oplog.sh` 経由。スクリプトは必ず `./` 付き相対パス。一時ファイルは `tmp/<sid>/` のみ。
- パイプ/`$()`/`;`/`<` を含むコマンドはスクリプトファイルに書いて `sh tmp/<sid>/x.sh`。

## 関連
- skill: `pxe-deploy` (Step 2-6 の sonnet 自律 runbook)、`irmc-bios-raid` (Step 1 検証付き Clear)
- scripts: `irmc-ipxe-cd-deploy.sh` / `sol-monitor.py` / `bmc-power.sh` / `tx1320-pve-setup.sh` /
  `irmc-kvm/server.py` / `irmc-kvm-recover.sh`
- 完了時に `report/` へレポート作成 (REPORT.md フォーマット)
