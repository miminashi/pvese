# SOL ログイン ブートステージ検出の実装

- **実施日時**: 2026年2月24日 01:26
- **課題**: #14 SOL ログイン接続のタイミング改善

## 前提・目的

Phase 6 (post-install-config) で SOL 経由のログイン・設定を行う際、SOL 接続が GRUB メニュー表示中にあたりコマンドが GRUB に送られてしまう問題を解決する。

- 背景: Run 1 Phase 6 で SOL 接続タイミングが GRUB メニュー表示中と重なり、60秒追加待機で手動回復した
- 目的: ブートステージを自動検出する状態機械を実装し、GRUB 表示中のキー入力を防止する
- 前提条件: サーバが GRUB でシリアルコンソール出力を有効にしていること

## 環境情報

- サーバ: Supermicro X11DPU, BMC IP 10.10.10.24
- OS: Debian 13.3 (Trixie) + Proxmox VE 9.1.5
- カーネル: 6.17.9-1-pve
- SOL: ipmitool -I lanplus, ttyS1 115200n8

## 実装内容

### scripts/sol-login.py

新規作成した汎用 SOL ログインスクリプト。主要機能:

1. **ブートステージ検出の状態機械**:
   ```
   DETECTING → GRUB_MENU → KERNEL_BOOT → SYSTEMD_INIT → LOGIN_PROMPT → LOGGED_IN
   ```

2. **GRUB 安全制御**: GRUB_MENU / KERNEL_BOOT 状態ではキー入力を一切送信しない

3. **コマンドライン引数**:
   ```
   scripts/sol-login.py --bmc-ip IP --bmc-user USER --bmc-pass PASS \
       --root-pass ROOTPASS \
       [--commands-file FILE] [--timeout 180] [--check-only]
   ```

4. **既存セッション対応**: ログイン済み (root@ プロンプト) の場合も自動検出

### SKILL.md / reference.md 更新

- Phase 6 ステップ 3 を `sol-login.py` 使用に書き換え
- reference.md に SOL ブートステージ検出リファレンスを追加

## テスト結果

### テスト 1: 起動済みサーバでの check-only

```
[01:26:17] Deactivating any existing SOL session
[01:26:19] Connecting SOL to 10.10.10.24
[01:26:22] Stage: DETECTING (timeout=60s)
[01:26:22] Stage: DETECTING -> LOGIN_PROMPT
[01:26:22] Login successful
[01:26:23] Check-only mode: login verified, disconnecting
```

結果: 即座にログインプロンプト検出、ログイン成功。

### テスト 2: 既にログイン済みの状態でコマンド実行

```
[01:28:52] Stage: DETECTING -> LOGGED_IN (shell prompt detected)
[01:28:52] Already at shell prompt, skipping login
[01:28:57] Executing 3 commands from tmp/a87c228d/test-commands.txt
[01:28:57] [1/3] hostname
[01:28:58] [2/3] ip -brief addr
[01:28:59] [3/3] uname -r
[01:29:03] All done
```

結果: 既存シェルを検出し、再ログインなしでコマンド実行成功。

### テスト 3: リブートからのフルブート検出

サーバを `bmc-power.sh cycle` でリブートし、直後に接続:

```
[01:29:39] Deactivating any existing SOL session
[01:29:41] Connecting SOL to 10.10.10.24
[01:29:44] Stage: DETECTING (timeout=300s)
[01:29:54] DETECTING: sending Enter to probe    ← POST 中、応答なし
  ... (約90秒の POST 待機)
[01:31:15] Stage: DETECTING -> GRUB_MENU        ← GRUB 検出！
[01:31:20] GRUB_MENU: waiting for auto-boot (5s, NO keys sent)  ← キー入力なし
[01:31:20] Stage: GRUB_MENU -> KERNEL_BOOT      ← GRUB 自動ブート → カーネル
[01:31:47] Stage: KERNEL_BOOT -> LOGIN_PROMPT   ← ログインプロンプト到達
[01:31:47] Login successful
[01:31:47] Executing 3 commands
[01:31:53] All done
```

結果: GRUB メニュー検出成功。GRUB 中はキー入力なし。自動ブート後にカーネル→ログイン到達。コマンド実行成功。

## ブートステージ所要時間（実測値）

| ステージ | 開始時刻 | 所要時間 |
|----------|---------|---------|
| POST/BIOS (DETECTING) | 01:29:44 | 約91秒 |
| GRUB メニュー | 01:31:15 | 約5秒 |
| カーネルブート | 01:31:20 | 約27秒 |
| ログインプロンプト到達 | 01:31:47 | — |
| **合計** | — | **約123秒** |
