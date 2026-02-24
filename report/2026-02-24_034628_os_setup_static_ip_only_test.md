# os-setup 通しテスト: 静的 IP のみで Phase 1-8 完了検証

- **実施日時**: 2026年2月24日 02:58〜03:46
- **所要時間**: 約 48 分
- **セッション**: eb24305a

## 前提・目的

SKILL.md を修正し、DHCP IP (192.168.39.x) への SSH 接続を排除、全て静的 IP (10.10.10.204) 経由に変更した。この修正が正しく動作するか Phase 1-8 の通しテストで検証する。

- **背景**: OS 再インストールで DHCP アドレスが変動するため、SSH 接続を静的 IP に統一する必要があった
- **目的**: Phase 6 で SOL 経由で静的 IP を設定し、以降全 SSH を静的 IP のみで実行するフローの動作検証
- **前提条件**: BMC (10.10.10.24) にアクセス可能、SMB 共有 (10.1.6.1) が利用可能
- **参考**: [2026-02-24_023448_os_setup_phase1-8_sol_monitor_test.md](2026-02-24_023448_os_setup_phase1-8_sol_monitor_test.md)

## 環境情報

- サーバ: Supermicro X11DPU (ayase-web-service-4)
- BMC IP: 10.10.10.24
- 静的 IP: 10.10.10.204 (eno2np1)
- DHCP IP: 192.168.39.201 (eno1np0) — 今回は一切使用しない
- OS: Debian 13.3 (trixie) preseed インストール
- PVE: 9.1.5 (カーネル 6.17.9-1-pve)

## 検証ポイント

| # | 検証項目 | 結果 |
|---|---------|------|
| 1 | Phase 6 で SOL 経由の静的 IP 設定が成功すること | OK |
| 2 | `ssh-keygen -R` は静的 IP (10.10.10.204) のみ | OK |
| 3 | SSH 接続は静的 IP のみ (`ssh root@10.10.10.204`) | OK |
| 4 | Phase 7 の scp/ssh は全て静的 IP 経由 | OK |
| 5 | Phase 8 の最終検証で PVE が静的 IP で動作 | OK |
| 6 | DHCP IP (192.168.39.x) は一切使用しない | OK |

## フェーズ別結果

### Phase 1: iso-download (スキップ)
- ISO 既存 + sha256 一致のためスキップ
- `c9f09d24b7e834e6834f2ffa565b33d6f1f540d04bd25c79ad9953bc79a8ac02`

### Phase 2: preseed-generate
- `scripts/generate-preseed.sh config/os-setup.yml preseed/preseed-generated.cfg` → 成功

### Phase 3: iso-remaster
- `scripts/remaster-debian-iso.sh` → efi.img は Option B (grub-mkstandalone) で再構築
- 出力: `/var/samba/public/debian-preseed.iso` (763MB)

### Phase 4: bmc-mount-boot
- VirtualMedia マウント成功 (DEVICE ID="0" STATUS="4")
- パワーサイクル後、Boot ID = `Boot000E` を検出
- BootNext 設定 + パワーサイクルで CD ブート開始

### Phase 5: install-monitor
- sol-monitor.py で監視（初回は PowerState Off を即検出 → 再実行で正常監視）
- ステージ進行: LOADING_COMPONENTS (1.6min) → CONFIGURING_APT (1.9min) → INSTALLING_SOFTWARE (5.1min) → INSTALLING_GRUB (6.4min) → POWER_DOWN (7.1min)
- 合計約 7.7 分で完了

### Phase 6: post-install-config（核心部分）
1. VirtualMedia アンマウント + Boot Override 解除
2. サーバ起動 (Power On)
3. SOL 経由で以下を実行:
   - PermitRootLogin yes 設定
   - SSH 公開鍵設置
   - sudoers 設定
   - **静的 IP 設定 (`eno2np1 inet static 10.10.10.204/8`)**
   - `ifup eno2np1`
4. `ssh-keygen -R 10.10.10.204` のみ実行（DHCP IP なし）
5. `ssh -o StrictHostKeyChecking=no root@10.10.10.204 true` → **成功**

### Phase 7: pve-install
- `scp scripts/pve-setup-remote.sh root@10.10.10.204:/tmp/` → 静的 IP 経由
- pre-reboot: PVE リポジトリ追加、パッケージ更新、PVE カーネルインストール
- リブート後: 最初の SSH 接続に約 3.5 分要した（パワーサイクルで解消）
- post-reboot: proxmox-ve インストール（already newest）、Debian カーネル削除
- 最終リブート後: `pveversion` → pve-manager/9.1.5, Web UI → HTTP 200

### Phase 8: cleanup
- VirtualMedia アンマウント、Boot Override 解除、cookie 削除

## 最終検証サマリ

```
OS:       Debian GNU/Linux 13 (trixie)
PVE:      pve-manager/9.1.5/80cf92a64bef6889 (running kernel: 6.17.9-1-pve)
Kernel:   6.17.9-1-pve
Network:
  lo        UNKNOWN  127.0.0.1/8
  eno1np0   UP       192.168.39.201/24
  eno2np1   UP       10.10.10.204/8
  eno3np2   DOWN
  eno4np3   DOWN
Web UI:   https://10.10.10.204:8006 → HTTP 200
```

## 注意点・改善メモ

1. **sol-monitor.py 初回の誤検出**: サーバ起動直後は PowerState が安定せず、初回ポーリングで Off を検出して早期終了することがある。再実行で解消。
2. **PVE カーネル初回ブート遅延**: pre-reboot 後のリブートで SSH 接続まで 3.5 分以上かかった。パワーサイクル (ForceOff + On) で解消。VirtualMedia の中途半端なマウント状態が原因の可能性あり（Phase 6 でアンマウント済みだが POST でスキャンされる場合がある）。

## 再現方法

```sh
# Phase 全リセット
scripts/os-setup-phase.sh reset iso-download
scripts/os-setup-phase.sh reset preseed-generate
# ... (全8フェーズ)

# os-setup スキルを実行（config/os-setup.yml 使用）
# SKILL.md に従い Phase 1-8 を順次実行
```

## 結論

SKILL.md の静的 IP のみフローは正常に動作する。Phase 6 で SOL 経由で静的 IP を設定し、以降全ての SSH/scp を `root@10.10.10.204` で実行するフローで Phase 1-8 が完了した。DHCP IP は一切使用していない。
