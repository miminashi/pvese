# Server4 BIOS リセット + OS セットアップ 反復8 レポート

- **実施日時**: 2026年4月5日 18:19 〜 19:55 JST (約1時間36分)
- **対象サーバ**: 4号機 (ayase-web-service-4, 10.10.10.204)
- **反復**: 8回目

## 目的

Supermicro X11DPU (4号機) の BIOS F3 (Load Optimized Defaults) リセット後に、Debian 13 + Proxmox VE 9 の OS セットアップを実施し、スキル手順の習熟度と再現性を確認する。

## 実施内容

### BIOS リセット

- Delete キー 60回連打 (1秒間隔) で BIOS Setup に入場
  - キー 31〜45 番付近で canvas サイズ 720x400 → 800x600 → 1024x768 に変化
  - キー 45 番付近で "Aptio Setup Utility" Main タブが確認できた
- F3 → Enter (Load Optimized Defaults) 実行
- F4 → Enter (Save & Exit) で保存・リブート

### OS セットアップ フェーズ

| フェーズ | 所要時間 | 備考 |
|---------|---------|------|
| iso-download | 0m18s | 既存 ISO 再利用 (SHA256 確認) |
| preseed-generate | 0m07s | generate-preseed.sh 実行 |
| iso-remaster | 0m14s | 既存 ISO 再利用 (preseed ハッシュ一致) |
| bmc-mount-boot | 24m32s | ForceOff x3 リカバリ込み |
| install-monitor | 1m49s | SOL 監視、POWER_DOWN で完了検出 |
| post-install-config | 13m08s | SOL 鍵配置 + 静的 IP 設定 |
| pve-install | 36m06s | pre-reboot + post-reboot (手動修正あり) |
| cleanup | 1m24s | VirtualMedia umount + ブリッジ + IB |
| **合計** | **77m38s** | |

## 最終検証結果

| 項目 | 結果 |
|------|------|
| OS | Debian GNU/Linux 13.4 (trixie) |
| PVE | 9.1.7 (running kernel: 6.17.13-2-pve) |
| ホスト名 | ayase-web-service-4 |
| 静的 IP | 10.10.10.204/8 (vmbr0) |
| vmbr0 | eno2np1 (10.10.10.204/8) - UP |
| vmbr1 | eno1np0 (DHCP 192.168.39.x/24) - UP |
| IPoIB | ibp134s0 @ 192.168.100.1/24, MTU 65520, connected |
| drbd-dkms | 9.3.1-1 |
| linstor-satellite | 1.33.1-1 |
| PVE Web UI | https://10.10.10.204:8006 - 応答確認 |

## 発見事項

### 新規発見

1. **BIOS F3 後の POST スタック現象 (4号機)**
   - 症状: F3 Defaults リセット後のリブートで POST code 0x00/0x01 が stale 状態のまま黒画面が継続 (約3-5分)
   - 回数: 今回は ForceOff → 20s → On のリカバリを3回実施
   - 対処: ForceOff → 20s → On でリカバリ可能。リカバリ後はロゴ画面→FlexBoot→UEFI NVMe ブートの正常フローに復帰
   - 今後: bmc-mount-boot フェーズで POST スタックを検出する場合、3回まではリカバリを試みること

2. **post-reboot の postfix 依存関係エラー**
   - 症状: `apt-get install proxmox-ve` 実行時に exim4 と postfix の MTA 競合で exit code 100
   - 発生タイミング: post-reboot スクリプト内の proxmox-ve インストール時
   - 対処: 手動で `apt-get install -y proxmox-ve` を再実行して成功
   - 原因調査: pve-setup-remote.sh の pre-reboot で exim4 が残っている場合、proxmox-ve が postfix インストール時に競合する可能性

### 既知の事象 (再確認)

- **ATEN Virtual CDROM が BootOptions に現れない**: `find-boot-entry "ATEN Virtual CDROM"` は全3回失敗。ただし BIOS F3 後に Boot Option #1 が CD/DVD になっていたため、自動的にインストーラが起動した
- **POST code stale 値**: 0x00/0x01 が長時間継続 → KVM スクリーンショットで実際の状態確認が必須

## 比較 (反復7との差分)

| 項目 | 反復7 | 反復8 |
|------|-------|-------|
| bmc-mount-boot | 29m57s | 24m32s |
| install-monitor | 0m02s | 1m49s |
| post-install-config | 5m01s | 13m08s |
| pve-install | 34m54s | 36m06s |
| cleanup | 1m06s | 1m24s |
| **合計** | **71m13s** | **77m38s** |

反復8は install-monitor の SOL 監視が正常に動作したため install-monitor フェーズが伸び、post-install-config は POST の追加待機時間が含まれた。合計では約6分増加。

## 結論

反復8の BIOS F3 リセット + OS セットアップが正常完了。4号機特有の POST スタック現象 (BIOS F3 後) が発生したが、ForceOff → 20s → On のリカバリ手順で対処できた。PVE 9.1.7 + LINSTOR/DRBD (drbd-dkms 9.3.1, linstor-satellite 1.33.1) の稼働を確認。
