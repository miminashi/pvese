# 6号機 os-setup 10回トレーニング

## Context

6号機 (Supermicro X11DPU) で os-setup スキルを10回繰り返し実行するトレーニング。
Iteration 10 で判明した6号機固有の問題（Redfish BootOptions 空、boot-override 無効）に対する
ワークアラウンドを確立し、スキルの信頼性を向上させる。

## CD ブート戦略

**BIOS Setup Boot Override 方式** を採用:
1. VirtualMedia マウント後、`ipmitool chassis bootdev bios` で BIOS Setup に入る
2. Save & Exit タブ → Boot Override → Legacy ATEN CD (pos 8) → Enter
3. ISOLINUX が起動しインストール実行
4. preseed の late_command で grub-efi を追加インストール（UEFI ブート対応）
5. インストール完了後、`bootdev disk options=efiboot` で UEFI ディスクブート
