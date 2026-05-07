# preseed netcfg 修正 自動再現性検証 + ドキュメント整合化 レポート

- **実施日時**: 2026年5月2日 07:30 - 09:05 JST

## 添付ファイル

- [実装プラン](attachment/2026-05-02_090532_iter_test_preseed_netcfg/plan.md)
- [machine-id 検証スクリプト](attachment/2026-05-02_090532_iter_test_preseed_netcfg/check-machineid.sh)
- [Cycle 1 SOL ログ](attachment/2026-05-02_090532_iter_test_preseed_netcfg/sol-iter1.log)
- [Cycle 2 SOL ログ](attachment/2026-05-02_090532_iter_test_preseed_netcfg/sol-iter2.log)

## 前提・目的

[前任レポート 2026-05-02_070349_preseed_netcfg_vlan_overwrite_fix.md](2026-05-02_070349_preseed_netcfg_vlan_overwrite_fix.md) の **残タスク** 4 項目のうち、ユーザ指示により「10号機 RTC バッテリ交換 or 起動時 NTP 強制同期」**以外**の 3 項目に着手する。

| # | 残タスク | 優先度 | 本タスクで対応 |
|---|---------|--------|---------------|
| A | `config/server10.yml` 注釈の修正 (`/dev/sda` コメント) | 中 | ✅ |
| B | bios-setup スキル reference.md に LSI HBA OPROM 詳細追記 | 低 | ✅ |
| C | iter2-3 反復通しテスト (preseed 自動再現性) | 低 | ✅ (2サイクル) |
| D | 10号機 RTC バッテリ問題 | 中 | ❌ (除外) |

参照した過去レポート:
- [2026-05-02_070349_preseed_netcfg_vlan_overwrite_fix.md](2026-05-02_070349_preseed_netcfg_vlan_overwrite_fix.md) — preseed 修正の 1 サイクル目通しテスト
- [2026-05-02_060639_server10_disk_first_boot_recovery.md](2026-05-02_060639_server10_disk_first_boot_recovery.md) — LSI HBA OPROM Enabled 確認
- [2026-04-30_094039_server10_os_install.md](2026-04-30_094039_server10_os_install.md) — 10号機 初期セットアップ

## 環境情報

| 項目 | 値 |
|------|----|
| ホスト名 | `ayase-web-service-10` |
| BMC IP | `10.10.10.30` (ASPEED 2400 / Redfish 1.0.1 / FW 3.65 stock) |
| 静的 IP (内部) | `10.10.10.210/8` (`vmbr0` ← `eno1.1083` = VLAN 1083) |
| インターネット側 | `vmbr1` ← `eno1.1120` = VLAN 1120 (DHCP, 192.168.120.0/24) |
| Disk | `/dev/sda` = TOSHIBA THNSNJ240PCSZ 240GB (LSI SAS HBA 経由 / mpt3sas) |
| BIOS | AMI Aptio 2.17.1249 / Boot Mode = LEGACY / LSI HBA OPROM = Enabled |
| OS | Debian 13.3 (Trixie) + PVE 9.1.9 (kernel 7.0.0-3-pve) |
| 設定ファイル | `config/server10.yml` |

## 修正内容

### タスクA: `config/server10.yml` の disk コメント修正

旧:
```yaml
# Target disk - SATA SSD on the LSI/onboard controller (not NVMe).
# Verified 2026-04-30 via d-i shell: 240 GB sd 0:0:0:0 [sda].
# Nutanix NX-1065-G5 ships with SATA SSDs, NOT NVMe like the X11DPU servers.
disk: /dev/sda
```

新:
```yaml
# Target disk - SATA SSD behind the LSI SAS HBA (mpt3sas driver), not PCH SATA.
# Verified 2026-04-30 via d-i shell: 240 GB sd 0:0:0:0 [sda].
# Nutanix NX-1065-G5 ships with SATA SSDs, NOT NVMe like the X11DPU servers.
# NOTE: BIOS "LSI HBA OPROM" must be Enabled for Legacy disk first boot
# (see .claude/skills/bios-setup/reference.md, Issue #53).
disk: /dev/sda
```

意図:
- 「LSI/onboard controller」は曖昧で PCH SATA と誤解される可能性 → 「LSI SAS HBA 経由 (mpt3sas)」と明記。実際 BIOS 上で PCH SATA / sSATA は全 "Not Installed"
- LSI HBA OPROM Enabled が必須である事実を bios-setup reference.md / Issue #53 ヘクロスリファレンス

### タスクB: `.claude/skills/bios-setup/reference.md` の LSI HBA OPROM 項目を Why/How 追加で書き換え

旧 (4 行):
- オプション値、解説、現在値 (Disabled) のみ。なぜ Enabled が必要か / Disabled 時症状 / 変更手順なし

新 (約 20 行):
- 出荷時 default = Disabled、現在値 = Enabled (2026-05-02 変更)
- **Linux Legacy boot 必須**: 10号機 OS disk が LSI SAS HBA 配下 (mpt3sas) のため、Disabled だと disk が boot device に列挙されず disk first boot 不能
- **Disabled 時の症状**: Boot Override に PXE のみ / Hard Disk BBS Priorities が空 / Legacy Boot Order #5 backing 無し
- **Enabled への変更手順** (POST 中 Delete x60 → Advanced > PCIe/PCI/PnP Configuration > LSI HBA OPROM → Enabled → F4)
- 関連 Issue / レポート / メモリへの参照

メモリ `server10_lsi_hba_oprom.md` の内容を reference.md に取り込み、reference.md を BIOS 操作の唯一参照ポイントとして自己完結化。

### タスクC: 反復通しテスト 2 サイクル

`os-setup` スキル Phase 3-8 を 2 サイクル完走。各サイクル:
1. Phase 3-8 を `os-setup-phase.sh reset` でリセット (Cycle 1 のみ preseed-generate も reset、Cycle 2 は ISO 再利用)
2. Phase 4 (bmc-mount-boot) で VirtualMedia mount + power cycle
3. Phase 5 (install-monitor) で sol-monitor.py が POWER_DOWN 検出 → exit 0
4. Phase 6 (post-install-config): VirtualMedia umount → power on → SSH 到達待ち (本命検証点)
5. Phase 7 (pve-install): pre-pve-setup → pve-setup-remote (pre-reboot → reboot → post-reboot --linstor)
6. Phase 8 (cleanup): pve-bridge-setup.sh で vmbr0/vmbr1 を VLAN-aware bridge 化

## 再現方法

```sh
# タスクA: config 編集 (Edit ツール)
# タスクB: reference.md 編集 (Edit ツール)
# タスクC: 反復通しテスト

# 1. preseed 再生成 + ISO リマスター
./scripts/os-setup-phase.sh reset preseed-generate --config config/server10.yml
./scripts/os-setup-phase.sh reset iso-remaster --config config/server10.yml
./scripts/generate-preseed.sh config/server10.yml preseed/preseed-generated-s10.cfg
./scripts/remaster-debian-iso.sh /var/samba/public/debian-13.3.0-amd64-netinst.iso \
    preseed/preseed-generated-s10.cfg /var/samba/public/debian-preseed-s10.iso
sha256sum preseed/preseed-generated-s10.cfg | awk '{print $1}' \
    | tee /var/samba/public/debian-preseed-s10.iso.preseed-sha256

# 2. 各サイクル: Phase 3-8 リセット
./scripts/os-setup-phase.sh reset cleanup --config config/server10.yml
./scripts/os-setup-phase.sh reset pve-install --config config/server10.yml
./scripts/os-setup-phase.sh reset post-install-config --config config/server10.yml
./scripts/os-setup-phase.sh reset install-monitor --config config/server10.yml
./scripts/os-setup-phase.sh reset bmc-mount-boot --config config/server10.yml

# 3. Phase 4: VirtualMedia mount + cycle
./pve-lock.sh wait ./oplog.sh ./scripts/bmc-power.sh forceoff 10.10.10.30 claude Claude123
./scripts/bmc-session.sh login 10.10.10.30 claude Claude123 tmp/rainbow/bmc-cookie-s10
sh tmp/rainbow/vm-mount.sh   # bmc-virtualmedia.sh config + mount + verify
./pve-lock.sh wait ./oplog.sh ./scripts/bmc-power.sh on 10.10.10.30 claude Claude123

# 4. Phase 5: install monitor (POWER_DOWN まで)
python3 scripts/sol-monitor.py --bmc-ip 10.10.10.30 --bmc-user claude --bmc-pass Claude123 \
    --log-file tmp/rainbow/sol-cN-install.log --max-reconnects 3

# 5. Phase 6: VirtualMedia umount + disk first boot SSH 到達
./scripts/bmc-virtualmedia.sh umount 10.10.10.30 tmp/rainbow/bmc-cookie-s10 "$CSRF"
./pve-lock.sh wait ./oplog.sh ./scripts/bmc-power.sh on 10.10.10.30 claude Claude123
./scripts/ssh-wait.sh 10.10.10.210 --timeout 240 --interval 10

# 6. ネットワーク状態検証
ssh -F ssh/config root@10.10.10.210 ip -br a

# 7. machine-id 検証 (本セッションでは bmc-mount-boot.start を install-monitor.start に同期して通す)
sh tmp/rainbow/check-machineid.sh

# 8. Phase 7-8: PVE インストール + ブリッジ
scp -F ssh/config scripts/pre-pve-setup.sh root@10.10.10.210:/tmp/
ssh -F ssh/config root@10.10.10.210 sh /tmp/pre-pve-setup.sh --dhcp-iface eno1.1120 --static-gw 10.10.10.1 --codename trixie
scp -F ssh/config scripts/pve-setup-remote.sh root@10.10.10.210:/tmp/
ssh -F ssh/config root@10.10.10.210 /tmp/pve-setup-remote.sh --phase pre-reboot ...
ssh -F ssh/config root@10.10.10.210 reboot
./scripts/ssh-wait.sh 10.10.10.210 --timeout 300 --interval 10
scp -F ssh/config scripts/pve-setup-remote.sh root@10.10.10.210:/tmp/
ssh -F ssh/config root@10.10.10.210 /tmp/pve-setup-remote.sh --phase post-reboot ... --linstor
ssh -F ssh/config root@10.10.10.210 reboot
./scripts/ssh-wait.sh 10.10.10.210 --timeout 300 --interval 10
scp -F ssh/config scripts/pve-bridge-setup.sh root@10.10.10.210:/tmp/
ssh -F ssh/config root@10.10.10.210 sh /tmp/pve-bridge-setup.sh \
    --vlan-iface eno1 --internet-vlan-id 1120 --internal-vlan-id 1083 --static-ip 10.10.10.210/8
```

## 検証結果

### タスクA / B 静的検証

| 項目 | 結果 |
|------|------|
| `config/server10.yml` lines 39-44: "LSI SAS HBA (mpt3sas)" 表記 + LSI HBA OPROM 注記追加 | ✅ |
| `.claude/skills/bios-setup/reference.md` LSI HBA OPROM 項目: Why / Disabled 症状 / 変更手順 5 ステップ追加 | ✅ |
| 現在値 "Enabled (2026-05-02 変更、Issue #53)" に更新 | ✅ |

### タスクC 反復通しテスト結果

#### Phase 別所要時間

| Phase | Cycle 1 (40m34s 合計) | Cycle 2 (26m37s 合計) | 備考 |
|-------|----------------------|----------------------|------|
| iso-download | 0m13s | (skip) | キャッシュ済 |
| preseed-generate | 0m07s | (skip) | preseed 同一 |
| iso-remaster | 2m04s | (skip) | ISO 同一 (sha256 match) |
| bmc-mount-boot | 10m55s | 0m36s | C1 は POST code stale で診断時間込み (実進行は SOL で確認済) / C2 は短縮 |
| install-monitor | 12m29s | 10m42s | preseed 自動インストール完走 → POWER_DOWN |
| **post-install-config** | **4m09s** | **2m46s** | **本命検証点: 手動介入なしで SSH 到達** |
| pve-install | 10m11s | 9m54s | PVE 9.1.9 インストール (LINSTOR 失敗は仕様内) |
| cleanup | 0m26s | 0m15s | vmbr0/vmbr1 VLAN-aware bridge セットアップ |

#### 検証ポイント (両サイクル共通)

| ポイント | 期待値 | Cycle 1 | Cycle 2 |
|---------|--------|---------|---------|
| Phase 6 SSH 到達時刻 | 100-150s 以内 (手動介入なし) | **100s (attempt 11)** ✅ | **100s (attempt 11)** ✅ |
| `eno1` IP | なし (IPv6 LL のみ) | ✅ | ✅ |
| `eno1.1083` IP | `10.10.10.210/8` | ✅ | ✅ |
| `eno1.1120` IP | DHCP (`192.168.120.x/24`) | `192.168.120.200/24` | `192.168.120.200/24` |
| default route | `via 192.168.120.1 dev eno1.1120` | ✅ | ✅ |
| `/etc/network/interfaces` | 4 ブロック (lo / eno1 manual / eno1.1120 dhcp / eno1.1083 static)、append なし | ✅ | ✅ |
| machine-id mtime > install start | 真 (FALSE POSITIVE 検出ガード) | ✅ (20s 後生成) | ✅ |
| Phase 7 PVE インストール | `pve-manager/9.1.9` 起動 | ✅ | ✅ |
| Phase 8 vmbr0/vmbr1 | UP + 適切な IP | ✅ | ✅ |
| PVE Web UI | HTTP 200 | ✅ | ✅ |

#### Phase 6 ネットワーク状態 (両サイクル一致)

```
lo               UNKNOWN        127.0.0.1/8 ::1/128
eno1             UP             fe80::ae1f:6bff:fe18:ff0/64                  ← IP なし
eno2             DOWN
eno1.1120@eno1   UP             192.168.120.200/24 ...                       ← internet (DHCP)
eno1.1083@eno1   UP             10.10.10.210/8 ...                           ← internal mgmt (static)
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

→ Cycle 1 / Cycle 2 で完全一致。前任レポートで指摘された append-only による重複 IP は再発せず、preseed 修正 (Issue #55) の自動再現性が立証された。

#### Phase 8 最終ネットワーク状態

```
vmbr0            UP             10.10.10.210/8                ← bridge (eno1.1083 入り)
vmbr1            UP             192.168.120.200/24            ← bridge (eno1.1120 入り)
```

PVE Web UI: `curl -sk https://10.10.10.210:8006` → **HTTP 200** (両サイクル)

## 副次知見

### 1. RTC バッテリ問題が今回の 2 サイクルでは顕在化しなかった

前任レポートでは Phase 7 開始前に `date -s @<epoch>` 手動同期が必要だったが、本セッションでは両サイクルとも `timedatectl` が正しい時刻を返し、apt-get GPG エラーは発生しなかった:

```
$ ssh root@10.10.10.210 timedatectl
       Local time: Sat 2026-05-02 08:30:17 JST
         RTC time: Fri 2026-05-01 23:30:17     ← 正しい
System clock synchronized: no
```

仮説: 前任セッションで apt-get update が systemd-timesyncd の NTP 同期を経由 → `hwclock --systohc` で RTC に書き戻し → 以降の再起動で時刻が保持。RTC バッテリは完全に死んでいるのではなく劣化レベルで、短期間ならハードウェア保持可能。タスクD（RTC 完全対策）は別途継続課題。

### 2. BMC POST code API stale + KVM canvas stale を併発

Cycle 1 の Phase 4 で:
- POST code API が `0x01 SEC: Power on, reset detected` を 3 分以上返し続ける
- KVM screenshot が ISOLINUX 6.04 の banner を 3 回連続で同じ画像として返す

実際は SOL ログで installer (keyboard-configuration インストール中) が動作中だった。**SOL ログを最終的な真実として使用**し、KVM screenshot と POST code API は補助情報扱いとする運用が必要。

### 3. 10号機 BMC は Redfish BootOptions API 非対応

`./scripts/bmc-power.sh find-boot-entry` は exit 1 (BootOptions 404)。サーバ 10 (Nutanix OEM, Redfish 1.0.1, FW 3.65) は `BootOptions` collection を持たず、`/redfish/v1/Systems/1` の `BootSourceOverrideTarget@Redfish.AllowableValues` (`Cd`, `UefiCd` 等) のみ。

幸い、VirtualMedia mount 後の単純な power cycle で BIOS が CD を優先ブートするため、explicit な `boot-next` 指定は不要だった。前任レポート Phase 4 がこの動作を実証している。

### 4. Cycle 1 で os-setup-phase の install-monitor.start タイムスタンプ管理に注意点

Phase 4 の cycle で installer が即座に起動するため、Phase 5 (install-monitor) を後から `start` すると `install-monitor.start > /etc/machine-id mtime` となり Phase 6 の machine-id 検証が **誤って False Positive** を返す。本セッションでは `cp state/.../bmc-mount-boot.start state/.../install-monitor.start` で同期して回避。

→ os-setup-phase.sh または skill 側で「install-monitor.start = max(現在時刻, bmc-mount-boot.start)」のような補正を入れると安全。新規 issue 候補。

## 関連ファイル

- 修正: `config/server10.yml` (disk コメント明確化)
- 修正: `.claude/skills/bios-setup/reference.md` (LSI HBA OPROM 項目を Why/How 追記で再構成)
- Issue #56: 本レポートで close

## 残タスク / 継続課題

| 優先度 | 内容 |
|-------|------|
| 中 | **10号機 RTC バッテリ交換 or 起動時 NTP 強制同期** — タスクD として除外。今回 2 サイクルでは時刻保持されたが本質的な対策ではない。`pre-pve-setup.sh` 冒頭に `chronyd -q` 等を仕込むのが運用回避策 |
| 低 | **install-monitor.start タイムスタンプ補正** — Phase 5 を遅れて開始した場合の machine-id 検証 false positive を避けるため、`os-setup-phase.sh` に補正ロジック追加 (本レポートで発見) |
| 低 | **追加サイクル (3 回目以降)** — 必要に応じて将来別タスクとして実施 (現状 2 サイクルで再現性は十分立証) |
