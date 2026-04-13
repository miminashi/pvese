# 6号機 os-setup トレーニング Iteration 2 (ESP 欠如問題の特定と修正)

- **実施日時**: 2026年4月2日 18:00 〜 20:28 JST
- **所要時間**: 約2.5時間
- **対象**: 6号機 (ayase-web-service-6, Supermicro X11DPU)
- **前回レポート**: [Iteration 1](2026-04-02_034720_server6_training_iteration1.md)

## 添付ファイル

- [実装プラン](attachment/2026-04-02_202850_server6_training_iteration2/plan.md)

## 目的

Iteration 1 で未完了だった UEFI ブート確認を完了し、Phase 6-8 を実行して os-setup を完了すること。

## 重要な発見

### 1. 根本原因: Legacy ISOLINUX インストールでは ESP が作成されない

Iteration 1 で `bootdev disk options=efiboot` が PXE に落ちた原因を特定した:

- Debian installer が Legacy ISOLINUX でブートされた場合、パーティション自動設定 (`partman-auto/choose_recipe select atomic`) は **EFI System Partition (ESP) を作成しない**
- preseed の late_command で `grub-install --target=x86_64-efi --efi-directory=/boot/efi` を実行しても、ESP マウントポイント (`/boot/efi`) が存在しないため **サイレントに失敗** していた
- NVMe には ESP がないため、UEFI ファームウェアはブート可能なデバイスとして認識しない
- EFI Shell から `map` コマンドで確認したところ、**ファイルシステムマッピング (FS0: 等) が一切存在しない** ことを確認

### 2. "debian" Boot Override エントリの消失

- Iteration 1 終了時には BIOS Save & Exit タブの Boot Override に "debian" エントリが存在していた
- 本セッション中に "Restore User Defaults" ダイアログを誤ってトリガーした影響か、"debian" エントリが消失
- ESP が存在しないため、ファームウェアが再検出できず、エントリは復活しなかった
- Iteration 1 で見えていた "debian" エントリは、preseed late_command の `grub-efi-amd64` パッケージインストール時に一時的に作成された可能性がある (chroot 環境で efivarfs がマウントされていた場合)

### 3. bmc-kvm-interact.py の改善

BIOS ナビゲーションの信頼性向上のため、以下のオプションを追加:

| オプション | 動作 | 用途 |
|-----------|------|------|
| `--safe-click` | canvas 右下隅 (795,595) をクリック | BIOS メニュー項目を避ける |
| `--no-click` | JS `focus()` のみ、マウスイベントなし | BIOS カーソル干渉を完全回避 |

ただし `--no-click` はキー入力が不安定 (JS focus だけでは Playwright keyboard イベントが canvas に到達しない場合がある)。`--safe-click` は BIOS 右下の status bar をクリックするため比較的安全だが、一部のBIOS画面で干渉あり。

### 4. Redfish BootOptions が6号機で常に空

```
curl -sk -u claude:Claude123 https://10.10.10.26/redfish/v1/Systems/1/BootOptions
→ (空レスポンス)
```

6号機の Supermicro BMC は Redfish BootOptions API を実装していない。`UefiBootNext` も `AllowableValues` に含まれない。ブート制御は BIOS KVM 操作でのみ可能。

### 5. Save & Exit Boot Override のメニュー構造 (UEFI モード)

`--no-click` + `--wait 500` で正確にマッピング:

| ArrowDown | 項目 |
|-----------|------|
| 0 (初期) | Discard Changes and Exit |
| 1 | Save Changes and Exit |
| 2 | Save Changes |
| 3 | Discard Changes |
| 4 | Restore Defaults |
| 5 | Save User Defaults(?) |
| 6 | Restore User Defaults |
| 7-12 | PXE Boot Override (IBA 40-10G 複数エントリ) |
| 13 | Launch EFI Shell from Filesystem Device |
| 14 | (不明: EFI Shell 関連) |
| 15+ | ラップ (先頭に戻る) |

IBA 40-10G デュアルポート 40G アダプタが 6 つの PXE エントリを生成 (IPv4/IPv6 x ポート数 + FlexBoot)。

### 6. EFI Shell への直接ブート

Boot Mode を UEFI に変更後、`bootdev bios` なしで通常ブートすると、ブート可能デバイスが見つからず **EFI Shell に自動的に落ちる**。EFI Shell から `map` で確認したところファイルシステムなし。

## コード変更

| ファイル | 変更内容 |
|---------|---------|
| `preseed/preseed.cfg.template` | `atomic` レシピを ESP 付きカスタムレシピ `efi-lvm` に置換 |
| `scripts/bmc-kvm-interact.py` | `--safe-click`, `--no-click` オプション追加 |

### preseed カスタムレシピ (efi-lvm)

```
512MB FAT32 ESP ($primary, method{ efi })
512MB ext2 /boot ($primary, $bootable)
残り全て LVM vg0:
  - 4GB swap
  - 残り ext4 / (root)
```

## 次回の作業項目

1. **Phase 2-5 の再実行**: preseed-generate → iso-remaster → bmc-mount-boot → install-monitor
   - 修正済み preseed テンプレートで ISO をリマスター
   - Legacy ISOLINUX Boot Override (位置 8) で CD ブート
   - Debian installer が ESP 付きカスタムレシピでパーティション作成
   - late_command の grub-install が ESP 上に grub-efi を正しくインストール
2. **UEFI ブート確認**: インストール完了後、EFI Shell から FS0:\EFI\BOOT\BOOTX64.EFI の存在確認
3. **Phase 6-8**: post-install-config → pve-install → cleanup

## 環境状態

| サーバ | 状態 |
|--------|------|
| 4号機 | Off |
| 5号機 | Off |
| 6号機 | **Off** — NVMe に ESP なしの不完全な Debian 13 インストール。Boot Mode: UEFI |
| 7-9号機 | Off |

## os-setup フェーズ状態

```
iso-download              done
preseed-generate          pending  ← ここから再実行
iso-remaster              pending
bmc-mount-boot            pending
install-monitor           pending
post-install-config       pending
pve-install               pending
cleanup                   pending
```
