# TX1320 RAID 初期化 → Debian → PVE 通しセットアップ

## Context

ユーザ依頼: 「tx1320 の RAID を初期化のうえで、PVE までセットアップしてください」。

training-tx1320 (Fujitsu PRIMERGY TX1320 M3 / iRMC S4 FW 9.69F / 10.254.254.9) は別拠点設置の一時マシン。
この依頼は **確立済みの標準経路** で実行できる定型作業:
- 直近 2026-06-10 に同一依頼を opus が完遂 (`report/2026-06-10_212639_tx1320_raid_clear_pve_e2e.md`)
- それ以前に 3/3 (2026-06-03) + sonnet 自律 10/10 (2026-06-04) で実証済み
- iPXE-CD 経路が iRMC USB redirector の累積劣化を回避する標準手段

ゴール: Debian 13 + HW RAID10 (1.635 TB) + PVE 9.x (web UI HTTP 200) を物理操作なしで構築。

## 方式

- **RAID 初期化**: BIOS HII KVM で明示的に RAID Clear (標準経路)。その後 install 中の preseed `partman/early_command` の storcli が RAID10 を delete+create するため、最終 RAID10 は install が作成する。
- **OS deploy**: iPXE-on-CD を iRMC Virtual Media (NFS) 経由で起動 (`irmc-ipxe-cd-deploy.sh`)。GRUB 2.12 が 6.12 kernel を当 firmware で起動できない (EFI_LOAD_ERROR) のを iPXE loader で回避。
- **ネットワーク**: eno1 = 192.168.33.x (拠点 NAT 背後で不達) / eno2 = dark-net 10.254.254.0/8 (claude 到達可、MAC `4c:52:62:14:de:f0`)。lease は reboot で変動するため MAC 再 discovery で追従。

## 前提・環境変数

セッション tmp: `mkdir -p tmp/<sid>` (UUID 先頭8文字、Glob で取得)。

iRMC 操作の env。`bmc-power.sh` を直接呼ぶ (Step 0 status / Step 4 boot-override+on) 際は、未 export だと `BMC_CURL_OPTS` の cipher が効かず TLS rc=52 で失敗する (PXE 10run #10 の真因として判明済み)。
```
BMC_SCHEME=https
BMC_CURL_OPTS="--ciphers DEFAULT@SECLEVEL=0"
POWER_ON_RESET_TYPE=On
BMC_PATCH_REQUIRES_ETAG=1
BMC_BOOT_OVERRIDE_NO_DISABLED=1
```
> 🚨 **Bash 呼び出し間で env は persist しない** (各 Bash 呼び出しは新シェル)。よって「Step 0 で一度 export」では Step 4 に効かない。`bmc-power.sh` の直接呼び出しは **毎回、上記 export を含むラッパースクリプト `tmp/<sid>/bmc.sh` 経由で実行する** (`sh tmp/<sid>/bmc.sh <args>` 形式)。`irmc-ipxe-cd-deploy.sh` と `tx1320-pve-setup.sh` は内部で export するためラッパー不要。

## 手順

### Step 0: 事前確認
- `mkdir -p tmp/<sid>` (Glob で session UUID 取得)
- env を含む `tmp/<sid>/bmc.sh` ラッパーを作成 (上記 5 変数 export + `exec ./scripts/bmc-power.sh "$@"`)。bmc-power.sh 直接呼び出しはすべてこれ経由。
- `ping -c 5 10.254.254.9` で iRMC 到達性 (latency 60-340ms 想定、loss 高ければ待つ)
- `sh tmp/<sid>/bmc.sh status 10.254.254.9 claude Claude123` で現電源状態
- NFS 共有上に `ipxe-tx1320.iso` が存在するか確認 (10.1.6.6:/var/samba/public)。
  - **存在する場合** (6/10 run が再利用したため可能性大): そのまま Step 1 へ。
  - **不在の場合**: ISO 再生成が必要。`build-ipxe-iso.sh` は embed 済み `ipxe.efi` を前提とするため、まず `pxe-deploy` スキルの手順で `EMBED=<host>-embed.ipxe` 付き ipxe.efi をビルド → `scripts/build-ipxe-iso.sh <ipxe.efi> ipxe-tx1320.iso` → playground (10.1.6.6:/var/samba/public) へ配置。この分岐に入る場合は所要時間が増えるためユーザに一報する。

### Step 1: BIOS HII KVM で RAID Clear (`irmc-bios-raid` スキル)
1. `./scripts/irmc-kvm-recover.sh config/training_tx1320.yml tmp/<sid>/recover-bios.jpg`
   (host ForceOff → Manager.Reset → boot-override BiosSetup + on → POST 待ち。健全 KVM 状態へ復旧)
2. 永続 KVM サーバ起動 (background): `.venv/bin/python scripts/irmc-kvm/server.py --bmc-ip 10.254.254.9 --bmc-user claude --bmc-pass Claude123 --srv-dir tmp/<sid>/srv` → `=== KVM server READY ===` を待つ
3. `tmp/<sid>/srv/in/NNN.cmd` を per-key 投入、各 `shot` をサブエージェントで画像分析:
   - `press ArrowRight 2000` + `shot tab.png` → Advanced タブ着地確認 (指紋 size≈17919, caret_y≈102)
   - `navy 393 caret 25 1500` + `shot avago_row.png` → AVAGO 行 adaptive 着地 (size≈18051)
   - `Enter` ×3 → AVAGO dashboard → Main Menu → Config Mgmt (VD 有り = 2項目)
   - `ArrowDown 1` → Clear Configuration 行確認 (size≈10135)
   - modal commit 1ファイル集約: `press Enter 3000` (dialog size≈11383) → `mouse 80 240` (focus、中央 512,384 ではない) → `ArrowDown→Enter` ×3 (No→Confirm→Enabled→Yes) → commit → committed.png (size≈9462)
   - `Enter` (►OK) → `Escape` (Main Menu) → `keyrepeat ArrowDown 2 1600` (VDM 行) → `Enter` → `shot vdm.png` → **size≈9758 = "no Virtual Drives currently available" = Clear 成功**
   - `quit`
   - 落とし穴: ArrowRight ドロップ (高 latency) は shot 検証→retry。keyrepeat は ≥1600ms。F1 は使わない。

### Step 2: iPXE-CD deploy
```
./oplog.sh ./scripts/irmc-ipxe-cd-deploy.sh config/training_tx1320.yml ipxe-tx1320.iso
```
DisconnectCD(400 無害) → CDImage NFS(200) → VirtualMediaServiceRestart(204) → On → ConnectCD(204、HTTP500 は自動 retry) → ForceOff → boot-override Cd UEFI → On。

### Step 3: install 監視 (foreground 必須、background 禁止)
```
.venv/bin/python scripts/sol-monitor.py --bmc-ip 10.254.254.9 --bmc-user claude --bmc-pass Claude123 \
    --log-file tmp/<sid>/install.log --timeout 2400 --powerstate-interval 30
```
stage: DETECTING_NETWORK → CONFIGURING_APT → INSTALLING_SOFTWARE → INSTALLING_GRUB → POWER_DOWN → Off (rc=0)。
- #15 (netcfg stuck): DETECTING_NETWORK が deploy から ~10min 停滞したら `sh tmp/<sid>/bmc.sh forceoff 10.254.254.9 claude Claude123` → Step 2 retry (2回目で +3-4min 解消)。

### Step 4: disk boot + eno2 IP 特定
env が必要なため bmc.sh ラッパー経由 (oplog でラップ):
```
./oplog.sh sh tmp/<sid>/bmc.sh boot-override 10.254.254.9 claude Claude123 Hdd UEFI
./oplog.sh sh tmp/<sid>/bmc.sh on 10.254.254.9 claude Claude123
```
`tmp/<sid>/find-ip.sh` (ping-sweep で neigh 充填 → `ip neigh | grep 4c:52:62:14:de:f0` で 10.254.254.X 抽出)。

### Step 5: PVE 通しセットアップ
```
./oplog.sh ./scripts/tx1320-pve-setup.sh config/training_tx1320.yml <ip>
```
pre-reboot (PVE repo + kernel) → reboot → post-reboot (proxmox-ve) → reboot → 検証。
wait_ssh が eno2 lease 変動 (例 .5→.16) を MAC 再 discovery で追従。live hostname (`tx1320`) を採用。
※ PVE apt の `W: Tried to start delayed item` 大量警告は無害。出力は grep/tail のみ (全 Read しない)。

### Step 6: 独立検証
- `ssh -F ssh/config -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@<ip> "pveversion; systemctl is-active pveproxy pvedaemon pve-cluster"` → PVE 9.x / active
- `curl -sk --max-time 15 https://<ip>:8006 -o /dev/null -w '%{http_code}'` → 200
- storcli 直読で RAID10 Optl 1.6xx TB 確認

### Step 7: レポート作成
完了後 `report/` に REPORT.md フォーマットでレポート作成 (BIOS Clear 指紋値、install 所要時間、最終 IP、PVE version)。

## 主要ファイル (すべて既存、変更なし)

- `config/training_tx1320.yml` — 設定 (bmc/nfs/eno2_mac/disk)
- `scripts/irmc-kvm-recover.sh` / `scripts/irmc-kvm/server.py` — BIOS HII KVM
- `scripts/irmc-ipxe-cd-deploy.sh` — iPXE-CD deploy
- `scripts/sol-monitor.py` — install 監視
- `scripts/bmc-power.sh` — 電源/boot-override
- `scripts/tx1320-pve-setup.sh` — PVE 通し
- `scripts/build-ipxe-iso.sh` — ISO 不在時のみ

これは新規実装ではなく既存ツールの実行作業。コード変更は想定しない (ISO build が必要な場合を除く)。

## 検証 (end-to-end)

最終的に以下がすべて成立すれば成功:
1. storcli `/c0/vall show` → `RAID10 Optl ... 1.6xx TB`
2. `pveversion` → `pve-manager/9.x`
3. pveproxy / pvedaemon / pve-cluster すべて active
4. `https://<eno2-ip>:8006` → HTTP 200
5. 物理操作なしで `ssh root@<eno2-ip>` 到達

## 所要時間見込み

~56min (BIOS 復旧 5 + RAID Clear 6 + deploy 1 + install 14 + IP 特定 5 + PVE 30)。
