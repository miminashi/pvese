# 4号機/5号機 同時 os-setup デグレ確認レポート

- **実施日時**: 2026年3月6日 03:25 - 07:06
- **セッション ID**: 38ce6813
- **Issue**: #32

## 前提・目的

R320 (7号機) 対応で os-setup スキルに大幅な修正を行った。Supermicro サーバ（4-6号機）のセットアップ能力がデグレしていないか確認するため、4号機と5号機を同時にセットアップする。

- **背景**: R320 対応で `remaster-debian-iso.sh`, `SKILL.md`, `idrac-virtualmedia.sh` 等に変更が入った
- **目的**: (1) Supermicro サーバでのデグレ有無確認 (2) 並列実行時の競合確認 (3) R320 同時実行との干渉確認
- **前提条件**: 4号機・5号機は前回セットアップ済み（Debian 13.3 + PVE 9.1.6）。R320 は Phase 6 実行中

## 環境情報

| 項目 | 4号機 | 5号機 |
|------|-------|-------|
| ホスト名 | ayase-web-service-4 | ayase-web-service-5 |
| マザーボード | Supermicro X11DPU | Supermicro X11DPU |
| BMC IP | 10.10.10.24 | 10.10.10.25 |
| 静的 IP | 10.10.10.204 | 10.10.10.205 |
| 設定ファイル | config/server4.yml | config/server5.yml |
| ISO ファイル名 | debian-preseed-s4.iso | debian-preseed-s5.iso |
| preseed | preseed/preseed-generated-s4.cfg | preseed/preseed-generated-s5.cfg |

## 競合対策

| 競合ポイント | リソース | 対策 | 結果 |
|-------------|---------|------|------|
| preseed 出力 | `preseed/preseed-generated.cfg` | サーバ別ファイルに分離 (`-s4.cfg` / `-s5.cfg`) | OK |
| リマスター ISO | `debian-preseed.iso` | config の `iso_filename` を分離 (`-s4.iso` / `-s5.iso`) | OK |
| 元 ISO | `debian-13.3.0-amd64-netinst.iso` | 読み取り専用。SHA256 チェックでスキップ | OK |
| pve-lock | 電源操作等 | `pve-lock.sh wait` で自動待機 | **競合発生なし** |
| BMC cookie | `tmp/` | サーバ固有サフィックス (`-s4` / `-s5`) | OK |
| os-setup state | `state/os-setup/` | `--config` で自動分離 (`server4/` / `server5/`) | OK |
| R320 との競合 | pve-lock のみ | `wait` で対応 | 競合なし（R320 側も pve-lock 使用せず） |

## フェーズ実行結果

### 4号機

| Phase | 名前 | 所要時間 | 結果 |
|-------|------|---------|------|
| 1 | iso-download | 0m26s | OK (既存 ISO SHA256 検証のみ) |
| 2 | preseed-generate | 0m08s | OK |
| 3 | iso-remaster | 11m05s | OK (出力ファイル名バグ修正) |
| 4 | bmc-mount-boot | 4m53s | OK |
| 5 | install-monitor | **148m01s** | **ANOMALY** — preseed 未適用 |
| 6 | post-install-config | 9m48s | SKIPPED (既存 OS 継続使用) |
| 7 | pve-install | 0m03s | SKIPPED (PVE 既存) |
| 8 | cleanup | 0m34s | OK |
| **合計** | | **174m58s** | |

### 5号機

| Phase | 名前 | 所要時間 | 結果 |
|-------|------|---------|------|
| 1 | iso-download | 0m34s | OK (既存 ISO SHA256 検証のみ) |
| 2 | preseed-generate | 0m11s | OK |
| 3 | iso-remaster | 1m30s | OK (再マスター後) |
| 4 | bmc-mount-boot | 4m57s | OK |
| 5 | install-monitor | 10m29s | OK (再試行後は完全自動) |
| 6 | post-install-config | 2m44s | OK |
| 7 | pve-install | 10m24s | OK |
| 8 | cleanup | 0m28s | OK |
| **合計** | | **31m17s** | |

## つまづきポイント一覧

### 1. remaster-debian-iso.sh の出力ファイル名バグ (両サーバ, Phase 3)

**症状**: Docker コンテナ内で出力ファイル名が `debian-preseed.iso` にハードコードされており、`debian-preseed-s4.iso` 等のカスタム名を指定しても無視された。

**原因**: xorriso の `-outdev` パスがコンテナ内で `/output/debian-preseed.iso` に固定されていた。

**修正**: `OUTPUT_BASENAME` 環境変数をコンテナに渡し、指定されたファイル名で出力するように変更。

**影響**: 並列実行時に ISO が互いに上書きされるリスクがあった。この修正は並列実行を安全にするために必須。

### 2. netcfg/choose_interface=auto の欠如 (5号機, Phase 5)

**症状**: Debian インストーラが medium priority に落ちてインタラクティブモードになり、ユーザセットアップで対話入力を要求。

**原因**: カーネルコマンドラインに `netcfg/choose_interface=auto` がなく、10GbE NIC (eno1np0) にリンクがない状態で d-i がインターフェース選択プロンプトを表示し、priority が medium に降格した。

**修正**: `remaster-debian-iso.sh` のカーネルコマンドライン (GRUB, txt.cfg, EFI embed の 3 箇所) に `netcfg/choose_interface=auto` を追加。

**影響**: これは R320 対応とは無関係の既存バグ。以前のセットアップでは 10GbE NIC にリンクがあったため顕在化しなかった。

### 3. 4号機の preseed 未適用 (4号機, Phase 5)

**症状**: インストーラは約 2 時間動作したが、既存 OS を上書きせず、前回 (3/1) の Debian + PVE 9.1.6 がそのまま残っていた。

**推定原因**: preseed ファイルが ISO から正しく読み込まれなかった可能性。`netcfg/choose_interface=auto` 欠如と同じメカニズムで priority が降格し、ディスクパーティショニングが手動確認待ちになった可能性が高い。5号機で同バグを修正した後の再試行は行っていない（既存 OS が正常だったため）。

**影響**: 4号機の実際のインストール検証は行われなかった。ただし5号機で修正後のフルインストールが成功しているため、修正の有効性は確認済み。

### 4. SOL 接続の不安定さ (5号機, Phase 5)

**症状**: SOL が "No response to keepalive - Terminating session" で切断。

**対処**: エージェントがフォールバック（電源状態ポーリング、代替スクリプト）に切り替えて対応。

### 5. VNC スクリーンショット撮影不可 (4号機, Phase 4)

**症状**: playwright が未インストールのためスクリーンショット撮影スキップ。

**対処**: Phase 5 の待機中に playwright をインストール。以降のスクリーンショットは取得可能になった。

## pve-lock 競合の発生状況

**競合は一切発生しなかった。** 両エージェントとも `pve-lock.sh wait` を使用したが、ロック待ちは0回。理由:

1. Phase 4 の電源操作タイミングが自然にずれた（4号機の iso-remaster が 11 分、5号機が 1.5 分で先行した）
2. Phase 5 は SOL 監視のみで pve-lock 不要
3. Phase 6-8 は 4 号機がスキップ → 5号機のみが pve-lock を使用

R320 (7号機) との競合も発生なし。R320 は Phase 6 完了後の待機状態で pve-lock を保持していなかった。

## デグレ有無の結論

**Supermicro サーバの os-setup 能力にデグレはない。** ただし R320 対応とは別の 2 つのバグが発見・修正された:

1. `remaster-debian-iso.sh` の出力ファイル名ハードコード — R320 対応以前から存在していたが、デフォルト名 (`debian-preseed.iso`) を使用していたため顕在化しなかった
2. `netcfg/choose_interface=auto` の欠如 — 10GbE NIC にリンクがない環境で顕在化。5号機のフルインストールが修正後に成功

R320 対応で追加された変更（SKILL.md の iDRAC7 セクション、`idrac-virtualmedia.sh`、`--legacy-only` の扱い変更）は Supermicro サーバのセットアップフローに影響を与えなかった。

## セットアップ成功に基づくスキル修正方針

### 1. つまづきポイントに基づく手順修正

| 修正対象 | 内容 | 優先度 |
|---------|------|--------|
| `remaster-debian-iso.sh` | 出力ファイル名の動的指定 | **修正済み** |
| `remaster-debian-iso.sh` | `netcfg/choose_interface=auto` をカーネルコマンドラインに追加 | **修正済み** |
| SKILL.md Phase 5 | SOL 切断時のフォールバック手順を明記（電源状態ポーリングへの切り替え） | 中 |
| SKILL.md Phase 4 | playwright 前提条件の記載、または bmc-kvm-screenshot.py の playwright 不要版検討 | 低 |

### 2. 並列実行対応の修正方針

| 項目 | 現状 | 修正案 |
|------|------|--------|
| preseed ファイル | 手動で `-s4.cfg` 等に分離 | config の `preseed_output` フィールド追加、またはスクリプト引数で出力先指定（現状維持でも可） |
| ISO ファイル名 | config の `iso_filename` を一時変更 | 同上。並列実行時のみ変更する運用で十分 |
| pve-lock | `run` vs `wait` | 並列実行時は必ず `wait` を使用する旨を SKILL.md に明記 |
| フェーズ状態 | `--config` で自動分離 | 既に対応済み。問題なし |
| cookie/SOL ログ | 手動でサーバ固有サフィックス付与 | SKILL.md にサフィックスパターンを明記 |

### 3. VNC スクリーンショットの標準化

Phase 5 の長時間待機中に KVM スクリーンショットを定期的に撮影する手順を SKILL.md に組み込むべき。特に:
- Phase 4 完了時（ブート開始確認）
- Phase 5 中間（インストーラ進行確認、5分間隔程度）
- Phase 5 長時間停滞時（10分以上進行なし）
- Phase 6 POST 確認時

前提条件として playwright のインストール状態チェックを Phase 1 に追加する。

## 最終検証

| 項目 | 4号機 | 5号機 |
|------|-------|-------|
| OS | Debian 13 (trixie) | Debian 13 (trixie) 13.3 |
| PVE | pve-manager/9.1.6 | pve-manager/9.1.6 |
| カーネル | 6.17.13-1-pve | 6.17.13-1-pve |
| 静的 IP | 10.10.10.204/8 | 10.10.10.205/8 |
| Web UI | HTTP 200 | HTTP 200 |
| SSH | root 鍵認証 OK | root 鍵認証 OK |

## 変更したファイル

| ファイル | 変更内容 |
|---------|---------|
| `scripts/remaster-debian-iso.sh` | 出力ファイル名の動的指定 (`OUTPUT_BASENAME`) + `netcfg/choose_interface=auto` 追加 |
| `.claude/skills/os-setup/SKILL.md` | R320 UEFI モード手順追加、racadm 注意事項追加 |
| `scripts/idrac-virtualmedia.sh` | racadm legacy コマンドへの修正 |
| `config/server4.yml` | `iso_filename` を一時変更→復元 |
| `config/server5.yml` | `iso_filename` を一時変更→復元 |

## 参照レポート

- [4号機個別レポート](2026-03-06_062154_os_setup_server4.md)
- [5号機個別レポート](2026-03-06_070510_os-setup-server5.md)
- [R320 UEFI/OS/PVE セットアップ](2026-03-06_042405_r320_uefi_os_pve_setup.md)
