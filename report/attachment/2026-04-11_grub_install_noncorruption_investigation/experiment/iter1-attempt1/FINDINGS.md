# iter1 attempt 1 — 決定的発見: 仮説 B (NVRAM full) 確定

## タイムライン

- 2026-04-11 08:40 JST: sol-monitor × 3 台並列起動 (server 7/8/9)
- 08:40:25 頃: 3 台とも BIOS POST → GRUB → installer kernel 起動
- 08:43:57: installer stage LOADING_COMPONENTS 検知
- 08:44:25: DETECTING_NETWORK, CONFIGURING_APT 検知
- 08:47:44: grub-installer phase 開始
- 08:48:12: **grub-install 実行 → NVRAM 書込み失敗**
- 09:25:29 頃: 3 台とも 45 分 timeout (installer が dialog 待ち状態)

## 決定的ログ (installer-syslog-all.log, 23:48:12 行)

```
<13>Apr 10 23:47:58 grub-installer: info: YES on force-efi-extra-removable
<13>Apr 10 23:48:12 grub-installer: info: Installing grub on '/dev/sda'
<13>Apr 10 23:48:12 grub-installer: info: Running chroot /target grub-install  --force-extra-removable --force "/dev/sda"
<13>Apr 10 23:48:12 grub-installer: Installing for x86_64-efi platform.
<13>Apr 10 23:48:13 grub-installer: grub-install: warning: Cannot set EFI variable Boot0007.
<13>Apr 10 23:48:13 grub-installer: grub-install: warning: efivarfs_set_variable: writing to fd 12 failed: No space left on device.
<13>Apr 10 23:48:13 grub-installer: grub-install: warning: _efi_set_variable_mode: ops->set_variable() failed: No space left on device.
<13>Apr 10 23:48:13 grub-installer: grub-install: error: failed to register the EFI boot entry: No space left on device.
<13>Apr 10 23:48:13 grub-installer: error: Running 'grub-install  --force-extra-removable --force "/dev/sda"' failed.
```

## 結論

**仮説 B (iDRAC7 efivars NVRAM 枯渇) が決定的に確定**。

原因は NVRAM の**物理破損ではなく、蓄積された Boot#### エントリによる空間枯渇**。つまり累積破損ではなく **累積枯渇**。この違いは重要:

- **累積破損 (corruption)** — 物理 CMOS/NVRAM チップの故障、物理介入 (CMOS reset / reflash) が必要
- **累積枯渇 (exhaustion)** — 論理的な空き領域不足、**既存 Boot エントリを削除すれば回復可能**、物理介入不要

## プランの仮説との整合性

| 仮説 | プランでの扱い | 実験結果 |
|------|------------|---------|
| A (force-efi-extra-removable 欠落) | HIGH 尤度 | 部分確認: "YES on force-efi-extra-removable" が効いている。ただし grub-installer 内部呼出しは `--force` 付きで NVRAM 書込みを強行 |
| **B (efibootmgr NVRAM 失敗)** | **HIGH 尤度 (最有力)** | **✓ 決定的に確定**: "failed to register the EFI boot entry: No space left on device" |
| C (GPT backup 残骸) | MEDIUM 尤度 | 未検証 (early_command arithmetic syntax error で dd ループが壊れた) |
| D (non_efi_system 暗黙依存) | LOW-MEDIUM 尤度 | 該当せず (実行は通った) |
| E (パッケージ postinst) | MEDIUM 尤度 | 該当せず (failure は grub-installer 本体経路) |
| F (cdrom-detect/eject) | LOW 尤度 | 該当せず |

## 副次的バグ

1. **preseed early_command の arithmetic syntax error**:
   ```
   Apr 10 23:44:52 log-output: sh: arithmetic syntax error
   ```
   原因: `end_mb=$(( $(blockdev --getsz "$disk") / 2048 - 10 ))` を busybox sh が解釈できない。
   対策: コマンド置換を外で実行して変数に入れる。

2. **`d-i grub-installer/grub2/update_nvram boolean false` が存在しないディレクティブ**:
   Debian 13 の grub-installer に該当する preseed 変数は存在しない。`--no-nvram` フラグは grub-install の CLI レベルでしか指定できない。プランでこの前提を立てたが誤りだった。正しい対策は **NVRAM を事前 clear する** ことで、preseed ディレクティブでは制御不可。

## 次のステップ (iter 1 attempt 2)

1. preseed の `d-i grub-installer/grub2/update_nvram boolean false` を削除
2. preseed の early_command で **efivarfs 上の Boot#### エントリを削除** (NVRAM 空間確保)
3. preseed の partman/early_command の arithmetic syntax error を修正
4. 全 3 台で iter 1 を再実行
5. grub-install が NVRAM 書込み成功 → install 完遂 → iter 2, 3 へ

## 関連ログファイル

- `installer-syslog-all.log` — 3 台分の installer syslog 混在 (2672 行)
- `iter1-sol-install-s{7,8,9}.log` — sol-monitor 出力 (stage 観測履歴)
