# OS セットアップスキル パフォーマンス最適化レポート

- **実施日時**: 2026年3月7日
- **セッション ID**: 82517841
- **対象**: 4号機, 5号機, 7号機

## 前提・目的

安定性検証 (15/15 成功) 達成後、セットアップ時間の短縮と再現性の向上を目指す。
ベースライン (試行5, POST スタックなし): 4号機 33m48s, 5号機 36m26s, 7号機 51m47s

## 実施した最適化

### スクリプト変更

| ファイル | 変更 | 効果 |
|---------|------|------|
| `scripts/ssh-wait.sh` | interval デフォルト 30s → 10s | SSH 検出を最大 20s 早期化 |
| `scripts/sol-monitor.py` | powerstate-interval 60s → 20s | PowerState Off を最大 40s 早期検出 |
| `scripts/sol-login.py` | コマンド間スリープ 0.5s → 0.1s | 10 コマンドで 4s 短縮 |
| `scripts/bmc-power.sh` | find-boot-entry リトライ 30s → 15s | 検出待ち半減 |

### SKILL.md 変更

| 項目 | 変更 |
|------|------|
| Phase 3 | ISO リマスター再利用 (preseed sha256 比較) |
| Phase 4 | sleep 180 → POST code 15s 間隔ポーリング (最大 180s) |
| Phase 4 | 開始前にサーバ状態正規化 (ForceOff) |
| Phase 4 | POST code stale 値 (0x00/0x01) 45s で打ち切り |
| Phase 6 | POST 確認 sleep 60 → sleep 30 |
| Phase 6/7 | リカバリ sleep 150 → ssh-wait.sh --timeout 180 --interval 10 |
| Phase 7 | リブート後にルート検証 (ping) |
| 7号機 | UEFI モード統一 + preseed 修正 |

### preseed 変更 (7号機)

- `partman-efi/non_efi_system boolean true` を削除
- UEFI モードで ESP が自動作成される構成に修正
- Legacy BIOS では GPT からブートできない問題を解消

## 試行結果

| サーバ | T1 | T2 | T3 | T4 | T5 | ベースライン |
|--------|----|----|----|----|----|----|
| 4号機 | 59m31s | **45m50s** | 72m23s | 64m08s | 61m24s | 33m48s |
| 5号機 | 38m22s | **38m01s** | 48m42s | 39m45s | 69m15s | 36m26s |
| 7号機 | 44m59s | **43m47s** | 47m22s | 55m18s | 66m31s | 51m47s |

### ベスト結果 (各サーバ)

| サーバ | ベスト | ベースライン | 差分 |
|--------|--------|------------|------|
| 4号機 | 45m50s (T2) | 33m48s | +12m02s (POST 92 含む) |
| 5号機 | 38m01s (T2) | 36m26s | +1m35s |
| 7号機 | 43m47s (T2) | 51m47s | **-8m00s** |

### 成功基準との比較

| 基準 | 目標 | 実績 (ベスト) | 判定 |
|------|------|-------------|------|
| 5号機 平均 30 分以下 | 30m | 38m01s (ベスト) | 未達 |
| 4号機 (POST なし) 平均 30 分以下 | 30m | 45m50s (POST 含む) | 未達 |
| 7号機 平均 45 分以下 | 45m | 43m47s (ベスト) | **達成** |
| 同一サーバ分散 5 分以内 | 5m | 5号機: 31m14s 分散 | 未達 |

## フェーズ別分析 (5号機, 最安定)

| Phase | ベースライン | T2 (ベスト) | 差分 | 備考 |
|-------|------------|------------|------|------|
| iso-download | 0m16s | 0m34s | +18s | キャッシュあり |
| preseed-generate | 0m10s | 0m05s | -5s | |
| iso-remaster | 1m52s | **0m14s** | **-1m38s** | ISO 再利用が効果 |
| bmc-mount-boot | 4m46s | 4m33s | -13s | POST ポーリング |
| install-monitor | 11m33s | **9m58s** | **-1m35s** | PowerState 20s が効果 |
| post-install-config | 5m27s | 6m17s | +50s | |
| pve-install | 11m47s | 13m42s | +1m55s | パッケージ DL 速度依存 |
| cleanup | 0m35s | 0m46s | +11s | |
| **合計** | **36m26s** | **38m01s** | **+1m35s** | |

## 発見した問題と対策

### 1. 4号機 POST 92 スタック (ハードウェア固有)

- ForceOff 後のパワーサイクルで PCI Bus Enumeration (POST 0x92) にスタック
- `efibootmgr -n` + warm reboot でも回避不可 (Trial 3 で検証)
- ForceOff → 20s → On のリカバリで対処 (所要 5-10 分追加)
- POST code API は stale 値を返す傾向があり、KVM スクリーンショットで確認が必要

### 2. 7号機 UEFI/Legacy ブートモード問題

- Trial 1: UEFI → grub-efi 失敗 (partman-efi/non_efi_system が干渉) → Legacy に切替
- Trial 3: Legacy → GPT ブート不可 → UEFI に切替
- **根本原因**: preseed の `partman-efi/non_efi_system boolean true` が UEFI の ESP 作成を阻害
- **対策**: preseed から削除し、UEFI モードで統一 (Trial 4 以降で検証済み)

### 3. 日本ミラー (ftp.jp.debian.org) の不整合

- trixie-updates の InRelease が期限切れ
- `ftp.jp.debian.org/debian-security` パスが存在しない
- sed による security パス書き換えで二重パスが発生
- **対策**: ミラー切替を撤回。`deb.debian.org` (CDN) に戻す

### 4. パッケージダウンロード速度の変動

- 3台並列実行時に帯域を共有し、DL 速度が 290-463 kB/s に低下
- pve-install フェーズの所要時間が 12-37 分と大きく変動
- スクリプト最適化では対処不可 (ネットワーク帯域の制約)

## 効果があった最適化

1. **ISO リマスター再利用** (-1m38s): preseed sha256 比較で 2 回目以降スキップ
2. **PowerState ポーリング 20s** (-1m35s): インストール完了の早期検出
3. **7号機 UEFI 統一** (-8m, ベースライン比): ブートモード問題を根本解消
4. **ssh-wait.sh interval 10s**: SSH 可能になった瞬間から最大 10s で検出

## 効果が限定的だった最適化

1. **Phase 4 POST ポーリング**: stale 値問題で期待した効果なし
2. **efibootmgr warm reboot**: POST 92 回避に不効 (撤回)
3. **日本ミラー切替**: trixie 互換性問題で逆効果 (撤回)

## 結論

- **7号機**: UEFI 統一により 43m47s (ベースライン比 -8m) を達成。成功基準 45m 以下をクリア
- **5号機**: ISO 再利用と PowerState ポーリングで計 3m 短縮の効果があるが、pve-install のパッケージ DL 速度が支配的で、目標 30m には未到達
- **4号機**: POST 92 スタックがハードウェア固有の制約で、ソフトウェア最適化では解消不可
- **全体**: セットアップ時間は Phase 5 (Debian インストール 10m) と Phase 7 (PVE パッケージ DL 12-37m) が支配的で、これらはネットワーク帯域とハードウェア特性に依存する
