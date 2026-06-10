# Save & Exit タブ — TX1320 M3 (D3373-B1x) BIOS 設定リファレンス

設定の保存・破棄・デフォルト復元・ブートオーバーライドを行うアクションタブ。
**WinSCU XML 非対象** (アクションであり設定値ではない) のため、KVM/OEM screenshot で項目を採取する。

## 🔬 KVM 実機確認 (2026-06-10、training-tx1320)

実機 Save & Exit タブを採取。**実機の項目・並び (上から)**:

| アクション | 内容 |
|-----------|------|
| Save Changes and Exit | 変更を NVRAM に保存して Setup 終了 (再起動) |
| **Discard Changes and Exit** | 変更を破棄して Setup 終了 (= 本リファレンス採取時の退出方法、"Exit system setup without saving any changes") |
| Save Changes and Reset | 変更を保存してシステムリセット |
| Discard Changes and Reset | 変更を破棄してシステムリセット |
| Save Changes | (Save Options) 変更を保存 (Setup に留まる) |
| Discard Changes | (Save Options) 変更を破棄 (Setup に留まる) |
| Restore Defaults | 工場出荷デフォルトを読み込む |
| Save as User Defaults | 現在値をユーザ既定として保存 |
| Restore User Defaults | ユーザ既定を復元 |
| Boot Override | 一覧から 1 回限りの起動デバイスを選ぶ |

**Boot Override 一覧 (2026-06-10、deploy 済 PVE 状態)**: `debian` ×2 / `UEFI: IP4 Intel(R) I210
Gigabit Network Connection` / `UEFI: IP6 Intel(R) I210 Gigabit Network Connection` ×各2。

> ⚠️ 本リファレンスの採取作業では **Save 系を実行しない**。BIOS を読むだけで、退出は
> `Discard Changes and Exit` または host ForceOff で行う (NVRAM 無変更を保証)。
> ※ 上位タブで `Esc` を押すと「Exit Without Saving」モーダルが開き入力をブロックするため、
> 退出は本タブのアクション選択か Redfish ForceOff を使う。

<!-- TODO: capture — Save & Exit タブの実項目・並びを OEM screenshot で確認して上表を確定する -->
