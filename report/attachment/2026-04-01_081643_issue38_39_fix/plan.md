# 残課題修正プラン (Issue #38 + #39)

## Context

report/2026-04-01_075650_skill_training_iter7to9.md の残課題3件のうち、コード修正が必要な #38 と #39 に対応する。Iteration 10 (6号機 os-setup 再実行) はサーバ操作が必要なため今回はスコープ外。

## Issue #38: IPoIB リブート後に自動起動しない

### 原因
`/etc/network/interfaces.d/ib0` の `pre-up modprobe ib_ipoib` だけでは、networking.service がインターフェース名 (ibp134s0) を解決する前にモジュールがロードされず、起動に失敗する。

### 修正: `scripts/ib-setup-remote.sh`

`--persist` ブロック (line 105-121) に以下を追加:

1. `/etc/modules-load.d/ib_ipoib.conf` に `ib_ipoib` を書き込む
   - `systemd-modules-load.service` が networking.service より前にモジュールをロード
   - 冪等 (同じ内容で上書き)

2. interfaces heredoc に `pre-up sleep 2` を追加 (modprobe の後、mode 設定の前)
   - udev リネーム (ib0 → ibpXXsX) の完了を待つ
   - 既存の runtime 側 sleep 2 (line 57) と同じ待機時間

### 変更後の persist ブロック概要
```
# NEW: modules-load.d
echo "ib_ipoib" > /etc/modules-load.d/ib_ipoib.conf

# interfaces.d/ib0 (変更箇所: pre-up sleep 2 追加)
auto $iface
iface $iface inet static
    address $addr_only/$prefix
    mtu $mtu
    pre-up modprobe ib_ipoib
    pre-up sleep 2
    pre-up echo $ib_mode > /sys/class/net/$iface/mode || true
```

## Issue #39: LINBIT リポジトリ GPG 鍵 + enterprise.sources 除去

### 修正1: `scripts/pve-setup-remote.sh`

**A. enterprise repo 除去** — `phase_post_reboot()` の locale fix 直後、proxmox-ve install の前に追加:
```sh
echo "--- Removing enterprise repositories ---"
rm -f /etc/apt/sources.list.d/pve-enterprise.list
rm -f /etc/apt/sources.list.d/pve-enterprise.sources
```
→ 全サーバで常に実行 (冪等)

**B. `--linstor` フラグ追加** — 引数パーサに `--linstor) linstor=1; shift ;;` を追加。`--linstor` は必須パラメータではない (デフォルト off)。

**C. LINSTOR リポジトリ + パッケージインストール** — `phase_post_reboot()` の末尾 (Debian kernel 除去の後) に条件付きで追加:
```sh
if [ "$linstor" = "1" ]; then
    echo "--- Setting up LINBIT repository ---"
    echo "deb [signed-by=/usr/share/keyrings/linbit-keyring.gpg] http://packages.linbit.com/public/ proxmox-9 drbd-9" > /etc/apt/sources.list.d/linbit.list
    if [ ! -f /usr/share/keyrings/linbit-keyring.gpg ]; then
        wget -qO /usr/share/keyrings/linbit-keyring.gpg https://packages.linbit.com/package-signing-pubkey.gpg
    fi
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get -y install drbd-dkms drbd-utils linstor-satellite linstor-client linstor-proxmox
    systemctl enable linstor-satellite
    echo "LINSTOR/DRBD setup complete"
fi
```

### 修正2: `.claude/skills/os-setup/SKILL.md`

1. **Phase 7 ステップ 4** (line 516-521): コマンド例に `--linstor` フラグを追加し、使用条件を注記
2. **Phase 8 ステップ 6** (line 599-605): `--persist` が modules-load.d も書くようになった旨を注記
3. スクリプト一覧 (あれば) に `--linstor` フラグの説明を追加

## 対象ファイル

| ファイル | 変更内容 |
|---------|---------|
| `scripts/ib-setup-remote.sh` | persist ブロックに modules-load.d + sleep 2 追加 |
| `scripts/pve-setup-remote.sh` | enterprise repo 除去 + --linstor フラグ + LINBIT セットアップ |
| `.claude/skills/os-setup/SKILL.md` | Phase 7/8 ドキュメント更新 |

## 検証方法

- `sh -n scripts/ib-setup-remote.sh` / `sh -n scripts/pve-setup-remote.sh` で構文チェック
- 実際のサーバでの通しテストは Iteration 10 (6号機 os-setup) で実施 — 今回はコード修正 + issue 更新のみ
- Issue #38, #39 を done に更新
