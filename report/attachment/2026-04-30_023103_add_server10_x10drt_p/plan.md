# 10号機追加 (BMC 10.10.10.30, Supermicro X10DRT-P)

## Context

新規物理サーバを pvese プロジェクトに追加する。

- BMC IP: `10.10.10.30`
- ボード型番: **Supermicro X10DRT-P** (Twin Server 用ハーフ幅マザーボード)
- 既存命名規則に従って **10号機** = `ayase-web-service-10` / 静的IP `10.10.10.210` として扱う

X10DRT-P は X11DPU と同じ Supermicro 系で BMC は Redfish/CGI 対応と見込まれるため、4-6号機 (X11DPU) のテンプレートをベースに `config/server10.yml` を作成し、`os-setup` スキルの Platform Dispatch (`bmc_type: supermicro`) を経由して既存スクリプト群がそのまま使えるようにする。

ユーザ確認済みの方針:
- ホスト名 `ayase-web-service-10`、静的IP `10.10.10.210` で確定
- LINSTOR/DRBD は当面未参加 (実機・IB 接続性確認後に別タスクで決定)
- `bios-setup` スキル (現状 X11DPU 専用) の X10DRT-P 対応は今回触らない (実機検証後に別タスク)

NIC 名 (`eno1np0`/`eno2np1`) と `serial_unit: 1` は X11DPU 既存値を雛形値とし、実機 OS インストール時に `ip link` と KVM で確認・修正する。本プランは「サーバ追加 + 既存スキルから操作可能になるための config/ドキュメント整備」までを範囲とし、OS インストール自体は別タスクで `/os-setup config/server10.yml` を実行する。

## 変更対象

### 新規作成

**`config/server10.yml`** — `config/server4.yml` をベースに以下を変更:

| フィールド | 値 |
|---|---|
| `hostname` | `ayase-web-service-10` |
| `static_ip` | `10.10.10.210` |
| `static_iface` | `eno2np1` (X11DPU 想定、実機検証要) |
| `dhcp_iface` | `eno1np0` (同上) |
| `bmc_type` | `supermicro` |
| `bmc_ip` | `10.10.10.30` |
| `bmc_user` / `bmc_pass` | `claude` / `Claude123` (4-6号機慣例) |
| `iso_filename` | `debian-preseed-s10.iso` |
| `serial_unit` | `1` (X11DPU 想定、実機検証要) |
| `disk` | `/dev/nvme0n1` (X11DPU 想定、実機検証要) |

その他 (`domain`, `debian_*`, `smb_*`, `iso_download_dir`, `root_password`, `user_*`) は server4.yml と同値。実機検証要のフィールドにはコメントを付与する。

### 修正

**`CLAUDE.md`** L36-48 「サーバ一覧」セクション

- 表に 10号機行を追加: `| 10号機 | \`10.10.10.30\` | \`10.10.10.210\` | ayase-web-service-10 | \`config/server10.yml\` |`
- L47 注釈を「4-6号機共通」→「4-6号機共通: ... / Supermicro X11DPU」のように維持しつつ、新しい行で「10号機: Supermicro X10DRT-P / ユーザ名 `claude` / パスワード `Claude123` / NIC・disk・serial_unit は X11DPU と同等想定 (実機確認要)」を追加

**`README.md`**

- L89-107 「対応済みハードウェア」セクションに **`### Supermicro X10DRT-P (10号機)`** サブセクションを「DELL PowerEdge R320」の前に追加。表は X11DPU セクションを雛形にし、判明済みの項目 (マザーボード=X10DRT-P、BMC=Supermicro IPMI、ブートモード=UEFI 想定、SOL=COM2/ttyS1 想定) を記載、不明項目には「実機確認要」と明記
- L135-149 「サーバ一覧」表に 10号機行追加。L146 「4-6号機: ...」周辺の注釈を更新し、10号機が Supermicro X10DRT-P であることを明記
- L153-210 mermaid 図に `srv10` サブグラフ (`BMC10 10.10.10.30`, `PVE10 10.10.10.210`)、`CC -- "SSH" --> PVE10`、`CC -- "IPMI" --> BMC10`、`BMC10 -- "SMB" --> SMB` を追加。LINSTOR 未参加のため `IB` への接続線は引かない

**`/home/ubuntu/.claude/projects/-home-ubuntu-projects-pvese/memory/MEMORY.md`** (auto-memory)

- 冒頭「サーバ情報」表に 10号機列を追加 (ホスト名/設定ファイル/BMC IP/静的 IP/Web UI)
- 表下の注釈に「10号機: Supermicro X10DRT-P / NIC・serial_unit は X11DPU 想定 (実機確認要) / LINSTOR 未参加」を追加

**`ssh/config`** L35-70 「PVE ノード」セクション末尾

- `pve9` エントリの後に `pve10` を追加 (HostName `10.10.10.210`、`User root`、`IdentityFile /home/ubuntu/projects/pvese/ssh/id_ed25519`、`IdentitiesOnly yes`)

### 触らない (明示)

スキル側の SKILL.md・script はいずれも変更不要であることを Plan に明記する:

- **`os-setup`**: Platform Dispatch (`bmc_type` 判別) で自動対応。SKILL.md に対応サーバ列挙はないので修正不要。`config/server10.yml` を作成した時点で `/os-setup config/server10.yml` がそのまま使える
- **`linstor-node-ops` / `linstor-bench` / `linstor-migration`**: LINSTOR 未参加のため argument-hint や対象表に `server10` を含めない (将来 LINSTOR 参加時に別タスクで追記)
- **`bios-setup`**: ユーザ確認済み、X11DPU 専用のまま据え置き
- **`perc-raid` / `idrac7` / `idrac7-fw-update`**: それぞれ DELL R320 専用、X10DRT-P は対象外
- **`ib-switch` / `dell-fw-download` / `tftp-server` / `playwright`**: サーバ非依存、修正不要
- **`config/linstor.yml`**: LINSTOR 未参加のため変更なし
- **`scripts/*`**: サーバ番号ハードコードなし、`config/server<N>.yml` 経由で動作
- **`.claude/settings.local.json` / `settings.local.example.json`**: 現状 4-6号機分の preseed-server*.cfg sha256sum エントリは存在しないため、10号機分も追加不要 (server7-9 のみ既存だが、これは iDRAC 別管理 preseed 専用)

## 重要ファイルパス

- `config/server4.yml` — 雛形元 (Supermicro Lego)
- `config/server7.yml` — 参考 (iDRAC 系の差分理解用、変更しない)
- `ssh/config` — pve4-6 エントリと同パターンで pve10 追加
- `CLAUDE.md` L36-54 — サーバ一覧
- `README.md` L89-149, L153-210 — 対応ハードウェア・サーバ一覧・mermaid 図
- `/home/ubuntu/.claude/projects/-home-ubuntu-projects-pvese/memory/MEMORY.md` — auto-memory のサーバ情報表
- `.claude/skills/os-setup/SKILL.md` L36-49 — Platform Dispatch (修正不要、確認のみ)

## 既存資産の再利用

- `scripts/bmc-session.sh`, `scripts/bmc-virtualmedia.sh`, `scripts/bmc-power.sh`, `scripts/bmc-kvm.sh` (Supermicro CGI/Redfish 系) — `bmc_type: supermicro` の判別で自動利用
- `scripts/generate-preseed.sh`, `scripts/remaster-debian-iso.sh` — 既存テンプレートを使用
- `scripts/os-setup-phase.sh` — フェーズ管理は config 非依存
- `os-setup` スキル本体 — Platform Dispatch ロジックで `server10.yml` を読み込み既存処理に分岐

## 検証方法

1. `./bin/yq '.bmc_ip' config/server10.yml` → `10.10.10.30`
2. `./bin/yq '.hostname' config/server10.yml` → `ayase-web-service-10`
3. `./bin/yq '.bmc_type' config/server10.yml` → `supermicro`
4. `ipmitool -I lanplus -H 10.10.10.30 -U claude -P Claude123 chassis status` — BMC 疎通確認 (BMC が `claude`/`Claude123` に初期化されている前提。出荷状態の場合は手動でユーザ作成が必要)
5. ドキュメント反映確認: 各ファイルを Grep ツールで検索し `10\.10\.10\.30`, `10\.10\.10\.210`, `server10`, `ayase-web-service-10`, `pve10`, `X10DRT-P` がそれぞれ期待通りの位置にあること
6. (本プラン範囲外、別タスク) OS インストール: `/os-setup config/server10.yml` を実行
7. (OS インストール後) `ssh -F ssh/config pve10 hostname` で `ayase-web-service-10` が返ること

## 注意点

- **NIC 名・serial_unit・disk は X11DPU 想定の仮値**。OS 初回起動時に `ip link` と KVM コンソールで確認し、異なれば `config/server10.yml` を修正してから `/os-setup` を再実行
- **BMC 認証** は他サーバと同じ慣例 `claude` / `Claude123` を記載。BMC が出荷状態の場合は事前に CGI/Web UI でユーザ作成が必要 (既存スキル外、手動)
- **LINSTOR/IB は未参加**。本プラン完了後、実機の IB ポート有無と物理接続を確認した上で別タスクで `config/linstor.yml` への追加可否を決定する
- **`bios-setup` スキルは X11DPU 専用のまま**。X10DRT-P で BIOS 設定変更が必要になった場合は、別タスクで実機の BIOS UI を KVM スクリーンショットで確認し、UI 互換なら SKILL.md の対応サーバ表に追記、非互換なら専用 reference を作成
- **OS インストールは本プラン範囲外**。本プランの完了条件は「ファイル整備のみで `os-setup` スキルから 10号機が見えるようになる」までとする
