# 10号機 (X10DRT-P) OS セットアップ + VLAN 対応化

## Context

10号機 (Supermicro X10DRT-P, Nutanix NX-1065-G5 OEM) は `config/server10.yml` を整備済みで、BMC アクセス・BIOS 操作の準備は完了している。本タスクでは Debian + Proxmox VE をインストールし、PVE クラスタで利用可能な状態にする。

ただし他サーバ (4-9号機) と異なり、10号機のホスト LAN は **1本の VLAN trunk** (両 VLAN タグ付き) で配信されている。さらに **10号機は別拠点に設置されている** ため、共通なのは `10.0.0.0/8` 側だけで、インターネット側のサブネットは 4-9号機と異なる可能性が高い:

| VLAN ID | サブネット | 用途 | ゲートウェイ | インターネット |
|---------|----------|------|------------|---------------|
| `1120` | **DHCP で配布 (4-9号機の `192.168.39.0/24` とは別の可能性)** | apt/外部通信 | DHCP 通知 (動的取得) | 可 |
| `1083` | `10.0.0.0/8` (4-9号機と共通) | 管理 (SSH/PVE API) | `10.10.10.1` | 不可 |

> **重要**: VLAN 1120 のサブネット・ゲートウェイは静的に決め打たず、DHCP 取得結果から動的に判定する。スクリプト・config に `192.168.39.x` をハードコードしない。既存の `pre-pve-setup.sh` には DHCP GW 動的検出 (L83-85: `ip route show dev <iface> | grep 'default via'`) が既にあるので流用可能。

BMC (`10.10.10.30`) は IPMI 専用ポートで届くため host NIC とは独立 (今回の調査対象外)。host NIC のうちどれが trunk ケーブル接続点かは **未調査**。既存の `os-setup` スキル系スクリプトは VLAN 非対応なので、(1) 物理ポート調査、(2) 既存スクリプトを VLAN 対応に拡張、(3) OS インストール実施、の3段で進める。

LINSTOR 未参加・IB 接続性未確認のため、IB セットアップは本タスクのスコープ外 (既存 SKILL も「IB 搭載サーバのみ」分岐済み)。

## アプローチ全体像

| Phase | 目的 | pve-lock |
|-------|------|---------|
| 0 | 物理ポートと VLAN 構成の実測 (rescue shell) | 不要 |
| A | VLAN 対応のためのスクリプト/preseed/config 拡張 | 不要 |
| B | os-setup スキル Phase 1-8 (Debian + PVE インストール) — iter1 | Phase 4-8 で必要 |
| D | iter2-3 を実行してスキル安定化 (反復で発見した不具合をスクリプトに還元) | Phase 4-8 で必要 |
| C | レポート作成 | 不要 |

---

## Phase 0: 物理ポート/VLAN 構成の実測

**目的**: trunk ケーブルが繋がっている host NIC を特定し、VLAN 1120/1083 の到達性を確認する。

**手段**: 既存の Debian stock ISO (`/var/samba/public/debian-13.3.0-amd64-netinst.iso` — Phase 1 でダウンロード済みの想定。未ダウンロードなら先に取得) を **preseed なしのまま** VirtualMedia でマウント、Expert Install のタイミングで Alt+F2 でシェルに降りて実測する。

### 0.1 既存スキルの活用

- ISO マウントと Power Cycle: `bmc-session.sh` + `bmc-virtualmedia.sh` + `bmc-power.sh boot-next` (既存)
- KVM スクリーンショット + キーストローク: `bmc-kvm-screenshot.py` + `bmc-kvm-interact.py` (既存、`bios-setup` スキルが使用しているもの)

### 0.2 手順

1. **ISO 準備**: stock ISO がローカルになければ `config/server10.yml` の `debian_iso_url` から SMB share 配下にダウンロード (sha256 検証)。preseed リマスター ISO ではなく **生 ISO** を使う
2. **VirtualMedia マウント**: SMB から stock ISO (`debian-13.3.0-amd64-netinst.iso`) を `bmc-virtualmedia.sh config/mount/verify`
3. **Power cycle + GRUB 操作**: `bmc-power.sh cycle`、KVM スクリーンショットで GRUB メニュー出現を確認後、`bmc-kvm-interact.py sendkeys` で `Advanced options → Expert install` を選択
4. **Expert install で前進**: "Detect network hardware" まで進め、NIC 列挙画面を KVM で読む。ここで host NIC の論理名 (例: `eno1np0`/`eno2np1`/`enp1s0` 等) を確認
5. **シェル降下**: `Ctrl+Alt+F2` (KVM の send keys で送信) で busybox シェルに降りる
6. **link 状態の実測**:
   ```sh
   ip -brief link            # 各 NIC の link state
   ethtool <iface>           # link up な物理 NIC の詳細 (cable/speed/duplex)
   ```
7. **VLAN 到達性テスト** (link up な物理 NIC を `$PHY` とする):
   ```sh
   modprobe 8021q
   # VLAN 1120 (DHCP) テスト — サブネットは未知なので動的判定
   ip link add link "$PHY" name "$PHY.1120" type vlan id 1120
   ip link set "$PHY" up && ip link set "$PHY.1120" up
   udhcpc -i "$PHY.1120" -n -q     # 一発取得を試行 (lease を観察)
   # → inet が付けば 1120 配信あり。サブネット/GW は表示された値を記録する
   ip -4 addr show "$PHY.1120"
   ip route show dev "$PHY.1120"
   GW=$(ip route show dev "$PHY.1120" | awk '/^default/ {print $3}')
   ping -c 2 -W 2 "$GW"            # 動的取得した GW へ到達確認
   ping -c 2 -W 2 8.8.8.8          # 外部到達確認 (任意、firewall 次第)
   # VLAN 1083 (静的) テスト — 10.0.0.0/8 共通なので 10.10.10.1 で確認
   ip link add link "$PHY" name "$PHY.1083" type vlan id 1083
   ip link set "$PHY.1083" up
   ip addr add 10.10.10.210/8 dev "$PHY.1083"
   ping -c 2 -W 2 10.10.10.1       # 内部 GW 到達 (= 1083 配信確認)
   ```
   観察値 (`$PHY.1120` の inet/GW、サブネット幅) は Phase 0 の発見ノートに必ず記録する (後段の MEMORY/レポートに反映)。
8. **シェル操作の実装**: 各コマンドを `bmc-kvm-interact.py sendkeys --string "<cmd>" --press Return` の連続として送信し、`bmc-kvm-screenshot.py` で結果を撮影。`tmp/<sid>/phase0-<step>.png` に保存して目視確認
9. **片付け**: シェルで `poweroff` を発行 (もしくは `bmc-power.sh forceoff`) → `bmc-virtualmedia.sh umount`
10. **結果記録**: `tmp/<sid>/phase0-findings.md` に
    - link up な物理 NIC 名 (`$PHY`)
    - 1120 / 1083 の到達確認結果
    - X10DRT-P での実際の NIC 命名規則 (X11DPU と同じ `enoNnpM` 系か、enpXsY 系か)

> **判定ロジック**: link up な物理 NIC が複数あれば、それぞれで上記テストを行い、両 VLAN を同時に通せる NIC のみ「trunk 線」と認定する。1本 trunk 前提なので想定的には 1 NIC のみ link up。

> **失敗パターンへの対処**: VLAN 1120 で DHCP が来ない場合は、1083 untagged で来ている可能性 (回答が「1本 trunk」でも実態が異なる可能性) を考慮し、untagged DHCP (`udhcpc -i $PHY`) も試す。

### 0.3 完了条件

- `vlan_iface` (例: `eno1np0`) が確定
- 1120 で DHCP 取得成功 + 取得 GW へ到達、1083 で `10.10.10.1` 疎通、両方が成功
- 1120 側のサブネット/GW (= 4-9号機と異なる可能性のある拠点固有値) を実測記録
- 結果を Phase A の `config/server10.yml` 更新と MEMORY 追記に渡せる

---

## Phase A: VLAN 対応のためのスクリプト/preseed 拡張

**設計方針**: VLAN フィールドが config にあれば VLAN 動作、無ければ従来動作 (4-9号機を壊さない後方互換)。

### A.1 `config/server10.yml` 更新

Phase 0 の結果を反映:

```yaml
# 既存フィールドの修正
static_iface: vmbr0      # PVE インストール後のホスト IP は vmbr0 上 (1083 タグ vlan を bridge した先)
dhcp_iface: vmbr1        # DHCP も vmbr1 上 (1120 タグ vlan を bridge した先)

# VLAN 設定 (新規、optional)
vlan_iface: <Phase 0 で確定した物理 NIC>   # trunk が来ている物理 NIC
internet_vlan_id: 1120
internal_vlan_id: 1083
```

> **注**: 既存値 `static_iface: eno2np1` / `dhcp_iface: eno1np0` は VLAN 環境では意味が変わる。物理 NIC 名は新フィールド `vlan_iface` で表現する。

### A.2 `preseed/preseed.cfg.template` 拡張

- `d-i preseed/early_command` を追加 (テンプレ展開後、VLAN なら VLAN setup コマンド、VLAN 無しなら空) — 新プレースホルダ `%%EARLY_CMD%%`
- `d-i netcfg/choose_interface select %%CHOOSE_INTERFACE%%` (VLAN ありなら `<phy>.<internet_vlan>`, 無しなら `auto`)
- `late_command` の `/etc/network/interfaces` 追記部分を VLAN 対応に拡張: VLAN ありなら 8021q モジュール永続化 (`/target/etc/modules` に `8021q` 追記) + VLAN サブインタフェース定義 + 1083 サブに静的 IP

VLAN 時の early_command (テンプレ展開後の例):
```
modprobe 8021q; \
ip link set <phy> up; \
ip link add link <phy> name <phy>.<internet_vlan> type vlan id <internet_vlan>; \
ip link set <phy>.<internet_vlan> up
```

### A.3 `scripts/generate-preseed.sh` 拡張

- yq で `vlan_iface`, `internet_vlan_id`, `internal_vlan_id` を読み取り (空なら VLAN 無し動作)
- VLAN 有り/無しで `EARLY_CMD`, `CHOOSE_INTERFACE`, `STATIC_IFACE_INSTALLED` (late_command 用) を切替えて sed 展開

### A.4 `scripts/pve-bridge-setup.sh` 拡張

- 新フラグ追加: `--vlan-iface <phy>`, `--internet-vlan-id <N>`, `--internal-vlan-id <N>`
- VLAN 指定がある場合の `/etc/network/interfaces` テンプレ:
  ```
  auto <phy>
  iface <phy> inet manual

  auto <phy>.<internal_vlan>
  iface <phy>.<internal_vlan> inet manual
      vlan-raw-device <phy>

  auto <phy>.<internet_vlan>
  iface <phy>.<internet_vlan> inet manual
      vlan-raw-device <phy>

  auto vmbr0
  iface vmbr0 inet static
      address <static_ip>/<mask>
      bridge-ports <phy>.<internal_vlan>
      bridge-stp off
      bridge-fd 0

  auto vmbr1
  iface vmbr1 inet dhcp
      bridge-ports <phy>.<internet_vlan>
      bridge-stp off
      bridge-fd 0
  ```
- VLAN 指定が無ければ既存ロジック (物理 NIC 直結) に従う
- `--static-iface` / `--dhcp-iface` は VLAN 非指定時のみ必須に変更 (VLAN 時は無視)
- 8021q モジュール永続化 (`echo 8021q >> /etc/modules` 冪等)

### A.5 `scripts/pre-pve-setup.sh` の動作確認

- `--dhcp-iface <phy>.<internet_vlan>` を渡せば、`ifupdown` の VLAN サポート (`auto <phy>.1120` を /etc/network/interfaces に書く) で動作する想定。preseed の late_command で書き込んでおけば追加変更不要
- **GW 動的検出は L83-85 で既に実装済み** (`ip route show dev <iface> | grep 'default via'`)。10号機の VLAN 1120 GW (4-9号機の 192.168.39.1 とは別拠点で異なる値) でもこのロジックがそのまま通る。`192.168.39.1` をハードコードしている箇所は無い (L85 のフォールバックは DHCP iface のサブネット末尾を `.1` に置換する汎用ロジック)
- 念のため: VLAN サブインタフェース指定時に `ip link show <iface>` で存在確認、無ければ `ip link add` で動的追加 → `ifup`、というフォールバックを入れるかどうかは Phase B 実行時の挙動を見て判断 (まずは現状のまま試す)

### A.6 SKILL 更新 (`os-setup/SKILL.md`)

- Platform Dispatch 表に「VLAN 環境」の節を追加 (10号機の例として)
- Phase 0 (調査) は SKILL のフェーズには含めず、本プランで一回限りの作業とする (将来 VLAN サーバ追加時は MEMORY と本レポートを参照)

### A.7 `MEMORY.md` 更新

- 10号機の VLAN 構成 (1120/1083 trunk, vlan_iface = `<確定値>`) を追記
- **10号機は別拠点設置で VLAN 1120 のサブネット/GW は 4-9号機と異なる** ことを明記し、Phase 0 で実測した値 (サブネット/GW) を記録
- 既存「ネットワーク」表に「10号機は VLAN trunk・別拠点」を補注

### A.8 検証

```sh
./bin/yq '.vlan_iface' config/server10.yml
./bin/yq '.internet_vlan_id' config/server10.yml
./scripts/generate-preseed.sh config/server10.yml /dev/stdout | grep -E 'early_command|choose_interface|8021q|vlan'
```

---

## Phase B: OS インストール (os-setup Phase 1-8)

`os-setup` スキルを `config/server10.yml` で実行。VLAN 対応は Phase A で済んでいる前提。

| Phase | 内容 | 注意点 |
|-------|------|--------|
| 1: iso-download | Debian ISO 取得 | Phase 0 でダウンロード済みなら hash 検証のみ |
| 2: preseed-generate | VLAN 対応 preseed 生成 | Phase A の generate-preseed.sh を使用 |
| 3: iso-remaster | preseed を初期 ISO に注入 | UEFI + Legacy dual。Supermicro なので initrd 注入される |
| 4: bmc-mount-boot | VirtualMedia + Boot Next | 既存ロジック。`pve-lock.sh wait` |
| 5: install-monitor | SOL 監視 | syslog receiver 起動。stage 観測必須 |
| 6: post-install-config | SSH 鍵配置 + machine-id 検証 | SOL 経由。VLAN trunk 上で SSH (`vmbr0`) 経由で接続できるはず |
| 7: pve-install | PVE 本体インストール + リブート | VLAN サブ (`<phy>.1120`) で apt が通るか要確認。pre-pve-setup.sh を VLAN 対応で呼ぶ |
| 8: cleanup | bridge セットアップ + 検証 | VLAN 対応 pve-bridge-setup.sh を呼ぶ。**IB セットアップはスキップ** (linstor 未参加) |

> Phase 7 で `pre-pve-setup.sh --dhcp-iface <phy>.1120` を呼ぶ。その時点で preseed late_command により `/etc/network/interfaces` に VLAN サブが定義済みであるはず (A.2 で実装) なので `ifup <phy>.1120` がそのまま動く想定。
>
> Phase 8 の bridge セットアップは VLAN フラグ付きで `pve-bridge-setup.sh --vlan-iface <phy> --internet-vlan-id 1120 --internal-vlan-id 1083 --static-ip 10.10.10.210/8` を呼ぶ。

### B.1 想定リスク

- **trunk 1本だと管理 IP と DHCP IP が同じ物理ケーブル経由**: ケーブル不具合で全断する単一障害点。実測完了まで気付けない (許容)
- **NIC 命名違い**: X10DRT-P が X11DPU と異なる命名規則の可能性 → Phase 0 で確定済みなのでケアされる
- **VLAN サブインタフェースで DHCP route 取得が遅い**: `pre-pve-setup.sh` の DHCP wait は最大 30 秒。VLAN ロード遅延あればタイムアウト → 必要なら `dhcp_max` を増やす (固有変更不要、現行の dhclient フォールバックで吸収できる想定)
- **拠点固有 GW が 4-9号機と違う**: VLAN 1120 で取得される GW が `192.168.39.1` 以外。`pre-pve-setup.sh` は GW を動的検出するので問題ないが、Phase 7 のインターネット到達確認 (`ping deb.debian.org`) が失敗する場合は拠点側 firewall/NAT 設定の可能性があるため、その時点で別途調査する (本タスクスコープ外)

---

## Phase D: スキル安定化 (反復セットアップ × 3)

**目的**: VLAN 対応で新たに加えた早期 VLAN 設定 (preseed early_command, generate-preseed.sh, pve-bridge-setup.sh の subinterface 経路) が冪等・再現可能で安定して通ることを、繰り返し実行で検証する。1反復は約 30-50 分。

> 既存 4-9号機でも iter10 規模の反復で SKILL を磨いてきた経緯がある (例: `report/2026-04-06_071801_server4_bios_reset_os_setup_iter10.md`)。10号機は新規 VLAN 経路を含むので、最低 iter3 までで安定性を確認する。

### D.1 1反復のサイクル

各反復で以下を行う:

1. **状態リセット**:
   ```sh
   rm -rf state/os-setup/server10
   ./scripts/os-setup-phase.sh init --config config/server10.yml
   ```
2. **Power Off + VirtualMedia アンマウント** (前反復のクリーンアップ):
   ```sh
   ./pve-lock.sh wait ./scripts/bmc-power.sh forceoff 10.10.10.30 claude Claude123
   # bmc-virtualmedia.sh umount は前回 Phase 8 で実施されている想定だが、念のため再実行
   ```
3. **iso-download / preseed-generate / iso-remaster は再実行**:
   - iso-download は sha256 一致でスキップ (キャッシュ)
   - preseed-generate は config 値が変わっていなければ同一出力、ハッシュ照合で iso-remaster もスキップ
   - 反復ごとに preseed/scripts を直していれば自然に再生成される
4. **Phase 4 (bmc-mount-boot) 〜 Phase 8 (cleanup) を順次実行**
5. **完了後の検証**:
   - `os-setup-phase.sh status --config config/server10.yml` → 全 phase done
   - `os-setup-phase.sh times --config config/server10.yml` で所要時間を記録
   - `ssh -F ssh/config pve10 pveversion`、`ip -brief addr`、`ip -d link show type vlan`
6. **問題があれば**:
   - 該当スクリプト・preseed を修正
   - 次反復で再現性確認
7. **反復ログ**: `tmp/<sid>/iter<N>-summary.md` に要点を残す (時間・発見事項・修正箇所)

### D.2 反復目標

| 反復 | 目標 | 中断条件 |
|------|------|---------|
| iter1 (= Phase B 本体) | まず通す。発生した問題は記録して修正可否を判断 | 致命的問題のみ中断、それ以外は次反復で対処 |
| iter2 | iter1 の修正を反映し、無修正で通ること (= 自動再現性) を確認 | クラッシュレベル問題で中断 |
| iter3 | iter2 と同じく無修正で通ることを再確認 (= 安定) | 同上 |

> **連続 2 反復が無修正で完走した時点で「安定化」とみなす**。iter3 で新規問題が出たら iter4 を追加する判断は反復実行中にユーザに相談する。

### D.3 反復間で触る/触らない

- 触る: `preseed/preseed.cfg.template`, `scripts/generate-preseed.sh`, `scripts/pve-bridge-setup.sh`, `scripts/pre-pve-setup.sh`, `config/server10.yml`, `.claude/skills/os-setup/SKILL.md`
- 触らない (反復で問題が出れば触る): `scripts/bmc-*`, `scripts/sol-*`, `scripts/os-setup-phase.sh`, `scripts/remaster-debian-iso.sh` (既存の安定動作部分)
- BIOS リセット: 不要 (bios-setup スキル拡張で X10DRT-P 対応済み、現状の BIOS 状態で OS インストールが通る前提)

### D.4 反復間の注意

- **VirtualMedia mount lock**: 各反復の Phase 4 開始前に `bmc-virtualmedia.sh status` を確認、Inserted=true ならまず umount。前反復が umount せずに終了した場合に備える
- **state ディレクトリ**: 反復ごとに完全削除して `init` し直す。`reset` での部分リセットだと cleanup の bridge 設定が累積する可能性
- **ホスト鍵**: 各反復で `ssh-keygen -R 10.10.10.210 -f ssh/known_hosts` を実行し、再インストール後の鍵不一致エラーを避ける (`os-setup` SKILL Phase 6 step 4 で実行する仕様だが、反復前に念押し)
- **machine-id 検証**: 既存 SKILL Phase 6 step 5 の False positive 防止ロジック (install-monitor 開始時刻より新しい /etc/machine-id mtime を確認) は反復のたびに新規時刻が記録されるので素直に動作する

---

## Phase C: レポート作成

3反復完了 (もしくは安定化判定が出た) 時点で `report/<timestamp>_server10_os_install.md` に以下を記録:

- Phase 0 の実測結果 (NIC 一覧、link 状態、VLAN 到達性、1120 で取得した拠点固有のサブネット/GW)
- 既存スクリプトに加えた VLAN 対応差分の要約
- 各反復の `os-setup-phase.sh times` 出力 + 反復間で見つけた不具合と修正履歴
- 安定化判定 (iter2-3 が無修正で完走したか)
- リブート後の `pveversion`, `ip -brief addr show`, `ip -d link show type vlan`
- 残タスク (LINSTOR 参加可否、bios-setup での VLAN 対応など)

---

## 修正対象ファイル

| ファイル | 修正種別 |
|---------|---------|
| `config/server10.yml` | フィールド追加 (vlan_iface, internet_vlan_id, internal_vlan_id) + static_iface/dhcp_iface 値見直し |
| `preseed/preseed.cfg.template` | early_command + choose_interface + late_command 拡張、`%%EARLY_CMD%%` `%%CHOOSE_INTERFACE%%` プレースホルダ |
| `scripts/generate-preseed.sh` | VLAN フィールド読み取り + 条件分岐展開 |
| `scripts/pve-bridge-setup.sh` | `--vlan-iface` 系フラグ + サブインタフェース対応分岐 |
| `.claude/skills/os-setup/SKILL.md` | VLAN 環境の節追加 (短く) |
| `/home/ubuntu/.claude/projects/-home-ubuntu-projects-pvese/memory/MEMORY.md` | 10号機 VLAN 構成追記 |
| `report/<timestamp>_server10_os_install.md` | 新規 |
| `tmp/<sid>/phase0-*.png`, `phase0-findings.md` | 一時調査結果 (commit せず) |

## 触らないもの

- `scripts/pre-pve-setup.sh` (動作確認のみ。ifupdown の VLAN サポートで吸収できる想定)
- `scripts/pve-setup-remote.sh` (PVE 本体インストールはネットワーク中立)
- `scripts/remaster-debian-iso.sh` (kernel cmdline `netcfg/choose_interface=auto` のままで良い。preseed 内 `netcfg/choose_interface select` が後勝ちで上書きする d-i 仕様)
- `scripts/ib-setup-remote.sh` (LINSTOR 未参加の 10号機ではスキップ)
- `bios-setup` スキル (X10DRT-P 対応済み、VLAN とは独立)
- 既存サーバ (4-9号機) の config・preseed (VLAN 非指定なので動作不変)

## 再現手順 (要点)

```sh
# Phase 0: 実測
# stock ISO 取得 (Phase 1 と兼用)
./scripts/os-setup-phase.sh init --config config/server10.yml
./scripts/os-setup-phase.sh start iso-download --config config/server10.yml
# (curl で stock ISO ダウンロード)
# bmc-virtualmedia + bmc-power でブート → KVM 経由で expert install → Alt+F2 シェル
# 上記 0.7 のテストを実行 → vlan_iface を確定

# Phase A: 拡張実装
# (config/server10.yml, preseed.cfg.template, generate-preseed.sh, pve-bridge-setup.sh の編集)
./scripts/generate-preseed.sh config/server10.yml /tmp/test.cfg
grep -E 'early_command|choose_interface|vlan' /tmp/test.cfg

# Phase B (iter1): OS インストール
# 既存スキル呼び出し: /os-setup config/server10.yml
# 各 phase は os-setup-phase.sh next で自動進行

# Phase D (iter2-3): 反復
# 各反復ごとに状態リセット → Phase 4-8 再実行 → 完走確認
rm -rf state/os-setup/server10
./scripts/os-setup-phase.sh init --config config/server10.yml
ssh-keygen -R 10.10.10.210 -f ssh/known_hosts
# /os-setup config/server10.yml で再走

# Phase C: 検証
ssh -F ssh/config pve10 ip -brief addr
ssh -F ssh/config pve10 'ip -d link show type vlan'
ssh -F ssh/config pve10 pveversion
ssh -F ssh/config pve10 'ping -c1 deb.debian.org'
curl -sk https://10.10.10.210:8006 | head -3
```
