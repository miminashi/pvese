# 8号機 grub-install 間欠失敗: 累積破損以外の可能性を潰す

## Context

前回セッション (`report/2026-04-11_031406_sol_monitor_false_positive_fix.md`) の 7/8/9 並列 3 反復テストで 8 号機 iter 2 のみ `grub-install /dev/sda` ダイアログ失敗を観測した。iter 1/3 は同一 preseed/ISO で成功しているため**間欠的な環境問題**である。前回レポートでは「BIOS NVRAM 累積破損」を第一仮説として記録したが、実機 CMOS リセットが必要なため、それを試す前に **「累積破損以外」の非侵襲な仮説を順に潰して、再発時に原因を一点に絞り込める状態にする**ことが本プランの目的。

### 調査で得た新しい事実

1. **実際の失敗ログは `tmp/s8setup2/sol-install-s8{,-retry,-retry2}.txt`** にある (3 連続 "Unable to install GRUB in /dev/sda" ダイアログ、ファイルサイズ 16MB/5.4MB/6.4MB、作成時刻 2026-04-11 01:09〜01:51 JST、iter 2 子エージェントセッション)。ダイアログタイトルは **「[!!] Configuring shim-signed:amd64」** — つまり shim-signed/grub-efi-amd64 パッケージの **postinst 実行中** の失敗。
2. `tmp/da4c169f/sol-install-s8-iter2.log` は親セッションの生成物で BIOS POST ループのみ (installer 出力なし)。親レポートの「stage 7/9 到達」の主張は子セッションのログ由来。
3. **hand-maintained preseed とテンプレート/generated の divergence**:
   - `preseed/preseed-server{7,8,9}.cfg` には `grub-installer/force-efi-extra-removable` が **無い**
   - 同じく `grub-installer/grub2/update_nvram` が **無い** (default=true → efibootmgr を呼ぶ)
   - `preseed-generated-s8.cfg` だけが明示的に `partman-efi/non_efi_system boolean false` としており、内部コメントに **「Setting true prevents ESP creation on fresh disks, causing grub-efi installation failure」** と警告している。手動 preseed には設定自体が存在しない (default=false なので危険ではないが暗黙依存)
   - 8 号機/9 号機の `partman/early_command` は **ディスク先頭 1MB しか dd しない** → GPT バックアップテーブルが末尾に残る
4. `scripts/syslog-receiver.sh` は存在するが **install-monitor 中に起動されない**。preseed `early_command` で `syslogd -R 10.1.6.1:5514` が走っているのに受信側が居ないため、installer 側の `grub-install` / `efibootmgr` エラー文字列が一切保存されていない。ダイアログピクセルしか証拠がない。
5. `config/server7.yml` は `serial_unit: 0` だが、server 7 の BIOS SerialPortAddress は `Serial1Com1Serial2Com2` (COM2 = ttyS1)。本来 `serial_unit: 1` が正しい。残存課題 2 (pve-setup-remote.sh serial-unit ハードコード) は script 側ではなく **config 側の値が間違い** が真の原因。

### 非累積破損仮説 (優先順)

| ID | 仮説 | 根拠 | 尤度 |
|----|------|------|------|
| A | `grub-installer/force-efi-extra-removable` 欠落 → NVRAM 単一依存 | テンプレートには有り、手動 preseed には無い | **HIGH** |
| B | `grub2/update_nvram=true` (default) → efibootmgr 呼ぶ → iDRAC7 efivars 間欠失敗 | 失敗はシム/grub postinst 中、NVRAM 書込みの代表パス | **HIGH** |
| C | GPT バックアップテーブル残骸 → partman がスタンバイ層でズレた layout を適用 | dd count=1 は primary のみ、backup 末尾が残る | **MEDIUM** |
| D | `partman-efi/non_efi_system` 暗黙依存 | default=false で偶然救われているだけ | **LOW-MEDIUM** |
| E | パッケージ postinst が `grub-install` を独自呼出し | ダイアログ title が "Configuring shim-signed" | **MEDIUM** |
| F | VirtualMedia CD が install 中も mount 済み → 列挙ノイズ | `cdrom-detect/eject false` | **LOW** |

仮説 A+B のコンボが最有力。`force-efi-extra-removable=true` + `update_nvram=false` で「NVRAM を触らず、BOOTX64.EFI 経由で UEFI フォールバックブート」という **NVRAM 完全バイパス** が実現でき、これが通れば iter 2 再現は阻止できる。通らなければ NVRAM 累積破損の可能性が一段強まる。

## 実装プラン

### Phase 0: 証拠ログを attachment へ永続化

`tmp/<session-id>/` は定期的に掃除される可能性があるので、iter 2 grub-install 失敗の実証拠を `report/attachment/` 配下にコピーして将来参照可能にする。

対象ディレクトリ: `report/attachment/2026-04-11_grub_install_noncorruption_investigation/`

コピー対象:

| 元ファイル | コピー先名 | 内容 |
|-----------|-----------|------|
| `tmp/s8setup2/sol-install-s8.txt` (16 MB) | `iter2-s8-sol-attempt1.txt` | 1 回目の grub-install ダイアログ連続発生 TUI |
| `tmp/s8setup2/sol-install-s8-retry.txt` (5.4 MB) | `iter2-s8-sol-attempt2.txt` | 2 回目リトライ |
| `tmp/s8setup2/sol-install-s8-retry2.txt` (6.4 MB) | `iter2-s8-sol-attempt3.txt` | 3 回目リトライ (最終失敗) |
| `tmp/s8setup2/grub-fail-screen.png` | `iter2-s8-kvm-grubfail.png` | ダイアログ状態の KVM |
| `tmp/da4c169f/sol-install-s8-iter2.log` | `iter2-s8-parentsession-bootloop.log` | 親セッションから見える BIOS POST ループのみの側面 |
| `tmp/da4c169f/kvm-iter2-1.png` 〜 `kvm-iter2-late.png` (6 枚) | 同名でコピー | 親セッションからの iter 2 KVM 時系列 |

加えて、短い `README.md` を attachment ディレクトリに置いて「どのファイルが何を示すか」を記述する (1 ページ程度、上表 + 調査時に判明した「実際のダイアログ発生は s8setup2、親セッションログはブートループで誤解を招く」という注意書き)。

検証: `ls -la` で 10 ファイル + README が揃っていること、SOL ログの grep で "Unable to install GRUB" がヒットすることを確認。

### Phase 1: preseed-server{7,8,9}.cfg 三本に同一の grub 緩和バンドルを投入

対象ファイル:
- `preseed/preseed-server7.cfg`
- `preseed/preseed-server8.cfg`
- `preseed/preseed-server9.cfg`

#### 1.1 `### Boot loader` セクションに 3 行追加 (仮説 A, B 対策)

```diff
 ### Boot loader - UEFI (grub-efi-amd64 auto-detected)
 d-i grub-installer/only_debian boolean true
 d-i grub-installer/with_other_os boolean false
 d-i grub-installer/bootdev string /dev/sda
+d-i grub-installer/force-efi-extra-removable boolean true
+d-i grub-installer/grub2/update_nvram boolean false
```

- `force-efi-extra-removable` は `/boot/efi/EFI/BOOT/BOOTX64.EFI` を書く (NVRAM 非依存の UEFI removable fallback)。
- `update_nvram=false` は grub-install に `--no-nvram` 相当を渡し efibootmgr 呼び出しを抑止。
- 併用で NVRAM を一切触らない grub install になる。iDRAC7 R320 の BIOS は Boot#### エントリが無くても `/EFI/BOOT/BOOTX64.EFI` を UEFI 標準フォールバックで起動する。

#### 1.2 `### Partitioning` セクションに 1 行追加 (仮説 D 明示化)

```diff
 d-i partman-auto/disk string /dev/sda
 d-i partman-auto/method string regular
+### partman-efi/non_efi_system: false = create ESP in UEFI mode
+### Setting true can prevent ESP creation, causing grub-efi failure (per preseed-generated-s8.cfg)
+d-i partman-efi/non_efi_system boolean false
 d-i partman-lvm/device_remove_lvm boolean true
```

- default 値が false なので behavior は変わらないが、**明示** することで将来の template coherence バグを防ぐ。`preseed-generated-s8.cfg` の既知修正に整合させる。

#### 1.3 `early_command` を強化: GPT 両端消去 + wipefs (仮説 C 対策)

**preseed-server7.cfg** (現状: `dd /dev/sda bs=1M count=10`):

```diff
 d-i partman/early_command string \
   swapoff -a 2>/dev/null || true; \
-  dd if=/dev/zero of=/dev/sda bs=1M count=10 2>/dev/null || true
+  sgdisk --zap-all /dev/sda 2>/dev/null || true; \
+  wipefs -a /dev/sda 2>/dev/null || true; \
+  dd if=/dev/zero of=/dev/sda bs=1M count=10 2>/dev/null || true; \
+  end_mb=$(( $(blockdev --getsz /dev/sda) / 2048 - 10 )); \
+  dd if=/dev/zero of=/dev/sda bs=1M seek="$end_mb" count=10 2>/dev/null || true; \
+  partprobe /dev/sda 2>/dev/null || true
```

**preseed-server{8,9}.cfg** (現状: `for disk in list-devices disk ... dd bs=1M count=1`): 同様に `sgdisk --zap-all`, `wipefs -a`, 末尾 10MB dd, `partprobe` をループ内に追加。

- `sgdisk --zap-all` は GPT primary/backup + MBR を消去 (Debian 13 d-i に含まれている)。見つからない環境でも `|| true` でフェイルセーフ。
- 末尾 10MB の dd は sgdisk が無い場合の保険。`blockdev --getsz` は 512B sector 単位のデバイスサイズ。`/2048` で MB に変換 → `-10` で末尾 10MB 位置。

#### 1.4 debconf 直接 preseed でパッケージ postinst も NVRAM 非依存に (仮説 E 対策)

`### Boot loader` 直前に 4 行追加:

```
### Debconf preseeding for grub packages (package postinst path)
### Covers hypothesis E: shim-signed/grub-efi-amd64 postinst calling grub-install
### independently of grub-installer. Forces --no-nvram at package level too.
grub-pc grub2/update_nvram boolean false
grub-efi-amd64 grub2/update_nvram boolean false
grub-pc grub-pc/install_devices multiselect /dev/sda
grub-efi-amd64 grub-efi/install_devices multiselect /dev/sda
```

- `d-i grub-installer/*` は installer udeb の debconf 名前空間。パッケージ postinst は `grub-pc` / `grub-efi-amd64` の debconf 名前空間を読むので、両方に preseed しないと postinst 側だけ NVRAM 書込みを試みる可能性がある。

#### 1.5 `cdrom-detect/eject` を true に (仮説 F 対策)

```diff
-d-i cdrom-detect/eject boolean false
+d-i cdrom-detect/eject boolean true
```

- VirtualMedia 仮想 CD なので物理的 eject は no-op だが kernel 側のブロックデバイス列挙から外す。grub-install/efibootmgr が誤って CD をブートエントリに含めるリスクを排除。直後に poweroff=true なので副作用ゼロ。

#### 1.6 `late_command` を三本で統一: belt-and-suspenders 再投入

**preseed-server7.cfg** (現状: `true`)、**preseed-server8.cfg** (現状: `true`) を以下に置換。**preseed-server9.cfg** (現状: grub-install x2 + update-grub x2) も同じ内容に差し替え:

```
d-i preseed/late_command string \
  in-target update-grub || true; \
  in-target grub-install --target=x86_64-efi --efi-directory=/boot/efi \
      --bootloader-id=debian --no-nvram --force-extra-removable \
      --recheck /dev/sda || true; \
  in-target update-grub || true; \
  in-target sh -c 'echo "fs0:\\efi\\boot\\bootx64.efi" > /boot/efi/startup.nsh' || true; \
  true
```

- 全て `|| true` なので「失敗しても install は止めない」保険。
- `--no-nvram --force-extra-removable` を明示 → 1.1/1.2 の設定漏れがあっても grub-install 側で救済。
- `startup.nsh` は UEFI Shell fallback (三番目のブート経路)。
- **重要な制約**: iter 2 の実失敗は grub-installer ダイアログ段階で installer がブロックするため late_command までは走らない。つまりこの 1.6 は **次回以降の retry または別症状の予防** であり、今回発生した iter 2 失敗そのものの救済ではない。1.1-1.5 がメインの救済策。

### Phase 2: install-monitor で installer syslog を必ずキャプチャ

対象ファイル: `.claude/skills/os-setup/SKILL.md` Phase 5 の冒頭

現状 Phase 5 は `./scripts/sol-monitor.py` を直接起動するだけで、preseed の `syslogd -R 10.1.6.1:5514` が送る UDP パケットを受信するリスナーが居ない。以下のステップを追加:

```sh
### Step 0: Start installer syslog receiver (non-blocking background)
### preseed/early_command starts `syslogd -R 10.1.6.1:5514 -L` on the installer.
### Without a listener, installer syslog (including grub-install/efibootmgr errors)
### is lost forever when the installer poweroffs.
SYSLOG_LOG="tmp/<session-id>/installer-syslog-s${SUFFIX}.log"
if ss -uln 2>/dev/null | grep -q ':5514 '; then
    echo "WARN: UDP 5514 already in use; skipping syslog receiver for s${SUFFIX}"
    SYSLOG_RCV_PID=""
else
    ./scripts/syslog-receiver.sh 5514 "$SYSLOG_LOG" &
    SYSLOG_RCV_PID=$!
    echo "Started syslog receiver (pid=$SYSLOG_RCV_PID, log=$SYSLOG_LOG)"
fi
```

Phase 5 末尾 (sol-monitor.py 完了後) に停止コード:

```sh
if [ -n "$SYSLOG_RCV_PID" ]; then
    kill "$SYSLOG_RCV_PID" 2>/dev/null || true
    wait "$SYSLOG_RCV_PID" 2>/dev/null || true
    echo "Installer syslog saved to $SYSLOG_LOG"
    if [ -s "$SYSLOG_LOG" ]; then
        echo "Syslog size: $(wc -l < $SYSLOG_LOG) lines"
    else
        echo "WARN: Syslog file empty — check network path to 10.1.6.1:5514"
    fi
fi
```

**並列実行時の注意**: 7/8/9 並列テストでは 3 つの子エージェントが全員 UDP 5514 を listen しようとするため、**親セッションで一度だけ listener を立てる** のが正解。この場合は sol_monitor_false_positive_fix テスト時の親 orchestration スクリプト (`tmp/<parent-sid>/`) でリスナーを起動し、子エージェントには「syslog リスナーは既に走っている」と告げる運用に変更する。スキル文書にも注意書きを追加。

副次作業: 3 号機それぞれが同じ syslog 宛先に書くので受信側では送信元 IP (`10.10.10.207/208/209`) で切り分ける。`syslog-receiver.sh` はそのまま使え、socat が送信元アドレスを付けて渡す。取得後、ログ分割は `grep '10.10.10.208'` 等で OK。

### Phase 3: 残存課題 2 の真の修正 (config/server7.yml)

対象ファイル: `config/server7.yml`

```diff
-serial_unit: 0
+serial_unit: 1
```

コメントも追加 (server 7 の BIOS SerialPortAddress 固有事情):

```yaml
# Server 7: BIOS SerialPortAddress=Serial1Com1Serial2Com2 → iDRAC SOL maps to COM2 (ttyS1)
# Other R320s (server 8, 9) use Serial1Com2Serial2Com1 → ttyS0 (serial_unit: 0)
serial_unit: 1
```

- 前回レポートが言う「pve-setup-remote.sh の serial-unit ハードコード」は誤診断。script は既に `--serial-unit ${SERIAL_UNIT}` を受け取り、SKILL.md Phase 7 も既に `${SERIAL_UNIT}` を yq で渡している。真のバグは config 側。
- server 8, 9 の yml は `serial_unit: 0` のままで正しい (preseed は `ttyS0`)。

### Phase 4: 残存課題 3 (デフォルトゲートウェイ reversion) の修正

対象ファイル: `scripts/pve-setup-remote.sh` の `phase_post_reboot` 関数

**背景**: `apt-get -y install proxmox-ve` が `ifupdown2` をインストールする際、`/etc/network/interfaces` を再評価してデフォルトゲートウェイをインストール直後の静的設定 (`10.10.10.1`) に戻してしまう。現状は毎回 `pre-pve-setup.sh` を再実行して `ip route` で修正しているが、再起動で再発する。

**方針**: preseed `late_command` にラボ固有ネットワーク情報を混ぜるのは結合度が上がるため避け、PVE インストール後 (= ifupdown2 配備後) に **恒久的な if-up.d フック** を書いて ifup/ifdown のたびに経路を修正する。

`phase_post_reboot` の末尾 (post-reboot 完了メッセージの直前)、`if [ "$linstor" = "1" ]` ブロックの外側に以下を追加:

```sh
echo "--- Installing durable default-route fix hook ---"
mkdir -p /etc/network/if-up.d
cat > /etc/network/if-up.d/z-fix-default-route << 'EOF'
#!/bin/sh
# Persistent default route fix for lab environment.
# The management network 10.0.0.0/8 has no internet; 192.168.39.0/24 (DHCP)
# is the only internet-capable path. Installer/ifupdown2 sometimes sets
# default via 10.10.10.1 during re-evaluation; this hook reverts on every up.
ip route del default via 10.10.10.1 2>/dev/null || true
if ! ip route show default | grep -q 'default'; then
    ip route add default via 192.168.39.1 2>/dev/null || true
fi
EOF
chmod 0755 /etc/network/if-up.d/z-fix-default-route
/etc/network/if-up.d/z-fix-default-route
echo "Default-route fix hook installed"
```

**配置場所の理由**:
- `phase_post_reboot` の `apt-get -y install proxmox-ve` (ifupdown2 を含む) **より後**: ifupdown2 配備後に書くことで、以後の boot/ifup は確実にこのフックを通る
- `phase_pre_reboot` に書くと、その後の ifupdown2 パッケージ postinst が /etc/network/if-up.d を上書き/無視する可能性がある
- `--linstor` ブロックの前後どちらでも良いが **外側** にすることで LINSTOR 無し構成でも適用される

**冪等性**: 毎回上書きで OK。スクリプト内容が固定なので重複実行しても同じ結果。

**副作用考慮**:
- `ip route del default via 10.10.10.1` は default が別経由 (`192.168.39.1`) の時も `|| true` で安全
- `if ! ip route show default | grep -q 'default'` で既にデフォルトがある場合は上書きしない → VMBR1 インターフェースダウン時に不正な経路を作らない
- スクリプト名先頭の `z-` は ifup が辞書順で処理するため **既存の if-up.d フックより後に実行される** ことを保証

**リスク**:
- `/etc/network/if-up.d/` は ifupdown / ifupdown2 両対応の標準フックディレクトリ。破壊変更のリスクは非常に低い
- 万一 192.168.39.1 が unreachable でも `|| true` で落ちない
- ユーザが手動で `ip route` で経路を組み替えた場合、次の ifup で上書きされる可能性 → ラボ運用上は許容範囲

## 検証方法 (物理アクセス不要)

### 検証 1: preseed 構造 diff

```sh
diff -u preseed/preseed.cfg.template preseed/preseed-server8.cfg
diff -u preseed/preseed-server8.cfg preseed/preseed-server9.cfg  # ほぼ同じになるべき
diff -u preseed/preseed-server8.cfg preseed/preseed-server7.cfg  # console=ttyS1, 単一ディスク wipe, 等の差分のみ
```

以下を 3 ファイル全てに対して確認 (Grep で一括):
- `grub-installer/force-efi-extra-removable boolean true`
- `grub-installer/grub2/update_nvram boolean false`
- `partman-efi/non_efi_system boolean false`
- `cdrom-detect/eject boolean true`
- `grub-pc grub2/update_nvram boolean false`
- `grub-efi-amd64 grub2/update_nvram boolean false`
- `sgdisk --zap-all`
- `--no-nvram --force-extra-removable`

### 検証 2: syslog-receiver smoke test (ホストのみ)

前提: `socat` が必要。確認した結果 **現時点では未インストール** (`which socat` → not found)。事前に `sudo apt install -y socat` で入れる。`Bash(sudo apt:*)` は許可リスト内なので自動承認される。

```sh
./scripts/syslog-receiver.sh 5514 tmp/<sid>/sl-smoke.log &
PID=$!
logger -n 127.0.0.1 -P 5514 -d "test-message-$$"
sleep 1
kill $PID
grep "test-message" tmp/<sid>/sl-smoke.log
```

"test-message-XXXX" が出れば OK。

### 検証 3: 実機 iter 2 再現テスト (ユーザが別途指示)

1. server 8 を一度 ForceOff + jobqueue delete all + iDRAC 状態健全化
2. `sh tmp/<sid>/reset-all-phases.sh` で 3 台全フェーズ reset
3. syslog receiver を親セッションで起動 (`./scripts/syslog-receiver.sh 5514 tmp/<sid>/installer-syslog-all.log &`)
4. server 8 のみ単独で iter 1 → 成功確認
5. **iter 1 直後に iter 2** (電源サイクル以外の介入なし) → 結果を観察
6. iter 2 成功なら iter 3 も流す
7. syslog ログを送信元 IP (`10.10.10.208`) で grep して iter 2 区間の `grub-install` / `efibootmgr` / `shim-install` 行を確認

### 検証 3.5: 実験ログの attachment 永続化 (iter 2 再現テスト直後に実施)

実験ログは tmp/<session-id>/ 配下にあるため、tmp 掃除で失われる前に保存する。検証 3 が完了したら直ちに以下を `report/attachment/2026-04-11_grub_install_noncorruption_investigation/experiment/` にコピー:

| 元ファイル | コピー先名 | 備考 |
|-----------|-----------|------|
| `tmp/<sid>/installer-syslog-all.log` | `retest-installer-syslog.log` | **最重要** — grub-install / efibootmgr の生エラー。検証 4 判定の根拠 |
| `tmp/<sid>/sol-install-s8-iter1.log` | `retest-iter1-sol.log` | iter 1 成功ログ (比較対照) |
| `tmp/<sid>/sol-install-s8-iter2.log` | `retest-iter2-sol.log` | **最重要** — iter 2 の挙動。成功 or 失敗を問わず保存 |
| `tmp/<sid>/sol-install-s8-iter3.log` | `retest-iter3-sol.log` | iter 3 ログ (実行した場合) |
| `tmp/<sid>/kvm-retest-*.png` | 同名でコピー | 異常発生時の KVM スナップショット全て |
| `state/os-setup/server8/*.{start,end,status}` の関連タイムスタンプ | `retest-phase-timestamps.txt` に集約 | Phase 5-6 の time window 特定用 |
| `log/oplog.log` の実験区間抜粋 | `retest-oplog-excerpt.log` | 実験中に実行した pve-lock コマンド履歴 (iter 1 開始前から iter 3 終了後まで) |

加えて、実験所感をまとめた `retest-summary.md` を同 `experiment/` 配下に作成:
- 実験時刻 (開始/終了、JST)
- preseed 変更前後の iter 2 挙動の違い
- syslog receiver が捕捉した決定的エラー文字列 (grep 結果を原文で引用)
- 検証 4 判定フローのどの分岐に該当したか
- 次の action (修正で治った / 追加調査 / 物理介入段階へ進む 等)

**Phase 0 の既存証拠ログとは `pre-fix/` と `experiment/` のサブディレクトリで分ける** こと:
```
report/attachment/2026-04-11_grub_install_noncorruption_investigation/
├── README.md
├── pre-fix/                      # Phase 0 でコピー済み (iter 2 失敗時点の証拠)
│   ├── iter2-s8-sol-attempt{1,2,3}.txt
│   ├── iter2-s8-kvm-grubfail.png
│   ├── iter2-s8-parentsession-bootloop.log
│   └── kvm-iter2-{1,2,3,progress,midlate,late}.png
└── experiment/                   # 検証 3 実施後にコピー (修正後 re-test 証拠)
    ├── retest-installer-syslog.log
    ├── retest-iter{1,2,3}-sol.log
    ├── retest-phase-timestamps.txt
    ├── retest-oplog-excerpt.log
    ├── retest-summary.md
    └── kvm-retest-*.png
```

この分離により「修正前後」の比較が後から独立して追跡可能になる。

### 検証 4: 結果判定フローチャート

| iter 2 の結果 | syslog の決定的エラー行 | 結論と次の手 |
|---------------|----------------------|-------------|
| 成功 (iter 3 も成功) | — | 仮説 A+B (+C+D+E+F) のどれかが原因だった。Phase 3 の config 修正を適用後、別セッションでサブ課題 3 へ |
| 失敗 | `efibootmgr: Could not prepare Boot variable: Input/output error` | 仮説 B 確定だが `--no-nvram` propagation 不足。debconf seed が届いたか `/target/var/cache/debconf/config.dat` で検証 |
| 失敗 | `grub-install: error: cannot find EFI system partition` | 仮説 C 確定。sgdisk が installer udeb に無かった可能性 → early_command に dd 末尾追加のみで対応 |
| 失敗 | `grub-install: error: embedding is not possible` | BIOS mode で booted している (`/sys/firmware/efi` 無し) → iDRAC の boot-once が legacy CD を選んだ。Phase 4 `bmc-mount-boot` に UEFI fallback 強制を追加 |
| 失敗 | syslog に決定的エラー無し + ダイアログ | **NVRAM 累積破損が強く示唆される**。物理 CMOS リセット実施タイミングへ。この時点で本プランの目的は達成 |

### 検証 5: Phase 3 (config/server7.yml) の後追い確認

config を修正した上で server 7 の OS セットアップを一度通す (user が指示した時)。完了後:

```sh
ssh -F ssh/config pve7 cat /etc/default/grub
```

`GRUB_SERIAL_COMMAND="serial --unit=1 ..."` と `GRUB_CMDLINE_LINUX="... console=ttyS1,115200n8"` を確認。POST 後の GRUB メニューが SOL に表示されれば OK。

## 実装順序と依存関係

1. **Phase 0 (既存証拠ログの pre-fix/ へコピー)** — 最初に実施 (tmp 消失リスクを抑止)
2. **Phase 1 (preseed 三本の修正)** — 単独コミット、全サブステップまとめて
3. **Phase 2 (SKILL.md Phase 5 syslog receiver)** — 単独コミット
4. **Phase 3 (config/server7.yml serial_unit: 1)** — 単独コミット
5. **Phase 4 (pve-setup-remote.sh if-up.d フック)** — 単独コミット
6. **検証 1 + 検証 2** をアシスタントが実施 (ハード不要)
7. **ユーザが検証 3 実行を指示 → 実機再現テスト** (アシスタントは子エージェント起動等)
8. **検証 3.5 (実験ログの experiment/ へコピー)** — 検証 3 完了直後、tmp 掃除前に必ず実施
9. **検証 4 フローで結論確定** → レポート作成 (attachment 全ファイルをまとめて参照)

**コミット粒度の理由**: Phase 1-4 を別コミットにすることで、後から bisect して「どの修正が iter 2 失敗に効いたか」を切り分け可能にする。全部一気に投入するより診断価値が高い。Phase 0 はコミット不要 (attachment 配下のファイル追加は最終レポートのコミットでまとめる)。

## 既知のリスク

| 変更 | リスク | 緩和 |
|------|--------|------|
| 1.1 `force-efi-extra-removable=true` | 無し (他 preseed で既に実績) | — |
| 1.2 `update_nvram=false` | NVRAM Boot#### エントリが作られず removable fallback 依存 | R320 BIOS 2.3.3 は標準 UEFI fallback 対応。1.1 と必ずセット |
| 1.3 `non_efi_system=false` | 明示化のみで behavior 変化無し | default と一致 |
| 1.4 `sgdisk --zap-all` | installer udeb に sgdisk 無い可能性 | `|| true` + 末尾 dd の二重化 |
| 1.5 `cdrom-detect/eject=true` | VirtualMedia で物理 eject 無し、無影響 | 直後 poweroff |
| 1.6 debconf seed | 無害 | — |
| 1.7 `late_command` | `|| true` で全て保険なので副作用無し | — |
| 2.1 syslog receiver | UDP 5514 ポート競合 | `ss -uln` で事前チェック |
| 3.1 `serial_unit: 1` | OS 側で `ttyS1` を使うよう grub 再設定される。誤ると console 途切れる | 検証 5 で実機確認 |

## 明示的なスコープ外

- `scripts/remaster-debian-iso.sh` — 前回セッションで HEAD revert したのでこのプランでは触らない
- `scripts/sol-monitor.py` — 前回セッションで exit code 4 修正済み、再度触らない
- `preseed/preseed.cfg.template` — テンプレートと手動 preseed の template coherence 全般の見直しは別件
- 物理 CMOS リセット、BIOS 再フラッシュ、ジャンパ操作 — **今回の目的はこれらを試す前の準備**

## Critical Files

- `/home/ubuntu/projects/pvese/preseed/preseed-server7.cfg` (修正)
- `/home/ubuntu/projects/pvese/preseed/preseed-server8.cfg` (修正)
- `/home/ubuntu/projects/pvese/preseed/preseed-server9.cfg` (修正)
- `/home/ubuntu/projects/pvese/.claude/skills/os-setup/SKILL.md` (修正、Phase 5)
- `/home/ubuntu/projects/pvese/config/server7.yml` (修正、Phase 3)
- `/home/ubuntu/projects/pvese/scripts/pve-setup-remote.sh` (修正、Phase 4 phase_post_reboot 末尾追記)
- `/home/ubuntu/projects/pvese/scripts/syslog-receiver.sh` (既存、変更なし)
