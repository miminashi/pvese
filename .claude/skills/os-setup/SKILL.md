---
name: os-setup
description: "Debian + Proxmox VE OS自動セットアップ。BMC VirtualMedia経由でpreseedインストール、PVEインストールまでを実行する。"
disable-model-invocation: true
argument-hint: "[config_file]"
---

# OS Setup スキル

Debian + Proxmox VE のインストールを BMC VirtualMedia 経由で自動実行する。

## 事前準備

1. 設定ファイルを準備（引数で指定、デフォルト: `config/os-setup.yml`）
   - `config/os-setup.example.yml` をコピーして編集
2. 技術詳細は `reference.md` を参照

## スクリプト一覧

| スクリプト | 用途 |
|-----------|------|
| `scripts/bmc-session.sh` | BMC 認証・CSRF トークン |
| `scripts/bmc-virtualmedia.sh` | VirtualMedia 操作 |
| `scripts/bmc-power.sh` | Redfish 電源制御 + POST code 取得 |
| `scripts/bmc-screenshot.sh` | BMC スクリーンショット（DCMS 要） |
| `scripts/os-setup-phase.sh` | フェーズ状態管理 |
| `scripts/generate-preseed.sh` | preseed 生成 |
| `scripts/remaster-debian-iso.sh` | ISO リマスター |
| `scripts/pve-setup-remote.sh` | PVE インストール（リモート実行） |

## 設定値の読み取り

```sh
YQ="${PROJECT_DIR}/bin/yq"
CONFIG="config/os-setup.yml"  # または引数で指定されたパス
BMC_IP=$("$YQ" '.bmc_ip' "$CONFIG")
SMB_HOST=$("$YQ" '.smb_host' "$CONFIG")
SMB_SHARE=$("$YQ" '.smb_share_path' "$CONFIG")  # YAML "\\public" → \public
# 以下同様に各値を読み取る
```

## フェーズ実行

### 初期化

```sh
scripts/os-setup-phase.sh init
scripts/os-setup-phase.sh status
```

既に初期化済みの場合は `status` で進行状況を確認し、完了済みフェーズはスキップする。
`scripts/os-setup-phase.sh next` で次の未完了フェーズを取得する。

---

### Phase 1: iso-download

**pve-lock**: 不要

1. 設定ファイルから `debian_iso_url`, `debian_iso_sha256`, `iso_download_dir` を読み取る
2. ISO がダウンロード済みか確認（ファイル存在 + sha256 照合）
3. 未ダウンロードなら `curl -L -o <path> <url>` でダウンロード
4. sha256 検証: `sha256sum <file>` の出力と設定値を比較
5. 完了: `scripts/os-setup-phase.sh mark iso-download`

**エラー時**: sha256 不一致 → ファイル削除して再ダウンロード

---

### Phase 2: preseed-generate

**pve-lock**: 不要

1. `scripts/generate-preseed.sh <config.yml> preseed/preseed-generated.cfg`
2. 生成結果を確認（diff でテンプレートとの差分表示）
3. 完了: `scripts/os-setup-phase.sh mark preseed-generate`

---

### Phase 3: iso-remaster

**pve-lock**: 不要

1. ISO パスと生成した preseed のパスを確認
2. `scripts/remaster-debian-iso.sh <元ISO> preseed/preseed-generated.cfg <出力ISO>`
   - デフォルト出力: `<iso_download_dir>/debian-preseed.iso`
3. 出力 ISO の存在確認
4. 完了: `scripts/os-setup-phase.sh mark iso-remaster`

---

### Phase 4: bmc-mount-boot

**pve-lock**: 必要（`pve-lock.sh run` で実行）

このフェーズは以下をまとめて実行する:

1. **BMC ログイン**:
   ```sh
   COOKIE_FILE="/tmp/bmc-cookie-$$"
   scripts/bmc-session.sh login "$BMC_IP" "$BMC_USER" "$BMC_PASS" "$COOKIE_FILE"
   CSRF=$(scripts/bmc-session.sh csrf "$BMC_IP" "$COOKIE_FILE")
   ```

2. **VirtualMedia 設定・マウント**:
   ```sh
   scripts/bmc-virtualmedia.sh config "$BMC_IP" "$COOKIE_FILE" "$CSRF" "$SMB_HOST" "$SMB_SHARE"'\debian-preseed.iso'
   scripts/bmc-virtualmedia.sh mount "$BMC_IP" "$COOKIE_FILE" "$CSRF"
   scripts/bmc-virtualmedia.sh status "$BMC_IP" "$COOKIE_FILE" "$CSRF"
   ```

3. **サーバをパワーサイクルして BootOptions を列挙させる**:
   > **重要**: `Boot0011` (ATEN Virtual CDROM) は UEFI POST で VirtualMedia を
   > 検出した後にのみ BootOptions に出現する。VirtualMedia をマウントした後、
   > 最低1回はパワーサイクル（POST 通過）が必要。

   ```sh
   # VirtualMedia マウント後、パワーサイクルして POST を通過させる
   scripts/bmc-power.sh cycle "$BMC_IP" "$BMC_USER" "$BMC_PASS" 20
   # POST + OS ブート完了を待つ（約3分）
   sleep 180
   ```

4. **BootOptions から VirtualMedia CD の Boot ID を動的検索**:
   ```sh
   BOOT_ID=$(scripts/bmc-power.sh find-boot-entry "$BMC_IP" "$BMC_USER" "$BMC_PASS" "ATEN Virtual CDROM")
   ```
   - Boot ID は固定ではなく OS インストール後に変動する（例: Boot0011 → Boot0013）
   - `find-boot-entry` は最大3回リトライする（30秒間隔）。POST 直後は BootOptions が空の場合があるが、リトライで検出される
   - 3回リトライしても見つからない場合は VirtualMedia マウントを再確認
   - **絶対に efibootmgr -c でブートエントリを手動作成しないこと**
     （無効なデバイスパスが UEFI BDS フェーズの POST code 92 スタックを引き起こす）

5. **Boot Override 設定**（UefiBootNext で VirtualMedia CD を直接指定）:
   ```sh
   scripts/bmc-power.sh boot-next "$BMC_IP" "$BMC_USER" "$BMC_PASS" "$BOOT_ID"
   ```

6. **電源サイクル**（CD ブート開始）:
   ```sh
   scripts/bmc-power.sh cycle "$BMC_IP" "$BMC_USER" "$BMC_PASS" 20
   ```

5. 完了: `scripts/os-setup-phase.sh mark bmc-mount-boot`

**エラー時**:
- CSRF エラー → `bmc-session.sh login` + `csrf` を再実行
- VirtualMedia マウント失敗 → status 確認、config 再実行

---

### Phase 5: install-monitor

**pve-lock**: 必要（Phase 4 から継続保持）

Debian インストーラの進行を3層で監視する。

#### 1. POST code ポーリング（30秒間隔）

`scripts/bmc-power.sh postcode` で BIOS/UEFI の進行を追跡する:

```sh
scripts/bmc-power.sh postcode "$BMC_IP" "$BMC_USER" "$BMC_PASS"
```

- POST code が変化していれば POST 進行中
- POST code `0x92` (PCI bus init) で10分以上停滞 → POST スタックの可能性（`reference.md` の回復手順参照）
- POST code が安定（変化なし5分以上）→ OS/インストーラがカーネルに制御移行済み
- POST code `0x00` → POST 完了 or 電源 Off

#### 2. SOL 監視（バックグラウンド）

`ipmitool sol activate` を `Bash(run_in_background=true)` で起動し、出力を監視:

```sh
ipmitool -I lanplus -H "$BMC_IP" -U "$BMC_USER" -P "$BMC_PASS" sol activate
```

出力があればキーワード検出:
- `Installation complete` → インストール完了
- `login:` → OS 起動完了（poweroff せずリブートした場合）
- `Power down` → シャットダウン中

SOL に出力がない場合（efi.img のシリアル設定が効かなかった場合）は POST code + PowerState で監視を続ける。

#### 3. PowerState ポーリング（5分間隔）

```sh
scripts/bmc-power.sh status "$BMC_IP" "$BMC_USER" "$BMC_PASS"
```

- `Off` → インストール完了（preseed の poweroff が成功）
- `On` が45分超過 → `scripts/bmc-power.sh forceoff` で強制停止

#### 4. BMC スクリーンショット（オプション）

DCMS ライセンスがある場合のみ使用可能:

```sh
scripts/bmc-screenshot.sh "$BMC_IP" "$COOKIE_FILE" "$CSRF" /tmp/installer-screenshot.bmp
```

ライセンスエラーが返った場合はスキップ（POST code + PowerState で代替）。

#### 完了処理

1. SOL を切断: `ipmitool ... sol deactivate`
2. 完了: `scripts/os-setup-phase.sh mark install-monitor`

---

### Phase 6: post-install-config

**pve-lock**: 必要

Debian インストール後の初期設定。

1. **VirtualMedia アンマウント + Boot Override 解除**:
   ```sh
   # BMC セッション再確立（必要なら）
   scripts/bmc-session.sh login "$BMC_IP" "$BMC_USER" "$BMC_PASS" "$COOKIE_FILE"
   CSRF=$(scripts/bmc-session.sh csrf "$BMC_IP" "$COOKIE_FILE")
   scripts/bmc-virtualmedia.sh umount "$BMC_IP" "$COOKIE_FILE" "$CSRF"
   pve-lock.sh run scripts/bmc-power.sh boot-override-reset "$BMC_IP" "$BMC_USER" "$BMC_PASS"
   ```

2. **ディスクからブート**:
   ```sh
   pve-lock.sh run scripts/bmc-power.sh on "$BMC_IP" "$BMC_USER" "$BMC_PASS"
   ```

3. **SOL 経由でログイン確認・設定**:
   > **重要**: preseed の late_command は Debian 13 で動作しないことが多い。
   > SSH 公開鍵、PermitRootLogin、sudoers は SOL 経由で設定する必要がある。

   python3 + subprocess で SOL に接続し、root/password でログイン後:
   ```
   sed -i "s/^#PermitRootLogin.*/PermitRootLogin yes/" /etc/ssh/sshd_config
   systemctl restart sshd
   echo "debian ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/debian
   chmod 0440 /etc/sudoers.d/debian
   mkdir -p /root/.ssh && chmod 700 /root/.ssh
   echo "<SSH_PUBKEY>" > /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys
   ```

   `<SSH_PUBKEY>` はローカルの `~/.ssh/id_ed25519.pub` を Read ツールで読み取った内容を使用する。
   ハードコードではなく、毎回ファイルから読み取ること。

4. **古いホスト鍵を削除**（OS 再インストールで鍵が変わるため）:
   ```sh
   ssh-keygen -R <dhcp_ip> 2>/dev/null || true
   ssh-keygen -R <static_ip> 2>/dev/null || true
   ```

5. **SSH 接続を待機**:
   - DHCP IP は変わる可能性がある。SOL の `ip -brief addr` で現在の IP を確認
   - SSH 接続確認: `ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no root@<ip> true`

6. **静的 IP 設定**:
   設定ファイルの `static_ip`, `static_iface` が指定されている場合:
   ```sh
   ssh root@<ip> 'printf "\nauto eno2np1\niface eno2np1 inet static\n    address 10.10.10.204/8\n" >> /etc/network/interfaces'
   ssh root@<ip> 'ifup eno2np1'
   ```

7. 完了: `scripts/os-setup-phase.sh mark post-install-config`

---

### Phase 7: pve-install

**pve-lock**: 必要

PVE のインストールを SSH 経由で実行。

1. **スクリプト転送**:
   ```sh
   scp scripts/pve-setup-remote.sh root@<ip>:/tmp/
   ```

2. **pre-reboot フェーズ**:
   ```sh
   ssh root@<ip> '/tmp/pve-setup-remote.sh --phase pre-reboot --hostname <hostname> --ip <static_ip> --codename <codename>'
   ```

3. **リブート**:
   ```sh
   ssh root@<ip> 'reboot' || true
   ```

4. **SSH 再接続待機**（最大10分、30秒間隔）:
   PVE カーネルでの起動を待つ。

5. **NIC 名変更チェック**:
   SSH 接続できない場合、SOL 経由で NIC 名を確認（`reference.md` 参照）。
   Debian 13 + PVE 9 では変更なし（eno1np0 等）を確認済みだが、念のためチェック。

6. **post-reboot フェーズ**:
   ```sh
   scp scripts/pve-setup-remote.sh root@<ip>:/tmp/
   ssh root@<ip> '/tmp/pve-setup-remote.sh --phase post-reboot --hostname <hostname> --ip <static_ip> --codename <codename>'
   ```

7. **最終リブート**:
   ```sh
   ssh root@<ip> 'reboot' || true
   ```

8. **PVE 動作確認**:
   - SSH 再接続待機（最大5分、30秒間隔で ping）
   - **注意**: リブート後5分以上ネットワーク到達不能な場合、BMC で ForceOff → On を試す
     （VirtualMedia が中途半端にマウントされているとブートが遅延する場合がある）
   - `ssh root@<ip> 'pveversion'` で PVE バージョン確認
   - `curl -sk https://<static_ip>:8006` で Web UI アクセス確認

9. 完了: `scripts/os-setup-phase.sh mark pve-install`

---

### Phase 8: cleanup

**pve-lock**: 必要

1. **VirtualMedia クリーンアップ**（まだマウントされていれば）:
   ```sh
   scripts/bmc-session.sh login "$BMC_IP" "$BMC_USER" "$BMC_PASS" "$COOKIE_FILE"
   CSRF=$(scripts/bmc-session.sh csrf "$BMC_IP" "$COOKIE_FILE")
   scripts/bmc-virtualmedia.sh umount "$BMC_IP" "$COOKIE_FILE" "$CSRF"
   ```

2. **Boot Override 確認・解除**:
   ```sh
   pve-lock.sh run scripts/bmc-power.sh boot-override-reset "$BMC_IP" "$BMC_USER" "$BMC_PASS"
   ```

3. **cookie ファイル削除**:
   ```sh
   rm -f "$COOKIE_FILE"
   ```

4. **最終検証サマリ**:
   - OS: `ssh root@<ip> 'cat /etc/os-release | head -2'`
   - PVE: `ssh root@<ip> 'pveversion'`
   - カーネル: `ssh root@<ip> 'uname -r'`
   - ネットワーク: `ssh root@<ip> 'ip -brief addr'`
   - Web UI: `curl -sk -o /dev/null -w '%{http_code}' https://<static_ip>:8006`

5. 完了: `scripts/os-setup-phase.sh mark cleanup`

6. **レポート作成**: `report/` ディレクトリに実行結果のレポートを作成（REPORT.md フォーマットに従う）

---

## Resume（中断からの再開）

スキル呼び出し時に `scripts/os-setup-phase.sh status` で現在の状態を確認し、
完了済みフェーズをスキップして次のフェーズから再開する。

`scripts/os-setup-phase.sh next` で次の未完了フェーズ名を取得できる。

失敗したフェーズは `scripts/os-setup-phase.sh reset <phase>` でリセットして再実行可能。

## pve-lock の使い方

Phase 4〜8 では状態変更操作に `pve-lock.sh` を使用する:

```sh
pve-lock.sh run <command...>     # 即座に実行（ロック中ならエラー）
pve-lock.sh wait <command...>    # ロック待ち→実行
```

ロック中の場合は別の課題に着手し、ロック解放後に再開する。
