# pve-lock.sh subshell flock 修正の3回通しテスト検証

- **実施日時**: 2026年2月25日 23:06 - 01:05 (UTC)

## 前提・目的

Issue #13 で `pve-lock.sh` の fd 管理を `exec 9>lockfile` パターンから subshell パターン `( flock ...; cmd ) 9>lockfile` に変更した (コミット `75e3cea`)。元の不具合は Phase 7 の `./pve-lock.sh run ssh root@host 'pve-setup-remote.sh ...'` で出力が空になる散発的問題（3回中1回程度）。

- **背景**: `exec 9>lockfile` パターンではプロセスツリー全体に fd 9 が伝播し、SSH のパイプ (stdout/stderr) と干渉して出力欠落が発生していた
- **目的**: subshell flock パターンへの変更により、fd 9 のスコープがサブシェル内に閉じられ、SSH パイプ出力が安定するかを3回の通しテストで検証する
- **前提条件**: pve-lock.sh 修正済み (コミット `75e3cea`)、サーバ電源 On

### 参照レポート

- [report/2026-02-24_192754_os_setup_virtualmedia_verify_test.md](2026-02-24_192754_os_setup_virtualmedia_verify_test.md) — 直近の通しテスト (1回、51m44s)

## 環境情報

| 項目 | 値 |
|------|-----|
| サーバ | Supermicro X11DPU (ayase-web-service-4) |
| BMC IP | 10.10.10.24 |
| サーバ IP | 10.10.10.204 (static, eno2np1) |
| OS | Debian 13.3 (Trixie) |
| PVE | pve-manager/9.1.5 → 9.1.6 (Run 2/3 で自動更新) |
| カーネル | 6.17.9-1-pve |
| ISO | debian-13.3.0-amd64-netinst.iso (preseed 組み込みリマスター版) |
| ディスク | /dev/nvme0n1 |

## 修正内容 (コミット `75e3cea`)

`pve-lock.sh` の `cmd_run()` と `cmd_wait()` を subshell flock パターンに変更:

```diff
-    exec 9>"$LOCK_FILE"
-    if ! flock -n 9; then
-        ...
-        exit 1
-    fi
-    "$@" 9>&-
-    rc=$?
-    exec 9>&-
-    return $rc
+    (
+        flock -n 9 || { ...; exit 1; }
+        "$@" 9>&-
+        rc=$?
+        exit "$rc"
+    ) 9>"$LOCK_FILE"
```

**変更のポイント**:
- fd 9 のリダイレクト `9>"$LOCK_FILE"` がサブシェル `(...)` のスコープに限定される
- `exec 9>` によるプロセスレベルの fd 汚染が排除され、子プロセス (SSH) のパイプに影響しない
- `cmd_status()` も同様に `(flock -n 9) 9>"$LOCK_FILE"` パターンに統一
- `local` キーワード (bash 依存) を削除して POSIX sh 準拠に修正

## 検証ポイント (VP)

| ID | Phase | コマンド | 期待出力 |
|----|-------|---------|----------|
| VP1 | 7 (pre-reboot) | `./pve-lock.sh run ssh root@10.10.10.204 '/tmp/pve-setup-remote.sh --phase pre-reboot ...'` | `=== pre-reboot phase complete. Reboot required. ===` を含む |
| VP2 | 7 (post-reboot) | `./pve-lock.sh run ssh root@10.10.10.204 '/tmp/pve-setup-remote.sh --phase post-reboot ...'` | `=== post-reboot phase complete ===` を含む |
| VP3 | 8 | `./pve-lock.sh run ssh root@10.10.10.204 'pveversion'` | `pve-manager/` を含む |

## 検証結果サマリ

| VP | Run 1 | Run 2 | Run 3 | 結果 |
|----|-------|-------|-------|------|
| VP1 (pre-reboot) | PASS — 出力あり、マーカー含む | PASS — 出力あり、マーカー含む | PASS — 出力あり、マーカー含む | **3/3 成功** |
| VP2 (post-reboot) | PASS — 出力あり、マーカー含む | PASS — 出力あり、マーカー含む | PASS — 出力あり、マーカー含む (リトライ1回) | **3/3 成功** |
| VP3 (pveversion) | PASS — `pve-manager/9.1.5` | PASS — `pve-manager/9.1.6` | PASS — `pve-manager/9.1.6` | **3/3 成功** |

**全9検証ポイント (3 VP × 3 Run) で SSH 出力の欠落なし。**

## フェーズ実行時間

### Run 1

| Phase | Name | 所要時間 | 備考 |
|-------|------|---------|------|
| 1 | iso-download | 0m14s | sha256 検証のみ |
| 2 | preseed-generate | 0m06s | |
| 3 | iso-remaster | 0m12s | キャッシュ済み ISO 使用 |
| 4 | bmc-mount-boot | 5m11s | VirtualMedia verify 1回で成功 |
| 5 | install-monitor | 10m01s | SOL 監視、正常完了 |
| 6 | post-install-config | 5m09s | POST 92 なし |
| 7 | pve-install | 18m15s | VP1/VP2 出力正常 |
| 8 | cleanup | 1m03s | |
| | **合計** | **40m11s** | |

### Run 2

| Phase | Name | 所要時間 | 備考 |
|-------|------|---------|------|
| 1 | iso-download | 0m04s | キャッシュ済み |
| 2 | preseed-generate | 0m08s | |
| 3 | iso-remaster | 0m05s | キャッシュ済み ISO 使用 |
| 4 | bmc-mount-boot | 5m00s | VirtualMedia verify 1回で成功 |
| 5 | install-monitor | 10m16s | SOL 監視、正常完了 |
| 6 | post-install-config | 10m48s | **POST 92 スタック → リカバリ** |
| 7 | pve-install | 14m29s | VP1/VP2 出力正常 |
| 8 | cleanup | 0m51s | |
| | **合計** | **41m41s** | |

### Run 3

| Phase | Name | 所要時間 | 備考 |
|-------|------|---------|------|
| 1 | iso-download | 0m04s | キャッシュ済み |
| 2 | preseed-generate | 0m09s | |
| 3 | iso-remaster | 0m04s | キャッシュ済み ISO 使用 |
| 4 | bmc-mount-boot | 5m03s | VirtualMedia verify 1回で成功 |
| 5 | install-monitor | 10m45s | SOL 監視、正常完了 |
| 6 | post-install-config | 4m41s | POST 92 なし |
| 7 | pve-install | 16m58s | VP1/VP2 出力正常 (VP2 リトライ1回) |
| 8 | cleanup | 0m56s | |
| | **合計** | **38m40s** | |

### 3回の統計

| 指標 | 値 |
|------|-----|
| 平均所要時間 | 40m11s |
| 最短 | 38m40s (Run 3) |
| 最長 | 41m41s (Run 2) |
| POST 92 発生回数 | 1回 (Run 2 Phase 6) |
| VP2 リトライ | 1回 (Run 3、SSH 接続タイミング) |

## トラブルシューティング

### POST code 92 スタック (Run 2 Phase 6)

Run 2 の Phase 6 で Power On 後、POST code 92 (DXE--BIOS PCI Bus Enumeration) でスタック。KVM スクリーンショットで確認し、ForceOff → 20秒待機 → Power On → 150秒待機で回復。Phase 6 の所要時間が 5m09s (Run 1) → 10m48s (Run 2) に増加。

この問題は VirtualMedia のマウント/アンマウント後のパワーサイクルで散発的に発生する既知の問題。

### VP2 リトライ (Run 3 Phase 7)

Run 3 の VP2 (post-reboot) で proxmox-ve パッケージのインストール中（ifupdown2 インストール時）に SSH 接続が切断され、exit code 100 で終了。ifupdown2 パッケージのインストールがネットワーク設定を変更し、一時的に SSH 接続が失われたことが原因。SSH 再接続後に post-reboot フェーズを再実行し、正常完了した。**SSH 切断は pve-lock.sh の fd 問題とは無関係**（apt のネットワーク設定変更が原因）。

### PVE バージョン変動

Run 1 で PVE 9.1.5 がインストールされたが、Run 2/3 では PVE 9.1.6 に自動更新された（Proxmox リポジトリの更新タイミングによる）。

## スクリーンショット

### Run 1

| タイミング | ファイル |
|-----------|---------|
| Phase 4: VirtualMedia verify 後 | ![](../tmp/2c27638b/screenshots/run1-phase4-verify.png) |
| Phase 5: インストール完了 | ![](../tmp/2c27638b/screenshots/run1-phase5-complete.png) |
| Phase 6: ディスクブート後 | ![](../tmp/2c27638b/screenshots/run1-phase6-boot.png) |
| Phase 6: SOL ログイン後 | ![](../tmp/2c27638b/screenshots/run1-phase6-login.png) |
| Phase 7: PVE 稼働確認 | ![](../tmp/2c27638b/screenshots/run1-phase7-pve.png) |
| Phase 8: 最終状態 | ![](../tmp/2c27638b/screenshots/run1-phase8-final.png) |

### Run 2

| タイミング | ファイル |
|-----------|---------|
| Phase 4: VirtualMedia verify 後 | ![](../tmp/2c27638b/screenshots/run2-phase4-verify.png) |
| Phase 5: インストール完了 | ![](../tmp/2c27638b/screenshots/run2-phase5-complete.png) |
| Phase 6: ディスクブート後 | ![](../tmp/2c27638b/screenshots/run2-phase6-boot.png) |
| Phase 6: POST 92 リカバリ後 | ![](../tmp/2c27638b/screenshots/run2-phase6-post92.png) |
| Phase 6: SOL ログイン後 | ![](../tmp/2c27638b/screenshots/run2-phase6-login.png) |
| Phase 7: PVE 稼働確認 | ![](../tmp/2c27638b/screenshots/run2-phase7-pve.png) |
| Phase 8: 最終状態 | ![](../tmp/2c27638b/screenshots/run2-phase8-final.png) |

### Run 3

| タイミング | ファイル |
|-----------|---------|
| Phase 4: VirtualMedia verify 後 | ![](../tmp/2c27638b/screenshots/run3-phase4-verify.png) |
| Phase 5: インストール完了 | ![](../tmp/2c27638b/screenshots/run3-phase5-complete.png) |
| Phase 6: ディスクブート後 | ![](../tmp/2c27638b/screenshots/run3-phase6-boot.png) |
| Phase 6: SOL ログイン後 | ![](../tmp/2c27638b/screenshots/run3-phase6-login.png) |
| Phase 7: PVE 稼働確認 | ![](../tmp/2c27638b/screenshots/run3-phase7-pve.png) |
| Phase 8: 最終状態 | ![](../tmp/2c27638b/screenshots/run3-phase8-final.png) |

## 最終検証サマリ (Run 3 最終状態)

| 項目 | 値 |
|------|-----|
| OS | Debian GNU/Linux 13 (trixie) |
| PVE | pve-manager/9.1.6/71482d1833ded40a (running kernel: 6.17.9-1-pve) |
| カーネル | 6.17.9-1-pve |
| ネットワーク | eno1np0: 192.168.39.199/24, eno2np1: 10.10.10.204/8 |
| Web UI | https://10.10.10.204:8006 → HTTP 200 |

## 結論

- **subshell flock パターンにより SSH パイプ出力欠落は解消された**: 全3回 × 3検証ポイント = 9回のテストで出力欠落なし
- 修正前は3回中1回程度の頻度で出力が空になっていた (Issue #13 報告) のに対し、修正後は0/9回
- `( flock ...; cmd ) 9>lockfile` パターンにより fd 9 のスコープがサブシェル内に限定され、SSH の stdout/stderr パイプへの干渉が排除された
- 平均所要時間 40m11s (38m40s - 41m41s) は従来と同等であり、パフォーマンスへの影響はない
- POST 92 スタック (1/3回) は既知のハードウェア起因問題であり、pve-lock.sh の修正とは無関係
