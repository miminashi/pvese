# Phase A サマリ (2026-04-30 JST)

## BMC 操作確認結果 (10号機 X10DRT-P, BMC 10.10.10.30)

| Step | コマンド | 結果 | 備考 |
|------|---------|------|------|
| A1 | `ipmitool ... chassis status` | ✅ OK | System Power: **off** |
| A2 | `ipmitool ... mc info` | ✅ OK | **Firmware Revision: 3.65** (メジャー番号 = **3**) |
| A3 | `ipmitool ... fru print 0` | ✅ OK | **Nutanix NX-1065-G5 OEM** (Board: X10DRT-P-G5-NI22) |
| A4 | `ipmitool ... lan print 1` | ✅ OK | Static `10.10.10.30/8`, Default GW 0.0.0.0, MAC ac:1f:6b:18:0e:04 |
| A4b | `ipmitool ... user list 1` | ✅ OK | claude = **index 4**, ADMIN/root も生存 |
| A5 | `./scripts/bmc-power.sh status` | ✅ OK | Off (Redfish 経由) |
| A6 | `curl /redfish/v1/Managers/1` | ✅ OK | FW 3.65 一致, **Model: ASPEED**, Redfish 1.0.1 |
| A7 | `./scripts/bmc-session.sh login` | ✅ OK | Cookie 保存 |
| A8 | `./scripts/bmc-session.sh csrf` | ✅ OK | CSRF トークン取得 (Base64 風: 43 文字) |
| A9 | `bmc-kvm-screenshot.py` (HTML5 iKVM) | ✅ OK | 300x150 PNG (システム OFF のため小サイズは正常) |
| A10 | `./scripts/bmc-power.sh postcode` | ✅ OK | `0x00` (POST complete or power off) |

## X10DRT-P 固有の発見

1. **Nutanix OEM サーバ** (NX-1065-G5)。BMC FW は Supermicro stock を使っているように見える (mc info で `Manufacturer Name: Super Micro Computer Inc.`, `Product Name: X10DRT-P` と表示される) が、Nutanix が独自カスタマイズしている可能性は否定できない
2. **claude ユーザは index 4** (4-6号機 X11DPU では index 2)。Phase D 検証時に `user list` で確認するときも index 4 を見る
3. **Default Gateway 0.0.0.0** で正常 (10.0.0.0/8 内部 LAN)
4. **CSRF トークンは Base64 風 43 文字** — X11DPU の 16進トークンと形式が違うが `bmc-session.sh` の regex `CSRF_TOKEN", "([^"]*)"` でちゃんと取れた
5. **既存 Supermicro 系スクリプト 100% 互換** — bmc-power.sh, bmc-session.sh, bmc-kvm-screenshot.py がそのまま動く

## メジャー番号判定

- 現行: **3.65** (メジャー = **3**)
- Phase B で取得する最新 FW のメジャー番号と比較し、一致なら Phase C に進む

## 残ファイル

- `A1-chassis-status.txt` ... `A4b-user-list.txt`
- `A9-kvm-pre.png`
- 本サマリ `A-summary.md`
