# OS Setup 通しテスト (Issue #17: VirtualMedia Redfish verify 追加)

- **実施日時**: 2026年2月24日 18:37 - 19:27

## 前提・目的

Issue #17 — `bmc-virtualmedia.sh mount` 後に Redfish API で `Inserted` フィールドを確認する `verify` コマンドを追加し、CSRF トークン失効による silent failure を検出可能にする。

- **背景**: 前回テスト (2026-02-24 14:00) で Phase 4 に 23m56s を要した。CGI API が `VMCOMCODE=001` (成功) を返しながら実際にはマウントされていない問題が原因で、3回のパワーサイクルが必要だった
- **目的**: Redfish 検証ステップの追加により、マウント失敗を即座に検出して再マウントし、Phase 4 の所要時間を短縮する
- **前提条件**: 既存 Debian + PVE インストール済みサーバを再インストール

### 参照レポート

- [report/2026-02-24_150952_os_setup_issue16_fix_test.md](2026-02-24_150952_os_setup_issue16_fix_test.md) — 前回の通しテスト (54m47s, Phase 4 で 23m56s)

## 環境情報

| 項目 | 値 |
|------|-----|
| サーバ | Supermicro X11DPU (ayase-web-service-4) |
| BMC IP | 10.10.10.24 |
| サーバ IP | 10.10.10.204 (static, eno2np1) |
| OS | Debian 13.3 (Trixie) |
| PVE | pve-manager/9.1.5 |
| カーネル | 6.17.9-1-pve |
| ISO | debian-13.3.0-amd64-netinst.iso (preseed 組み込みリマスター版) |
| ディスク | /dev/nvme0n1 |

## Issue #17 修正内容

### コミット 1: `6e22680` — verify コマンド追加

`scripts/bmc-virtualmedia.sh` に `cmd_verify()` 関数を追加:

```sh
cmd_verify() {
    bmc_ip="$1"
    bmc_user="$2"
    bmc_pass="$3"

    result=$(curl -sk -u "${bmc_user}:${bmc_pass}" \
        "https://${bmc_ip}/redfish/v1/Managers/1/VirtualMedia/CD1")

    inserted=$(echo "$result" | sed -n 's/.*"Inserted"[[:space:]]*:[[:space:]]*\([a-z]*\).*/\1/p')
    connected=$(echo "$result" | sed -n 's/.*"ConnectedVia"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')

    echo "Inserted: $inserted, ConnectedVia: $connected"

    if [ "$inserted" = "true" ]; then
        return 0
    else
        echo "ERROR: VirtualMedia not inserted (CSRF token may have expired)" >&2
        return 1
    fi
}
```

**設計ポイント**:
- CGI セッション (cookie + CSRF) ではなく Redfish Basic Auth を使用 → CSRF 失効の影響を受けない
- `jq` 不要 (POSIX sh の `sed` でパース)
- exit code: 0=マウント済み, 1=未マウント

### コミット 2: `867423c` — SKILL.md Phase 4 更新

Phase 4 のステップ 2 (VirtualMedia マウント) の後にステップ 3 (Redfish 検証) を追加。`Inserted: false` の場合は BMC 再ログイン + CSRF 再取得 + 再マウントのリカバリ手順を記載。

## フェーズ実行結果

| Phase | Name | 所要時間 | 前回比 | 備考 |
|-------|------|---------|--------|------|
| 1 | iso-download | 0m17s | +4s | sha256 検証のみ |
| 2 | preseed-generate | 0m08s | +2s | |
| 3 | iso-remaster | 1m35s | ±0s | xorriso による ISO 再構築 |
| 4 | bmc-mount-boot | **7m32s** | **-16m24s** | verify でマウント確認、パワーサイクル1回のみ |
| 5 | install-monitor | 10m11s | -43s | SOL 監視、正常インストール完了 |
| 6 | post-install-config | 13m43s | +10m33s | POST 92 スタック → パワーサイクルリカバリ (後述) |
| 7 | pve-install | 17m20s | +3m20s | pre-reboot + reboot + post-reboot + final reboot |
| 8 | cleanup | 0m58s | +5s | VirtualMedia アンマウント + 最終検証 |
| | **合計** | **51m44s** | **-3m03s** | 前回 54m47s |

### 前回比の分析

- **Phase 4 大幅短縮 (-16m24s)**: verify コマンドにより、マウント成功を1回で確認でき、パワーサイクルは1回のみで済んだ。前回は CSRF silent failure により3回のパワーサイクルが必要だった
- **Phase 6 増加 (+10m33s)**: 初回 Power On 後に POST code 92 (PCI Bus Enumeration) でスタック。ForceOff → 20秒待機 → Power On → 3分待機 のリカバリサイクルが発生
- **Phase 7 増加 (+3m20s)**: PVE パッケージダウンロードの帯域変動 (4m59s @ 1155 kB/s)
- **合計で 3分03秒短縮**: Phase 4 の16分短縮が Phase 6/7 の増加を相殺

## verify コマンドの動作ログ

### 初回マウント (SMB パス二重バックスラッシュ問題)

最初の試行で SMB パスが `\\public\\debian-preseed.iso` (二重バックスラッシュ) になり、CGI は成功を返すが verify で検出:

```
=== VirtualMedia Config ===
Config result: ok
=== VirtualMedia Mount ===
Mount result: VMCOMCODE=001
=== VirtualMedia Verify (Redfish) ===
Inserted: false, ConnectedVia: NotConnected
ERROR: VirtualMedia not inserted (CSRF token may have expired)
```

### 修正後のマウント (正しい単一バックスラッシュ)

SMB パスを `\public\debian-preseed.iso` に修正し、yq から読み取った値を使用:

```
=== VirtualMedia Config (path: \public\debian-preseed.iso) ===
Config result: ok
=== VirtualMedia Mount ===
Mount result: VMCOMCODE=001
=== VirtualMedia Verify (Redfish) ===
Inserted: true, ConnectedVia: URI
Verify exit code: 0
```

**教訓**: シェルのシングルクォート内で `\\` はリテラルな2文字のバックスラッシュになる。yq で YAML から読み取った値 (`\public`) を直接使うのが正しい。

## トラブルシューティング

### POST code 92 スタック (Phase 6)

Phase 6 で Power On 後、POST code 92 (DXE--BIOS PCI Bus Enumeration) で約4分間スタックした。sol-login.py が 180秒タイムアウトで失敗。ForceOff + 20秒待機 + Power On + 3分待機で回復し、ログインプロンプトに到達。

この問題は VirtualMedia のマウント/アンマウント後のパワーサイクルで散発的に発生する。UEFI が PCI バス列挙中に VirtualMedia デバイスの検出でタイムアウトする模様。

## スクリーンショット

| タイミング | ファイル | 内容 |
|-----------|---------|------|
| Phase 4: verify 後 | ![](../tmp/07e102fa/screenshots/phase4-verify-mounted.png) | PVE ログインプロンプト (マウント前の OS 稼働中画面) |
| Phase 5: install 完了 | ![](../tmp/07e102fa/screenshots/phase5-install-complete.png) | 電源 Off 後の画面 (640x480) |
| Phase 6: POST 92 スタック | ![](../tmp/07e102fa/screenshots/phase6-boot-after-install.png) | DXE--BIOS PCI Bus Enumeration.. 画面 |
| Phase 6: リカバリ後 | ![](../tmp/07e102fa/screenshots/phase6-recovery-check.png) | Debian 13 ログインプロンプト |
| Phase 7: PVE 稼働 | ![](../tmp/07e102fa/screenshots/phase7-pve-running.png) | PVE カーネルでの稼働画面 |
| Phase 8: 最終検証 | ![](../tmp/07e102fa/screenshots/phase8-final.png) | 最終稼働状態 |

## 最終検証サマリ

| 項目 | 値 |
|------|-----|
| OS | Debian GNU/Linux 13 (trixie) |
| PVE | pve-manager/9.1.5/80cf92a64bef6889 (running kernel: 6.17.9-1-pve) |
| カーネル | 6.17.9-1-pve |
| ネットワーク | eno1np0: 192.168.39.198/24, eno2np1: 10.10.10.204/8 |
| Web UI | https://10.10.10.204:8006 → HTTP 200 |

## 結論

- `bmc-virtualmedia.sh verify` コマンドにより、CGI API の silent failure を確実に検出可能になった
- Phase 4 の所要時間が 23m56s → 7m32s に 68% 短縮
- 全 8 フェーズが正常完了し、PVE 9.1.5 + カーネル 6.17.9-1-pve が稼働中
- CGI API のマウント結果は信頼できないため、常に Redfish verify で二重確認するべき
