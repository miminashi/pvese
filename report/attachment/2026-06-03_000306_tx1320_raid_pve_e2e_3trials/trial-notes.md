# TX1320 RAID→PVE 通し 3試行検証ノート (session 6d0368bf, 2026-06-02)

経路: BIOS HII KVM Clear → iPXE-CD deploy → Debian+RAID10(storcli) install → disk boot → IP discovery → tx1320-pve-setup.sh → verify

## 試行1 (SUCCESS, ~60min)

- **RAID Clear**: `irmc-kvm-recover.sh` で BIOS Setup 到達 → `server.py` + `clear-all.cmd` 単一投入。
  指紋 5/5 完全一致 (c1=18051/c2=10135/c3=11383/c4=9462/c5=9758)。c5 = "no Virtual Drives" 確認。
- **deploy**: `irmc-ipxe-cd-deploy.sh ... ipxe-tx1320.iso`。ISO basename は `ipxe-tx1320.iso`
  (config hostname ベースの既定 `ipxe-training-tx1320.iso` ではない → 明示指定要)。
  cosmetic errors (無害・`|| true` ガード済): ① 起動時 DisconnectCD→HTTP400 (未接続時は ConnectCD のみ可)、
  ② step4 PowerOn "On"→ActionParameterValueNotInList (既に On のとき。ConnectCD 前提は満たされる)。
- **install**: sol-monitor 23min で DETECTING_NETWORK→CONFIGURING_APT→INSTALLING_SOFTWARE→
  INSTALLING_GRUB→POWER_DOWN→Off。partman 通過 = storcli RAID10 作成成功の証拠。
- **RAID10 裏取り**: sda 1.6T 単一 disk + LVM (root 1.6T + swap)。4本バラでなく単一 VD = RAID10 OK。
- **IP discovery**: eno2 dark-net。MAC 4c:52:62:14:de:f0。初回 .15 (boot 後 ~150s で SSH 到達)。
- **PVE setup**: pre-reboot (PVE repo + kernel) → reboot → post-reboot (proxmox-ve 581pkg) → reboot → verify。
  `pve-manager/9.2.3`、pveproxy/pvedaemon/pve-cluster 全 active、web UI HTTP 200。

### 試行1で判明した知見 (修正済み)
1. **実 hostname = `tx1320`** (config は `training-tx1320`)。preseed netcfg/get_hostname や iPXE
   cmdline hostname より優先される何か (DHCP?) で tx1320 になる。PVE は `hostname`↔IP を /etc/hosts で
   解決するため不整合だと pve-cluster 起動失敗。→ **wrapper を「live hostname を ssh で取得して使う」よう修正**。
   結果 pve-cluster active を確認 = 修正が正しい。
2. **eno2 DHCP リースは reboot をまたいで変わる** (memory #12 実証: 最終 reboot で .15 → .16)。
   wrapper の旧 fallback は `ip neigh | grep MAC` だけで **ping-sweep で neigh を populate していなかった**
   ため新 IP を発見できず exit 1。→ **wrapper の wait_ssh fallback に /24 ping-sweep + retry を追加**。
   PVE 自体は最終 reboot 前に既にインストール完了・pveversion 応答済みだった (verify だけ取り逃した)。
3. **dark-net IP は使い回され known_hosts に stale entry** が残る → host key 警告。
   `ssh-keygen -R` で掃除。SSH は StrictHostKeyChecking=no で接続自体は成功するので致命的でない。
4. **timing** (cross-site): install ~23min、PVE setup の apt ~15-20min (pve-firmware 231MB + PVE kernel
   131MB を 600KB/s で取得)。total ~60min/試行。
5. **iRMC ping ジッタ大** (36-315ms) だが Clear 指紋一致・install 完走に支障なし。

### 標準経路化に向けた確定事項
- deploy ISO は `ipxe-tx1320.iso` を明示指定。
- PVE は新規 `scripts/tx1320-pve-setup.sh <config> <ip>` で 1 コマンド化 (live hostname 自動採用 + IP 再discovery)。
- z-fix-default-route フック (本拠点 GW ハードコード) は **無害**だった: 既に eno1 経由 default route が
  あるため `if no default` ガードが発火せず誤ルートを足さない。apt は eno1 (192.168.33.1) 経由で成功。

## 試行2 (SUCCESS, end-to-end / ラッパー修正を実証)

- **RAID Clear: 単一ファイル recipe が失敗** → 検証付き経路で成功。
  - 1回目 (srv2): `clear-all.cmd` 単一投入。指紋が全く不一致 (c1=14584 caret_y=292 等、c3==c4=19607)。
    c1 画像 = **BIOS Main タブ**のまま (cursor=System Time)。
    **真因: 先頭 `press ArrowRight` (Main→Advanced タブ切替) が高 latency でドロップ** → Main タブで
    14×ArrowDown して System Time に着地 → 以降全て誤画面。RAID 未クリア。
  - 2回目 (re-recover → srv3): **検証付き経路**で成功:
    ① `press ArrowRight` + `shot tab.png` → Advanced タブ着地を画像確認 (size 17919, eno2 MAC も確認)。
    ② `navy 393 caret 25 1500` → AVAGO 行に **adaptive 着地** (16 press で自己補正、size=18051/y393 一致)。
    ③ Enter×3 + ArrowDown + `shot clearrow.png` → "Clear Configuration"/"Deletes all..." 確認。
    ④ modal commit を1ファイル投入 → vdm.png=**9758** (trial1 c5 一致 = "no Virtual Drives" = クリア成功)。
- **install**: sol-monitor 26.6min で 7/9 stage → PowerState Off (完遂)。
- **IP discovery**: 初回 .17。
- **PVE setup (修正済みラッパー)**: live hostname `tx1320` 採用 → pve-cluster active。
  最終 reboot で **eno2 lease .17→.16 に変動** → 修正済み `wait_ssh` が ping-sweep + MAC 再 discovery で
  **自動 reconnect (.16)** → verify 完走。pve-manager/9.2.3、3サービス active、sda 1.6T、web UI HTTP 200。

### 試行2の主要知見
1. 🚨 **単一ファイル Clear recipe (r10hiicd 10/10) は先頭 ArrowRight タブ切替ドロップに脆弱**。
   高 latency 拠点では Advanced タブ着地を `shot` で検証し、AVAGO 行は `keyrepeat ArrowDown 14` でなく
   **`navy 393 caret` (adaptive, ドロップ自己補正)** で着地するのが堅牢。→ irmc-bios-raid skill へ反映。
2. ✅ **eno2 lease 変動は trial 1/2 で再現** (.15→.16、.17→.16)。ラッパーの ping-sweep 再 discovery が
   両試行で機能 = 修正は正しい。.16 が 2 回出現 = DHCP プールの IP 使い回し。
3. timing: install 26.6min、PVE setup ~18min。total ~75min (re-recover 1回分を含む)。

## 試行3 (SUCCESS, end-to-end)

- **RAID Clear**: 1回目 srv4 で先頭 ArrowRight が再びドロップ (tab.png=14629=Main 指紋)。retry で Advanced
  着地したが、その後 navy が LSI SW RAID (406/411) に overshoot、続く ArrowUp が **ArrowRight に誤登録**
  して Security タブへ、さらに ArrowLeft ドロップ + **stale/ghost フレーム** (Main 内容に Advanced 項目残像)
  と KVM が連鎖的に劣化。→ **recover (Manager.Reset) で KVM 健全化** → srv5 で検証付き経路がクリーン完走:
  tab 初回成功 (17919) → navy 14press で AVAGO (18051/393) → clearrow (10135) → commit (dlg 11383 /
  committed 9462 / vdm **9758**) = 全指紋 trial1 一致 = クリア成功。
- **install**: 12.7min (cross-site 良好で最速)。7/9 stage → Off。
- **PVE setup**: live hostname tx1320、eno2 lease .18→.16 自動再 discovery、pve-manager/9.2.3、
  3サービス active、sda 1.6T、web UI HTTP 200。

### 試行3の主要知見
1. 🚨 **高 latency spell では検証付き経路でも単発キーが頻繁にドロップ/誤登録** (ArrowRight drop、
   ArrowUp→ArrowRight 誤登録によるタブ移動、stale frame)。**recover (Manager.Reset) が KVM pipeline を
   健全化する唯一確実な復旧**。劣化の兆候 (連続ドロップ・stale frame) を見たら早めに recover する。
2. navy は AVAGO(393)/LSI(406) の 13px 隣接で LSI に overshoot しうる → 着地後に行テキスト/指紋検証必須。

## 🏁 3/3 通し成功サマリ

| 試行 | RAID Clear 経路 | install | PVE | 最終IP | recover回数 |
|---|---|---|---|---|---|
| 1 | 単一ファイル (一発成功) | 23min | 9.2.3 ✅ | .16 | 1 |
| 2 | 検証付き (単一は ArrowRight drop) | 26.6min | 9.2.3 ✅ | .16 | 2 |
| 3 | 検証付き (KVM劣化→recover で健全化) | 12.7min | 9.2.3 ✅ | .16 | 2 |

- **全試行で「RAID10 初期化 → Debian install → PVE 9.2.3 + web UI 200」を達成 (3/3)**。
- install+PVE 部分は 3/3 決定論的 (極めて堅牢)。**BIOS HII KVM Clear が唯一の脆弱リンク** (latency 依存)。
- eno2 の最終 reboot 後リースは 3 試行とも **.16 に収束** (PVE kernel boot 時の DHCP が同一 lease)。
- 標準経路: iPXE-CD (`irmc-ipxe-cd-deploy.sh ... ipxe-tx1320.iso`) + `tx1320-pve-setup.sh`。3/3 成功で昇格確定。
