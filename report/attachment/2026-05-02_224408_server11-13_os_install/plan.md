# 11/12/13号機 OS+PVE セットアップ展開プラン

## Context

10号機 (10.10.10.30 / Supermicro X10DRT-P / Nutanix NX-1065-G5) では `report/2026-05-02_090532_iter_test_preseed_netcfg.md` までで以下が達成済み:

- `os-setup` スキル (Phase 1-8) が config-driven で動作
- VLAN trunk (eno1 上の 1120/1083) preseed netcfg が自動再現 (Cycle 1/2 完走、SSH 100s 到達)
- BIOS `LSI HBA OPROM=Enabled` で disk first boot 成功
- PVE 9.1.9 + vmbr0/vmbr1 (VLAN-aware bridge) 立ち上げ
- Nutanix OEM BMC FW 3.65 stock のまま運用 (公式 FW は silent reject)

11/12/13号機は 10号機と **同一機種・同一拠点・同一 VLAN trunk (1120/1083)** の Twin Server シブリング。同じスクリプト群がそのまま動作するはずで、新たな差分は config 値 (BMC IP / static IP / hostname / iso_filename) のみ。本プランではこれら 3 台を 10号機と同等の状態 (PVE インストール済 + vmbr0/vmbr1) まで持ち上げる。

ユーザ回答に基づくスコープ:
- 同一拠点・同一 VLAN (1120/1083) 前提 → Phase 0 探索なし、config 直書き可
- 通しテスト (OS+PVE インストール) まで実施
- LINSTOR は今回不参加 (将来課題)
- **直列**実行 (11 → 12 → 13)、各サーバ OS+PVE で約 45 分 × 3 ≒ 2-3 時間

## Plan Overview

| Step | 種別 | 概要 |
|------|------|------|
| 1 | 事前確認 | 3 台の BMC 到達性 + ユーザ `claude` 認証 + LSI HBA OPROM 状態を read-only で確認 |
| 2 | issue 起票 | 3 件の active issue を issue.sh で起票 (1/server) |
| 3 | config 作成 | `config/server11.yml`, `server12.yml`, `server13.yml` を server10.yml からクローン |
| 4 | ssh/config 更新 | `pve11`, `pve12`, `pve13` alias を追加 |
| 5 | ドキュメント更新 | `CLAUDE.md` / `README.md` のサーバ表に 11-13 を追加 |
| 6 | メモリ更新 | `MEMORY.md` のサーバ情報表に 11-13 を追加 |
| 7 | BIOS 事前確認 | 11→12→13 で `bios-setup` スキル経由 LSI HBA OPROM 状態確認、必要なら Enabled に変更 |
| 8 | OS+PVE 展開 | 11→12→13 で `os-setup` スキル Phase 1-8 を実施 |
| 9 | 検証 | 各サーバ vmbr0/vmbr1 + PVE Web UI HTTP 200 + machine-id 検証 |
| 10 | レポート + close | `report/` にレポート作成、issue close |

## Step Details

### Step 1: 事前確認 (read-only, ~5 分)

- `ipmitool -I lanplus -H 10.10.10.31 -U claude -P Claude123 chassis status` (32, 33 も同様) — BMC 認証 + 電源状態
- `./scripts/bmc-power.sh status 10.10.10.3X claude Claude123` — Redfish 経由
- 3 台すべて到達不可なら停止してユーザ報告

NG ケース:
- BMC 認証失敗 → ユーザに BMC 初期セットアップ依頼 (10号機と同様 `claude/Claude123` index 4 想定だが、機体差で異なる可能性)
- 電源 ON で既に何か動いている → ユーザ確認後に上書きインストールしてよいかを判断

### Step 2: issue 起票

```sh
./issue.sh add "11号機 OS+PVE セットアップ通しテスト" --tags infra
./issue.sh add "12号機 OS+PVE セットアップ通しテスト" --tags infra
./issue.sh add "13号機 OS+PVE セットアップ通しテスト" --tags infra
./issue.sh start <id> --owner <session-id>
```

(1 サーバずつ active 化、完了で done 化、または 1 親 issue + 子 3 件の構造でもよい)

### Step 3: config ファイル作成

`config/server10.yml` を 3 部複製し、以下のフィールドのみ書き換え:

| Field | s10 | s11 | s12 | s13 |
|-------|-----|-----|-----|-----|
| `hostname` | ayase-web-service-10 | ayase-web-service-11 | ayase-web-service-12 | ayase-web-service-13 |
| `static_ip` | 10.10.10.210 | 10.10.10.211 | 10.10.10.212 | 10.10.10.213 |
| `bmc_ip` | 10.10.10.30 | 10.10.10.31 | 10.10.10.32 | 10.10.10.33 |
| `iso_filename` | debian-preseed-s10.iso | debian-preseed-s11.iso | debian-preseed-s12.iso | debian-preseed-s13.iso |

その他のフィールド (VLAN 1120/1083, disk `/dev/sda`, serial_unit 1, smb_host, debian_iso_*, root_password, user_*, bmc_user/pass) は 10 と完全同一。

ファイル先頭コメントの `# Server 10 (...)` も `# Server 11/12/13 (...)` に更新。

### Step 4: ssh/config 更新

`ssh/config` 末尾の `Host *` ブロック直前に以下 3 ブロックを追加 (pve10 と同形式):

```
Host pve11 10.10.10.211
  HostName 10.10.10.211
  User root
  IdentityFile /home/ubuntu/projects/pvese/ssh/id_ed25519
  IdentitiesOnly yes

Host pve12 10.10.10.212
  HostName 10.10.10.212
  User root
  IdentityFile /home/ubuntu/projects/pvese/ssh/id_ed25519
  IdentitiesOnly yes

Host pve13 10.10.10.213
  HostName 10.10.10.213
  User root
  IdentityFile /home/ubuntu/projects/pvese/ssh/id_ed25519
  IdentitiesOnly yes
```

### Step 5: CLAUDE.md / README.md のサーバ表拡張

- `CLAUDE.md` のサーバ一覧表に 11/12/13 行を追加 (BMC IP, 静的 IP, ホスト名, 設定ファイル)
- `CLAUDE.md` 「サーバ一覧」直下の **10号機固有解説** を「10-13号機共通: Supermicro X10DRT-P (Twin Server) / ...」に書き換え
- `README.md` も同様 (line 158, 174-175, 198-199 周辺)

### Step 6: MEMORY.md 更新

- `MEMORY.md` 冒頭のサーバ情報表 (4-10号機の表) に 11-13 列を追加
- 10号機固有の解説文 "10号機: Nutanix NX-1065-G5 OEM..." を 10-13号機共通記述に更新
- `server10_*` 補助ファイル (vlan, lsi_hba_oprom, nutanix_oem) は **編集不要** — 内容は 10-13 すべてに適用される旨をファイルヘッダで一言追記するか、ファイル名を `x10drt_*` 系にリネームする (リネームは MEMORY.md エントリも要更新)。今回は最小変更でファイルヘッダ追記のみとする

### Step 7: BIOS 事前確認 (per server, 11→12→13 順、~5-15 分/台)

各サーバについて `bios-setup` スキルを以下の流れで起動:

1. `./scripts/bmc-power.sh status` で電源状態確認 (off なら on にしてから)
2. POST 中に `<Del> x60` で BIOS Setup へ
3. `Advanced > PCIe/PCI/PnP Configuration > LSI HBA OPROM` の現在値確認
4. `Disabled` なら → `Enabled` へ変更 → F4 保存 → POST 再起動
5. `Enabled` ならそのまま F10/Esc で抜ける

機体差で出荷時 default が `Enabled` のものもあり得るため、まず現状確認。
10号機と同じ `Disabled` 出荷想定で見積もると 3 台すべてで変更が必要 (各 ~5 分)。

### Step 8: OS+PVE 通しインストール (per server, 11→12→13 順、~45 分/台)

各サーバ N (11, 12, 13) について `os-setup` スキルを起動:

```sh
# 引数: config/server${N}.yml
```

スキル内部で実行されるフェーズ:

| Phase | 概要 | 期待時間 (10 号機実績) |
|-------|------|---------------------|
| 1. iso-download | Debian 13.3 ISO (キャッシュ済 → skip) | 0s |
| 2. preseed-generate | `generate-preseed.sh config/serverN.yml preseed/preseed-generated-sN.cfg` | ~7s |
| 3. iso-remaster | `remaster-debian-iso.sh ... debian-preseed-sN.iso` | ~2 分 |
| 4. bmc-mount-boot | VirtualMedia mount + power cycle (ISO boot) | ~1 分 (POST stale なら ~10 分) |
| 5. install-monitor | sol-monitor.py で POWER_DOWN まで監視 | ~10-12 分 |
| 6. post-install-config | umount + power on + SSH 到達 (10.10.10.21N) | ~3 分 |
| 7. pve-install | pre-pve-setup → pve-setup-remote (pre-reboot → reboot → post-reboot) | ~10 分 |
| 8. cleanup | `pve-bridge-setup.sh --vlan-iface eno1 --internet-vlan-id 1120 --internal-vlan-id 1083 --static-ip 10.10.10.21N/8` | ~30s |

各 Phase は `os-setup-phase.sh` で state 管理され、サーバごとに `state/os-setup/server11/`, `server12/`, `server13/` に分離される。並列ではなく **直列** 実行とするため、サーバ N の Phase 8 完了を確認してから N+1 に進む。

並列実行規約 (preseed/ISO/cookie/SOL ログのサーバ別分離) は直列でも遵守する (将来 1 台再走時の混線回避)。

### Step 9: 検証 (per server)

10号機の `report/2026-05-02_090532_iter_test_preseed_netcfg.md` 「検証ポイント」表と完全同一の項目で検証:

- `eno1` UP / IP なし (LL のみ)
- `eno1.1083` static `10.10.10.21N/8`
- `eno1.1120` DHCP
- `default route` via `eno1.1120` (動的 GW)
- `vmbr0` UP `10.10.10.21N/8`
- `vmbr1` UP DHCP
- `/etc/network/interfaces` 4 ブロック (lo / eno1 manual / eno1.1120 dhcp / eno1.1083 static)
- `machine-id` mtime > install-monitor.start
- `pve-manager` バージョン取得 (PVE 9.1.x)
- `curl -sk https://10.10.10.21N:8006` HTTP 200

### Step 10: レポート + issue close

`report/<timestamp>_server11-13_os_install.md` (または 1 サーバ 1 レポートで 3 本) を REPORT.md ルールに従い作成。Phase 別所要時間表 + 検証結果表 + 副次知見を含める。各 issue を `done` に遷移。

## Files to Modify

### 新規作成

- `/home/ubuntu/projects/pvese/config/server11.yml`
- `/home/ubuntu/projects/pvese/config/server12.yml`
- `/home/ubuntu/projects/pvese/config/server13.yml`
- `/home/ubuntu/projects/pvese/report/<timestamp>_server11-13_os_install.md` (実行後)
- `/home/ubuntu/projects/pvese/preseed/preseed-generated-s11.cfg` (生成)
- `/home/ubuntu/projects/pvese/preseed/preseed-generated-s12.cfg` (生成)
- `/home/ubuntu/projects/pvese/preseed/preseed-generated-s13.cfg` (生成)

### 編集

- `/home/ubuntu/projects/pvese/ssh/config` (3 alias 追加)
- `/home/ubuntu/projects/pvese/CLAUDE.md` (サーバ一覧表 + 10号機固有解説の汎化)
- `/home/ubuntu/projects/pvese/README.md` (サーバ一覧表)
- `/home/ubuntu/.claude/projects/-home-ubuntu-projects-pvese/memory/MEMORY.md` (サーバ情報表 + 解説)
- `/home/ubuntu/projects/pvese/issues/issues.yml` (`./issue.sh add` 経由)

### 編集不要 (汎用済)

- `.claude/skills/os-setup/SKILL.md` — config-driven で 11-13 を自動サポート
- `.claude/skills/bios-setup/SKILL.md` — X10DRT-P 対応済 (Issue #51 完了)
- `scripts/generate-preseed.sh` — hostname 末尾数字から SUFFIX を導出
- `scripts/pve-bridge-setup.sh` — `--vlan-iface` 系フラグでパラメタライズ済
- `scripts/bmc-virtualmedia.sh` — Nutanix OEM の `VM1/CD1` パスを既に対応

## Risks & Gotchas (10 号機実績ベース)

1. **POST code stale + KVM screenshot stale 併発**: Phase 4 で診断時間が伸びる可能性。SOL ログを最終真実として扱う運用は既に reference 化済
2. **RTC バッテリ劣化** (10 号機で観測): 3 台同型なので同様の傾向あり。`pre-pve-setup.sh` で chronyd 強制同期されるため大半は救済可能。apt GPG エラーが起きたら時刻同期を疑う
3. **machine-id false positive**: `install-monitor.start > /etc/machine-id mtime` の状態だと Phase 6 検証が誤判定する。10号機で `cp .../bmc-mount-boot.start install-monitor.start` で回避した運用を踏襲。あるいは前任レポート残タスク「install-monitor.start タイムスタンプ補正」を本タスクで先に潰すのも選択肢
4. **BMC ユーザ index**: 10号機は `claude = index 4`。11-13 も同様想定だが、機体差で異なる可能性 (Step 1 で確認)
5. **DHCP リース重複**: VLAN 1120 DHCP プールが小さいと 4 台同時運用で衝突する可能性。Phase 7 完了後の DHCP 取得アドレスを記録する
6. **Twin Server 物理冷却**: 4 ノードを同時に高負荷運用するため熱設計に注意 (本タスクでは I/O ベンチを走らせないので問題は出にくい)

## Verification (E2E)

各サーバ N について以下が成功すれば合格:

```sh
# SSH
ssh -F ssh/config root@10.10.10.21N hostnamectl
# → "Static hostname: ayase-web-service-N" を含む

# Network
ssh -F ssh/config root@10.10.10.21N ip -br a
# → vmbr0 UP 10.10.10.21N/8, vmbr1 UP <DHCP>/24 を含む

# PVE
curl -sk -o /dev/null -w '%{http_code}' https://10.10.10.21N:8006
# → 200

# pve-manager version
ssh -F ssh/config root@10.10.10.21N pveversion
# → pve-manager/9.1.x ...

# machine-id (新規生成確認)
ssh -F ssh/config root@10.10.10.21N stat -c '%Y' /etc/machine-id
# → install-monitor.start エポックより大きい
```

3 台分の合格を確認後にレポートを書き、issue を close する。
