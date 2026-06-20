# training-tx1320 通しセットアップ (RAID Clear → Debian+PVE → WebUI/API 制限)

## Context (背景と目的)

training-tx1320 (Fujitsu PRIMERGY TX1320 M3 / iRMC S4, `config/training_tx1320.yml`) に対し、
以下 3 フェーズを通しで実施する。

1. **① BIOS HII KVM で RAID 初期化 (RAID Clear)** — 既存 RAID 構成 (現 PVE 9.2.3稼働中) を破棄
2. **② Debian + Proxmox VE の通しインストール/セットアップ** — 標準経路 (iPXE-CD deploy → sol-monitor → tx1320-pve-setup)
3. **③ PVE Web UI (8006) と API を 192.168.33.0/24 + loopback のみに制限** — `/etc/default/pveproxy`

training-tx1320 は **一時設置・クラスタ/LINSTOR 非参加** で、RAID Clear から再 install して既存環境を破壊しても問題ない。
各フェーズは過去に個別実証済み (6/13 RAID Clear+PVE e2e, 6/14 + 6/19 WebUI 制限, 6/19 bridge 構成)。
今回はこれらを 1 セッションで通し再実行し、結果を 1 枚のレポートにまとめる。

**ユーザ確定事項 (本セッションで確認済み):**
- 実行方式 = **このセッション (opus) で直接実行** (sonnet 委譲 / dual-verify pane は不使用)
- ③ の適用範囲 = **都度適用のみ** (install 後に `/etc/default/pveproxy` を手動適用。preseed/pve-setup への恒久化はしない)

**pve-lock について (CLAUDE.md 規約との整合):**
training-tx1320 是クラスタ/LINSTOR 非参加の単体一時マシンのため、BMC 電源操作や pveproxy 再起動は
他クラスタメンバーに影響しない。6/13 レポート・pxe-deploy runbook ともに **pve-lock を使わず直接実行** している。
本計画もこれに倣い pve-lock は使用しない (排他制御不要)。

**重要な設計上の注意 (③ 適用後):**
現在のブリッジ構成では claude は dark-net `10.1.4.16` 経由で SSH 到達するが、③ で 8006 を
`192.168.33.0/24 + 127.0.0.1` のみに制限すると **dark-net 側 (10.1.4.16:8006) は遮断**される。
claude (送信元 = dark-net `10.1.x`) は 192.168.33.0/24 外のため、**適用後 claude 自身が WebUI/API を失い SSH(22) のみが残る**。
これは仕様 (許可元限定) の意図的帰結。WebUI 検証はすべて **SSH 経由でホスト上の curl (127.0.0.1 / 192.168.33.129)** で行う。
SSH は pveproxy と独立系統のため復旧経路として常時維持される。

---

## 現状 (前提知識 — 探索で確認済み)

- **config**: `config/training_tx1320.yml` は既にブリッジ+固定IP構成に modified 済み
  - BMC IP `10.254.254.9` (iRMC S4 FW 9.69F) / user `claude` / `Claude123` / index 4
  - `bridge_setup: true`, `secondary_bridge_address: "10.1.4.16/8"`
  - vmbr0 (eno1) = site LAN 192.168.33.0/24 DHCP / vmbr1 (eno2, MAC `4c:52:62:14:de:f0`) = dark-net static `10.1.4.16/8`
  - `virtual_media_type: nfs`, `nfs_host: 10.1.6.6` (playground), `nfs_export_path: /var/samba/public`
- **SSH**: `ssh -F ssh/config training-tx1320` (= root@`10.1.4.16`, `IdentityFile ssh/id_ed25519`) が定義済み
- **OS/PVE 到達後**: Debian 13 + pve-manager/9.2.3, HW RAID10 (SAS HDD 900GB×4 → 1.635 TB) / LVM
- **ISO**: `ipxe-tx1320.iso` が playground NFS (`/var/samba/public/`) に配置済みの前提

---

## ステップ 0: 事前準備・現状確認

1. セッション UUID 取得: **Glob ツール** (`pattern: "*.jsonl"`, `path: "/home/ubuntu/.claude/transcripts"`) で最新 transcript 名前 (= セッション UUID) を取得し先頭 8 字を `<sid>` とする。`mkdir -p tmp/<sid>`
2. BMC env ラッパー作成 (bmc-power.sh 直接呼び出し用。env は Bash 呼び出し間で persist しないため必須):
   `tmp/<sid>/bmc.sh` を Write (内容: 5 変数 export `BMC_SCHEME=https` / `BMC_CURL_OPTS="--ciphers DEFAULT@SECLEVEL=0"` / `BMC_PATCH_REQUIRES_ETAG=1` / `BMC_BOOT_OVERRIDE_NO_DISABLED=1` / `POWER_ON_RESET_TYPE=On` + `exec ./scripts/bmc-power.sh "$@"`)。bmc-power.sh の直接呼び出しはすべて `sh tmp/<sid>/bmc.sh ...` 経由とする
3. 疎通確認 (個別 Bash 呼び出し、パイプ/`;` なし):
   - `ping -c3 -W2 10.254.254.9` (iRMC), `ping -c3 -W2 10.1.6.6` (playground), `ping -c2 10.1.4.16` (現 PVE 有無)
4. playground の前提ファイル確認 (ssh 経由、個別呼び出し): `/var/samba/public/ipxe-tx1320.iso`, `/var/www/html/preseed/`, `/var/www/html/firmware/{storcli64.bin,setup-raid10-storcli.sh,phonehome-setup.sh}`
5. 既存 RAID 状態は BIOS AVAGO dashboard (① step 3) で確認するため事前の storcli 確認は省略可

---

## ステップ ①: BIOS HII KVM で RAID 初期化 (RAID Clear)

skill `irmc-bios-raid` + 6/13 レポートの検証付き経路 (単一 blind recipe は先頭 ArrowRight ドロップに脆弱のため非採用)。

1. **BIOS Setup + 健全 KVM 状態へ復旧**:
   `./oplog.sh ./scripts/irmc-kvm-recover.sh config/training_tx1320.yml tmp/<sid>/recover-bios.jpg`
   (内部: host ForceOff → 必要なら Manager.Reset → boot-override BiosSetup UEFI + on → POST 待ち。KVM 劣化時は Manager.Reset で復帰 ~3min)
2. **永続 KVM サーバ起動** (foreground、 別 Bash 呼び出しで `=== KVM server READY ===` を待つ):
   `.venv/bin/python scripts/irmc-kvm/server.py --bmc-ip 10.254.254.9 --bmc-user claude --bmc-pass Claude123 --srv-dir tmp/<sid>/srv`
3. **per-key 投入** (`tmp/<sid>/srv/in/NNN.cmd` を書き、各 shot をサブエージェント/画像で検証):
   1. `press ArrowRight 2000` + shot → Advanced タブ着地 (指紋 size=**17919**)
   2. `navy 393 caret 25 1500` + shot → AVAGO 行 adaptive 着地 (size=**18051**, caret_y=393)
   3. `Enter` → AVAGO dashboard (**Virtual Drives: 1 / Drive Groups: 1 / Drives: 4 / Status [Optimal]** = 既存 VD 存在確認)
   4. `Enter` → Main Menu (5項目) → `Enter` → Config Mgmt (VD 有り=2項目)
   5. `ArrowDown 1` → `Clear Configuration` 行 (size=**10135**)
   6. modal commit: `press Enter 3000` (dialog size=**11383**) → `mouse 80 240` → `ArrowDown→Enter`×3 (No→Confirm→Enabled→Yes) → commit (size=**9462**, "operation performed successfully")
   7. `Enter`(►OK) → `Escape`(Main Menu) → `keyrepeat ArrowDown 2 1600`(VDM 行) → `Enter` → shot → **size=9758 = "no Virtual Drives currently available" = Clear 成功**
   8. `quit`
4. 失敗時リカバリ: ArrowRight ドロップ(Main 居残り) → shot 検出 + 再送 / AVAGO 着地失敗 → navy リトライ / stale フレーム → sleep + 再 shot / commit 進捗不明 → per-key screenshot

> 指紋値は 6/13, 6/02, 6/10 レポートと完全一致。KVM canvas shot (server.py) は BIOS 画面で有効 (OS install VGA ブランク時とは別)。全操作 `./oplog.sh` 記録。

---

## ステップ ②: Debian + PVE 通しインストール (標準経路)

### ②-a: iPXE-CD deploy

deploy スクリプトは内部で BMC env を自前 export するため、ラッパー不要:
```
./oplog.sh ./scripts/irmc-ipxe-cd-deploy.sh config/training_tx1320.yml ipxe-tx1320.iso
```
内部動作: DisconnectCD(400 無害) → CDImage NFS(200) → VirtualMediaServiceRestart(204、USB redirector 劣化リセット) → On → ConnectCD(204、HTTP500 なら最大4回リトライ、ダメなら abort) → ForceOff → boot-override Cd UEFI(Off で設定) → On。
> ConnectCD abort したら②-a をもう一度。HTTP500 放置は旧 HDD GRUB 起動のサイレント失敗になる。

### ②-b: install 監視 (sol-monitor、foreground)

```
.venv/bin/python scripts/sol-monitor.py --bmc-ip 10.254.254.9 --bmc-user claude --bmc-pass Claude123 --log-file tmp/<sid>/install.log --timeout 2400 --powerstate-interval 30
```
- **進捗判定**: sol-monitor の d-i stage (DETECTING_NETWORK → CONFIGURING_APT → INSTALLING_SOFTWARE → INSTALLING_GRUB → POWER_DOWN)。正常なら deploy から ~3-4min で CONFIGURING_APT 以降へ。**nginx access.log は当てにしない**。
- **完遂判定**: rc=0 (POWER_DOWN → PowerState Off 二重確認)。
- **落とし穴 #15 (d-i netcfg stuck、発生率 ~30%)**: deploy から ~10min で CONFIGURING_APT に進まなければ `sh tmp/<sid>/bmc.sh forceoff 10.254.254.9 claude Claude123` → ②-a から再 deploy (2 回目は +3〜4min で正常)。恒久対策 (cmdline `interface=eno1`) は embed 済みだがタイミング依存で再発しうる。
- **手動 ForceOff による rc=4 (false positive)** は異常ではない (無視して retry)。
- **install 完遂前の手動 ForceOff は #15 判定時のみ** (finish-install の sync 中断で authorized_keys 等の遅延書込喪失を防ぐ)。
- 🚨 **foreground 実行**: harness が長時間 Bash を自動 background 化することがある。その場合でも **出力ファイルを Read で定期ポーリングして rc=0 (POWER_DOWN) を待ち切る** (yield しない)。Monitor ツールは使わない。
- **install 中の RAID10 作成**: preseed `partman/early_command` の storcli が RAID10 を delete+create する (SOL ログで "raid10-setup OK" マーカ確認)。

### ②-c: disk boot (bmc.sh ラッパー経由、env 必須)

```
./oplog.sh sh tmp/<sid>/bmc.sh boot-override 10.254.254.9 claude Claude123 Hdd UEFI
./oplog.sh sh tmp/<sid>/bmc.sh on 10.254.254.9 claude Claude123
```
> boot-override は `-o UserKnownHostsFile=/dev/null` でないが、bmc-power.sh は Redfish 経由なので SSH 鍵問題なし。`sh tmp/<sid>/bmc.sh` は env 未 export の rc=52 (落とし穴 #10) を防ぐ。

### ②-d: PVE 通しセットアップ

固定管理 IP `10.1.4.16` を直渡し (bridge_setup + 固定 IP で eno2 lease 変動の IP 特定は不要。内部 wait_ssh が MAC 再 discovery で追従):
```
./oplog.sh ./scripts/tx1320-pve-setup.sh config/training_tx1320.yml 10.1.4.16
```
- 内部: wait_ssh → pve-setup-remote.sh --phase pre-reboot (PVE repo/kernel/GRUB serial) → reboot → --phase post-reboot (proxmox-ve install, Debian kernel 削除) → reboot → 検証
- live hostname `tx1320` を `/etc/hosts` に採用 (config の `training-tx1320` を盲信しない、pve-cluster 不起動を防ぐ)
- スクリプトは `-o UserKnownHostsFile=/dev/null` を使うため known_hosts stale key 問題なし
- **ログ巨大化注意**: 初回 PVE install の `W: Tried to start delayed item` 警告が ~220 万行/119MB になることがある (無害)。**全体 Read 禁止**、grep/tail 相当 (スクリプト経由) で `DONE. Final reachable IP` 行と検証ブロックのみ確認。

### ②-e: 通し完了検証

独立検証の ssh には **`-o UserKnownHostsFile=/dev/null`** を付ける (IP 使い回しで stale key MISMATCH を防ぐ。`StrictHostKeyChecking=no` だけでは鍵不一致で拒否される):
```
ssh -F ssh/config -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@10.1.4.16 pveversion
ssh -F ssh/config -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@10.1.4.16 systemctl is-active pveproxy pvedaemon pve-cluster
curl -sk --max-time 15 https://10.1.4.16:8006 -o /dev/null -w '%{http_code}\n'   # ③ 適用前は 200
ssh ... root@10.1.4.16 "storcli64 /c0/vall show"   # → 0/0 RAID10 Optl 1.635 TB (tx1320-pve-setup.sh 検証ステップが自動取得+直読)
```
期待: PVE 9.2.x / 全 active / 200 / RAID10 Optl 1.635 TB。

---

## ステップ ③: WebUI/API を 192.168.33.0/24 + loopback のみに制限

過去レポート (`report/2026-06-19_073943_...reapply.md`) と完全同一の内容を都度適用。**現ホストのみ (リポジトリ無改変)**。

1. 適用前の実機取得 (claude 側、③ 適用前は到達): `curl -sk -o /dev/null -w '%{http_code}\n' --connect-timeout 8 https://10.1.4.16:8006/` → 200、`/api2/json/version` → 401
2. **冪等適用スクリプト** `tmp/<sid>/apply-pveproxy.sh` を Write し、`scp` → `ssh ... sh /tmp/apply-pveproxy.sh` で実行 (CLAUDE.md パーミッション規則: パイプ/リダイレクト含むためインライン禁止):
   - 既存ファイルから `^[[:space:]]*(ALLOW_FROM|DENY_FROM|POLICY)=` 行を除去 → 正準 3 行を追記 → 一時ファイルを `/etc/default/pveproxy` へアトミック `mv` (初期状態 不在/3キー/一部/無関係併存 に関わらず収束、再実行で重複しない)
   - **🚨 mktemp は 0600 で作成されるため、mv 後に必ず `chmod 0644 /etc/default/pveproxy` を付ける** (0600 のままだと pveproxy が `Permission denied` で ALLOW_FROM を読めず全許可になる — 本セッションで発見)
   - 最終内容:
     ```
     ALLOW_FROM="127.0.0.1,192.168.33.0/24"
     DENY_FROM="all"
     POLICY="allow"
     ```
3. 反映 (適用スクリプト内に含めるか ssh 経由): `systemctl restart pveproxy` → `systemctl is-active pveproxy`
4. 検証:
   - claude 側 (ローカル): `curl -sk -o /dev/null -w '%{http_code}\n' --connect-timeout 8 https://10.1.4.16:8006/` → **000 (遮断)**
   - ホスト上 (検証スクリプト `tmp/<sid>/verify-pveproxy.sh` を scp → `ssh ... sh`):
     - `curl -sk -o /dev/null -w '%{http_code}\n' https://127.0.0.1:8006/` → **200** (loopback 許可)
     - `curl -sk -o /dev/null -w '%{http_code}\n' https://192.168.33.129:8006/` → **200** (vmbr0 LAN 側許可、IP は動的取得)
     - `curl -sk -o /dev/null -w '%{http_code}\n' https://10.1.4.16:8006/` → **000** (vmbr1 自己 dark-net 遮断)
   - **SSH 維持確認**: 検証スクリプトを ssh 経由で実行できた事実自体が SSH(22) 維持の実機証拠
5. 全操作 `./oplog.sh` 記録。

> pveproxy は不許可 IP を TLS 接続確立前に切断 (curl exit 35 / http_code 000)。IPv6 も `ALLOW_FROM` が IPv4 のみのため全拒否 (実害低、`::1` で 8006 を叩くツールがある場合のみ `::1` 追加)。

---

## レポート作成 (完了後)

REPORT.md に従い `report/` 配下に作成 (1 枚に統合):

1. タイムスタンプ取得: `TZ=Asia/Tokyo date +%Y-%m-%d_%H%M%S`
2. ファイル名: `report/<ts>_tx1320_raid_clear_pve_webui_restrict_e2e.md` (英語名)
3. 添付 (必須): `mkdir -p report/attachment/<ファイル名(拡張子除く)>/` → `cp /home/ubuntu/.claude/plans/training-tx1320-config-training-tx1320-y-cached-parnas.md report/attachment/<名>/plan.md`
4. セクション: タイトル(日本語) / 実施日時(JST) / 添付ファイル / 前提・目的 / 環境情報 / 再現方法 (①②③) / 結果 (検証表) / 復旧手順 / 補足
5. 過去レポート (6/13, 6/14, 6/19 ×2) へのリンクを参照として記載
6. Write で `report/` 直下に書き込むと Discord webhook 通知 (PostToolUse hook)

---

## 検証 (end-to-end 成功判定)

- **① RAID Clear**: VDM 画面で "no Virtual Drives currently available" (KVM shot size=9758)
- **② PVE**: `pveversion` で PVE 9.2.x、`pvedaemon/pveproxy/pve-cluster` active、install 中 storcli が RAID10 再作成 (SOL ログ marker)、RAID10 Optl 1.635 TB (storcli 直読)
- **③ WebUI 制限**: claude 側 8006 = 000 (遮断)、ホスト lo/vmbr0(192.168.33.129) = 200、vmbr1 自己(10.1.4.16) = 000、SSH(22) 維持
- **到達性**: `ssh -F ssh/config training-tx1320` (= 10.1.4.16) で通し全過程到達、物理操作なし

## リスク・リカバリ

- **KVM 劣化**: BIOS Clear 中や deploy 中に黒画/degrade したら `Manager.Reset` で復帰 (~3min)
- **#15 netcfg stuck**: deploy から ~10min 停滞で ForceOff (bmc.sh 経由) + retry (確立済みパターン、2 回目 +3〜4min)
- **ConnectCD HTTP500**: deploy スクリプトが内部リトライ (max 4)。abort したら②-a 再実行
- **vmbr0 DHCP 遅延 (本セッションで発見)**: PVE setup の reboot 後に vmbr0 (eno1) の DHCP 取得が遅延 (APIPA 169.254.x) し apt が失敗 (exit 4/100) することがある。vmbr0 を static (192.168.33.129/24、gateway 192.168.33.1) + resolv.conf 固定 (chattr +i) で根絶。
- **③ 適用後 claude が WebUI 喪失**: SSH(22) 維持のため `ssh ... "rm /etc/default/pveproxy && systemctl restart pveproxy"` で即復旧
