# TX1320 PVE ブリッジ構成 (vmbr0=LAN / vmbr1=闇ネット固定) + RAID初期化からのフルセットアップ

- **実施日時**: 2026年6月19日 04:05〜04:57 (JST)
- **対象**: training-tx1320 (Fujitsu PRIMERGY TX1320 M3 / iRMC S4 FW 9.69F)
- **担当セッション**: 3af72c92 (opus)

## 添付ファイル

- [実装プラン](attachment/2026-06-19_045707_tx1320_pve_bridge_vmbr0_lan_vmbr1_darknet/plan.md)

## 前提・目的

- **背景**: training-tx1320 に PVE をセットアップしたが、Linux ブリッジ (vmbr0/vmbr1) が
  一切作られていなかった。従来の `generate-preseed.sh` dhcp ブランチは
  `/etc/network/interfaces` にフラットな物理 NIC 2 本 (eno1/eno2 とも DHCP) を書くだけで、
  PVE が前提とするブリッジ抽象を作らなかった。
- **目的**: セットアップスキル (preseed 生成) を修正し、PVE ブリッジ構成を出力させた上で、
  **RAID 初期化 → Debian install → PVE** までフルでやり直す。
  - **vmbr0 = LAN (192.168.33.0/24)** … eno1 をブリッジ、**DHCP**
  - **vmbr1 = 闇ネット (10.0.0.0/8)** … eno2 をブリッジ、**静的 `10.1.4.16/8`** (ユーザ指定)

## 環境情報

| 項目 | 値 |
|------|-----|
| 機種 | Fujitsu PRIMERGY TX1320 M3 (MainBoard D3373) |
| BMC | iRMC S4 FW 9.69F / `10.254.254.9` / claude / Claude123 |
| RAID | PRAID EP400i (AVAGO MegaRAID, HII Utility 03.25.05.10) / RAID10 / SAS HDD 900GB×4 → 1.635 TB |
| OS | Debian 13 (trixie) + Proxmox VE 9.2.3 / kernel 7.0.6-2-pve |
| ディスク | /dev/sda (RAID10 VD) → sda1 EFI / sda2 boot / sda3 LVM (root 1.6T + swap) |
| NIC | eno1 (Intel I210, MAC 4c:52:62:14:a5:5c) / eno2 (MAC 4c:52:62:14:de:f0) |
| ネットワーク | eno1=site LAN 192.168.33.0/24 (OpenWrt NAT 背後、internet 可) / eno2=dark-net 10.0.0.0/8 |
| playground | `10.1.6.6` (NFS/HTTP 配信。ens19=10.1.6.1/8 で dark-net L2 共有) |
| deploy ISO | `ipxe-tx1320.iso` (iRMC Virtual Media NFS) |

参照: 標準経路は [pxe-deploy / irmc-bios-raid スキル] および
[TX1320 RAID→Debian→PVE 通しセットアップレポート (2026-06-13)](2026-06-13_074047_tx1320_raid_clear_pve_e2e.md)。

## 結果サマリ (全項目 PASS)

最終稼働 PVE (`10.1.4.16`) で検証:

```
pve-manager/9.2.3/d0fde103346cf89a (running kernel: 7.0.6-2-pve)
pveproxy / pvedaemon / pve-cluster : すべて active
vmbr0  UP  192.168.33.11/24   (bridge member: eno1)   ← LAN, DHCP
vmbr1  UP  10.1.4.16/8        (bridge member: eno2)   ← 闇ネット, static
default via 192.168.33.1 dev vmbr0                     ← internet 経路
storcli /c0/vall: 0/0 RAID10 Optl 1.635 TB
PVE web UI https://10.1.4.16:8006 → HTTP 200
```

- `vmbr0` の MAC は eno1 (a5:5c)、`vmbr1` の MAC は eno2 (de:f0) を継承。
- vmbr1 は静的 `10.1.4.16` で reboot を跨いでも不変 (従来の eno2 DHCP lease 変動 #12 を解消)。
  vmbr0 の DHCP は reboot で変動 (初回 .174 → 最終 .11、想定どおり)。

## 実装 (セットアップスキル修正)

### `config/training_tx1320.yml`
```yaml
bridge_setup: true                        # dhcp ブランチをブリッジ出力に切替
secondary_bridge_address: "10.1.4.16/8"   # vmbr1 (eno2 / dark-net) static
```

### `scripts/generate-preseed.sh`
- `bridge_setup` / `secondary_bridge_address` を yq で読取り。
- `network_mode=dhcp` かつ `bridge_setup=true` のとき、late_command が以下を
  `/etc/network/interfaces` に書く分岐を追加:
  ```
  iface eno1 inet manual
  auto vmbr0
  iface vmbr0 inet dhcp
      bridge-ports eno1
      bridge-stp off
      bridge-fd 0
  iface eno2 inet manual
  auto vmbr1
  iface vmbr1 inet static
      address 10.1.4.16/8
      bridge-ports eno2
      bridge-stp off
      bridge-fd 0
  ```
- 同ブランチで `pkgsel_include` に **`bridge-utils`** を追加 (初回ブートで ifupdown が
  ブリッジを起動するため。PVE 導入後は ifupdown2 が同構文を管理)。
- `secondary_bridge_address` 空なら vmbr1 も DHCP にフォールバック (後方互換)。
- 陳腐化コメント (旧「pve-setup-remote が bridge に変換」) を実態に合わせ更新。

### `ssh/config`
- `Host training-tx1320 10.1.4.16` を追加 (固定管理 IP に id_ed25519 を提示)。
  ※ 旧 `Host 10.254.254.*` のみだと新 IP `10.1.4.16` で鍵が提示されず publickey 失敗するため必須。

### `.claude/skills/pxe-deploy/SKILL.md`
- 固定管理 IP `10.1.4.16` とブリッジ構成、IP 特定手順が不要になった旨を追記。

> `scripts/tx1320-pve-setup.sh` は無改変。固定 `10.1.4.16` を引数に渡すだけで全 phase が
> primary check で到達 (MAC 再 discovery はデッドパスとして無害残置)。

## 再現方法 (フルセットアップ手順)

```sh
# 0. preflight
ping -c3 10.254.254.9 ; ping -c3 10.1.6.6

# 1. preseed 再生成 + playground 配置 (コード変更を install に反映)
./scripts/generate-preseed.sh --pxe config/training_tx1320.yml tmp/<sid>/training-tx1320.cfg
scp -F ssh/config tmp/<sid>/training-tx1320.cfg ubuntu@10.1.6.6:/tmp/
ssh -F ssh/config ubuntu@10.1.6.6 sudo mv /tmp/training-tx1320.cfg /var/www/html/preseed/training-tx1320.cfg

# 2. BIOS HII KVM RAID Clear (irmc-bios-raid スキル)
./oplog.sh ./scripts/irmc-kvm-recover.sh config/training_tx1320.yml tmp/<sid>/recover-bios.jpg
.venv/bin/python scripts/irmc-kvm/server.py --bmc-ip 10.254.254.9 --bmc-user claude --bmc-pass Claude123 --srv-dir tmp/<sid>/srv
#   検証付き Clear: ArrowRight→shot(Advanced=17919) / navy 393→shot(AVAGO=18051) /
#   Enter×3→shot(Config Mgmt) / ArrowDown→shot(Clear row=10135) /
#   commit 1ファイル(dialog=11383→committed=9462→VDM=9758 "no Virtual Drives")

# 3. iPXE-CD deploy
./oplog.sh ./scripts/irmc-ipxe-cd-deploy.sh config/training_tx1320.yml ipxe-tx1320.iso

# 4. install 監視 (storcli が RAID10 作成)
.venv/bin/python scripts/sol-monitor.py --bmc-ip 10.254.254.9 --bmc-user claude --bmc-pass Claude123 \
    --log-file tmp/<sid>/install.log --timeout 2400 --powerstate-interval 30

# 5. ディスクブート (BMC env を export してから)
#   export BMC_SCHEME=https BMC_CURL_OPTS="--ciphers DEFAULT@SECLEVEL=0" POWER_ON_RESET_TYPE=On \
#       BMC_PATCH_REQUIRES_ETAG=1 BMC_BOOT_OVERRIDE_NO_DISABLED=1
./oplog.sh ./scripts/bmc-power.sh boot-override 10.254.254.9 claude Claude123 Hdd UEFI
./oplog.sh ./scripts/bmc-power.sh on 10.254.254.9 claude Claude123

# 5b. 到達性 sanity check (固定 IP が上がったか)
ping -c2 10.1.4.16
ssh -F ssh/config -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@10.1.4.16 \
    "cat /etc/network/interfaces; ip -br addr show vmbr0 vmbr1"

# 6. PVE 通しセットアップ (固定 IP を直接指定)
./oplog.sh ./scripts/tx1320-pve-setup.sh config/training_tx1320.yml 10.1.4.16
```

## 経過 (タイムライン、JST)

> 時刻は JST。バックグラウンドタスクのログ (`[04:xx]`) と `TZ=Asia/Tokyo date` (04:57) が
> 一次情報。BIOS RTC が 19:12 UTC (= 04:12 JST) を示していた点とも整合。

| 時刻 | 段階 | 結果 |
|------|------|------|
| ~04:05 | preseed 再生成 + playground 配置 | vmbr0/vmbr1 + bridge-utils を HTTP 配信で確認 |
| ~04:07-04:12 | iRMC 復旧 → BIOS Main 到達 | OEM VGA で Aptio Main 確認 (Administrator)。KVM server READY 04:13 |
| 04:14-04:18 | BIOS HII RAID Clear | Advanced→AVAGO(EP400i)→Config Mgmt→Clear→commit。VDM "no Virtual Drives" (size 9758) |
| ~04:18-04:20 | iPXE-CD deploy | CDImage NFS(200)/ConnectCD(204)/boot-override Cd→PowerOn |
| 04:20-04:33 | install 監視 | DETECTING_NETWORK(2.4m, **#15 発生せず**)→APT→SOFTWARE→GRUB→POWER_DOWN(11.4m)→complete(04:32:54)、rc=0 |
| ~04:33-04:34 | ディスクブート + sanity | 10.1.4.16 到達。`/etc/network/interfaces` に vmbr0/vmbr1、ip -br addr で 192.168.33.174 + 10.1.4.16 |
| ~04:35-04:56 | PVE 通しセットアップ | pre-reboot(kernel)→reboot→post-reboot(proxmox-ve 9.2.0)→reboot→検証、rc=0 |
| ~04:57 | 最終検証 | pveversion 9.2.3 / services active / bridges OK / 8006=200 / RAID10 Optl |

## 落とし穴・知見

- **ssh/config に新固定 IP のエントリが必須**: `tx1320-pve-setup.sh` は `ssh -F ssh/config`
  のみで `-i` を付けない。旧 `Host 10.254.254.*` は新 IP `10.1.4.16` にマッチせず、
  `Host *` (IdentityFile 無し) だけが効いて publickey 失敗する。`Host training-tx1320 10.1.4.16`
  追加で解決。
- **bridge-utils を pkgsel に入れれば初回ブートからブリッジが上がる** (Approach A を実証)。
  初回ディスクブート時点で素の Debian + ifupdown だが、vmbr0/vmbr1 とも正常起動し
  10.1.4.16 到達を確認 (R1 リスクは顕在化せず)。
- **post-reboot 直後の一瞬 vmbr0 が link-local (169.254.x) で apt が Ign** になるが、
  vmbr0 DHCP は数秒後に取得し apt は回復 (R2 は許容範囲)。internet 経路は vmbr0 経由で機能。
- **#15 (d-i netcfg stuck) は発生せず** (embed iPXE の `interface=eno1` 固定が有効)。
- BIOS HII RAID Clear は「検証付き Clear」(タブ切替を shot で確認 + navy で AVAGO adaptive 着地 +
  指紋 size で各段階検証) で 1 発成功。スクリーンショット判読は general-purpose サブエージェントに委任。
- **`vmbr1` の MAC は eno2 (de:f0) を継承する**ので、仮に MAC ベースの IP 特定 (`ip neigh | grep 4c:52:62:14:de:f0`)
  を使っても box を引き当てられる (単一ポートブリッジは最小ポート MAC を継承)。本構成では固定 IP のため不要。
- **wait_ssh 中に旧 DHCP 経路の stale ARP (`disc=10.254.254.16`) が一瞬出現**したが、wait_ssh は
  「discover した IP に SSH 成功した時のみ切替」する設計のため無害に無視され、primary check (10.1.4.16) で収束。
- ⚠️ **潜在的制約**: `tx1320-pve-setup.sh` の `discover_by_mac` は `10.254.254.0/24` を ping-sweep する
  ハードコード。box が `10.1.4.x` に固定された今、このフォールバックは機能しない (primary 10.1.4.16 が
  常に成立するので実害なし)。万一 primary が落ちた場合の MAC 再 discovery は効かない点に留意 (将来、
  config の dark-net レンジを参照する一般化が望ましい)。

## 追加検証・補足知見 (完了後、稼働 PVE 10.1.4.16 で確認)

- **`ifupdown2 3.3.0-1+pmx12` が proxmox-ve により導入され `ifupdown` を置換**。`bridge-utils 1.7.1` も併存。
  → **同一の `/etc/network/interfaces` が、bridge-utils+ifupdown で起動した初回〜PVE kernel boot と、
  ifupdown2 で起動した最終 boot の両方で正常動作**したことを実証 (Approach A の互換性前提が成立)。
- **最終ルートテーブルはクリーン** (余計な経路なし):
  ```
  default via 192.168.33.1 dev vmbr0
  10.0.0.0/8 dev vmbr1 proto kernel scope link src 10.1.4.16
  192.168.33.0/24 dev vmbr0 proto kernel scope link src 192.168.33.11
  ```
  `169.254.x` (link-local) も `192.168.39.1` (別拠点 GW) も残存せず → **z-fix-default-route フックは
  余計な経路を残さなかった (R3 を実機で確認)**。dark-net 宛 (10.0.0.0/8) は vmbr1 の scope-link で直結、
  internet/apt は vmbr0 の default 経由。
- **PVE ノードのネットワーク認識**: `pvesh get /nodes/tx1320/network` に `vmbr0` / `vmbr1` / `eno1` / `eno2`
  が出現し、vmbr1 に `cidr: 10.1.4.16/8` を確認 (PVE が `/etc/network/interfaces` を正しく解釈)。
- **環境補足**: TotalSystemMemory 24 GiB、MainBoard D3373 (SN 57662941)、システム SN MABK035229、
  AVAGO MegaRAID HII Utility ver 03.25.05.10、storcli CLI 007.2705。

## 未コミットの変更 (ユーザ承認待ち)

以下はコミット未実施 (CLAUDE.md: コミット/push はユーザ承認後):
- `config/training_tx1320.yml` (bridge_setup / secondary_bridge_address 追加)
- `scripts/generate-preseed.sh` (dhcp+bridge ブランチ + bridge-utils + コメント更新)
- `ssh/config` (Host training-tx1320 10.1.4.16)
- `.claude/skills/pxe-deploy/SKILL.md` (固定 IP / ブリッジ注記)
