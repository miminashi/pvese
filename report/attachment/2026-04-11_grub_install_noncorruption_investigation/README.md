# iDRAC7 R320 grub-install 非累積破損仮説潰し込み 調査/実験 証拠

本ディレクトリは以下 2 つのフェーズの証拠を格納する:

- `pre-fix/` — 修正適用前 (2026-04-10 の 7/8/9 並列 3 反復テストで発生した server 8 iter 2 grub-install 失敗の実証拠)
- `experiment/` — 修正適用後の re-test 結果 (検証 3 完了後に追加される)

## 調査上の注意: どのログが「本物の失敗証拠」か

親セッション `da4c169f` が記録した `tmp/da4c169f/sol-install-s8-iter2.log` (本ディレクトリの `pre-fix/iter2-s8-parentsession-bootloop.log`) は iter 2 の **BIOS POST ループのみ** を含み、installer 出力は一切入っていない。これだけを見ると「iter 2 は installer まで到達していない」と誤読しかねない。

**実際の grub-install ダイアログ失敗の証拠**は、iter 2 を担当した子エージェントセッション `s8setup2` が別キャプチャした SOL 3 本:

- `iter2-s8-sol-attempt1.txt` (元: `tmp/s8setup2/sol-install-s8.txt`, 16 MB)
- `iter2-s8-sol-attempt2.txt` (元: `tmp/s8setup2/sol-install-s8-retry.txt`, 5.4 MB)
- `iter2-s8-sol-attempt3.txt` (元: `tmp/s8setup2/sol-install-s8-retry2.txt`, 6.4 MB)

これらには ANSI TUI で描画された以下のダイアログが計 43+ 回出現する:

```
[!!] Configuring shim-signed:amd64
Unable to install GRUB in /dev/sda
Executing 'grub-install /dev/sda' failed.
This is a fatal error.
<Go Back>  <Continue>
```

ダイアログタイトルが **「Configuring shim-signed:amd64」** である点が重要 (grub-installer の本体フェーズではなくパッケージ postinst 経路での失敗)。

## pre-fix/ ファイル一覧

| ファイル | 元の場所 | サイズ | 内容 |
|---------|---------|-------|------|
| `iter2-s8-sol-attempt1.txt` | `tmp/s8setup2/sol-install-s8.txt` | 16 MB | 1 回目の試行、grub-install ダイアログが連続発生した TUI |
| `iter2-s8-sol-attempt2.txt` | `tmp/s8setup2/sol-install-s8-retry.txt` | 5.4 MB | 2 回目のリトライ |
| `iter2-s8-sol-attempt3.txt` | `tmp/s8setup2/sol-install-s8-retry2.txt` | 6.4 MB | 3 回目のリトライ (最終失敗) |
| `iter2-s8-kvm-grubfail.png` | `tmp/s8setup2/grub-fail-screen.png` | ~3 KB | iDRAC7 VNC 経由のスクリーンショット (SYSTEM IDLE のため内容なし — VNC stale frame の既知問題) |
| `iter2-s8-parentsession-bootloop.log` | `tmp/da4c169f/sol-install-s8-iter2.log` | 258 KB | 親セッションから見える SOL、BIOS POST ループのみで installer 出力なし (=親セッションからは失敗の全貌が見えない証拠) |
| `kvm-iter2-1.png` | `tmp/da4c169f/kvm-iter2-1.png` | — | 親セッションから撮影した Dell BIOS スプラッシュ |
| `kvm-iter2-2.png` | `tmp/da4c169f/kvm-iter2-2.png` | — | 同上、F2/F10/F11/F12 メニュー表示直前 |
| `kvm-iter2-3.png` | `tmp/da4c169f/kvm-iter2-3.png` | — | 黒画面 (遷移中) |
| `kvm-iter2-progress.png` | `tmp/da4c169f/kvm-iter2-progress.png` | — | 黒画面 (installer は裏で動作中だが VNC stale frame) |
| `kvm-iter2-midlate.png` | `tmp/da4c169f/kvm-iter2-midlate.png` | — | 同上 |
| `kvm-iter2-late.png` | `tmp/da4c169f/kvm-iter2-late.png` | — | iDRAC VNC "SYSTEM IDLE" 表示 (セッションタイムアウト) |

## ダイアログ原文の再現

`iter2-s8-sol-attempt1.txt` の行 10711〜10720 付近から:

```
                 lqqu [!!] Configuring shim-signed:amd64 tqqqk
                 x                                           x
  lqqqqqqqqqqqqqqx    Unable to install GRUB in /dev/sda     x qqqqqqqqqqqqqk
  x              x Executing 'grub-install /dev/sda' failed. x              x
  x              x                                           x              x
  x              x This is a fatal error.                    x              x
```

同パターンが attempt1 で 10714, 11361, 12008, 12655, ... と約 640 行間隔で繰り返し (TUI 描画 refresh)。attempt2/3 でも同様。

## 関連ドキュメント

- 元レポート: [../../2026-04-11_031406_sol_monitor_false_positive_fix.md](../../2026-04-11_031406_sol_monitor_false_positive_fix.md) — 3 反復テストと iter 2 失敗の発見
- 8 号機 VM recovery テスト: [../../2026-04-10_172807_server8_vmedia_recovery_test.md](../../2026-04-10_172807_server8_vmedia_recovery_test.md) — 前段の false positive 発見
- 本プラン: `/home/ubuntu/.claude/plans/prancy-hugging-raccoon.md` (セッション中のみ参照可)
- Issue #46: iDRAC7 R320 grub-install 間欠失敗: 非累積破損仮説の潰し込み + 残存課題 2/3 修正
