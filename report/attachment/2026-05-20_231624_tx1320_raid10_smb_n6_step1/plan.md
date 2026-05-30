# TX1320 iRMC SMB silent failure N6 仮説検証 step 1: Samba ソース + Microsoft SMB UNIX 拡張仕様で level=513 (0x201) の意味を確定する

- **担当**: s-quizzical-wozniak (Opus 4.7)
- **対象**: training-tx1320 (10.254.254.9, Fujitsu PRIMERGY TX1320 M3, iRMC S4 FW 9.08F)
- **Issue**: #69 (継続中、 N6 検証 step 1 を実施)
- **親レポート**: [2026-05-20_200157_tx1320_raid10_smb_n2_disproof.md](/home/ubuntu/projects/pvese/report/2026-05-20_200157_tx1320_raid10_smb_n2_disproof.md) (s-twinkly-boole、 N2 反証 + N6 仮説導出)

## Context

前セッション (s-twinkly-boole、 2026-05-20) で iRMC SMB attach silent failure の真因候補として **N6 = iRMC が qfsinfo level=513 (0x201) を全 retry cycle で要求するが Samba 4.19.5-Ubuntu は NT_STATUS_INVALID_LEVEL を返す** ことが Samba debug log で確定した。Samba ソース (`source3/smbd/smb1_trans2.c:1686`) の `call_trans2qfsinfo` 内で level=513 に対する case label が無く、default 句に落ちて INVALID_LEVEL が返される推察。

本セッションでは Samba ソースを samba.org tarball で取得し、 level=513 の case label 不在を grep で確認したうえで、 Microsoft の SMB UNIX 拡張仕様 / Samba 開発者ドキュメント (SambaXP papers, MS-CIFS, MS-SMB) を WebFetch で参照して level 513 (0x201) の本来の意味を確定する。 read-only 作業のみ、 リモートマシン (training-tx1320) への state-changing 操作は一切なし。

成果物は (a) Samba ソース内の level=513 case 不在の確証、 (b) Microsoft / Samba 仕様上の level=513 の意味、 (c) iRMC FW 9.08F が要求する正規 response 形式の推定、 (d) 次セッションへの N6 step 2 (patch + 検証) 実施可否判断。

## スコープと制約

- **scope (今回)**: N6 step 1 (Samba ソース解析 + 仕様調査) のみ
- **scope 外 (次セッション)**: N6 step 2 (Samba patch + Samba 再起動 + ConnectCD で attach 検証)、 N3 (iRMC Licenses dump)、 N5 (smb_posix_open response 形式)、 ksmbd 代替
- **state-changing 操作**: なし (BMC / Samba / VirtualMedia は触らない)
- **ユーザ sudo 操作**: 不要
- **Samba 取得方法**: samba.org tarball を `tmp/<sid>/` に展開 (sudo 不要)

## Phases

### Phase 0: Pre-flight (read-only)

- セッション ID 生成: `SID=$(openssl rand -hex 4); mkdir -p tmp/$SID`
- 現在の Samba バージョン確認 (`dpkg -l samba` 既に確認済: 2:4.19.5+dfsg-4ubuntu9.4)
- ping baseline は不要 (リモート操作なし)。任意で training-tx1320 への到達性のみ確認可

### Phase 1: Samba 4.19.5 ソース取得

- `curl -O https://download.samba.org/pub/samba/stable/samba-4.19.5.tar.gz` を `tmp/$SID/` 配下で実行
- 検証: `sha256sum samba-4.19.5.tar.gz` を取得し、 後でレポートに記録
- 展開: `tar xzf samba-4.19.5.tar.gz` → `tmp/$SID/samba-4.19.5/`
- 展開サイズと主要ディレクトリ (`source3/smbd/`) の存在を確認

### Phase 2: Samba ソース grep (N6 step 1 の核心)

検証対象は SMB1 trans2 系 (iRMC が SMB1 で接続している前提、 前セッションで確定):

- **対象ファイル**: `tmp/$SID/samba-4.19.5/source3/smbd/smb1_trans2.c`
- **対象関数**: `call_trans2qfsinfo()` と `smbd_do_qfsinfo()` (前セッションで debug log のソース位置を line 1686 で確認済)

検索キーワード:

```sh
grep -nE 'case 513|case 0x201|level *== *513|level *== *0x201' \
    tmp/$SID/samba-4.19.5/source3/smbd/smb1_trans2.c
grep -nE 'case SMB_QUERY_(FS|CIFS|POSIX)_' \
    tmp/$SID/samba-4.19.5/source3/smbd/smb1_trans2.c
grep -rnE 'SMB_QUERY_CIFS_UNIX_INFO|SMB_QUERY_POSIX_FS_INFO|0x0201|0x0202' \
    tmp/$SID/samba-4.19.5/libcli/smb/ tmp/$SID/samba-4.19.5/source3/include/ \
    tmp/$SID/samba-4.19.5/source3/smbd/
```

### Phase 3: SMB UNIX 拡張仕様の調査 (WebFetch)

- Samba wiki UNIX_Extensions (CIFS POSIX 拡張概要 + capability flags + struct 定義)
- Microsoft 公式 [MS-CIFS] / [MS-SMB] (Trans2 info level)
- Linux kernel cifs.ko の info_level 定義 (cifspdu.h)

### Phase 4: 分析と結論

| 判定 | 次セッションの方針 |
|------|---|
| (A) Samba patch で attach 成立する可能性高い | N6 step 2 (patch + 検証) を最優先 |
| (B) iRMC FW 独自要件で Samba spec 外 | ksmbd 代替 / Windows SMB server で検証 |
| (C) Microsoft 仕様で別の目的 | iRMC FW upgrade 検討 / Fujitsu 問い合わせ |
| (D) 仕様が見つからず判断不能 | N5 / packet 詳細解析へ |

### Phase 5: レポート + Issue update

## ロールバック / 互換性復元

本セッションでは **state-changing 操作なし** のため、 rollback 不要。
