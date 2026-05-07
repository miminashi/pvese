# preseed の netcfg 重複 IP 修正 (10号機 VLAN モード)

## Context

[Issue #55](issues/issues.yml) / [前任レポート](report/2026-05-02_060639_server10_disk_first_boot_recovery.md) の **最高優先度残タスク**:

10号機 (X10DRT-P / VLAN trunk 構成) の preseed インストールで、`/etc/network/interfaces` に **untagged `eno1` と VLAN サブインタフェース `eno1.1083` の両方に `10.10.10.210/8` が割り当てられる**重複問題が発生する。原因は preseed の `netcfg/get_ipaddress` directive が物理 NIC `eno1` に static IP ブロックを書き、その後 `late_command` が VLAN サブ定義を**追記 (append)** するため、両方のブロックが共存する状態になる。

前回セッションでは running system 側で `tmp/s10vkbd/fix-interfaces.sh` を SSH 経由でデプロイして手動修正したが、preseed テンプレート側は未修正のため、再インストールすると同じ問題が再発する。今回はテンプレート側を修正し、**追加の手動介入なしで先頭 boot から SSH 到達できる状態**を実現する。

## 修正方針

`scripts/generate-preseed.sh` の VLAN モード分岐 (`late_network` 変数の組み立て、lines 106-118) で、最初の echo を **`>` (overwrite)** に変えて `/target/etc/network/interfaces` を**完全に書き直す**。これにより d-i の netcfg が書いた `iface eno1 inet static` ブロックがクロバーされ、netcfg-written content は残らない。

ファイル先頭には d-i 標準の構造 (`source /etc/network/interfaces.d/*` + `lo` インタフェース) も含めて書き出す。

非 VLAN モード分岐 (4-9号機) は無変更。`>>` での append のままで動作変化なし。

## 修正内容

### `scripts/generate-preseed.sh` (lines 106-118)

VLAN モード分岐の `late_network` を以下のように変更:

```sh
# 旧: 全行 >> (append) — netcfg が書いた eno1 static ブロックが残る
# 新: 2行目 > (overwrite) で全消去後、残りは >> で書き足す。
#     `lo` と `source /etc/network/interfaces.d/*` を先頭に含めて
#     d-i 標準の構造を再現する。
late_network="echo 8021q >> /target/etc/modules; \
echo 'source /etc/network/interfaces.d/*' > ${NWFILE}; \
echo '' >> ${NWFILE}; \
echo 'auto lo' >> ${NWFILE}; \
echo 'iface lo inet loopback' >> ${NWFILE}; \
echo '' >> ${NWFILE}; \
echo 'auto ${vlan_iface}' >> ${NWFILE}; \
echo 'iface ${vlan_iface} inet manual' >> ${NWFILE}; \
echo '' >> ${NWFILE}; \
echo 'auto ${vlan_iface}.${internet_vlan_id}' >> ${NWFILE}; \
echo 'iface ${vlan_iface}.${internet_vlan_id} inet dhcp' >> ${NWFILE}; \
echo '    vlan-raw-device ${vlan_iface}' >> ${NWFILE}; \
echo '' >> ${NWFILE}; \
echo 'auto ${vlan_iface}.${internal_vlan_id}' >> ${NWFILE}; \
echo 'iface ${vlan_iface}.${internal_vlan_id} inet static' >> ${NWFILE}; \
echo '    address ${static_ip}/${static_netmask}' >> ${NWFILE}; \
echo '    vlan-raw-device ${vlan_iface}' >> ${NWFILE};"
```

`8021q` の `/etc/modules` への追記は `>>` のまま (modules は他の行も持つため上書き禁止)。

### コメント更新

同ファイルの lines 81-94 のヘッダコメントで「append」「pin static_ip」と書かれている挙動説明を、**「上書きで完全に再構築する」**旨に更新:

```sh
# - VLAN host: overwrite /target/etc/network/interfaces from late_command with
#   a fresh definition: lo + physical NIC (manual) + internet/internal VLAN
#   subinterfaces. The overwrite clobbers the `iface <phy> inet static` block
#   that d-i netcfg writes from netcfg/get_ipaddress (otherwise the static IP
#   ends up on both the untagged NIC and the VLAN sub, breaking SSH).
```

`preseed/preseed.cfg.template` (lines 127-129) のコメントも、VLAN ブロックは「上書き」、非 VLAN は「append」である点を明記する形で更新。

### `preseed/preseed-generated-s10.cfg` (生成物) の再生成

修正後 `./scripts/generate-preseed.sh config/server10.yml preseed/preseed-generated-s10.cfg` を実行し、コミット対象に含める。

### Issue #55 の close

修正完了後 `./issue.sh done 55` で完了マーク。

## 修正対象ファイル

| ファイル | 変更内容 |
|---------|---------|
| `scripts/generate-preseed.sh` | VLAN 分岐 `late_network` の 1行目を `>` に変更 + `lo`/`source` 行追加 + ヘッダコメント更新 (lines 81-118) |
| `preseed/preseed.cfg.template` | `%%LATE_NETWORK%%` 上の説明コメント更新 (lines 127-129) |
| `preseed/preseed-generated-s10.cfg` | 修正後スクリプトで再生成 |
| `issues/issues.yml` | Issue #55 を done に遷移 (`./issue.sh done 55`) |

## 検証

### 1. 静的検証 (手元で完結)

```sh
./scripts/generate-preseed.sh config/server10.yml tmp/<sid>/preseed-s10-new.cfg
# late_command 行を抽出して、/target/etc/network/interfaces への書き出しが
# > で始まり >> が続く順序になっていることを目視確認
diff preseed/preseed-generated-s10.cfg tmp/<sid>/preseed-s10-new.cfg
```

### 2. late_command の dry-run シミュレーション

`tmp/<sid>/sim-late.sh` に late_command の echo チェイン部分だけを抜き出し、`NWFILE=tmp/<sid>/sim-interfaces` で実行 → 出力が `tmp/s10vkbd/fix-interfaces.sh` の `cat <<EOF` 部分と本質的に等価 (順序・空行は許容差) であることを確認。

### 3. 非 VLAN モード非リグレッション

```sh
./scripts/generate-preseed.sh config/server4.yml tmp/<sid>/preseed-s4-new.cfg
# 既存のロジック (4号機向け) を一度生成して、いつもの内容と一致するか目視
```

非 VLAN 分岐は無変更なので、生成内容は今までと同一になるはず。

### 4. 通しテスト (10号機での再インストール)

ユーザの明確な指示があった場合のみ実施。`os-setup` スキルで 10号機を OS 再インストール:

- Phase 5 (preseed install) 完了後、Phase 6 で disk first boot 到達 (LSI HBA OPROM は既に Enabled)
- `./scripts/ssh-wait.sh 10.10.10.210 --timeout 240 --interval 10` で**手動修正なしで** SSH 到達することを確認
- `ssh pve10 'ip -br a'` で eno1 に IP が無く、eno1.1083 にのみ 10.10.10.210/8 が乗っていることを確認
- `cat /etc/network/interfaces` で `iface eno1 inet manual`, `iface eno1.1083 inet static`, `iface eno1.1120 inet dhcp` の 3 ブロックのみであることを確認

通しテストはユーザ明示指示が無い限り着手しない (CLAUDE.md ルール)。スコープは「テンプレート修正 + 静的検証 + Issue close」までとし、通しテストは別セッションでユーザが指示してから走らせる。

## 関連参照

- 前任レポート: `report/2026-05-02_060639_server10_disk_first_boot_recovery.md` (Phase 6: 副次バグの修正)
- 手動修正の参照実装: `tmp/s10vkbd/fix-interfaces.sh`
- post-install 側のフル上書き: `scripts/pve-bridge-setup.sh:73-113` (VLAN モード分岐)
- Issue: `issues/issues.yml#55`
