# 14・15号機 (Dell PowerEdge R430) 追加プラン

## Context

LINSTOR マルチリージョン基盤を拡張するため、新たに Dell PowerEdge R430 を 2 台（14・15号機）追加する。今回のスコープは **iDRAC 疎通確認 + OS (Debian + PVE) セットアップまで** とし、LINSTOR / クラスタ統合は別 issue で扱う。

最も近い既存実装は 7-9号機 (R320 + iDRAC7) で、本拠点配置・iDRAC ベース・SSH 鍵認証・`bmc_type: idrac` 分岐パスを丸ごと再利用できる。設置場所は 4-9号機と同じ本拠点 (10.10.10.0/8 直結 + 192.168.39.0/24 DHCP) のため、10-13号機系の VLAN trunk フィールドは入れない。

R320 → R430 の世代差で要注意なのは:
- iDRAC7 → iDRAC8 (racadm 互換性はほぼ保たれるが、`config -g` 旧 API ↔ `set` 新 API の混在に注意)
- PERC H710 mini → H730/H730P (RAID 構成は実機状態次第)
- SSH KEX: iDRAC8 新しめの FW は `diffie-hellman-group14-sha1` が無効化されている可能性あり (Phase 3 で要確認)
- BIOS BootMode 変更は **iDRAC7 同様に racadm 経由で行わない** (UefiBootSeq 破壊リスク。VNC + KVM interact で BIOS Setup から手動切替)

## 確定要件

| 項目 | 14号機 | 15号機 |
|---|---|---|
| ホスト名 | `ayase-web-service-14` | `ayase-web-service-15` |
| iDRAC IP | `10.10.10.34` | `10.10.10.35` |
| iDRAC user / pass | `claude` / `Claude123` | 同左 |
| 静的 IP | `10.10.10.214` | `10.10.10.215` |
| 機種 | PowerEdge R430 (iDRAC8) | 同左 |
| 設置 | 本拠点 (4-9号機と同じ) | 同左 |
| デフォルト GW | `192.168.39.1` (PVE セットアップ後) | 同左 |

## Phase 1: 設定ファイル整備

**変更**: `config/server14.yml`, `config/server15.yml` を新規作成 (`config/server8.yml` を雛形にコピー。8号機は serial_unit=0 で R430 デフォルトに近い)。

書き換えフィールド:
- `hostname`, `static_ip`, `bmc_ip`, `iso_filename`, `remoteimage_uri`
- `bmc_type: idrac`, `bmc_ssh_key: ssh/idrac_rsa` は維持
- `static_iface: eno1` (R430 で `em1` の可能性あり、Phase 5 直前に SOL/VNC で `ip link` 確認して必要なら修正)
- `serial_unit: 0` (Phase 4 で実測確定。`Serial1Com1Serial2Com2` だったら 1 に変更)
- `idrac_fw_version` / `idrac_fw_build` / `idrac_fw_updated` は Phase 3 で実測値を後追記

成功判定: `./bin/yq '.bmc_ip' config/server14.yml` → `10.10.10.34`, 15号機同様。

## Phase 2: SSH 設定整備

**変更**:
- `ssh/config` の iDRAC セクション末尾 (idrac9 の後) に `idrac14`, `idrac15` を追加。**当面は idrac7-9 と同じ KEX/HostKey/PubkeyAccepted 緩和を継承** (iDRAC8 でも legacy が必要なケースがあるため)。
- `ssh/config` の PVE セクション末尾 (pve13 の後) に `pve14`, `pve15` を追加 (`IdentityFile` は `ssh/id_ed25519`)。
- `scripts/idrac-virtualmedia.sh` の `resolve_idrac_host()` に `10.10.10.34) echo idrac14`, `10.10.10.35) echo idrac15` のケースを追加 (忘れるとデフォルトで idrac7 にフォールスルー)。

**SSH 公開鍵登録手順** (各号機個別、最初はパスワード認証で実行):
1. iDRAC index 確認: Web UI もしくは sshpass + ssh password 経由で `racadm get iDRAC.Users.2 / .3 / .4` を順に実行し、`UserName=claude` の index を特定 (R430 出荷状態は root=2、claude=3 か 4)。
2. 鍵登録: 同セッションで `racadm sshpkauth -i <INDEX> -k 1 -t "<ssh/idrac_rsa.pub の文字列>"`。
3. IPMI LAN 有効化: `racadm set iDRAC.IPMILan.Enable Enabled` (iDRAC8 新 API)。フォールバックで `racadm config -g cfgIpmiLan -o cfgIpmiLanEnable 1`。
4. 検証: `ssh -F ssh/config idrac14 racadm getsysinfo` が鍵認証で Service Tag を返す。

**Web UI フォールバック**: iDRAC Settings → User Authentication → SSH → Public Key Upload で `ssh/idrac_rsa.pub` を貼る。

成功判定: `ssh -F ssh/config idrac14 racadm getsysinfo` がパスワード入力なしで成功。

## Phase 3: iDRAC 疎通・互換性確認

**実行コマンド**:
```sh
ping -c3 10.10.10.34
ping -c3 10.10.10.35
ipmitool -I lanplus -H 10.10.10.34 -U claude -P Claude123 chassis status
ssh -F ssh/config idrac14 racadm getsysinfo
ssh -F ssh/config idrac14 racadm get iDRAC.Info.Version
./scripts/bmc-power.sh status 10.10.10.34 claude Claude123
```

`getsysinfo` の出力から `idrac_fw_version` / `idrac_fw_build` / `idrac_fw_updated` (今日 2026-05-11) を YAML へ反映。

**詰まりそうな点と回避**:
- iDRAC8 新 FW (例 2.8x+) が `diffie-hellman-group14-sha1` を拒否する場合: `ssh/config` の該当エントリから `KexAlgorithms` 行を削除して再試行 (素の ssh デフォルトの方が通る)。
- `racadm config -g cfgIpmiLan` が iDRAC8 で silent reject されたら新 API `racadm set iDRAC.IPMILan.Enable Enabled` に切替。
- `racadm remoteimage` 自体は iDRAC7/8 共通互換。

成功判定: `getsysinfo` で `System Description = PowerEdge R430` と FW バージョン取得。`bmc-power.sh status` が `On`/`Off` を返す。

## Phase 4: 物理状態・BIOS 確認

**実行コマンド** (各号機):
```sh
ssh -F ssh/config idrac14 racadm storage get controllers
ssh -F ssh/config idrac14 racadm storage get vdisks
ssh -F ssh/config idrac14 racadm storage get pdisks
ssh -F ssh/config idrac14 racadm get BIOS.BiosBootSettings.BootMode
ssh -F ssh/config idrac14 racadm get BIOS.SerialCommSettings.SerialPortAddress
ssh -F ssh/config idrac14 racadm get BIOS.SerialCommSettings.SerialComm
ssh -F ssh/config idrac14 racadm get BIOS.SerialCommSettings.RedirAfterBoot
```

**判定と対処**:
- VD 未構成 → idrac7 スキルの「VD 作成」手順 (`racadm storage createvd ... && jobqueue create RAID.Integrated.1-1 -r pwrcycle`) で OS 用 RAID-1 を作成。
- BootMode=Bios → **racadm では絶対に変更しない** (iDRAC7 の UefiBootSeq 破壊事例と同等リスク想定)。必要なら VNC + `idrac-kvm-interact.py` で BIOS Setup から手動切替。
- SerialComm/RedirAfterBoot が想定外 → racadm で安全に修正可能 (idrac7 スキル既存パス)。
- SerialPortAddress → `Serial1Com2Serial2Com1` なら `ttyS0` (serial_unit=0)、逆なら serial_unit=1 に YAML 修正。
- PERC Foreign Config → Phase 5 で `Press F to clear` プロンプトに当たる可能性。SOL から F キー送信で対処。

成功判定: VD0 (RAID-1, ≥100GB) が Ready/Online、BootMode=Uefi、SerialComm=OnConRedirCom1、RedirAfterBoot=Enabled。

## Phase 5: OS セットアップ (os-setup スキル)

**変更ファイル**: `preseed/preseed-server14.cfg`, `preseed/preseed-server15.cfg` (`preseed/preseed-server8.cfg` を雛形にコピーして hostname/static_ip/console=ttyS<UNIT> を 14/15 用に書き換え)。Phase 4 で serial_unit=1 と確定したら 7号機 preseed をベースに変更。

**実施**: `os-setup` スキルを呼び出し (`/os-setup config/server14.yml` と `/os-setup config/server15.yml` を並列起動可)。R430 はハード同一なので 8 フェーズフローをそのまま流す:
- Phase 1: ISO ダウンロード
- Phase 2: preseed-generate (iDRAC は手動管理 preseed のため即 mark)
- Phase 3: iso-remaster (`--serial-unit=<Phase 4 確定値>`)
- Phase 4: bmc-mount-boot (`idrac-virtualmedia.sh mount` → `boot-once VCD-DVD` → `bmc-power.sh cycle`)
- Phase 5: install-monitor (SOL モニタリング + syslog-receiver は親セッションで 1 本)
- Phase 6: post-install-config (SSH 鍵配置 + sshd 設定 + 静的 IP)
- Phase 7: pve-install (`pre-pve-setup.sh --dhcp-iface eno2 --static-gw 10.10.10.1 --codename trixie` → ルートを `192.168.39.1` 経由に切替 → `pve-setup-remote.sh`。**`--linstor` は付けない**)
- Phase 8: cleanup (umount + boot-reset + `pve-bridge-setup.sh --static-iface eno1 --static-ip 10.10.10.214/8 --dhcp-iface eno2`。**IB 設定はスキップ**)

**詰まりそうな点と回避**:
- `Optical.iDRACVirtual.1-1` が UefiBootSeq に未列挙 → idrac7 スキルの「VirtualMedia ブート復旧手順 Phase A〜C」を適用。
- `static_iface` が `em1` だった場合 → 初回 DHCP で接続し、SOL から `/etc/network/interfaces` を `em1` で書き直し + YAML/preseed 修正 + 再実行。
- 電源操作は必ず `pve-lock.sh wait ./oplog.sh ...` で包む。

成功判定: `ssh -F ssh/config pve14 pveversion` → `pve-manager/8.x`。`curl -sk https://10.10.10.214:8006` 応答あり。`ip -brief addr show vmbr0` に `10.10.10.214/8`、`vmbr1` に `192.168.39.x` (DHCP)。

## Phase 6: ドキュメント・課題管理更新

**変更ファイル**:
- `README.md` — サーバ一覧表に 14・15 行追加。「対応済みハードウェア」に "DELL PowerEdge R430 (14-15号機)" セクションを R320 の下に追加 (シャーシ / PERC / iDRAC8 FW / Boot mode / VirtualMedia / SOL / 認証)。
- `CLAUDE.md` — サーバ一覧表に 14・15 行追加。「14-15号機: DELL PowerEdge R430 / iDRAC8 SSH 鍵認証 / Web/IPMI: claude/Claude123 / IPMI LAN 有効化済み / FW <Phase 3 実測値>」を追記。
- `/home/ubuntu/.claude/projects/-home-ubuntu-projects-pvese/memory/MEMORY.md` — 7-9号機の縦持ち表に 14・15 列を追加 (R430 ハードなので 7-9 表との同居が自然) もしくは 14-15 用の縦持ち表を別途追加。「14-15号機 iDRAC claude ユーザ: index <Phase 2 実測値>」も追記。
- `ssh/config` — Phase 2 で更新済み。
- `scripts/idrac-virtualmedia.sh` — Phase 2 で `resolve_idrac_host()` ケース追加済み。
- `.claude/skills/idrac7/SKILL.md` 概要表 — 「14-15号機 (R430 + iDRAC8) も同スキルで操作可。差分があれば本ファイルに追記」と注記。

**issue 管理**:
- `./issue.sh add "14-15号機 (R430 + iDRAC8) 新規追加 - iDRAC 疎通 + OS/PVE セットアップ" --label infra` で課題作成。
- `./issue.sh start <id> --owner <session名>` で開始、完了時に `./issue.sh done <id> --report <path>`。

**レポート**:
- `report/2026-05-11_HHMMSS_server14-15_os_setup.md` を REPORT.md ルールに沿って作成。タイムスタンプは `TZ=Asia/Tokyo date +%Y-%m-%d_%H%M%S` で取得。
- 含めるもの: Phase 1〜8 の所要時間 (`os-setup-phase.sh times`)、`racadm getsysinfo` 出力、`pveversion` 出力、PERC RAID 状態、各号機の serial_unit 確定値、iDRAC index 確定値、つまずいた点、本プランファイルを `report/attachment/<レポート名>/plan.md` に添付。

## Critical Files

- `config/server7.yml` / `config/server8.yml` — 14/15 yml の雛形 (serial_unit=0 想定で 8号機ベース推奨)
- `ssh/config` — idrac14/15 + pve14/15 エントリ追加位置
- `scripts/idrac-virtualmedia.sh` — `resolve_idrac_host()` ケース追加 (必須)
- `scripts/bmc-power.sh` — Redfish 汎用、変更不要見込み
- `.claude/skills/os-setup/SKILL.md` — iDRAC 分岐の 8 フェーズフロー
- `.claude/skills/idrac7/SKILL.md` — sshpkauth ブートストラップ、BootMode 禁止、VirtualMedia 復旧手順
- `preseed/preseed-server8.cfg` — 14/15 用 preseed のコピー元 (serial_unit=0 想定時)
- `README.md`, `CLAUDE.md`, MEMORY.md — ドキュメント更新

## 検証 (エンドツーエンド)

1. **iDRAC 疎通**: `ssh -F ssh/config idrac14 racadm getsysinfo` が鍵認証で Service Tag を返す (15号機も同様)。
2. **FW バージョン記録**: `config/server14.yml`, `config/server15.yml` の `idrac_fw_version` が空欄でない。
3. **物理状態**: `racadm storage get vdisks` で OS 用 VD が Ready/Online。
4. **OS インストール**: `ssh -F ssh/config pve14 'pveversion && ip -brief addr'` で `pve-manager/8.x` + 静的 IP `10.10.10.214/8` + DHCP `192.168.39.x` (15号機も同様)。
5. **Web UI**: `curl -sk https://10.10.10.214:8006` / `https://10.10.10.215:8006` が応答。
6. **インターネット到達性**: `ssh -F ssh/config pve14 'curl -sI http://debian.org | head -1'` が `HTTP/.* 200` を返す。
7. **ドキュメント**: README / CLAUDE.md / MEMORY.md の表に 14・15 行が表示される。
8. **issue / report**: 課題が done、レポートが `report/` に存在し、plan.md が添付されている。
