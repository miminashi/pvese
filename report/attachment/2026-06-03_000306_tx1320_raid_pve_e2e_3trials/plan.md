# TX1320 RAID初期化〜PVE 通しセットアップ 3試行検証 + 標準経路化

## Context

training-tx1320 (Fujitsu PRIMERGY TX1320 M3 / iRMC S4 FW 9.69F, 別拠点) で
**「RAID初期化 → Debian install → PVE セットアップ」が通しで動くこと**を確認する。
3試行して再現性を見て、試行ごとの知見を skill/doc/memory に反映し、最後に一括コミット
(push はユーザ確認)。**通れば iPXE-CD を TX1320 の標準 OS install 経路に昇格させる**。

### 現状とギャップ(探索で確定)
- **既存パイプライン (`tx1320-raid10-orchestrate.sh`) は Debian + RAID10(storcli) まで**しか自動化していない。
  さらに `deploy` は **full-ISO VirtualMedia 経路**(GRUB 2.12→6.12 kernel が当 firmware で `EFI_LOAD_ERROR`
  → triple-fault、dead end とされた古い系統)を使っている。
- **PVE インストールは未組込の手動 Phase 7**: `scripts/pve-setup-remote.sh --phase pre-reboot` →
  reboot → `--phase post-reboot` → reboot → verify。os-setup skill にだけ手順がある。
- **直近 10/10 検証済みの堅牢経路は iPXE-CD** (`scripts/build-ipxe-iso.sh` + `scripts/irmc-ipxe-cd-deploy.sh`)。
  iPXE 独自ローダで firmware StartImage を回避。これを通しテストの本筋にする。

### ユーザ決定事項
1. **install 経路 = iPXE-CD**。通れば標準経路に昇格。
2. **RAID初期化 = 繰り返しテストなので試行ごとに BIOS HII KVM Clear**(irmc-bios-raid skill)。
   理由: storcli の clear+create は install が boot しないと走らないため、BIOS レベルで確実に初期化する。
   Clear 後、install 中に storcli が RAID10 を再作成する。
3. **PVE = ラッパースクリプト新規作成で1コマンド化** (`scripts/tx1320-pve-setup.sh`)。
4. **反映 = 毎試行 skill/doc/memory 編集、3試行後に一括コミット**(push 確認)。

### 既知リスク(トライアル1で顕在化見込み)
- `pve-setup-remote.sh` の `z-fix-default-route` フック(L110-125)は **本拠点ゲートウェイ
  `10.10.10.1`/`192.168.39.1` をハードコード**。training-tx1320 の拠点は `192.168.33.1`(eno1 経由
  でインターネット)/`10.254.254.0/24`(eno2 dark-net、GW なし)。フックが誤ルートを足すと
  PVE install の apt がインターネットに出られず失敗する恐れ。→ ラッパー側で拠点別 GW を扱うか
  フックをサイト非依存化する(トライアル1の知見として確定・反映)。
- 拠点間リンクは過去に latency 558ms+間欠 100% loss を観測。deploy 前に ping 確認必須。

---

## 事前準備(最初に1回)

- `issue.sh list` で関連 issue 確認、本作業の issue を `start`(なければ作成)。
- セッション tmp: Glob で transcripts の UUID 取得 → `mkdir -p tmp/<sid>`。
- 前提疎通(read-only): `ping 10.254.254.9`(iRMC)、`ping 10.1.6.6`(playground)、
  iRMC 電源/認証 (`./scripts/bmc-power.sh status ...`)。
- playground 資産確認: `ssh -F ssh/config ubuntu@10.1.6.6 ls -l /var/samba/public/`
  で `ipxe-training-tx1320.iso` / `storcli64.bin` の有無、nginx の docroot 配下に
  preseed があるか、nginx access.log 監視可否。
- **preseed の中身確認(重要)**: playground が配信する preseed に **storcli の
  `partman/early_command`(`/c0/vall delete force` → RAID10 作成)が含まれること**を
  `grep` で確認。これが無いと BIOS HII Clear 後にディスク不在で partman が失敗する。
- **ipxe.efi の確認**: 既存 `ipxe-training-tx1320.iso` は 10/10 検証で `interface=eno1`
  込みの ipxe.efi を焼いた版のはず。中身が `interface=eno1` 入りか不明なら、playground 側で
  ipxe.efi を `make ... EMBED=<embed>.ipxe`(interface=eno1 入り)で**コンパイルし直してから**
  `./scripts/build-ipxe-iso.sh <ipxe.efi> <out.iso>` で ISO 化 → playground の export へ配置。
  (`build-ipxe-iso.sh` は ipxe.efi を ISO に焼くだけで、コンパイルはしない点に注意。)
- BMC 操作の env(`irmc-ipxe-cd-deploy.sh` が内部で export 済みだが、手動 bmc-power.sh 用に):
  `BMC_SCHEME=https`, `BMC_CURL_OPTS="--ciphers DEFAULT@SECLEVEL=0"`, `POWER_ON_RESET_TYPE=On`,
  `BMC_PATCH_REQUIRES_ETAG=1`, `BMC_BOOT_OVERRIDE_NO_DISABLED=1`。

---

## 新規スクリプト: `scripts/tx1320-pve-setup.sh`

Debian install 完了・SSH 到達後の **Phase 7 を 1 コマンド化**するラッパー。`#!/bin/sh` + `set -eu`、
スネークケース、`./scripts/tx1320-pve-setup.sh` で実行。既存資産を再利用:
`scripts/pve-setup-remote.sh`(pre/post-reboot 本体)、`scripts/ssh-wait.sh`(reboot 後の再到達待ち)、
`bin/yq`、`ssh/config`。

```
Usage: tx1320-pve-setup.sh <config.yml> <target_ip>
```

処理(config から hostname/serial_unit/in_linstor を読む。codename は trixie 固定でよいが
`ssh root@<ip> . /etc/os-release; echo $VERSION_CODENAME` で動的取得が堅牢):
1. `ssh-wait.sh <ip>` で到達確認。
2. `scp -F ssh/config scripts/pve-setup-remote.sh root@<ip>:/tmp/`
3. `ssh root@<ip> /tmp/pve-setup-remote.sh --phase pre-reboot --hostname <h> --ip <ip> --codename <cn> --serial-unit <su>`
4. `ssh root@<ip> reboot || true` → `ssh-wait.sh <ip> --timeout 300`
5. **(拠点別ルート対策)** apt 用デフォルトルートが eno1(192.168.33.1)経由で生きているか
   `ssh root@<ip> ip route show default` で確認。無ければ補正(トライアル1の知見次第で確定)。
6. `scp` + `ssh root@<ip> /tmp/pve-setup-remote.sh --phase post-reboot ...`
   (`in_linstor: false` なので `--linstor` は付けない)
7. `ssh root@<ip> reboot || true` → `ssh-wait.sh <ip> --timeout 300`
8. **verify**: `ssh root@<ip> pveversion`、`ssh root@<ip> systemctl is-active pveproxy pvedaemon`、
   `curl -sk https://<ip>:8006`(HTML 応答)。

> **reboot 間の IP 変動対策**: eno2 は DHCP で、reboot をまたいで lease が変わり得る
> (memory #12)。同一 MAC なら維持されることが多いが、ssh-wait が旧 IP で失敗したら
> `ip neigh | grep 4c:52:62:14:de:f0` で再 discovery して以降の IP を差し替える
> (ラッパーに再探索フォールバックを入れる)。

> ラッパーは `z-fix-default-route` の拠点問題を吸収するのが望ましい。最小対応として
> training-tx1320 の正しい GW(192.168.33.1)をフックに渡せるよう `pve-setup-remote.sh` を
> 一般化(`--internet-gw`/`--mgmt-gw` 引数追加)するか、ラッパー側で install 後にフックを上書きする。
> 方針はトライアル1の実挙動を見て確定し reflect する。

---

## 1 試行のフロー(3 回繰り返す)

各 state 変更は `./oplog.sh` 経由で記録(training-tx1320 は非クラスタ・別拠点のため
本拠点 `pve-lock.sh` は不要)。

1. **RAID初期化 (BIOS HII KVM Clear)** — irmc-bios-raid skill の手順:
   `scripts/irmc-kvm/server.py` 永続セッション起動 → boot-override BiosSetup → Clear Configuration
   コマンドファイル(単一ファイルに集約、`keyrepeat ... 1600ms`、`mouse 80 240` でダイアログ focus)
   → Virtual Drive Management で「no Virtual Drives」確認。完了後 KVM quit。
2. **deploy (iPXE-CD)**: `./scripts/irmc-ipxe-cd-deploy.sh config/training_tx1320.yml`
   (DisconnectCD→config NFS→VirtualMediaServiceRestart→On→ConnectCD→ForceOff→boot-override Cd UEFI→On)。
3. **monitor**: `.venv/bin/python scripts/sol-monitor.py --bmc-ip ... --timeout 1800` を background。
   **真の進捗 = playground nginx access.log** の preseed/storcli/phonehome GET。
   install 中に storcli が `/c0/vall delete force` → RAID10 作成。
4. **install 完遂判定**: phonehome GET(nginx)+ auto-poweroff(PowerState=Off)。
   SOL の rc=0 だけで完遂判定しない(手動 ForceOff 後の誤完了既知)。
5. **disk boot**: `./scripts/bmc-power.sh boot-override <ip> <u> <p> Hdd UEFI` → `... on`。
6. **IP discovery**: eno2 dark-net 10.254.254.x。
   `ip neigh | grep 4c:52:62:14:de:f0`(MAC 既知)or phonehome の nginx ログから。
7. **PVE setup**: `./scripts/tx1320-pve-setup.sh config/training_tx1320.yml <ip>`。
8. **検証(その試行の合否)**:
   - RAID: `ssh root@<ip> /usr/local/bin/storcli64 /c0/vall show`(or storcli64) → RAID-10 / Optl / ~1.635TB
   - PVE: `ssh root@<ip> pveversion` が `pve-manager/...` を返す、`curl -sk https://<ip>:8006` が HTML
   - lsblk で RAID10 VD(/dev/sda 系)に LVM/PVE。

### 既知の失敗モードと対処(memory より)
- **#15 d-i netcfg stuck**: iPXE `interface=eno1` で解消済み。再発時は ForceOff→retry。
- **#14 eno2 DHCP 遅延**: 稀に 15min。preseed `auto eno2` 済み。到達待ちは余裕を持つ。
- **#10 boot-override rc=52**: 真因は BMC_CURL_OPTS cipher 未 export。env 5 変数を先に export。
  `-L` は NX-3060 用で削除厳禁(TX1320 では影響軽微だが踏襲)。
- **USB redirector 劣化**: `VirtualMediaServiceRestart`(deploy スクリプトに内蔵)でリセット。
  それでも POST 99 stuck なら PSU cold reset をユーザに依頼。

---

## 試行間の知見反映先

毎試行後、新知見を該当ファイルへ反映(編集のみ、コミットは最後):
- **skill `irmc-bios-raid`**: BIOS HII Clear の繰り返し運用知見・タイミング・ダイアログ操作の更新。
- **skill `pxe-deploy`**: iPXE-CD 経路の手順を「TX1320 標準 OS install 経路」として明文化、
  PVE ラッパー連携・拠点ルート注意を追記。
- **`config/training_tx1320.yml`**: 通し経路・PVE 手順への参照コメント更新、deprecated 整理。
- **`CLAUDE.md`**: training-tx1320 の標準経路(iPXE-CD + tx1320-pve-setup.sh)を1行追記。
- **memory topic files**: 通し検証結果・拠点ルート知見・PVE ラッパーの存在を追記、MEMORY.md 索引更新
  (索引は1行・200字未満厳守、本文は topic ファイルへ)。

## 3 試行後

- **REPORT.md 準拠のレポート**を `report/` に作成(3試行の成否・時間・知見・標準経路化の結論)。
  プランファイルを `report/attachment/<report-name>/plan.md` へコピー。
- **3/3 成功なら標準経路昇格を確定**: pxe-deploy skill / CLAUDE.md / config の表現を「推奨/標準」に。
- skill/doc/memory/新規スクリプトを **一括コミット**(`git commit -F tmp/<sid>/commit-msg.txt`、
  Co-Authored-By 行付き)。**push はユーザ確認**。
- issue を完了状態へ遷移。

---

## Verification(全体合格基準)

- 各試行で **RAID10 Optimal** + **`pveversion` 応答** + **`https://<ip>:8006` HTML 応答** の3点を確認。
- 3 試行のうち最低 3/3(理想)を目標。失敗があればその失敗モードを reflect し、対処後に再試行。
- 標準経路化の最終確認: `scripts/tx1320-pve-setup.sh` が単体で再現可能、deploy が
  iPXE-CD 一本で完結することをドキュメント上で追跡可能にする。
