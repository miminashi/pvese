# PVE サブスクリプション nag ダイアログ抑制 (apt フック永続化 + setup スクリプト組込)

- **実施日時**: 2026年6月13日 04:11 開始 (JST)。本体作業は 04:13 までに完了、同日中に追検証 (`dpkg -V` 冪等性・取りこぼし確認) とユーザ目視確認を実施。
- **担当**: opus (session cbd3dbe1)
- **結果**: ✅ 成功。現ホスト tx1320 (10.254.254.16) の web UI nag を抑制 + apt フックで永続化 + `scripts/pve-setup-remote.sh` に組込。

## 前提・目的

ユーザ依頼「web からログインすると `You do not have a valid subscription for this server.` と表示される。これを抑制できますか?」に対応する。ラボ環境のためサブスク nag は無効化して問題ない。

- 原因: `/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js` の `success` コールバック内のサブスク判定 (`res.data.status.toLowerCase() !== 'active'`) が `Ext.Msg.show({ title: gettext('No valid subscription') ... })` を表示。
- 既存の `scripts/pve-setup-remote.sh` は no-subscription リポジトリ設定・enterprise リポジトリ削除は実施済みだが、この JS nag パッチは未実装だった。

ユーザ決定: ① apt フックで永続化 (推奨)、② 現ホスト適用 + setup スクリプトにも組込。

## 採用したパッチ

`void(` 置換ではなく、**判定式を恒常 false 化** する sed を採用 (`orig_cmd()` の実行を保持でき副作用が小さい、tteck 系定番):

```sh
sed -i "/.*data.status.toLowerCase() !== .active./{s/\!//;s/active/NoMoreNagging/}" \
    /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js
```

`!==` → `!` 削除で `==`、`active` → `NoMoreNagging` → 条件 `status == 'NoMoreNagging'` は常に偽 → nag の `if` に入らず `else { orig_cmd() }` が走る。

## 実施内容

### Step 1: 現ホスト (10.254.254.16) に適用

`tmp/cbd3dbe1/nag-suppress.sh` を Write → scp → `./oplog.sh ssh ... "sh /tmp/nag-suppress.sh"` で実行:

1. apt フック `/etc/apt/apt.conf.d/no-nag-script` を quoted heredoc で設置
2. 上記 sed を即時適用
3. `systemctl restart pveproxy`

**apt フック内容**:
```
DPkg::Post-Invoke { "dpkg -V proxmox-widget-toolkit | grep -q '/proxmoxlib\.js$'; if [ $? -eq 1 ]; then { echo 'Removing subscription nag from UI...'; sed -i '/.*data.status.toLowerCase() !== .active./{s/\!//;s/active/NoMoreNagging/}' /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js; }; fi"; };
```
- `dpkg -V` で proxmoxlib.js が **未改変 (= apt 再インストール直後)** なら patch 再適用、**改変済み** なら skip する冪等設計。`apt upgrade` で proxmox-widget-toolkit が更新されても nag が復活しない。

### Step 2: setup スクリプト組込

`scripts/pve-setup-remote.sh` の `phase_post_reboot()`、proxmox-ve install + Debian kernel 除去の後 (update-grub の後) に「Suppressing subscription nag」ブロックを追加。既存の `z-fix-default-route` と同じ `<< 'NAG_EOF'` (quoted heredoc) パターンで `$?`/`$'` のシェル展開を防止。env-gate 不要 (no-subscription 前提のラボ専用スクリプト)。

## 検証結果

| 項目 | 結果 |
|------|------|
| proxmoxlib.js パッチ | ✅ `NoMoreNagging` **2 箇所** (614 = login nag dialog / 21182 = Repositories パネル `subscriptionActive` フラグ)、両方とも `== 'NoMoreNagging'` で恒常 false、JS 妥当 |
| apt フック設置 | ✅ `/etc/apt/apt.conf.d/no-nag-script` (306 bytes, `$?`/`'` リテラル保持) |
| apt 構文 | ✅ `apt-config dump DPkg::Post-Invoke` で正常パース (apt.conf 構文エラーなし) |
| pveproxy | ✅ 再起動後 web UI HTTP 200 |
| setup スクリプト構文 | ✅ `sh -n scripts/pve-setup-remote.sh` パス |
| フック冪等性 (skip 経路を実機裏取り) | ✅ パッチ後 `dpkg -V proxmox-widget-toolkit` が `??5??????   proxmoxlib.js` (md5 不一致=改変済み) を列挙 → 次回 apt 実行時は `grep -q` がマッチし **skip** (二重パッチなし) する経路を実機確認。なお「パッケージ更新後 (pristine) に非列挙→再パッチ」経路は実際の apt upgrade で発火させてはおらず、`dpkg -V` のセマンティクスからの論理的帰結 (未実証) |
| 取りこぼし確認 | ✅ パッチ後 `grep -n "!== 'active'" proxmoxlib.js` が 0 件 (exit 1)。サブスク判定 2 箇所はいずれもパッチ済みで未処理箇所なし |
| ユーザ目視 | ✅ ブラウザで nag ダイアログ消失を確認 (2026-06-13) |

> **計画との差異 (問題なし)**: 計画では `grep -c NoMoreNagging` = 1 を想定していたが実際は **2**。この PVE 9.x の proxmoxlib.js はサブスク判定を 2 箇所持つ (login nag + Repositories パネル) ため両方がパッチされた。2 箇所目は `subscriptionActive` を true 化しリポジトリ警告も抑制 = ラボでは望ましい挙動。

## 残作業・所感

- **ユーザ目視確認済み (2026-06-13)**: ブラウザでハードリロード後、nag ダイアログが消失していることを確認した。
- **コミット未実施**: `scripts/pve-setup-remote.sh` の変更はユーザ承認後にコミットする (`git push` は別途依頼)。
- 横展開: 今後の TX1320 (および同 setup スクリプトを使う PVE install) では最初から nag が出ない。

## 関連

- 対象 (リモート): `/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js`, `/etc/apt/apt.conf.d/no-nag-script`
- 編集 (リポジトリ): `scripts/pve-setup-remote.sh` (`phase_post_reboot` に追記)
- スクリプト: `tmp/cbd3dbe1/nag-suppress.sh`
