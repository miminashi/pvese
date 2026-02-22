# OS セットアップスキル テスト実行 #1

- **実施日時**: 2026年2月22日 03:28〜13:11 (UTC)

## 前提・目的

`/os-setup` スキルの実装後、初回テスト実行として Debian 13 + PVE 9 のフルインストールを実施し、スクリプトとスキル定義の問題を発見・修正する。

## 環境情報

- サーバ: Supermicro SYS-6019U-TN4R4T (X11DPU)
- BMC IP: 10.10.10.24
- サーバ IP: 10.10.10.204 (static), 192.168.39.202 (DHCP)
- NIC: eno1np0 (DHCP), eno2np1 (static 10.10.10.204/8)
- ターゲットディスク: /dev/nvme0n1
- OS: Debian 13.3 (Trixie) → PVE 9.1.5
- カーネル: 6.17.9-1-pve

## 結果

**成功**: Debian 13 + PVE 9 のインストール完了。SSH 接続可能、Web UI (https://10.10.10.204:8006) アクセス可能。

## 発見した問題と修正

### 問題 1: VirtualMedia CGI エンドポイントが 404

- **症状**: `bmc-virtualmedia.sh config` で 404 Not Found
- **原因**: エンドポイントを `cgi/virtual_media/config.cgi` にしていた
- **修正**: `cgi/op.cgi` に変更（`bmc-virtualmedia.sh` 更新）

### 問題 2: Boot Override `Cd` が VirtualMedia CD にマッチしない

- **症状**: Boot Override を Cd/UEFI に設定して電源サイクルしても、ディスクから既存 OS が起動する
- **原因**: Redfish の `BootSourceOverrideTarget=Cd` が ATEN Virtual CDROM デバイスにマッチしない
- **修正**: `UefiBootNext` + `BootNext=Boot0011` で ATEN Virtual CDROM の BootOption ID を直接指定（`bmc-power.sh` に `boot-next` サブコマンド追加）

### 問題 3: SOL にインストーラのシリアル出力が来ない

- **症状**: SOL 接続は成功するが、インストーラの出力が VGA のみ
- **原因**: UefiBootNext でブートした場合、ISO の GRUB 設定でシリアル出力が効かない可能性
- **対応**: Phase 5 の監視を PowerState ポーリング方式に変更（SKILL.md 更新）

### 問題 4: preseed の late_command が全く動作しない

- **症状**: PermitRootLogin、sudoers、全 NIC DHCP 設定が未適用
- **原因**: Debian 13 で in-target を使った late_command が失敗する（install_notes.md 既知問題）
- **対応**: Phase 6 で SOL 経由の手動設定手順を SKILL.md に記載。SSH 公開鍵配置も追加。

### 問題 5: preseed の poweroff が Debian 13 で動作しない

- **症状**: インストール完了後も PowerState が On のまま（45分超過）
- **原因**: `d-i debian-installer/exit/poweroff boolean true` が Debian 13 で効かない
- **対応**: 45分タイムアウト後に ForceOff を実行する手順を SKILL.md に記載。

### 問題 6: cdrom リポジトリが apt-get update でエラー

- **症状**: `pve-setup-remote.sh` の `apt-get update` で cdrom リポジトリエラー
- **修正**: `sed -i '/^deb cdrom:/d' /etc/apt/sources.list` を pre-reboot フェーズに追加

### 問題 7: /etc/hosts に行が重複追加される

- **症状**: `pve-setup-remote.sh` を2回実行すると /etc/hosts に同じ行が重複
- **修正**: `grep -q "${ip}"` で既存行チェックを追加

## 修正ファイル一覧

| ファイル | 修正内容 |
|---------|---------|
| `scripts/bmc-virtualmedia.sh` | エンドポイントを `cgi/op.cgi` に変更 |
| `scripts/bmc-power.sh` | `boot-next` サブコマンド追加 |
| `scripts/pve-setup-remote.sh` | cdrom 行削除、/etc/hosts 重複防止 |
| `.claude/skills/os-setup/SKILL.md` | Phase 4/5/6 を実体験に基づき更新 |
| `.claude/skills/os-setup/reference.md` | UefiBootNext、VirtualMedia エンドポイント追記 |
| `memory/bmc_api.md` | エンドポイント修正 |

## フェーズ所要時間（概算）

| Phase | 時間 |
|-------|------|
| 1 iso-download | 0分（ダウンロード済み） |
| 2 preseed-generate | 1分 |
| 3 iso-remaster | 2分 |
| 4 bmc-mount-boot | 3分（2回失敗 + 再試行） |
| 5 install-monitor | 45分（poweroff 未動作のため ForceOff） |
| 6 post-install-config | 15分（SOL 経由設定） |
| 7 pve-install | 25分 |
| 8 cleanup | 2分 |
