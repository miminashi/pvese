# 14号機 OS インストール再試行プラン

## Context

前回セッション (2026-05-11) で 14号機 (Dell PowerEdge R430 + iDRAC8 + PERC H730P Mini) の OS インストールが PERC RAID 構築失敗で未達 (issue #63)。15号機は同じ機種で成功済み。本プランは PERC RAID-1 を組み直して os-setup スキルで Debian + PVE をインストールし、issue #62 (R430 追加全体) と #63 (PERC 問題) を完了させる。

ユーザは「装着ディスクは全消去 OK」と明言済み。安全に全 clearconfig できる。

### 14号機の現状 (調査済)

| 項目 | 値 |
|---|---|
| iDRAC FW | 2.63.60.61 (Build 06, 2019-05-11) — 15号機 2.85 より古い |
| BIOS | 2.9.1 (UEFI、出荷時) — 変更不要 |
| PERC H730P FW | 25.5.5.0005 — 15号機 H730 25.5.9.0001 より古い |
| VD | 無し (前回の RAID-1 削除済み) |
| Bay 0 | ST300MP0026 (12.0Gb/s, Ready) |
| Bay 1 | ST9300653SS (6.0Gb/s, Ready) ← 仕様不一致 (BGI 26%停滞の主犯候補) |
| Bay 2,3,5,7 | Blocked (前回 createvd 失敗の残骸、520B Nutanix 系) |
| Bay 4, 6 | DKS5E K300SS (12.0Gb/s, Ready, 同一モデル) ← OS RAID-1 候補 |

### ユーザ確定方針

1. **OS RAID-1 = Bay 4+6** (同一モデル・両方 Ready)
2. **失敗時は段階エスカレーション** (Bay 0+1 → HBA mode → FW 更新)
3. **OS インストールは os-setup スキル Phase 1 から**

## Phase 0: RAID 事前整備

すべて `./pve-lock.sh wait ./oplog.sh ssh -F ssh/config idrac14 ...` で包む。

### 0.1 状態スナップショット (read-only)

`racadm raid get controllers/vdisks/pdisks -o` と `jobqueue view` を実行し tmp に保存。

### 0.2 過去 fail ジョブのクリーンアップ

`jobqueue view` 出力で `Failed`/`PR21` の `JID_xxxx` を抽出して個別 delete。最後に `jobqueue delete --all` で pending を空に。Pending が残ると createvd が PR21 で再失敗する。

### 0.3 全 RAID 構成消去

```sh
./pve-lock.sh wait ./oplog.sh ssh -F ssh/config idrac14 racadm raid clearconfig:RAID.Integrated.1-1
./pve-lock.sh wait ./oplog.sh ssh -F ssh/config idrac14 racadm jobqueue create RAID.Integrated.1-1 -s TIME_NOW -r pwrcycle
```

iDRAC8 では `clearforeignconfig` 不在 → `clearconfig` 一発で foreign + local + pending 全消去。Bay 2/3/5/7 の Blocked も解除されるはず。

待機: `jobqueue view` を 30 秒間隔でポーリングし `Completed (100)` で次へ (5-10 分目安)。

### 0.4 Blocked 解除確認

`racadm raid get pdisks -o -p State` で Bay 4 / Bay 6 が `State=Ready` を確認。

## Phase 1: Bay 4+6 で RAID-1 作成

### 1.1 createvd

```sh
./pve-lock.sh wait ./oplog.sh ssh -F ssh/config idrac14 racadm raid createvd:RAID.Integrated.1-1 -rl r1 \
  -pdkey:Disk.Bay.4:Enclosure.Internal.0-1:RAID.Integrated.1-1,Disk.Bay.6:Enclosure.Internal.0-1:RAID.Integrated.1-1 \
  -name OS_RAID1
./pve-lock.sh wait ./oplog.sh ssh -F ssh/config idrac14 racadm jobqueue create RAID.Integrated.1-1 -s TIME_NOW -r pwrcycle
```

### 1.2 ジョブ完了待機 (30秒間隔, 10分まで)

`jobqueue view` ポーリング。`Completed (100)` で次へ。`Failed`/`PR21` → Phase 4.1 へ。

### 1.3 BGI 監視

- `State=Online`, `OperationalState=Background Initialization` で BGI % を 60 秒間隔で観測。
- **失敗判定**: 連続 3 回 (3 分) 同じ %、または **26% 付近で停滞** (前回症状)、または 30 分で 5% 未満。
- **進捗あり** (1 分あたり 0.1% 以上) なら **5 分観測後に Phase 2 開始** (BGI はバックグラウンド継続)。

## Phase 2-8: os-setup スキル実行

`./scripts/os-setup-phase.sh init --config config/server14.yml` から開始。15号機と同じフロー。既存資産はすべて流用 (修正不要)。

| Phase | 内容 | 留意点 |
|---|---|---|
| 1 iso-download | `debian-13.3.0-amd64-netinst.iso` 共有 | 既存ならスキップ |
| 2 preseed-generate | iDRAC 系は手動管理 preseed → 即マーク | preseed-server14.cfg 確認のみ |
| 3 iso-remaster | `./scripts/remaster-debian-iso.sh ... --serial-unit=0` | Serial1Com2Serial2Com1 → ttyS0 |
| 4 bmc-mount-boot | `idrac-virtualmedia.sh mount` → `boot-once VCD-DVD` → `bmc-power.sh cycle` | `BIOS.SerialCommSettings.SerialComm` を事前確認 |
| 5 install-monitor | `sol-monitor.py` で SOL 監視 (PowerState=Off で完了) | exit 4 → bmc-mount-boot から再試行 |
| 6 post-install-config | SSH 鍵 + sshd_config + 静的 IP + **clock 修正** | iDRAC RTC 2001 年 → `date -s` + `hwclock --systohc` 必須 |
| 7 pve-install | `pre-pve-setup.sh --dhcp-iface eno1 --static-gw 10.10.10.1 --codename trixie` → `pve-setup-remote.sh` | reboot 後ルートを `192.168.39.1` 経由に |
| 8 cleanup | umount + boot-reset + `pve-bridge-setup.sh --static-iface eno2 --static-ip 10.10.10.214/8 --dhcp-iface eno1` | IB 設定はスキップ (LINSTOR は別 issue) |

### 古い iDRAC FW (2.63) の留意点

- racadm 主要コマンド (raid, jobqueue, remoteimage, set BIOS.*) は 2.63 でも同じ構文。
- `BIOS.BiosBootSettings.BootMode` は `Uefi` のまま。**触らない**。
- `remoteimage` SMB マウントが不安定なら umount → 5秒 → 再 mount を最大 3 回試行。
- VNC が必要なら `iDRAC.VNCServer.Enable` 確認 + パスワード `Claude1`。

## Phase 3: 失敗時エスカレーション

### 3.1 Bay 4+6 失敗判定基準
- jobqueue が `Failed`/`PR21` を返す
- BGI が同一 % で 3 分以上停滞 / 26% 付近で停滞 / 30 分で 5% 未満

### 3.2 Bay 0+1 fallback
Phase 0.3 と同じ clearconfig → `pdkey` を Bay.0/Bay.1 に変えて createvd → 同じ判定。

### 3.3 HBA mode 切替
`racadm storage controllers -action=changecontrollermode -mode=HBA` + jobqueue pwrcycle。HBA mode 採用時は新規 preseed `preseed/preseed-server14-hba.cfg` を作成 (mdadm RAID-1)。

### 3.4 FW アップグレード (最終手段)
`dell-fw-download` スキルで PERC H730P FW 25.5.9 取得 → `tftp-server` で配信 → `racadm fwupdate -g -u -a 10.1.6.1`。

## Phase 4: 操作ログ・ロック方針

すべて `./pve-lock.sh wait ./oplog.sh <cmd>` で包む:
- `racadm raid clearconfig`/`createvd`/`deletevd`
- `racadm jobqueue create -r pwrcycle`
- `racadm storage controllers -action=changecontrollermode`
- `racadm fwupdate`
- `racadm remoteimage -c`/`-d`
- `ssh root@10.10.10.214 reboot` / `pve-setup-remote.sh` / `pve-bridge-setup.sh`

read-only の `racadm getsysinfo`/`raid get vdisks`/`jobqueue view`/SSH 接続後の確認系はロック不要。

## Phase 5: issue / レポート更新

- 開始時: `./issue.sh start 63 --owner <session名>`
- Bay 4+6 成功 → `./issue.sh verify 63` → レポート → `./issue.sh done 63 --report report/<filename>.md`
- 同時に **#62 (R430 追加全体)** も `./issue.sh done 62 --report <同レポート>`

## Critical Files

- `config/server14.yml` (修正不要、参照)
- `preseed/preseed-server14.cfg` (修正不要、参照。HBA mode 採用時のみ派生作成)
- `scripts/os-setup-phase.sh` (Phase 管理、参照)
- `scripts/idrac-virtualmedia.sh` (mount/boot-once、参照)
- `scripts/remaster-debian-iso.sh` (ISO 作成、参照)
- `.claude/skills/os-setup/SKILL.md` (8 フェーズフロー、参照)
- `.claude/skills/idrac7/SKILL.md` (iDRAC8 でも流用可、参照)
- `report/2026-05-11_052054_server14-15_r430_setup.md` (前回レポート、比較基準)

## 検証 (エンドツーエンド)

| Phase | コマンド | 期待 |
|---|---|---|
| 0 | `racadm jobqueue view` + `raid get vdisks` + `raid get pdisks -o -p State` | jobqueue 空、旧 VD 全消失、Bay 4/6 = Ready |
| 1 | `racadm raid get vdisks -o` | `Disk.Virtual.0` State=Online、BGI 進捗継続 |
| 2-8 | `os-setup-phase.sh status --config config/server14.yml` | 全項目 done |

最終確認:
- `pveversion` → `pve-manager/9.x.x`, kernel 6.x or 7.x-pve
- vmbr0: 10.10.10.214/8, vmbr1: 192.168.39.xxx/24 (DHCP)
- default route via 192.168.39.1
- Web UI: 200 OK の HTML
