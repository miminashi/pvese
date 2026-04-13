# 6号機 os-setup Iteration 2 継続 — PXE 無限ループ問題

- **実施日時**: 2026年4月2日 20:30 〜 4月3日 00:30 JST
- **所要時間**: 約4時間
- **対象**: 6号機 (ayase-web-service-6, Supermicro X11DPU)
- **前回レポート**: [Iteration 2](2026-04-02_202850_server6_training_iteration2.md)

## 目的

前回レポートで特定した ESP 欠如問題を修正し、Debian 再インストール + UEFI ブートを完了すること。

## 成果

### 1. preseed テンプレート修正 (3 回)

| 修正 | 内容 | 効果 |
|------|------|------|
| ESP カスタムレシピ | `partman-auto/expert_recipe` で ESP 512MB を明示 | Iteration 1 の ESP 欠如を解消 |
| GPT 強制 | `partman-auto/disk_label string gpt` 追加 | Legacy ブート時の MBR → GPT 問題を解消 |
| startup.nsh | late_command で `startup.nsh` を ESP に作成 | EFI Shell からの自動 GRUB 起動を実現 |

### 2. CD ブート方法の確立

| 方法 | 結果 |
|------|------|
| `ipmitool chassis bootdev cdrom` | **不安定** — 動作する場合と EFI Shell に落ちる場合がある |
| BIOS Boot tab → center click → Enter → PageUp → Enter → F4 | **動作** — center click で選択された Boot Option の値を CD/DVD に変更して Save & Exit |

### 3. Debian インストール成功 (3 回実行)

| 試行 | 所要時間 | 結果 |
|------|---------|------|
| v2 (ESP レシピ) | 5.5 min | 完了 (ESP あり、FS0 確認済み) |
| v3 (GPT 強制) | 7.8 min | 完了 |
| v4 (startup.nsh) | 不明 (SOL 接続失敗) | 完了 (PowerState Off 検出) |

### 4. bmc-kvm-interact.py 改善

- `--safe-click`: 右下隅 (795,595) クリック
- `--no-click`: JS focus のみ (マウスイベントなし)
- いずれも BIOS ナビゲーションでは不安定

## 未解決の問題: PXE 無限ループ

### 症状
- DUAL Boot Mode で電源投入すると、IBA 40-10G PXE / FlexBoot が無限にリトライ
- 15分以上待っても PXE からディスクブートに進まない
- `ipmitool chassis bootdev disk` / `bootdev cdrom` が IPMI 経由では効かない
- BIOS Boot Override の KVM 操作が center click の干渉で不安定

### 原因分析
- Mellanox ConnectX-3 Pro 40G アダプタの FlexBoot PXE が無限リトライ
- Boot Option #1 が PXE/Network に設定されている (center click の誤操作で変更された)
- Supermicro X11DPU の BIOS / BMC 制限:
  - Redfish BootOptions API が空
  - `bootdev disk/cdrom options=efiboot` が効かない
  - BIOS KVM の center click がメニューカーソルを移動させる

### 次回セッションでの解決策

**優先案**: BIOS Setup の Boot タブで全 PXE Boot Option を Disabled に設定する

1. BIOS に入る (`bootdev bios` + power cycle)
2. Boot タブに移動 (ArrowRight x5)  
3. 各 Boot Option (PXE 関連) を Disabled に変更
4. Boot Option #1 を "UEFI Hard Disk:debian" に設定
5. F4 Save & Exit
6. Debian が UEFI ブート

**ツール改善案**: bmc-kvm-interact.py の canvas focus を改善
- Canvas 要素に `tabindex` を設定して `page.focus()` を確実に動作させる
- または `page.keyboard.press()` の前に `page.evaluate("document.querySelector('#noVNC_canvas').dispatchEvent(new Event('focus'))")` を実行

## 環境状態

| サーバ | 状態 |
|--------|------|
| 6号機 | **Off** — NVMe に Debian 13 (GPT + ESP + startup.nsh) インストール済み。Boot Mode: DUAL。PXE 無限ループでディスクブート不可 |

## os-setup フェーズ状態

```
iso-download              done
preseed-generate          done
iso-remaster              done
bmc-mount-boot            done
install-monitor           done
post-install-config       pending  ← ブート問題解決後に実行
pve-install               pending
cleanup                   pending
```
