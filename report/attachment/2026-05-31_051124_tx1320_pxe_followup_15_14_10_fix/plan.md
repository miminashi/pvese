# TX1320 PXE 10-run 堅牢性検証 フォローアップ実装プラン

## Context

`report/2026-05-30_130726_tx1320_pxe_10run_robustness.md` の PXE install ×10 反復検証は **10/10 成功・再現性 100%** を実証したが、レポート末尾の「フォローアップ候補」3 点が未実施で残った。本タスクはこの 3 点を恒久対策としてコード/スキルに実装し、**実機 PXE install で検証**する。

- **#15** (主要失敗モード, 発生率 30%): d-i netcfg 中に eno2 (dark-net) link-up が起きると 2 NIC 分の IPv6 autoconfiguration timeout が累積、または DNS dialog でスタックし preseed GET が来ない。ForceOff+retry で回避できるが無人運用の信頼性を下げる。
- **#10**: `scripts/bmc-power.sh` の `redfish_patch` が PATCH 時にも `curl -skL` の `-L` を付けるため、boot-override が rc=52 (empty reply) で失敗。現状は tmp の直 curl スクリプトで回避していて恒久化されていない。
- **#14**: installed-system の eno2 が `allow-hotplug` のため、ケーブル既接続だと link-up イベント不発生で DHCP が 15 分以上遅延することがある。

**重要な技術的前提 (調査で確定)**: #15 の真の修正レバーは preseed 内の `netcfg/choose_interface` **ではなく PXE kernel cmdline の `interface=`** である。PXE 経路では preseed をネットワーク越しに取得するため、preseed をダウンロードする netcfg はその preseed が読まれる前に走り終わっており、preseed 内の choose_interface 指定は #15 (preseed GET 前の netcfg stuck) には間に合わない。cmdline `interface=eno1` で install NIC を固定すれば netcfg が eno2 を完全に無視し、dual-NIC IPv6 timeout を根本排除できる。

PXE NIC が eno1 である根拠: embed iPXE は gateway 付き lease を取得するまで再 DHCP する (`isset ${net0/gateway} || goto nogw`)。dark-net は gateway を通知しないため、install が成立する以上 PXE NIC (net0) は常に gateway-bearing な site LAN ポートである。物理配線は固定 (eno1=PCIe 03:00.0=site LAN / eno2=PCIe 04:00.0=dark-net, Phase 19 + 10 runs で一貫観測) なので PXE NIC = eno1 と確定できる。万一この前提が崩れた場合 (install NIC 名が eno1 でない) は、初回 attempt で preseed GET が来ないため検証で即座に検出でき、`interface=auto` へ revert すればよい。

## 変更内容

### 1. #10 — `scripts/bmc-power.sh` の `redfish_patch` から PATCH 時の `-L` を削除

`redfish_patch()` (L69-94):
- **L79** (ETag 取得 GET): `curl -skL` を **維持** (NX-3060-G5 11/12号機の末尾 `/` 301 リダイレクトに必要)。
- **L83** (ETag あり PATCH 実行): `curl -skL` → `curl -sk`。
- **L89** (ETag なし PATCH 実行): `curl -skL` → `curl -sk`。
- PATCH が 301 を follow すると body が失われ rc=52 になる旨のコメントを追記。

**他機種影響**: GET/POST/ETag-GET は `-L` 維持のため NX-3060-G5 の末尾 `/` リダイレクトは引き続き吸収。PATCH 自体は末尾 `/` なしで処理されるため無影響。これにより `./scripts/bmc-power.sh boot-override` が iRMC 単体で動作し、tmp の `boot-pxe.sh`/`boot-hdd.sh` 直 curl 回避が不要になる。

### 2. #14 — `scripts/generate-preseed.sh` の eno2 を `allow-hotplug` → `auto`

- **L243**: `echo 'allow-hotplug ${dhcp_secondary_iface}'` → `echo 'auto ${dhcp_secondary_iface}'`。
- L239-240 のコメントを更新 (link-up イベント非依存で起動時 DHCP を確実化、ケーブル既接続でも遅延しない。TX1320 の eno2 は常時 dark-net に接続済みのため `auto` の起動ブロックは問題にならない旨)。

**他機種影響**: この late_network ブロックは `network_mode=dhcp` かつ `dhcp_secondary_iface` 設定時のみ実行 (L230, L238)。該当は training-tx1320 のみ (server4-6 は `network_mode=static` で else 分岐、`dhcp_secondary_iface` 未設定)。よって無影響。

### 3. #15 — PXE cmdline で install NIC を eno1 に固定

**主対策 (cmdline)** — `.claude/skills/pxe-deploy/SKILL.md` の embed iPXE script (L136):
- `kernel ... interface=auto ...` → `interface=eno1` (= config `static_iface`)。
- 「iPXE script の落とし穴」または embed セクションに「dual-NIC host では install NIC を `interface=<static_iface>` で固定し、もう一方の NIC link-up による netcfg の IPv6 autoconfig 累積 timeout (#15) を排除する」旨を追記。
- 反復実行ログの落とし穴 #15 行を「恒久対策済み (cmdline `interface=eno1`)」に更新。

**副対策 (preseed) — virtual-media/NFS フォールバック経路向け** — `scripts/generate-preseed.sh` 非VLAN ブロック (L217):
- `choose_interface="auto"` を、`dhcp_secondary_iface` が設定されている場合のみ `choose_interface="$static_iface"` に。それ以外 (`dhcp_secondary_iface` 未設定) は従来通り `auto`。
- **この変更は PXE 経路の #15 を直接修正するものではない** (PXE では上記 cmdline `interface=eno1` が唯一の修正レバー)。狙いは 2 つ: (a) cmdline と preseed の choose_interface 値を eno1 に揃えて整合させる、(b) TX1320 の旧経路である virtual-media/NFS install (preseed が ISO ローカルにあり netcfg 前に読まれる) でも install NIC を eno1 に固定し、同様の dual-NIC 問題を予防する。
- PXE 経路では cmdline が netcfg 前に eno1 を seed 済みなので、preseed の同値指定は整合のみで害はない。`dhcp_secondary_iface` を持つのは TX1320 のみのため他機種は `auto` のまま無影響。

**operational (検証に必須)** — playground (10.1.6.6) 上の `tx1320-embed.ipxe` を同様に書き換え、`ipxe.efi` を再ビルド (`make ... EMBED=tx1320-embed.ipxe`) → `/var/www/html/ipxe.efi` へ配置 → OpenWrt 拠点 router の `/tmp/tftp/ipxe.efi` を `wget` で更新。OpenWrt 操作はユーザ側 UCI/SSH が必要な場合があるため、到達不能なら手順を提示して依頼する。

## 検証 (実機 PXE install)

前提インフラ稼働確認: BMC 10.254.254.9 Redfish 応答、playground 10.1.6.6 nginx、OpenWrt TFTP、拠点間 ping。

0. **#15 用 ipxe.efi 再ビルド + 再配置 (#15 検証の必須前提)**: playground の `tx1320-embed.ipxe` を `interface=auto` → `interface=eno1` に書き換え、`make ... EMBED=tx1320-embed.ipxe` で `ipxe.efi` を再ビルド → `/var/www/html/ipxe.efi` へ配置 → OpenWrt `/tmp/tftp/ipxe.efi` を新版で更新。**この再配置を行わないと旧 cmdline で boot され #15 検証が無意味になる**ため、install run の前に必ず完了させ、deploy 後の OEM screenshot/SOL で kernel cmdline に `interface=eno1` が乗っていることを確認する。OpenWrt 操作がユーザ権限を要する場合は手順提示して依頼。
1. **#10 単体確認**: 修正後の `./scripts/bmc-power.sh boot-override 10.254.254.9 claude Claude123 Pxe UEFI` が rc=0 で成功し BootSourceOverride が反映されること (tmp 直 curl 不要を確認)。
2. **preseed 再生成 + 配置**: `./scripts/generate-preseed.sh --pxe=http://10.1.6.6 config/training_tx1320.yml tmp/<sid>/training-tx1320.cfg` → playground `/var/www/html/preseed/` へ配置。eno2 が `auto`、choose_interface が `eno1` になっていることを生成物で確認。
3. **PXE install 反復 (3〜5 回)**: レポート再現方法の Step 0-9 シーケンスで install。ただし boot-override は tmp の `boot-pxe.sh`/`boot-hdd.sh` 直 curl ではなく **修正後の `./scripts/bmc-power.sh boot-override`** を使い、#10 修正を実フロー内でも実証する。各回:
   - **#15 検証**: 初回 attempt で preseed GET が ~3-4 分以内に来る (netcfg stuck せず)。30% 基準に対し retry 0 を目標。OEM screenshot/SOL で「Name server addresses」dialog や DETECTING_NETWORK stuck が出ないこと。
   - **#14 検証**: disk boot 後 eno2 DHCP が即時 (~数分以内) に取得され `ip neigh | grep 4c:52:62:14:de:f0` で IP 特定、15 分遅延が発生しないこと。
   - 完遂判定は nginx phonehome GET + SSH 到達 + RAID10 Optl 1.635 TB。
4. 結果を `pxe-deploy` SKILL.md の反復ログに追記し、新レポートを `report/` に作成。

**進捗の真の指標** (レポート踏襲): nginx access.log の preseed→storcli→phonehome GET 順序 + OEM screenshot。sol-monitor の PowerState=Off 単独や stage 検出は誤判定するため phonehome GET で確定。

## critical files

- `scripts/bmc-power.sh` (L79/L83/L89 `redfish_patch`) — #10
- `scripts/generate-preseed.sh` (L217 choose_interface, L243 eno2 auto) — #14/#15副
- `.claude/skills/pxe-deploy/SKILL.md` (L136 embed iPXE cmdline, 落とし穴 #15 表) — #15主
- playground `tx1320-embed.ipxe` + `ipxe.efi` 再ビルド (operational) — #15 検証
- `config/training_tx1320.yml` (`static_iface: eno1`, `dhcp_secondary_iface: eno2` — 参照のみ、変更なし)

## 留意点

- 全状態変更操作は `./oplog.sh` 経由、一時ファイルは `tmp/<sid>/`。
- `bmc-power.sh` 修正は `settings.local.example.json` の許可リスト影響なし (コマンド形は不変)。
- `git push` はしない。commit はユーザ確認の上。
- 検証 install は本番インフラ (playground/OpenWrt) 稼働が前提。OpenWrt の ipxe.efi 更新がユーザ操作を要する場合は手順提示して依頼。
