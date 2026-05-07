# preseed netcfg VLAN モード重複 IP 修正 + 10号機通しテスト レポート

- **実施日時**: 2026年5月2日 06:30 - 07:03 JST

## 添付ファイル

- [実装プラン](attachment/2026-05-02_070349_preseed_netcfg_vlan_overwrite_fix/plan.md)
- [late_command dry-run スクリプト](attachment/2026-05-02_070349_preseed_netcfg_vlan_overwrite_fix/sim-late.sh)
- [10号機 install-monitor SOL ログ](attachment/2026-05-02_070349_preseed_netcfg_vlan_overwrite_fix/sol-install-s10.log)

## 前提・目的

[前任レポート 2026-05-02_060639_server10_disk_first_boot_recovery.md](2026-05-02_060639_server10_disk_first_boot_recovery.md) の **最高優先度残タスク** と Issue #55 の対処。

VLAN trunk 構成 (10号機) で preseed インストールすると、d-i の `netcfg/get_ipaddress` directive が物理 NIC `eno1` に `iface eno1 inet static` ブロックを書き込み、その後 `late_command` が VLAN サブインタフェース定義を **append** するため、untagged `eno1` と `eno1.1083` の両方に `10.10.10.210/8` が重複して割り当てられる問題があった (Issue #55)。前回セッションでは running system 側を `tmp/s10vkbd/fix-interfaces.sh` で手動修正したが、preseed テンプレート側は未修正のため、再インストールすると同じ問題が再発する。

目的:
1. **テンプレート側を修正**して、再インストール時に**手動介入なしで** SSH 到達できる状態にする
2. 修正の自動再現性を**通しテスト** (Phase 1-8 完走) で実証する
3. 非 VLAN モード (4-9号機) を**回帰させない**ことを確認する

参照した過去レポート:
- [10号機 disk first boot 復旧 + VirtualKeyboard 経由キー送信実装](2026-05-02_060639_server10_disk_first_boot_recovery.md)
- [10号機 OS インストール (前任タスク)](2026-04-30_094039_server10_os_install.md)

## 環境情報

| 項目 | 値 |
|------|----|
| ホスト名 | `ayase-web-service-10` |
| BMC IP | `10.10.10.30` (ASPEED 2400 / Redfish 1.0.1 / FW 3.65 stock) |
| 静的 IP (内部) | `10.10.10.210/8` (`eno1.1083` = VLAN 1083) |
| インターネット側 | `eno1.1120` = VLAN 1120 (DHCP, 192.168.120.0/24) |
| Disk | `/dev/sda` = TOSHIBA THNSNJ240PCSZ 223.6G (LSI SAS HBA 経由) |
| BIOS | AMI Aptio 2.17.1249 / Boot Mode = LEGACY / LSI HBA OPROM = Enabled |
| OS | Debian 13.3 (Trixie) + PVE 9.1.9 (kernel 7.0.0-3-pve) |
| 設定ファイル | `config/server10.yml` |

## 修正内容

### 1. `scripts/generate-preseed.sh` — VLAN 分岐の `late_network` を上書き形式に変更

VLAN モード分岐 (lines 104-130) で、`/target/etc/network/interfaces` の最初の echo を **`>` (overwrite)** に変更。`source /etc/network/interfaces.d/*` と `lo` も含めた完全なファイルを書き直す。netcfg-written `iface eno1 inet static` ブロックがクロバーされ、netcfg-written content は残らない。

```sh
# 旧: 全行 >> (append) — netcfg が書いた eno1 static ブロックが残る
# 新: 2行目 > (overwrite) で全消去後、残りは >> で書き足す
late_network="echo 8021q >> /target/etc/modules; \
echo 'source /etc/network/interfaces.d/*' > ${NWFILE}; \
echo '' >> ${NWFILE}; \
echo 'auto lo' >> ${NWFILE}; \
echo 'iface lo inet loopback' >> ${NWFILE}; \
echo '' >> ${NWFILE}; \
echo 'auto ${vlan_iface}' >> ${NWFILE}; \
echo 'iface ${vlan_iface} inet manual' >> ${NWFILE}; \
... (VLAN サブインタフェースの定義は既存と同じ) ..."
```

非 VLAN モード分岐 (4-9号機) は無変更 — 既存の `>>` (append) のまま。

ヘッダコメント (lines 81-95) も「上書きが mandatory」「append-only だと static IP が両方に乗って SSH が壊れる」旨を明記して更新。

### 2. `preseed/preseed.cfg.template` — `%%LATE_NETWORK%%` 上のコメント更新

旧テンプレートでは `%%LATE_NETWORK%%` が説明コメント中にあり、awk substitution で comment 自体に `late_network` の値が展開されてしまう副作用があった (`preseed-generated-s10.cfg` line 127 のように、コメントが echo チェインで汚染)。コメントを `late_network block (substituted below)` に書き換えて、substitution token を除去 + VLAN/非 VLAN それぞれの挙動 (上書き vs append) を明記。

### 3. `preseed/preseed-generated-s10.cfg` — 再生成

修正後の `generate-preseed.sh` で再生成。`late_command` の echo チェインが `> /target/etc/network/interfaces` (overwrite) で始まるようになっている (line 145)。

## 再現方法

### Phase A: テンプレート修正と静的検証

```sh
# 1. preseed テンプレートを再生成
./scripts/generate-preseed.sh config/server10.yml preseed/preseed-generated-s10.cfg

# 2. late_command 抜き出し: > と >> の順序確認
grep '/etc/network/interfaces' preseed/preseed-generated-s10.cfg
# → echo 8021q >> /target/etc/modules; echo 'source ...' > /target/etc/network/interfaces; ...

# 3. 非 VLAN モード非リグレッション
./scripts/generate-preseed.sh config/server4.yml tmp/<sid>/preseed-s4.cfg
grep '/etc/network/interfaces' tmp/<sid>/preseed-s4.cfg
# → 全行 >> (append) のまま、> は使われていない

# 4. dry-run シミュレーション
sh tmp/<sid>/sim-late.sh
# → netcfg-written `iface eno1 inet static` ブロックがクロバーされ
#   eno1 manual + eno1.1120 dhcp + eno1.1083 static + lo の 4 ブロックのみ
```

### Phase B: 10号機通しテスト (os-setup 再インストール)

```sh
# Phase 3-8 (iso-remaster 以降) をリセットして fresh 再インストール
for ph in post-install-config install-monitor bmc-mount-boot iso-remaster; do
    ./scripts/os-setup-phase.sh reset $ph --config config/server10.yml
done

# Phase 3-5: ISO 再リマスター + VirtualMedia mount + install
# (`os-setup` スキルのフロー通り)

# Phase 6: disk first boot で SSH 到達 (本命検証)
./scripts/ssh-wait.sh 10.10.10.210 --timeout 240 --interval 10
# → 100 秒で connected (手動修正なし)

ssh -F ssh/config root@10.10.10.210 ip -br a
# → eno1 IP なし、eno1.1083 = 10.10.10.210/8 単独、eno1.1120 = 192.168.120.200/24

# Phase 7: pve-install
# RTC バッテリ切れの追加発見 → 起動直後の apt-get が GPG 署名エラー (Not live)
# 対策: epoch 同期 → systemd-timesyncd が NTP 同期して以降は問題なし
sh tmp/<sid>/sync-time-s10.sh    # date -s @<epoch>
ssh root@... sh /tmp/pre-pve-setup.sh --dhcp-iface eno1.1120 --static-gw 10.10.10.1 --codename trixie
ssh root@... /tmp/pve-setup-remote.sh --phase pre-reboot ...
ssh root@... reboot
ssh root@... /tmp/pve-setup-remote.sh --phase post-reboot ... --linstor   # LINSTOR は失敗するが proxmox-ve はインストール済み (10号機 LINSTOR 未参加なので無視)

# Phase 8: VLAN-aware bridge セットアップ
ssh root@... sh /tmp/pve-bridge-setup.sh --vlan-iface eno1 --internet-vlan-id 1120 --internal-vlan-id 1083 --static-ip 10.10.10.210/8
```

## 検証結果

### 1. 静的検証

| 項目 | 結果 |
|------|------|
| `scripts/generate-preseed.sh` VLAN 分岐: 1行目 `>` overwrite | ✅ |
| `scripts/generate-preseed.sh` 非 VLAN 分岐: 全行 `>>` append (無変更) | ✅ |
| `preseed/preseed-generated-s10.cfg` 再生成 line 145: `echo 'source ...' > /target/...` を含む | ✅ |
| `tmp/<sid>/preseed-s4.cfg` (非 VLAN): `>` overwrite を含まない (回帰なし) | ✅ |
| dry-run シミュレーション: netcfg-written `iface eno1 inet static` ブロックがクロバー | ✅ |
| dry-run: 結果が `tmp/s10vkbd/fix-interfaces.sh` の意図と等価 | ✅ |

### 2. 10号機通しテスト

| Phase | 所要時間 | 結果 |
|-------|---------|------|
| iso-download | 0m13s | ✅ (キャッシュ済み) |
| preseed-generate | 0m00s | ✅ |
| iso-remaster | 1m43s | ✅ (新 preseed で再リマスター) |
| bmc-mount-boot | 5m43s | ✅ (VirtualMedia mount + power cycle) |
| install-monitor | 6m06s | ✅ (SOL: INSTALLING_BASE → POWER_DOWN, PowerState=Off) |
| **post-install-config** | **3m51s** | **✅ disk first boot 後、手動修正なしで SSH 到達 (100秒)** |
| pve-install | 12m15s | ✅ (PVE 9.1.9 / kernel 7.0.0-3-pve) |
| cleanup | 0m26s | ✅ (vmbr0 + vmbr1 の VLAN-aware bridge 設定) |
| **合計** | **30m17s** | **完走** |

### 3. ネットワーク状態の検証

**Phase 6 (disk first boot 直後、bridge 未設定の状態)**:
```
lo               UNKNOWN        127.0.0.1/8 ::1/128
eno1             UP             fe80::ae1f:6bff:fe18:ff0/64                          ← IP なし (修正成功)
eno2             DOWN
eno1.1120@eno1   UP             192.168.120.200/24 ...                                 ← internet (DHCP)
eno1.1083@eno1   UP             10.10.10.210/8 fe80::ae1f:6bff:fe18:ff0/64             ← internal mgmt (static)
```

`/etc/network/interfaces`:
```
source /etc/network/interfaces.d/*

auto lo
iface lo inet loopback

auto eno1
iface eno1 inet manual

auto eno1.1120
iface eno1.1120 inet dhcp
    vlan-raw-device eno1

auto eno1.1083
iface eno1.1083 inet static
    address 10.10.10.210/8
    vlan-raw-device eno1
```

`ip route`:
```
default via 192.168.120.1 dev eno1.1120 proto dhcp src 192.168.120.200 metric 1004
10.0.0.0/8 dev eno1.1083 proto kernel scope link src 10.10.10.210
192.168.120.0/24 dev eno1.1120 proto dhcp scope link src 192.168.120.200 metric 1004
```

→ default route はインターネット側 VLAN 1120 経由 (CLAUDE.md 規定通り、10.0.0.0/8 をデフォルトGW にしていない)。

**Phase 8 (cleanup 完了、bridge 設定後)**:
```
vmbr0            UP             10.10.10.210/8                              ← bridge (eno1.1083 入り)
vmbr1            UP             192.168.120.200/24                          ← bridge (eno1.1120 入り)
```

PVE Web UI: `curl -sk https://10.10.10.210:8006` → HTTP 200。

## 副次発見

### 10号機 RTC バッテリ切れ

通しテスト中に発見した別問題: 10号機は**起動時に system clock が `2025-09-04 03:38` ごろにずれる** (RTC は `2015-01-03` を返す = CMOS バッテリ切れ)。NTP 同期が走るまで apt-get update が GPG 署名エラー (`Not live until 2026-...`) で失敗する。

```
$ ssh root@10.10.10.210 timedatectl  # 起動直後
       Local time: Thu 2025-09-04 03:38:37 JST
         RTC time: Sat 2015-01-03 11:01:23
System clock synchronized: no
      NTP service: n/a
```

systemd-timesyncd が NTP 同期したあと (DHCP→ネットワーク接続→数十秒) は問題なし。今回は `date -s @<epoch>` で手動同期して回避した (`tmp/<sid>/sync-time-s10.sh`)。

これは preseed netcfg 修正タスクのスコープ外だが、`pre-pve-setup.sh` の冒頭で時刻同期を行うようにすると、再インストール時の手動介入をさらに減らせる。新規 issue として登録する余地あり。

### LINSTOR セットアップ失敗

`pve-setup-remote.sh --linstor` は失敗 (exit 2、proxmox-headers-7.0.0-3-pve 不在等)。ただし 10号機は CLAUDE.md にて「LINSTOR 未参加 (IB 接続性確認後に決定)」と明記されており、本タスクのスコープ外。proxmox-ve 自体は正常にインストール完了。

## 関連ファイル

- 修正: `scripts/generate-preseed.sh` (VLAN 分岐の `late_network` を上書き形式に変更 + ヘッダコメント更新)
- 修正: `preseed/preseed.cfg.template` (`%%LATE_NETWORK%%` 上のコメントを substitution token 除去 + 挙動明記)
- 再生成: `preseed/preseed-generated-s10.cfg`
- Issue #55: done (このレポートで close)

## 残タスク

| 優先度 | 内容 |
|-------|------|
| 中 | **10号機 RTC バッテリ交換 or 起動時 NTP 強制同期** — 物理的な CMOS バッテリ交換が望ましいが、ソフト側で `pre-pve-setup.sh` 冒頭に `chronyd -q` 等を仕込めば運用回避可能。新規 issue 候補 |
| 中 | **`config/server10.yml` 注釈の修正** — `disk: /dev/sda` のコメント "SATA SSD on the LSI/onboard controller" は正確には "LSI SAS HBA 経由 (mpt3sas)"。SATA controller (PCH) ではない (前任タスクから継続) |
| 低 | **iter2-3 反復通しテスト** — 今回 1 サイクル完走を確認したが、preseed の自動再現性をさらに保証するなら 2-3 反復実施 |
| 低 | **bios-setup スキル reference.md** に LSI HBA OPROM 項目の詳細追記 (前任タスクから継続) |
