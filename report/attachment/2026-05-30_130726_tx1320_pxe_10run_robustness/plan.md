# TX1320 PXE OS install ×10 反復 + skill 蓄積

## Context

ユーザ要望: TX1320 (training-tx1320) への OS install を **10 回試行**し、**各試行で判明したことを skill に反映**、**ネットワーク関連操作の失敗は最大 3 回まで再試行**する。

TX1320 の OS install は Phase 19 (2026-05-30, commit dbb936a) で **PXE pivot により完遂済み**。iRMC USB redirector の累積劣化 (FW 9.69F でも BIOS POST 99 stuck) を回避するため、確立した経路は `pxe-deploy` skill:

> OpenWrt ローカル TFTP → 完全 embed `ipxe.efi` → DHCP (gateway 付き lease を retry 取得) → ftp.jp.debian.org (IPv4 リテラル 153.127.75.11) で kernel/initrd → preseed (playground 10.1.6.6 nginx) → storcli RAID10 → deb.debian.org base → phone-home → poweroff

本タスクは、この確立済み経路を **10 回反復して堅牢性を検証し、各回の実測 (所要時間・失敗モード・リトライ統計・新たな落とし穴) を `pxe-deploy` SKILL.md に蓄積する**こと。

**確定方針** (ユーザ回答):
- 経路: **PXE** (Phase 19 確立、USB redirector を完全 bypass)
- インフラブロッカー: **ユーザに依頼せず自力で復旧を試みて継続** (ipxe.efi 再配置 / nginx 再起動 / BIOS BSPBR 再適用等)
- 成功基準: **SSH 到達まで** (install 完遂 → disk boot → eno2 dark-net IP 特定 → SSH login + RAID10 Optimal 検証)

## 前提インフラと到達情報

| 要素 | 値 |
|------|-----|
| iRMC (BMC) | 10.254.254.9 / claude / Claude123 / HTTPS + `--ciphers DEFAULT@SECLEVEL=0` |
| installed host eno2 (dark-net) | DHCP 割当 (前回観測 10.254.254.4、**変動可**) / MAC `4c:52:62:14:de:f0` / claude 到達可。SSH 先は毎回 `ip neigh` で特定 |
| installed host eno1 (site LAN) | 192.168.33.x / NAT 背後 / claude 不達 |
| playground (preseed/firmware/nginx) | 10.1.6.6 (ssh alias `playground`) |
| OpenWrt TFTP | `/tmp/tftp/ipxe.efi` (tmpfs, router reboot で消失) / dark-net 10.1.5.1 |
| kernel/initrd mirror | ftp.jp.debian.org = `153.127.75.11` (IPv4 リテラル) |
| SSH | `ssh -F ssh/config -i ssh/id_ed25519 root@<eno2-IP>`。`<eno2-IP>` は毎回 `ip neigh` で特定した実 IP を使う。 |

詳細な手順 (Step 0–9)、preflight、リトライ表、冪等性、skill 反映方針は本レポート本文を参照。承認済みプラン全文。

## 実行体制 (sonnet エージェントへ移譲)

実 install 作業は **sonnet エージェントに移譲**。opus がオーケストレータとして 10 回ループを逐次統括し、各回後に SKILL.md へ知見を反映、次回エージェントが参照。

(承認時の全文はオリジナル `/home/ubuntu/.claude/plans/tx1320-os-10-skill-3-wild-aurora.md` に保存。本ファイルは添付用コピー。)
