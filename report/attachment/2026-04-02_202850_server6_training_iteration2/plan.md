# 6号機 os-setup トレーニング Iteration 1 継続

## Context

6号機 (Supermicro X11DPU, BMC 10.10.10.26, static IP 10.10.10.206) は Debian 13 を NVMe にインストール済みだが、UEFI ブート確認が未完了の状態で電源 Off。preseed late_command で grub-efi-amd64 をインストールしたが、`bootdev disk options=efiboot` で PXE に落ちたため、BIOS Boot Order の設定が必要。

前回のレポート (`report/2026-04-02_034720_server6_training_iteration1.md`) の「次回の作業項目」を完了させ、Phase 6-8 を実行して os-setup を完了する。

## 主要ファイル

- `config/server6.yml` — サーバ設定
- `.claude/skills/os-setup/SKILL.md` — os-setup スキル定義
- `.claude/skills/bios-setup/SKILL.md` — BIOS 操作スキル定義
- `scripts/bmc-power.sh` — 電源/Redfish 操作
- `scripts/bmc-kvm-interact.py` — KVM スクリーンショット/キー送信
- `scripts/sol-login.py` — SOL ログイン
- `scripts/pve-setup-remote.sh` — PVE セットアップ
- `scripts/pve-bridge-setup.sh` — ブリッジ設定
- `scripts/ib-setup-remote.sh` — IPoIB 設定

## 手順

### 0. セッション準備

1. Glob で session-id 取得、`mkdir -p tmp/<sid>`
2. `./issue.sh list` で課題状態確認
3. `./scripts/os-setup-phase.sh status --config config/server6.yml` でフェーズ状態確認

### A. UEFI ブート確認・修正 (最重要ゲート)

**目標**: 6号機を NVMe から UEFI ブートさせる

#### A1. BIOS Setup に入る
- `ipmitool chassis bootdev bios` → `bmc-power.sh on`
- 150秒待機 (6号機 POST 所要時間)
- KVM スクリーンショットで "Aptio Setup Utility" 確認

#### A2. Save & Exit タブで Boot Override 確認
- ArrowRight x6 で Save & Exit タブへ
- Boot Override セクションまでスクロール
- "debian" (NVMe UEFI) エントリの有無を確認

#### A3. Boot タブで Boot Option #1 を設定
- ArrowLeft x1 で Boot タブへ (Save & Exit → Boot)
- Boot Option #1 の現在値を確認
- Boot Option #1 = "UEFI Hard Disk:debian" (index 10) に変更:
  - ArrowDown x2 → Enter → ArrowDown x10 → Enter
- F4 → Enter で Save & Exit

#### A4. ブート確認
- POST 完了を待機 (KVM スクリーンショット or POST code ポーリング)
- ログインプロンプト表示を確認
- **PXE に落ちた場合**: Boot Mode を DUAL → UEFI に変更して再試行

**フォールバック**: "UEFI Hard Disk:debian" が存在しない場合 → grub-efi 未インストール。VirtualMedia CD からの rescue boot or フルリインストールを検討

### B. Phase 6: post-install-config

**前提**: A で UEFI ブート成功

#### B1. VirtualMedia クリーンアップ + Boot Override リセット
- bmc-session login → csrf → vmedia umount → boot-override-reset
- スクリプトファイル経由で実行 (CSRF の $() 置換回避)

#### B2. SOL ログイン + SSH 設定
- `ssh/id_ed25519.pub` の公開鍵を読み取り
- SOL コマンドファイル作成:
  - PermitRootLogin yes
  - sudoers NOPASSWD
  - SSH authorized_keys
  - static IP (eno2np1 = 10.10.10.206/8)
  - ifup eno2np1
- `./scripts/sol-login.py` で実行

#### B3. SSH 接続確認
- `ssh-keygen -R 10.10.10.206 -f ssh/known_hosts`
- `./scripts/ssh-wait.sh 10.10.10.206 --timeout 150 --interval 10`
- `ssh -F ssh/config pve6 hostname` で疎通確認

#### B4. フェーズ完了マーク

### C. Phase 7: pve-install

#### C1. インターネット経路修正
- default gw を 10.10.10.1 → 192.168.39.1 に切替
- eno1np0 (DHCP) を有効化
- `ping -c1 -W3 deb.debian.org` で疎通確認

#### C2. pre-reboot
- `scp` で pve-setup-remote.sh 転送
- `ssh pve6 /tmp/pve-setup-remote.sh --phase pre-reboot --hostname ayase-web-service-6 --ip 10.10.10.206 --codename trixie --serial-unit 1`
- PVE リポジトリ追加、PVE カーネルインストール、GRUB シリアル設定

#### C3. リブート + SSH 待機
- `ssh pve6 reboot` → `ssh-wait.sh` (timeout 300s)
- **注意**: リブート後に UEFI Boot Order が変わる可能性。PXE に落ちたら A3 を再実行

#### C4. インターネット経路再修正 + post-reboot
- 再度 default gw を 192.168.39.1 に切替
- `pve-setup-remote.sh --phase post-reboot ... --linstor`
- proxmox-ve, LINSTOR/DRBD パッケージインストール

#### C5. 最終リブート + PVE 確認
- `ssh pve6 reboot` → `ssh-wait.sh`
- `ssh pve6 pveversion` / `curl -sk https://10.10.10.206:8006`

#### C6. フェーズ完了マーク

### D. Phase 8: cleanup

#### D1. ブリッジ設定 (vmbr0/vmbr1)
- `pve-bridge-setup.sh --static-iface eno2np1 --static-ip 10.10.10.206/8 --dhcp-iface eno1np0`

#### D2. IB 設定 (IPoIB)
- `ib-setup-remote.sh --ip 192.168.100.3/24 --mode connected --mtu 65520 --persist`

#### D3. 最終検証
- OS バージョン、PVE バージョン、カーネル、ネットワーク、Web UI

#### D4. クリーンアップ
- Cookie 削除、フェーズ完了マーク、タイミング出力

### E. レポート作成

- `report/` にレポート作成 (REPORT.md フォーマット)
- Issue #41 の状態を更新 (DIMM エラー観察結果に応じて)

## 検証方法

1. `ssh -F ssh/config pve6 pveversion` → PVE 9.x 表示
2. `ssh -F ssh/config pve6 uname -r` → pve カーネル
3. `curl -sk https://10.10.10.206:8006` → PVE Web UI レスポンス
4. `ssh -F ssh/config pve6 ip -brief addr` → vmbr0 + vmbr1 + ib0
5. `./scripts/os-setup-phase.sh times --config config/server6.yml` → 全フェーズ完了
