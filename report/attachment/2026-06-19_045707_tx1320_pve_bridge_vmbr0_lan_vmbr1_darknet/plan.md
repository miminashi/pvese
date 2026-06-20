# TX1320 PVE ブリッジ構成 + フルセットアップやり直し

## Context

training-tx1320 (Fujitsu PRIMERGY TX1320 M3) に PVE をセットアップしたが、Linux
ブリッジ (vmbr0/vmbr1) が一切作られていなかった。現状のセットアップ経路
(`generate-preseed.sh` の dhcp ブランチ) は `/etc/network/interfaces` に
**フラットな物理 NIC を 2 本 (eno1/eno2 とも DHCP)** 書くだけで、PVE が前提とする
ブリッジ抽象を作らない (確認済み: `pve-setup-remote.sh` / `pre-pve-setup.sh` も
ブリッジを作らず、generate-preseed.sh 内の「pve-setup-remote が bridge に変換する」
というコメントは実体のない陳腐化記述)。

ゴール:
- **vmbr0 = LAN (192.168.33.0/24)** … `eno1` をブリッジ、**DHCP**
- **vmbr1 = 闇ネット (10.0.0.0/8)** … `eno2` をブリッジ、**静的 `10.1.4.16/8`** (ユーザ指定)

セットアップスキル (preseed 生成) をこのブリッジ構成を出力するよう修正し、その上で
RAID 初期化 → Debian install → PVE までフルでやり直す。

### 到達性の裏付け (調査結果)
- claude ホスト `ens19 = 10.1.6.1/8`、route `10.0.0.0/8 dev ens19 scope link`。
  → 箱の vmbr1 静的 `10.1.4.16/8` は同一 dark-net L2 上にあり **ARP で直接到達可能**
  (playground `10.1.6.6` と同セグメント)。`10.1.4.16` は ping 応答なし = 空き。
- 静的 IP 化により従来の「eno2 DHCP lease がリブートごとに変動 (#12)」「MAC で IP 再発見」
  という不確実性が消え、箱は**初回ディスクブートから恒久的に `10.1.4.16` に固定**される。
- vmbr0 (eno1) の DHCP が default route (192.168.33.1 → インターネット) を供給 → apt 用。
  vmbr1 は scope-link で 10.0.0.0/8 (host・playground) に直結 (gateway なし)。
  仮に DHCP 側に問題が出ても vmbr1 静的側は独立して上がるため**到達性が保証され、現状より堅牢**。

## 設計判断

**アプローチ: install 時 (preseed late_command) から最終的なブリッジ構成を書き込む。**
- 単一の真実источник (`generate-preseed.sh` が `/etc/network/interfaces` を所有) を維持。
- 「フラット → 後で変換」の過渡状態や追加リブートが不要。箱は初回ブートから正しい構成。
- 初回ブート時 (PVE/ifupdown2 導入前の素の Debian) にブリッジを上げるため
  **`bridge-utils` を preseed の pkgsel に追加**する (apt mirror から install 時に導入)。
  PVE 導入後は ifupdown2 が同じ interfaces 構文をそのまま管理する。
- 静的ブリッジは dhclient 非依存で最も単純・堅牢。

設定は新フラグ `bridge_setup: true` でゲートし、他ホストに無影響 (training_tx1320 は
唯一の dhcp-mode config だが明示ゲートで安全側に)。

## 変更ファイル

### 1. `config/training_tx1320.yml` — ブリッジ構成キー追加
```yaml
bridge_setup: true
secondary_bridge_address: "10.1.4.16/8"   # vmbr1 (eno2 / dark-net) static addr
```

### 2. `scripts/generate-preseed.sh` — dhcp ブランチをブリッジ出力に
- `bridge_setup` / `secondary_bridge_address` の config 読取り追加。
- dhcp+bridge_setup ブランチで vmbr0 (eno1, dhcp) + vmbr1 (eno2, static) を出力。
- `pkgsel_include` に `bridge-utils` 追加。陳腐化コメント更新。

### 3. `scripts/tx1320-pve-setup.sh` — 変更不要 (固定 10.1.4.16 を直接渡す)
### 4. ssh/config — `Host training-tx1320 10.1.4.16` 追加 (固定管理 IP の鍵提示)
### 5. スキル文書追従 (`.claude/skills/pxe-deploy/SKILL.md`)

## フルセットアップ実行手順
0. Preflight (BMC/playground ping、資材確認)
1. preseed 再生成 + playground 配置
2. BIOS HII KVM RAID Clear
3. iPXE-CD deploy
4. install 監視 (sol-monitor、storcli RAID10)
5. ディスクブート (boot-override Hdd + on)
5b. 到達性 sanity check (10.1.4.16)
6. PVE 通しセットアップ (`tx1320-pve-setup.sh config/... 10.1.4.16`)

## リスクと回復
- (R1) bridge-utils 依存 (未導入だと初回ブート不通 → SOL/KVM 回復)
- (R2) vmbr0 DHCP 起動遅延 (許容、vmbr1 static は独立)
- (R3) z-fix-default-route フック (no-op、既存挙動)

## 検証 (end-to-end)
pveversion / services / `/etc/network/interfaces` / `ip -br addr` / 8006=200 / RAID10 Optl。
