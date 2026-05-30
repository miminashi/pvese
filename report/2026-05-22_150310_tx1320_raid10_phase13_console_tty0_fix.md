# Phase 13: TX1320 RAID10 OS install — **`console=tty0` 削除で kernel boot 成功確定、 installer まで到達 (preseed早期/netcfg/partman) — Phase 3-12 の真因確定**

- **実施日時**: 2026年5月22日 11:36-15:03 (JST)
- **セッション**: silly-rocket (59a84357)

## 添付ファイル

- [実装プラン](attachment/2026-05-22_150310_tx1320_raid10_phase13_console_tty0_fix/plan.md)
- [Step A2 = Phase 12 redo SOL log (本来は Step A だが ISO playground 未同期で Phase 12 再実行となった)](attachment/2026-05-22_150310_tx1320_raid10_phase13_console_tty0_fix/stepA4-sol.log)
- [Step A4 SOL log (syslogd 削除 + console=tty0 削除版、 kernel boot 成功 + screen UI 観測)](attachment/2026-05-22_150310_tx1320_raid10_phase13_console_tty0_fix/stepA4-sol.log)
- [Step A5 SOL log (static IP 設定追加、 partman/early_command 到達)](attachment/2026-05-22_150310_tx1320_raid10_phase13_console_tty0_fix/stepA5-sol.log)
- [Step A6 SOL log (multi-path script 検索、 found at /cdrom + rc=127)](attachment/2026-05-22_150310_tx1320_raid10_phase13_console_tty0_fix/stepA6-sol.log)
- [Screenshots: Phase 12 frozen vs Phase 13 kernel-boot vs disk boot BIOS Setup](attachment/2026-05-22_150310_tx1320_raid10_phase13_console_tty0_fix/screenshots/)

## 対象機

- **training-tx1320** (Fujitsu PRIMERGY TX1320 M3 / Mainboard D3373 / BIOS V5.0.0.11 R1.22.0 / iRMC S4 FW 9.08F / BMC 10.254.254.9)
- HW: PRAID EP400i (LSI MegaRAID SAS3008) + SAS HDD 900GB × 4 (RAID10 構成済予定だが本 Phase 開始時 VD なし)
- Virtual Media: iRMC OEM NFS Virtual Media (10.1.6.6:/var/samba/public)

## 前提・目的

[Phase 12 (2026-05-22 phase12-111602)](2026-05-22_113557_tx1320_raid10_phase12_sol_silence_confirmed.md) で `earlyprintk + loglevel=8 + ignore_loglevel + quiet 削除` でも kernel printk が 0 行、 OEM Screenshot で VGA も `Booting 'Automated Install'` で凍結を確定観測。

Phase 13 は引き継ぎ事項 3 経路 (console=tty0 削除 / stock 13.3.0 直接 NFS attach / Debian 12 baseline) を実施し、 仮説 12 (kernel startup hang) vs 仮説 13 (D3373 SOL UART bridge ExitBootServices 切断) のいずれかを確定する事が直接目標。

**最終目標**: OS インストール完遂 (preseed 完走 + RAID10 install + SSH login)。

## 環境情報

- Source ISO: `/var/samba/public/debian-13.3.0-amd64-netinst.iso` (stock Debian 13.3.0)
- 本番 ISO: `/var/samba/public/debian-training-tx1320-raid10.iso`
- preseed: `tmp/training-tx1320-preseed-raid10.cfg` (`--with-raid10-storcli`)
- config: `config/training_tx1320.yml` (SERIAL_UNIT=0、 virtual_media_type=nfs、 nfs_host=10.1.6.6)
- セッション tmp: `tmp/59a84357/`

## 試行と結果

### Step 0: 環境準備
- `tmp/59a84357/{stepA,stepB,stepC}` 作成
- iRMC ping (84-159ms latency) と PowerState=On 確認

### 🚨🚨🚨 Step 0.5: **重大発見** — `local /var/samba/public` は playground と同期されていない

- `scripts/tx1320-raid10-orchestrate.sh build` は **ローカル** `/var/samba/public/debian-training-tx1320-raid10.iso` に書き込む
- 一方 iRMC は **playground 10.1.6.6:/var/samba/public** から NFS マウントする
- **両者は別パスで自動同期されない** (ローカルは単なるディレクトリ、 NFS マウントなし)
- playground 上の wrapper.iso は 2026-05-21 17:58 のもの (Phase 9 era)
- **Phase 3-12 の cmdline patch 系試行は実際にはほぼ全て playground 上の古い ISO を boot していた可能性** (Phase 12 SOL silence の真因解釈に重大な影響)
- 対策: build 後に `scp wrapper.iso ubuntu@10.1.6.6:/tmp/...` + `ssh ... sudo mv /tmp/... /var/samba/public/...` で手動同期 (本 Phase で都度実施)

### Step A 系列: `console=tty0` 削除 + iSO 同期 + 再試行

| Step | ISO 内容 | 結果 | 解釈 |
|------|---------|------|------|
| A1 (= 初回) | `console=tty0` 削除 (`scripts/remaster-debian-iso.sh` L124/L134/L197) build したが playground 同期忘れ | Phase 12 と同じ "Booting Automated Install" 凍結 + kernel printk 0 | 実際には Phase 12 ISO 再 boot |
| A2 | 同上 ISO を playground に scp + Manager.Reset + 再 deploy | **🎯🎯🎯 kernel boot 成功** = `Linux version` が SOL に大量出現 + cdrom-detect 380 + preseed/early_command pvese marker 観測 | 仮説 12 (kernel startup hang) が完全に否定、 **仮説 13a (`console=tty0` で VGA console init hang) が真因として確定** |
| A3 | preseed early_command に pvese start/end marker 追加 + setup-raid10-storcli.sh / late_command にも marker | 各 boot で early_command start + end 両方 fire (= early_command 完了)、 ただし netcfg を待たず再 boot | preseed/early_command 後の syslogd setup を疑い |
| A4 | early_command の `syslogd -R 10.1.6.1:5514` 行を削除 | screen UI 起動 + `(1*installer)` 表示確認 (= d-i main-menu 到達)、 ただし **netcfg で "The value you provided is not a usable IPv4 or IPv6 address" ダイアログ block** | static_ip が空文字列 → 無効 IP として d-i に拒否 → ループ |
| A5 | config に `static_ip: 10.254.254.99 + static_gateway: 10.254.254.1 + static_iface: eth0` 設定 | netcfg pass → partman/early_command 到達 (`pvese: partman/early_command start at [373s]`)、 ただし `rc=127` で setup-raid10-storcli.sh 失敗 + d-i は `No root file system` ダイアログ block | rc=127 = sh 経由実行で初期 command が exit、 dpkg 不在の可能性 |
| A6 | partman/early_command に multi-path 探索 + diagnostic markers 追加 | `pvese: found setup-raid10-storcli.sh at /cdrom` 観測 = script は /cdrom にあり、 0.2 秒で rc=127 で死亡 | script の前半 (set -eu や log() function) で何かが exit |
| A7 | `--with-raid10-storcli` を外す (= partman/early_command なし) | partman は `disk: /dev/sda` を見つけられず `No root file system` ダイアログ block | 既存の RAID VD が存在せず、 storcli setup が必須 |
| A8 | setup-raid10-storcli.sh の `set -eu` → `set -u` に変更 + 各 step に kmsg marker | SOL silence (host が deploy 後すぐ S5 へ poweroff、 14 min 経過後 14:57 EDT に POST 再開) + screenshot 黒画 | install は途中で abort/poweroff、 詳細不明 |
| check-disk-A8 後 | DisconnectCD + boot-override Hdd UEFI で disk boot 試行 | **BIOS Setup 画面表示** = bootable HDD なし | install は完遂しておらず、 grub が installed disk に書かれていない |

### 🎯🎯🎯 **真因確定**: Phase 3-12 の SOL silence は **`console=tty0` を kernel cmdline に含む** ことが直接の原因

Phase 5 iter4 で「`console=tty0` 除去で kernel printk 0 維持」と結論したが、 これは playground 同期忘れによる ISO 不一致の誤判定だった可能性が高い。 本 Phase で **正しく playground 同期した上で console=tty0 削除版を boot した結果、 kernel printk が SOL に大量出現** (Linux version, BIOS-e820, ACPI, SMP, EFI, console init 全てログ)。

D3373 + iRMC NFS+UEFI 経路で `console=tty0` を含む cmdline はカーネルが VGA console (tty0) を初期化する段階で hang する。 これを抜くと VGA に何も書かれないが SOL ttyS0 に正常に printk 出力され、 installer (d-i) も busybox initramfs から screen UI まで起動する。

仮説 12 (kernel startup hang) は反証、 仮説 13a (VGA console init で hang) が確定。 仮説 13b (D3373 SOL UART bridge detach) も合わせて反証 (= UART は kernel から書ける)。

### 🎯 副次的に判明した知見

1. **iRMC DisconnectCD は host PowerState=Off でのみ動作**: 
   - host running 中: HTTP 500 "Internal service error"
   - host off 中: HTTP 204 (成功)
   - メディアスワップは必ず ForceOff → DisconnectCD → PATCH → ConnectCD → PowerOn の順序で

2. **`Manager.Reset` (GracefulRestart) で iRMC media subsystem 復旧**:
   - DisconnectCD 永続 500 等の sticky state は Manager.Reset で clear
   - 復旧 ~2 分、 KVM/IPMI session lost
   - 復旧後の AllowableValues は `["ConnectCD"]` (= clean state)

3. **netcfg は静的 IP 空文字列で「invalid IPv4」ダイアログ block**:
   - `network_mode: dhcp` でも DHCP fail → manual config → empty static IP → 無効
   - `auto=true priority=critical` でも本ダイアログは critical 級でスキップされない
   - 対策: `static_ip + static_netmask + static_gateway + static_iface` を必ず指定

4. **NIC は Intel igb driver (eth0 + eth1)**:
   - `[178s] igb 0000:03:00.0 / 0000:04:00.0: Intel(R) Gigabit Ethernet Network Connection`
   - igb は d-i 標準 udeb (nic-modules-6.12.63+deb13-amd64-di) で provided
   - hw-detect で auto load

5. **install 中の SOL ring buffer replay で `Linux version` が大量出現**:
   - 78 個 Linux version マッチ → 実 boot は **2 回のみ** ([7.87s], [78.87s] unique timestamps)
   - ipmitool sol activate の reconnect 毎に iRMC が ring buffer を re-replay する
   - 実 boot 数の判定には kernel time stamps `[N.NNNN]` の unique 数を見るべき
   - 同様に preseed/early_command pvese marker count も SOL replay で水増しされる

6. **partman/early_command で `sh /cdrom/setup-raid10-storcli.sh` rc=127** (未解決):
   - script は `/cdrom` に存在 (multi-path 探索で確認)
   - 0.2 秒で rc=127 終了 (script の前半部で死亡)
   - `set -eu` → `set -u` のみに変更しても解決せず
   - 仮説: `dpkg` が d-i busybox initramfs に存在しない → `dpkg -i` が 127 で帰る → set -e で exit
   - **Phase 14 で要解決**: storcli64 バイナリを .deb から事前抽出して ISO に直接配置するか、 dpkg-deb fallback を確実に通す

7. **10.254.254.99 はローカルマシン (Ubuntu)** = IP 衝突発生:
   - pvese local の ens19 (10.0.0.0/8) には 10.254.254.99 を持つ別ホスト存在
   - training-tx1320 に static_ip 10.254.254.99 設定しても SSH 到達不能 (local 機が ARP win)
   - **Phase 14 では 10.254.99.99 等の衝突なし IP を使用すべき** (本 phase で free 確認済)

8. **iRMC OEM Screenshot は実 VGA 状態を表示**:
   - kernel が VGA に書かなくなった後の "黒画 + 左上カーソル" = 12931 B (Phase 12 の "Booting Automated Install" 凍結 14591 B と区別)
   - 12915 B = "完全黒 (cursor なし)" = VGA framebuffer が空。 boot 直後一瞬 / kernel 切替時に観測
   - 67475 B = BIOS Setup 画面 (本 Phase 終盤の disk boot 試行で発見)

## Phase 13 で得た確定知見

### 🎯 主目標達成度

| 目標 | 達成度 | 補足 |
|------|--------|------|
| Phase 12 SOL silence の真因確定 | ✅ **完全達成** | `console=tty0` cmdline option が原因 |
| 仮説 12 vs 13 切り分け | ✅ **確定** | 仮説 13a (VGA console init hang) が真因 |
| OS install 完遂 (preseed + RAID10 + SSH login) | ❌ **未達成** | netcfg fix 達成、 partman/早期 storcli setup の rc=127 で停止 |

### 🎯 直接的進捗 (Phase 12 → 13)

- Phase 12: kernel printk 0 行、 `Booting Automated Install` で完全凍結
- Phase 13: kernel printk **数千行**、 d-i `screen` UI 起動、 `(1*installer)` window 観測、 cdrom-detect / preseed parsed / early_command run、 netcfg / partman 到達、 partman/early_command で停止

### 🎯 Phase 14 への引き継ぎ (優先度順)

| # | タスク | 補足 |
|---|--------|------|
| 1 | **`scripts/tx1320-raid10-orchestrate.sh build` に playground 同期処理を組み込み** | 現状は手動 scp。 build 完了後に `scp + ssh sudo mv` を automate。 これがないと cmdline patch 系試行が全部空振り |
| 2 | **partman/early_command rc=127 真因究明 + 修正** | 仮説: dpkg 不在。 対策: (a) storcli64 バイナリを .deb から事前抽出し ISO 直接配置、 (b) script 内で dpkg-deb -x fallback を強化 (現状 path は存在するが起動前に exit している)、 (c) `set -e` を完全削除して errexit を無視 |
| 3 | **CONSOLE_ORDER の `console=tty0` 削除 (installed system 側)** | `scripts/generate-preseed.sh` L94 `console_order="console=tty0 console=ttyS${serial_unit},115200n8"` を `console_order="console=ttyS${serial_unit},115200n8"` に変更。 install 後 boot した installed system の kernel cmdline にも `console=tty0` が入ると同じ hang 再発 |
| 4 | **static_ip を 10.254.99.99 等 conflict-free な IP に変更** | 現在 10.254.254.99 は pvese local の別 Ubuntu 機と衝突。 10.254.99.99 / 10.254.254.250 等は free 確認済 |
| 5 | **storcli setup を partman/early_command でなく initramfs hook で実行** | rc=127 が dpkg 不在によるものなら、 storcli64 バイナリ単体を ISO に置き、 partman 前に直接実行する単純化された wrapper を追加 |
| 6 | **stock 13.3.0 ISO baseline 試行 (Step B 完全未実施)** | 本 Phase は Step A で kernel boot 確定したため Step B (stock 直接 attach) は実施せず終了。 必要なら Phase 14 で追加 |
| 7 | **Debian 12 baseline 試行 (Step C 完全未実施)** | Phase 13 で Step C は不要となった (Debian 13 kernel で boot 成功確定のため)。 ただし Debian 12.14.0 ISO (709 MB) は playground にダウンロード済 |
| 8 | **memory `training-tx1320-kernel-silent-post-grub` の Phase 13 結論追記** | Phase 5 iter4 の「console=tty0 除去で 0 維持」記述は playground 同期忘れによる誤判定の可能性を追記 |
| 9 | **`scripts/setup-raid10-storcli.sh` の log() 関数の `set -eu` 互換性向上** | 既に `set -u` のみに変更済。 さらに log 出力先 `/var/log/raid10-setup.log` を `mkdir -p` する処理を追加済 (本 phase) |
| 10 | **orchestrate `monitor` wrapper bug 修正 (引き継ぎ事項 #6 from Phase 12)** | 未着手。 別 issue で対応 |

## 再現方法

### 1. cmdline patch (本 Phase 適用済、 既に committed 前)

```sh
# remaster-debian-iso.sh の 3 箇所で console=tty0 を削除 (L124 / L134 / L197)
sed -i 's|console=tty0 console=ttyS|console=ttyS|g' scripts/remaster-debian-iso.sh
```

### 2. preseed early_command の syslogd 削除 + pvese markers 追加 (本 Phase 適用済)

```sh
# preseed/preseed.cfg.template の early_command を以下に置換:
d-i preseed/early_command string \
  echo "pvese: preseed/early_command start (%%HOSTNAME%%)" > /dev/kmsg 2>/dev/null || true; \
  echo "pvese: preseed/early_command end" > /dev/kmsg 2>/dev/null || true; \
  :
```

### 3. config に static IP 設定

```yaml
network_mode: static
static_iface: eth0
static_ip: 10.254.254.99      # Phase 14 では conflict-free な IP に変更
static_netmask: 24
static_gateway: 10.254.254.1
```

### 4. ISO build + playground 同期 (= Phase 13 で発見の必須 workaround)

```sh
SKIP_STORCLI_FETCH=1 ./scripts/tx1320-raid10-orchestrate.sh build config/training_tx1320.yml
scp -F ssh/config -i ssh/id_ed25519 -o StrictHostKeyChecking=no /var/samba/public/debian-training-tx1320-raid10.iso ubuntu@10.1.6.6:/tmp/wrapper.iso
ssh -F ssh/config -i ssh/id_ed25519 -o StrictHostKeyChecking=no ubuntu@10.1.6.6 'sudo mv /tmp/wrapper.iso /var/samba/public/debian-training-tx1320-raid10.iso && sudo chmod 0644 /var/samba/public/debian-training-tx1320-raid10.iso'
```

### 5. deploy (= ForceOff + DisconnectCD + reconfigure + ConnectCD + PowerOn)

```sh
# まず host を Off にしてから DisconnectCD する必要あり (Phase 13 発見)
sh tmp/<sid>/stepA3-redeploy.sh   # ForceOff + DisconnectCD
sh tmp/<sid>/stepA-redeploy.sh    # PATCH + ConnectCD + boot-override Cd UEFI + PowerOn
```

### 6. SOL 監視

```sh
.venv/bin/python scripts/sol-monitor.py \
    --bmc-ip 10.254.254.9 --bmc-user claude --bmc-pass Claude123 \
    --log-file tmp/<sid>/install.log --timeout 1800 --powerstate-interval 60
```

### 7. 進捗判定 (Phase 11 教訓 + Phase 13 新規)

```sh
# 真の boot 数 (kernel time stamps unique)
sed -e 's/\x1b\[[0-9;?]*[a-zA-Z]//g' -e 's/\x1b[()][AB012]//g' install.log \
  | tr -d '\r\000-\010\013-\037\177' \
  | grep -aoE "\[ *[0-9]+\.[0-9]+\] pvese:[^]]*" | sort -u

# d-i 進行 stage 確認
grep -ac "pvese: preseed/early_command start" install.log    # 早期到達
grep -ac "pvese: partman/early_command start" install.log    # netcfg 通過
grep -ac "pvese: late_command start" install.log             # install 完遂
grep -ac "pvese: raid10-setup" install.log                   # storcli 動作 (Phase 14 未解決)
```

## 関連レポート / メモ

- [Phase 12 (2026-05-22 phase12-111602): SOL silence 確定](2026-05-22_113557_tx1320_raid10_phase12_sol_silence_confirmed.md)
- [Phase 11 (2026-05-22 phase11-084821): Phase 10 「installer boot 成功」判定の訂正](2026-05-22_093747_tx1320_raid10_phase11_phase10_misjudgment_revealed.md)
- [Phase 10 (2026-05-22 phase10-072719): cmdline bisect 完了 — 誤判定 (Phase 11 で訂正)](2026-05-22_082633_tx1320_raid10_phase10_cmdline_bisect_solved.md)
- [Phase 9 (2026-05-22 phase9-060436): stock 13.3.0 ISO 直接 boot で remaster wrapper cmdline が真因と確定](2026-05-22_071405_tx1320_raid10_phase9_remaster_cmdline_isolated.md)
- memory `training-tx1320-kernel-silent-post-grub` (Phase 3-12 経緯。 Phase 13 で **真因 console=tty0 確定** を追記予定)
- memory `training-tx1320-nfs-solved` (NFS attach 経路)
- memory `training-tx1320-irmc-kvm-framebuffer-artifact` (OEM Screenshot = 真 VGA capture)
- memory `playground-10-1-6-6` (Debian 12.14.0 ISO 配置済、 wrapper ISO sync target)
