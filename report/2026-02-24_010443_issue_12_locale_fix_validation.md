# 課題 #12 locale 修正 通しテスト結果レポート

- **実施日時**: 2026年2月24日 00:11 - 01:04
- **課題**: #12 pve-setup-remote.sh: locale 設定をスクリプト冒頭に移動する
- **関連レポート**: [report/2026-02-23_234404_issue_4_11_fix_validation.md](2026-02-23_234404_issue_4_11_fix_validation.md)

## 前提・目的

課題 #12 で `scripts/pve-setup-remote.sh` の post-reboot フェーズにおいて locale 設定（`locale-gen` + `update-locale` + `LC_ALL` 設定）を PVE パッケージインストールより前に移動する修正を行った。この修正により、`proxmox-ve` パッケージインストール時に発生していた `locale: Cannot set LC_ALL to default locale` 警告が解消されることを、通しテスト（全8フェーズ）で検証する。

- **背景**: pre-reboot フェーズの `apt-get upgrade` や PVE カーネルインストール時に locale 警告が大量に出力されていた
- **修正内容**: post-reboot フェーズで `--- Fixing locale ---` を `--- Installing proxmox-ve ---` の前に実行するよう順序を変更
- **目的**: 修正後の通しテストで locale 警告が出なくなったことを確認する

## 環境情報

- **サーバ**: Supermicro X11DPU (ayase-web-service-4)
- **BMC IP**: 10.10.10.24
- **サーバ IP**: 10.10.10.204 (static, eno2np1) / 192.168.39.199 (DHCP, eno1np0)
- **OS**: Debian 13.3 (Trixie)
- **PVE**: pve-manager/9.1.5 (kernel: 6.17.9-1-pve)
- **ISO**: debian-13.3.0-amd64-netinst.iso (sha256: c9f09d24...)

## テスト結果

### フェーズ実行サマリ

| Phase | 名前 | 結果 | 備考 |
|-------|------|------|------|
| 1 | iso-download | OK | 既存 ISO 再利用（sha256 一致） |
| 2 | preseed-generate | OK | テンプレート変数置換確認 |
| 3 | iso-remaster | OK | xorriso で ISO 再構築 |
| 4 | bmc-mount-boot | OK | VirtualMedia マウント → Boot000E → CD ブート |
| 5 | install-monitor | OK | 約7.5分でインストール完了（自動 poweroff） |
| 6 | post-install-config | OK | SOL ログイン、SSH/sudoers 設定、静的 IP 設定 |
| 7 | pve-install | **OK** | **locale 警告なし（重点確認ポイント）** |
| 8 | cleanup | OK | 最終検証サマリ全項目パス |

### Phase 7: locale 検証結果（重点）

#### post-reboot フェーズの出力順序

```
=== Phase: post-reboot ===
--- Fixing locale ---          ← locale 修正が最初に実行
--- Installing proxmox-ve ---  ← PVE インストールはその後
```

**確認事項**:
- `--- Fixing locale ---` が `--- Installing proxmox-ve ---` より前に出力されている: **OK**
- post-reboot フェーズ全体で `locale: Cannot set LC_ALL to default locale` 警告: **0件**
- post-reboot フェーズ全体で `Setting locale failed` 警告: **0件**
- PVE インストール・Debian カーネル削除: **正常完了**

#### 注記: pre-reboot フェーズでは locale 警告あり（想定内）

pre-reboot フェーズ（locale 修正前に実行される `apt-get upgrade` と PVE カーネルインストール）では依然として locale 警告が出る。これは preseed インストール直後の環境で `ja_JP.UTF-8` の `LC_TIME` が設定されているが locale が生成されていないため。post-reboot フェーズの冒頭で locale が修正されるため、以降の操作には影響しない。

### Phase 8: 最終検証

```
--- OS ---
PRETTY_NAME="Debian GNU/Linux 13 (trixie)"

--- PVE ---
pve-manager/9.1.5/80cf92a64bef6889 (running kernel: 6.17.9-1-pve)

--- Kernel ---
6.17.9-1-pve

--- Locale ---
LC_ALL=en_US.UTF-8 （全項目 en_US.UTF-8）

--- Network ---
eno1np0  UP  192.168.39.199/24
eno2np1  UP  10.10.10.204/8

--- Web UI ---
https://10.10.10.204:8006 -> HTTP 200
```

## 再現方法

1. `scripts/os-setup-phase.sh` で全フェーズをリセット
2. `os-setup` スキルに従い Phase 1-8 を順番に実行
3. Phase 7 の post-reboot 出力で locale 警告の有無を確認

## 追加変更

- `CLAUDE.md` に通しテストのルールを追記:「通しテストはユーザの明確な指示で実行する」

## 結論

課題 #12 の修正（locale 設定を post-reboot フェーズ冒頭に移動）により、`proxmox-ve` パッケージインストール時の locale 警告が完全に解消されたことを通しテストで確認した。
