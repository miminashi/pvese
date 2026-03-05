# os-setup SKILL.md への R320 知見反映レポート

- **実施日時**: 2026年3月5日 22:56

## 前提・目的

R320 (7号機) の Debian 13 + PVE 9 セットアップ通しテスト (Phase 1-8) を完了した過程で得られた
R320 固有の知見を os-setup SKILL.md に反映し、次回以降のセットアップで同じ問題を回避する。

## 変更対象ファイル

`.claude/skills/os-setup/SKILL.md`

## 変更一覧

| # | 優先度 | Phase | 変更内容 | 行番号 (変更後) |
|---|--------|-------|----------|----------------|
| 1 | LOW | Phase 2 | R320 preseed は手動管理 (`preseed-server7.cfg`) であることを明記 | L87-89 |
| 2 | MEDIUM | Phase 5 | R320 は SOL 監視不可。VNC スクリーンショットで進行確認する注記を追加 | L206-209 |
| 3 | HIGH | Phase 6 | SOL 不可時の pexpect フォールバック (debian ユーザ SSH → su root) を追記 | L339-348 |
| 4 | MEDIUM | Phase 6 | `bmc-power.sh postcode` / `bmc-kvm.sh screenshot` が使えない R320 用の代替手段 (VNC/SSH リトライ) を追記 | L298-300 |
| 5 | CRITICAL | Phase 7 | ステップ 0「インターネット接続確保」を追加 (eno2 DHCP + デフォルトルート修正 + apt + wget) | L370-383 |
| 6 | HIGH | Phase 7 | リブート後のデフォルトルート修正手順をステップ 5 とステップ 8 に追記 | L429-431, L448 |

## 各変更の詳細

### 1. Phase 2: preseed 手動管理の明記

R320 の preseed (`preseed/preseed-server7.cfg`) はテンプレート生成 (`generate-preseed.sh`) を使用しない。
CD-only インストール、Legacy BIOS、VNC 互換カーネルパラメータなど 4-6号機とは大幅に異なるため手動管理。

### 2. Phase 5: VNC 監視

R320 の SOL は `console=tty0` のため Linux のシリアル出力が見えない。
`sol-monitor.py` も `bmc-power.sh postcode` も使えないため、VNC スクリーンショット
(`vnc-wake-screenshot.py`) でインストーラ進行を確認する。

### 3. Phase 6: pexpect SSH フォールバック

SOL 経由のログイン・設定 (`sol-login.py`) が使えないため、pexpect ベースの SSH スクリプトで
debian ユーザにパスワード認証 SSH → su root で初期設定を行う代替手段を追記。

### 4. Phase 6/7: POST 監視の代替

Supermicro 専用の `bmc-power.sh postcode` と `bmc-kvm.sh screenshot` が R320 では使えない。
VNC スクリーンショットまたは SSH リトライ (30秒間隔) で監視する。
R320 の POST は Lifecycle Controller 初期化で 2-3 分かかるため SSH 到達まで最大 3.5 分待つ。

### 5. Phase 7: pre-pve-setup (インターネット接続確保)

R320 の preseed は CD-only (`apt-setup/use_mirror boolean false`) で apt ミラーが未設定。
wget と ca-certificates も未インストール。PVE インストールスクリプト実行前に:
- eno2 DHCP 有効化 + デフォルトルート修正 (10.10.10.1 → 192.168.39.1)
- apt sources.list 設定 + 必須パッケージインストール

### 6. Phase 7: リブート後のデフォルトルート修正

10.0.0.0/8 はインターネット不可のため、リブートのたびにデフォルトルート (via 10.10.10.1) を
削除する必要がある。pre-reboot 後のリブートと最終リブートの両方に注記を追加。
