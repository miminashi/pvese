# Phase B サマリ (2026-04-30 JST)

## FW ファイル取得結果

### ダウンロード元
- URL: https://www.supermicro.com/en/support/resources/downloadcenter/firmware/MBD-X10DRT-P/BMC
- フロー: Cookie Accept → Download ボタン → Sign-in ダイアログ → "Continue as Guest" → EULA Accept → zip 取得 (Playwright で自動化)

### ダウンロードファイル
| 項目 | 値 |
|------|------|
| ファイル名 | `BMC_X10AST2400-C001MS_20211001_03.94_STD.zip` |
| サイズ | 27,200,160 bytes (約 26 MB) |
| Revision | **03.94** |
| ファームウェア対象チップ | ASPEED AST2400 |
| 公開日 | 2021-10-01 |

### ハッシュ検証
- 計算 SHA256: `80fcf01d2073cabe81118140a8494c8a65431dd5d20460c12272db110b5f8d21`
- 公式表示 SHA256: `80fcf01d2073cabe81118140a8494c8a65431dd5d20460c12272db110b5f8d21`
- **一致 ✅**

### 展開後の主要ファイル
- `BMC_X10AST2400-C001MS_20211001_03.94_STD.bin` (33,554,432 bytes = 32 MiB) — **本体イメージ**
  - SHA256: `6a1424f04cef6257da62b8ed81639ffbe5a70ebd5918a3fb1e9be067a4b34dc2`
- `2.08/linux/x64/AlUpdate` — Linux x64 用 IPMI FW Update Utility (ATEN Technology, v2.08, Oct 9 2018)
- `IPMI Firmware Update_NEW.pdf` — 公式更新手順書
- `Redfish_Ref_Guide_2.0a.pdf`

### バージョン比較
- 現行 (Phase A2): **3.65**
- 最新 (Phase B): **03.94** = 3.94
- メジャー番号: **両方とも 3** ✅
- → **同マイナー系列内更新**。Preserve Configuration=ON 経路で進む

### 公式 PDF の Preserve に関する記述
> NOTE !!! Uncheck preserve configuration box during flashing (very important step for FW to work properly). All settings will be reset to default.

公式は OFF を強く推奨しているが、本環境 (`10.0.0.0/8` + DHCP 無し) では OFF で BMC が IP を失うリスクが高い。
ユーザ判断により **Preserve Configuration=ON で強行** する方針。第三者 KB (45Drives, Mark Francis 等) では同マイナー系列なら ON で問題ないとされる。

### Nutanix OEM への適用判断
10号機は Nutanix NX-1065-G5 (X10DRT-P-G5-NI22) OEM 版。Supermicro stock FW を当てると Nutanix 独自カスタマイズが上書きされる可能性があるが、ユーザ判断で **適用する** 方針。

### AlUpdate コマンド
```
AlUpdate -f <fw.bin> -i lan -h <BMC_IP> 623 -u <user> -p <pass> -r y|n

主要オプション:
  -f filename.bin   FW イメージファイル
  -i lan|kcs        IPMI チャネル (本タスクは LAN 経由)
  -h <IP> <port>    BMC アドレス + ポート (default 623)
  -u <user>         IPMI ユーザ名
  -p <pass>         IPMI パスワード
  -r y              Preserve Configuration ON (default)
  -r n              Preserve Configuration OFF
  -d <filename>     現 FW を dump (FW backup)
  -c -d <file>      IPMI config backup
  -c -f <file>      IPMI config restore
```

## Phase C への送り

採用方式: **AlUpdate (LAN 経由)** — Web UI Playwright よりも CLI で進捗監視が確実。
事前バックアップ:
1. IPMI config backup (`AlUpdate -c -d`)
2. 現行 FW dump (`AlUpdate -d`) — 万一のロールバック保険
本実行: `AlUpdate -f <bin> -i lan -h 10.10.10.30 623 -u claude -p Claude123 -r y`
