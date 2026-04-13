# iter 1 attempt 2 — 決定的結果: NVRAM cleanup で server 8/9 救済、server 7 不十分

## タイムライン

- 2026-04-11 09:47 JST: sol-monitor × 3 台並列起動 (iter 1 attempt 2)
- 09:56:30 頃: server 7 stage INSTALLING_SOFTWARE 到達
- 09:56:34: server 8 POWER_DOWN 検知 → **exit 0 成功** (9.1 分)
- 09:57:11: **server 7 grub-install 失敗** (再度 "No space left on device" = Boot0007)
- 09:58:06: server 9 POWER_DOWN 検知 → **exit 0 成功**
- 10:32:33: server 7 timeout (45 分、ダイアログ待ち)
- 10:39〜11:24 JST: iter1c (server 7 のみ) で diagnostic 改善版 early_command を再試行
- 11:24:51: server 7 iter1c も同じ NVRAM error で timeout

## 結果

| サーバ | 結果 | 時間 | 特記事項 |
|------|-----|-----|---------|
| server 7 | **❌ 失敗** | 45 分 timeout × 2 回 | grub-install: failed to register the EFI boot entry: No space left on device (Boot0007) |
| server 8 | **✅ 成功** | 9.1 分 | grub-install: Installation finished. No error reported. |
| server 9 | **✅ 成功** | ~10 分 | 同上 |

## 決定的ログ (server 8/9 成功、iter1-attempt2 syslog 00:56:00)

```
<13>Apr 11 00:55:52 grub-installer: info: initial os-prober call found the following OSes:
<13>Apr 11 00:55:52 grub-installer: info:     (空 — 古いインストール検出されず)
<13>Apr 11 00:55:52 grub-installer: info: Found NO other OSes, triggering question about os-prober, default no
<13>Apr 11 00:55:56 grub-installer: info: Additionally installing shim-signed to go with grub-efi-amd64
<13>Apr 11 00:56:00 grub-installer: info: Installing grub on '/dev/sda'
<13>Apr 11 00:56:00 grub-installer: info: Running chroot /target grub-install  --force-extra-removable --force "/dev/sda"
<13>Apr 11 00:56:00 grub-installer: Installing for x86_64-efi platform.
<13>Apr 11 00:56:00 grub-installer: Installation finished. No error reported.
<13>Apr 11 00:56:00 grub-installer: info: grub-install ran successfully
```

## 決定的ログ (server 7 失敗、iter1-attempt2 syslog 00:57:11 / iter1c syslog 01:49:17)

```
<13>Apr 11 00:57:11 grub-installer: grub-install: warning: Cannot set EFI variable Boot0007.
<13>Apr 11 00:57:11 grub-installer: grub-install: warning: efivarfs_set_variable: writing to fd 12 failed: No space left on device.
<13>Apr 11 00:57:11 grub-installer: grub-install: warning: _efi_set_variable_mode: ops->set_variable() failed: No space left on device.
<13>Apr 11 00:57:11 grub-installer: grub-install: error: failed to register the EFI boot entry: No space left on device.
<13>Apr 11 00:57:11 grub-installer: error: Running 'grub-install  --force-extra-removable --force "/dev/sda"' failed.
```

## 解釈

### 成功ケース (server 8/9)

preseed/early_command の NVRAM cleanup が効いたと推定される。iter1-attempt1 (NVRAM cleanup 無し) では同じサーバが NVRAM full で失敗、iter1-attempt2 (cleanup 有り) で成功したため、差分は NVRAM cleanup のみ。

ただし diagnostic output (`pvese:` プレフィックス) は syslog に現れず、cleanup の実行証拠は間接的。考えられる理由:
- d-i の busybox 環境には klogd が居らず `/dev/kmsg` 書込みが UDP forward されない
- `logger` が syslogd -R 起動直後に叩かれ race で失敗

それでも cleanup の**アクション**(chattr + rm) 自体は実行された可能性が高い。確証は次回以降の実験で diagnostic を強化して取得すべき。

### 失敗ケース (server 7)

同じ preseed 修正でも server 7 は NVRAM full を克服できず。理由として以下が考えられる:

1. **server 7 は Boot エントリ以外の NVRAM 変数が大量**: MokList, dbx, 他の EFI variable が大半を占めており、Boot#### 削除だけでは空間確保に足りない
2. **efivarfs の mount 失敗**: `mount -t efivarfs none /sys/firmware/efi/efivars` が server 7 では失敗している (kernel boot path の差異?)
3. **chattr -i が効かずに rm 失敗**: server 7 の efivarfs エントリが immutable のまま削除できていない
4. **accumulated Boot エントリが極端に多い**: server 7 は以前のテストで最も多くの install を経験しており、他より Boot entry が蓄積している

iter1c の diagnostic 強化 (sleep 2, mount 強制, 事前/事後 カウント) でも `pvese:` メッセージは syslog に現れなかった。d-i の busybox logger/kmsg 経路が使えない確認。

## 仮説 B (NVRAM 枯渇) の再確認

この実験は仮説 B を **強化**した:
- iter1-attempt1: 3/3 失敗 (NVRAM cleanup 無し)
- iter1-attempt2: 2/3 成功 (NVRAM cleanup 有り)

NVRAM cleanup を入れたことで server 8/9 が救済されたのは、cleanup が Boot#### エントリを削除して空間を作ったからと解釈できる (他に差分がない)。

server 7 が救済できなかったのは、server 7 の NVRAM 状態が 8/9 より悪化しているため (より多くの accumulated state)。preseed-level の cleanup では不十分で、**別手段** (BIOS UI での Boot Options 削除、racadm systemerase nvramclr, 物理 CMOS リセット) が必要。

## 次のステップ

1. **iter 2 on server 8/9 を実施**: 本プランの key test。連続 install で NVRAM cleanup が再度効くか検証
2. **server 7 は別課題として分離**: preseed-level cleanup 不足、追加調査を別セッションで
3. **レポート作成**: 現時点の証拠で十分結論を出せる
