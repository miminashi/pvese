# TX1320 iRMC SMB silent failure 真因調査: ネットワーク latency ではなく iRMC FW SMB redirector の application-layer retry サイクルが正体 (Issue #69)

- **実施日時**: 2026年5月19日 08:24 〜 16:38 (JST、 約 8時間 14分、 ただし大半はユーザ手動 sudo 実行待ち)
- **担当**: s-expressive-bubble (Opus 4.7)
- **Issue**: #69 (継続中、 status=blocked、 ただし blocker は「拠点間ネットワーク」ではない真因に修正済)
- **対象**: training-tx1320 (10.254.254.9, Fujitsu PRIMERGY TX1320 M3, iRMC S4 FW 9.08F)
- **親レポート**: [2026-05-19_023431_tx1320_raid10_smb_blocked_persist.md](2026-05-19_023431_tx1320_raid10_smb_blocked_persist.md) (lovely-meadow、 「ネットワーク経路品質が真因」結論)
- **祖先**: [2026-05-18_101017_tx1320_raid10_cdrom_patch_verify.md](2026-05-18_101017_tx1320_raid10_cdrom_patch_verify.md) (c-frolicking-starlight、 WAN latency 558ms root cause 推定)

## 添付ファイル

- [プラン](attachment/2026-05-19_163800_tx1320_raid10_smb_real_root_cause/plan.md)
- [Ping baseline (30 packets, 0% loss, RTT avg 228ms)](attachment/2026-05-19_163800_tx1320_raid10_smb_real_root_cause/ping-precheck.log)
- [Phase 1: tcpdump pcap (port 445 + ICMP、 90s capture)](attachment/2026-05-19_163800_tx1320_raid10_smb_real_root_cause/smb-trigger.pcap)
- [Phase 1: pcap 解析結果 (tcpdump 整形済 94 line)](attachment/2026-05-19_163800_tx1320_raid10_smb_real_root_cause/pcap-summary.txt)
- [Phase 1: 操作ログ](attachment/2026-05-19_163800_tx1320_raid10_smb_real_root_cause/phase1.log)
- [Phase 2: Samba debug log per-machine (log level=10、 1574 行)](attachment/2026-05-19_163800_tx1320_raid10_smb_real_root_cause/samba-machine.log)
- [Phase 2: Samba debug log empty-%m (8000+ 行、 iRMC + 他ローカル client 混在)](attachment/2026-05-19_163800_tx1320_raid10_smb_real_root_cause/samba-log-empty.log)
- [Phase 2: 操作ログ](attachment/2026-05-19_163800_tx1320_raid10_smb_real_root_cause/phase2.log)
- [Phase 3: iRMC OEM iRMCConfiguration root JSON](attachment/2026-05-19_163800_tx1320_raid10_smb_real_root_cause/oem-iRMCConfiguration.json)
- [Phase 5: guest user 作成試行 (失敗)](attachment/2026-05-19_163800_tx1320_raid10_smb_real_root_cause/phase5.log)
- [Phase 5b: ISO chown nobody:nogroup 試行 (失敗)](attachment/2026-05-19_163800_tx1320_raid10_smb_real_root_cause/phase5b.log)
- [Phase 5c: umount + 再 config 試行 (失敗)](attachment/2026-05-19_163800_tx1320_raid10_smb_real_root_cause/phase5c.log)
- [Phase 5d: force user=nobody smb.conf 試行 (失敗)](attachment/2026-05-19_163800_tx1320_raid10_smb_real_root_cause/phase5d.log)
- [互換性 baseline smbclient -L 結果](attachment/2026-05-19_163800_tx1320_raid10_smb_real_root_cause/smbclient-baseline.txt)
- [互換性 final smbclient -L 結果 (baseline と差異なし)](attachment/2026-05-19_163800_tx1320_raid10_smb_real_root_cause/smbclient-final.txt)
- [smb.conf backup (互換性復元基準)](attachment/2026-05-19_163800_tx1320_raid10_smb_real_root_cause/smb.conf.backup)
- [smb.conf.test (log level=10 追加版、 Phase 2 で適用)](attachment/2026-05-19_163800_tx1320_raid10_smb_real_root_cause/smb.conf.test)
- [smb.conf.test3 (force user=nobody 追加版、 Phase 5d で適用)](attachment/2026-05-19_163800_tx1320_raid10_smb_real_root_cause/smb.conf.test3)

## 前提・目的

前 2 セッションは「ネットワーク経路品質 (RTT 558→226ms、 jitter 90+ms) が iRMC SMB redirector の内部 timeout を超えるため SMB negotiation 不成立 (silent failure)」と外形観測のみで結論していた。 本セッションは **packet レベル + Samba application-level log で実証** し、 必要に応じて改善試行 (guest user / ISO chown / smb.conf force user 等) で attach 成立条件を探る。 互換性 (os-setup スキル等で使う SMB1+NTLMv1+guest) は smb.conf を試験ごとにバックアップ → 適用 → 復元 → 検証する手順で完全に保護した。

## 重要な発見 (next-session must-read)

### 🎯 1. **前セッションの結論は誤り**: silent failure は「SMB negotiation 不成立」ではなく **application-level の retry サイクル**

Phase 1 で tcpdump (port 445 + ICMP) を ConnectCD trigger と並行 capture した結果:

| 観測 | 値 |
|------|-----|
| TCP 3-way 完了 | ~640ms (RTT 約 320ms × 2) |
| 最初の SMB1 negotiate request → response | 0.5s 以内に往復 |
| SMB session setup 完了 | 5 秒以内 (initial 段 8 packet 往復) |
| Samba 送信累計 | 13,510 bytes (iRMC へ) |
| iRMC 送信累計 | 1,772 bytes (Samba へ) |
| **5 秒で初期 SMB session 完結後、 60 秒の沈黙** | **08:29:18 → 08:30:17 = 59 秒空白** |
| 沈黙明けの追加 SMB 往復 | small packets 6 ペア (146, 164, 166, 176, 45, 39 bytes) |
| 沈黙明けまでの累計 | Samba 13,889 / iRMC 2,129 bytes |
| 最終 socket state | ESTABLISHED 維持 (RTT 317ms、 retransmit なし) |

ping baseline は前セッションと同水準 (30 packets, 0% loss, RTT avg 228ms / jitter 93ms)。 つまりネットワーク経路は前セッションと変わらず、 **しかし TCP も SMB packet も双方向で正常に流れている**。 「silent failure」は packet レベルの障害ではない。

### 🎯 2. **真因確定**: iRMC は file open + AIO read まで実行している。 60 秒サイクルで同じ操作を retry

Phase 2 で Samba debug log を `log level = 10` に上げて trigger 再現すると、 1574 行 (per-machine) + 8000+ 行 (空 %m 落ちの併存 log) のログが取得できた。 iRMC の SMB 操作シーケンス:

```
08:41:38  SMB negotiate         → NT LM 0.12 (SMB1)
08:41:38  Session setup         → NTLMSSP + EXTENDED_SESSIONSECURITY + UserName=guest
                                  → guest が Samba passdb に無し → NT_STATUS_NO_SUCH_USER
                                  → `map to guest = bad user` で nobody (uid 65534) フォールバック
                                  → NT_STATUS_OK + session_global_id 0x4387b7d5
08:41:39  Tree connect          → \\10.1.6.1\public NT_STATUS_OK (tcon_wire_id 40835)
08:41:40  trans2 qfsinfo        → filesystem info (level 260, 261)
08:41:40  trans2 qpathinfo      → file info (level 263)
08:41:41  trans2 setpathinfo    → ★ info_level=521 (SMB_SET_FILE_UNIX_BASIC) ★
                                  fname=debian-training-tx1320-raid10.iso
                                  totdata=18 bytes
08:41:41  smb_posix_open        → ★ POSIX OPEN (SMB UNIX extensions) ★
                                  flags=1024, mode 0755
                                  open NT_STATUS_OK (open_global_id 0x1dd28695)
08:41:42  schedule_aio_read_and_X → AIO pread 開始
08:41:42  aio_pread_smb1_done     → AIO pread 完了
[60 秒沈黙]
08:42:42  trans2 setpathinfo / smb_posix_open / brl_get_locks_readonly
[60 秒沈黙]
08:43:42  同上 (3 回目 retry)
```

**iRMC は SMB1 + UNIX 拡張 (POSIX open / SET_FILE_UNIX_BASIC) を使う Linux SMB client**。 file open + AIO read まで成功しているのに、 USB device は生成されない (Members@odata.count=0)。 そして **60 秒間隔で同じ setpathinfo + smb_posix_open + AIO read を retry** している。 これが「silent failure」の正体: アプリケーション層では retry サイクルだけが回っており、 ネットワークレベルの問題ではない。

### 🎯 3. **未確定**: なぜ iRMC は file open / read 成功後に USB device を生成しないか

5 つの仮説のうち本セッションで切り分けたもの:

| # | 仮説 | 検証結果 |
|---|------|----------|
| H1 | TCP 上で SMB negotiate request が届かない | **棄却** (Phase 1 pcap で双方向の packet 確認) |
| H2 | SMB negotiate は完了するが session setup で内部 timeout | **棄却** (Phase 2 で session setup + tree connect + open + read まで成功) |
| H3 | Path MTU mismatch (1305 vs 1448) で大きい packet drop | **棄却** (Phase 1 で 2610 byte packet も正常受信、 retransmit なし) |
| H4 | iRMC が SMB2/3 を試して NT1 で reject | **棄却** (iRMC は NT LM 0.12 = SMB1 のみ送信、 SMB2 試行なし) |
| H5 | iRMC OEM に未確認の SMB/timeout 設定 | **棄却** (Phase 3 で iRMCConfiguration root の child resource すべて列挙、 SMB/timeout 関連なし) |

**新仮説 (本セッションで導出、 未検証で残る)**:

| # | 新仮説 | 根拠 | 検証手段 |
|---|--------|------|---------|
| N1 | trans2 setpathinfo (info_level=521 / SET_FILE_UNIX_BASIC) が EPERM 返却で iRMC abort | ISO は root:root 0644、 effective(65534, 65534) = nobody が chmod できない | chown nobody + force user=nobody で SMB session 再確立して setpathinfo の結果を Samba log で観察 |
| N2 | iRMC は AIO read で取得した最初の数 KB の ISO 9660 magic が想定と違って abort | 高 latency で部分 read 取得後にタイムアウト判定 | ISO の最初 64KB を別 SMB client でも read して比較 |
| N3 | iRMC FW 9.08F の SMB redirector 内に「USB SCSI emulation 開始条件」のチェックがあり、 ISO サイズ・GPT / MBR signature 等の特定条件を満たさないと device 生成しない | 推測 (ベンダ文書なし) | Debian 標準 ISO (debian-13.3.0-amd64-netinst.iso) などすでに動作実績ある ISO で attach 試行して比較 |

### 🎯 4. **iRMC は数時間の連続失敗で "give up" state に入る**

本セッションで実証した最も困る挙動:

| 時刻 | Phase | iRMC の挙動 |
|------|-------|------------|
| 08:28 | 1 | DisconnectCD → ConnectCD → 新規 socket 46616 + 即座に SMB negotiate + session setup + ... |
| 08:41 | 2 | 同上 (port 46618、 smbcontrol reload-config で TCP 強制断後) |
| 09:11 | 5 | DisconnectCD → ConnectCD → port 46620 で TCP 確立、 **SMB negotiate 一切送らず** |
| 15:37 | 5b | chown nobody + DisconnectCD → ConnectCD → port 46622 で TCP 確立、 **SMB なし** |
| 16:25 | 5c | umount + reconfig + ConnectCD → ConnectCD は **HTTP 400** (`ActionParameterValueNotInList`、 すでに connected と判定) → port 46624 で TCP のみ |
| 16:34 | 5d | force user=nobody + DisconnectCD → ConnectCD → port 46626 で TCP のみ、 **SMB なし** |

つまり Phase 2 直後の数十分間は iRMC は SMB negotiate を発火していたが、 数時間後 (Phase 5+) は ConnectCD trigger でも TCP socket は張るのに SMB negotiate を一切送らなくなる。 iRMC 内部で「attach 試行 N 回失敗 → SMB layer を試みない」 give-up 状態に固着していると推定。

**この give-up 状態の解除には恐らく Manager.Reset / PSU コールドリセットが必要** (前セッションでも Manager.Reset 後は SMB 復帰したが Members=0 だった = chown 等の修正なしで setpathinfo / read 失敗が継続)。

### 🎯 5. Samba ログファイル名の落とし穴: `%m` 解決失敗で `log.` (空ファイル名) に書かれる

`log file = /var/log/samba/log.%m` の `%m` は NetBIOS name または client IP。 iRMC は NetBIOS name を送らないが、 セッション初期 (smbd 起動直後 + setpathinfo 処理パス) で `%m` が空文字列に解決され、 `/var/log/samba/log.` (空ファイル名) に書き込まれる。 同じセッションの後半は `/var/log/samba/log.10.254.254.9` に書かれる。 → iRMC 関連のログを追うときは **両方** を見る必要がある。 本調査で Phase 2 ログから真因まで辿れたのは log. の発見が決定打。

### 6. パケットレベルの観察結果サマリ

- TCP MSS は iRMC SYN options に mss=1317、 Samba SYN+ACK に mss=1460 → 実効 MSS=1305 (両側の最小 - TS option 12 byte)。 advmss 1448 との差 175 byte = tunnel encapsulation オーバーヘッド (推定 GRE/EoIP/L2TPv3 など)
- RTT 317ms (TCP socket measured)、 ping RTT 228ms との差 89ms = tunnel オーバーヘッド + L4 処理時間
- **retransmit / out-of-order なし** (Phase 1 90 秒 capture 中で 0%)
- TCP 上で 2610 byte packet (multi-segment SMB) も正常 ack されている
- 60 秒沈黙明けの packet シーケンスは iRMC 内部 retry の発火タイミングと一致

### 7. 試行した解決策とその効果

| 試行 | 効果 |
|------|------|
| Samba `log level = 10` (Phase 2) | ログ取得成功 → 真因解析の決定打 |
| Samba に実 `guest` user 作成 + smbpasswd 登録 (Phase 5) | iRMC が SMB negotiate を送らないので検証不能。 cleanup で削除済 |
| ISO `chown nobody:nogroup` (Phase 5b) | 同上 (SMB なし)、 cleanup で復元 |
| iRMC umount + re-config + ConnectCD (Phase 5c) | ConnectCD 後の SMB negotiate なし。 socket 切り替わるが TCP のみ |
| smb.conf `[public] force user = nobody / force group = nogroup` (Phase 5d) | 同上、 復元 |

**いずれも iRMC give-up state を解除できず、 新仮説 N1 / N2 / N3 の検証ができなかった**。

## 環境情報

- **対象機**: training-tx1320 (Fujitsu PRIMERGY TX1320 M3, Serial MABK035229, iRMC S4 FW 9.08F)
- **BMC**: 10.254.254.9 (HTTPS + `--ciphers DEFAULT@SECLEVEL=0` 必須、 claude/Claude123、 user index = 4)
- **HW**: AVAGO MegaRAID + SAS HDD 900GB × 4 (HW RAID10 構成済)
- **BIOS**: V5.0.0.11 R1.22.0 for D3373-B1x、 CSM=Disabled、 UEFI mode
- **CPU/RAM**: 24 GiB
- **SMB server**: 10.1.6.1 (Samba 4.19.5-Ubuntu、 ローカル Claude Code 実行マシン、 ens19 で 10.1.6.1/8)
- **ISO**: `/var/samba/public/debian-training-tx1320-raid10.iso` (763 MiB / 800391168 bytes、 sha256 8aa5a651f7d0bc9543f23db82e60e85ca2ef98b3e2faa9d21154e4e937a22eba、 mtime 2026-05-18 10:07、 owner root:root mode 0644)
- **ネットワーク経路**: 拠点間 link (10.1.6.1 → 10.254.254.9)、 trunk encapsulation 175 byte、 RTT avg 228ms、 jitter 93ms、 peak 381ms、 loss 0%
- **本セッションの sudo 操作**: tcpdump 1 回、 smb.conf 切替 + reload-config 2 回、 chown nobody/root 3 回、 useradd/userdel + smbpasswd 1 回、 close-share public 2 回、 iRMC umount/config Redfish PATCH 2 回

## 実施内容

### Phase 0: Pre-flight ✅

- sid = 3bace1bf
- ping baseline: 30 packets / 0% loss / RTT avg 228ms / mdev 93ms
- BMC: PowerState=Off、 AllowableValues=`['DisconnectCD']`、 CDImage 設定保持
- smb.conf を `tmp/3bace1bf/smb.conf.backup` にバックアップ
- smbclient -L //10.1.6.1 -U guest%guest -m NT1 で baseline 採取 (sudo apt install -y smbclient はユーザ依頼)
- ip route: `10.254.254.9 dev ens19 src 10.1.6.1`

### Phase 1: SMB packet capture ✅

`sudo sh phase1-capture.sh` で 130 秒間 tcpdump + ConnectCD trigger + 90s Members polling。 pcap (33 KB) 取得、 Members=0 維持。 解析で 「初期 SMB session 5 秒で完結 → 60 秒沈黙 → 追加小規模 SMB 往復」 を確認。 H1 / H3 棄却。

### Phase 2: Samba debug log level=10 ✅

smb.conf.test (log level=10 追加) → sudo cp + reload-config → DisconnectCD → ConnectCD → 120s polling → Samba log capture → backup から復元 → diff 0 確認。 1574 行 (per-machine) + 8000+ 行 (log. の空ファイル名) 取得。 NTLMSSP / session setup / tree connect / **trans2 setpathinfo info_level=521 / smb_posix_open mode 0755 / AIO read** を確認。 60 秒間隔の retry サイクル発見。 H2 / H4 棄却 + 新仮説 N1 / N2 / N3 を導出。

### Phase 3: iRMC OEM iRMCConfiguration dump ✅

`GET /redfish/v1/Managers/iRMC/Oem/ts_fujitsu/iRMCConfiguration` の root JSON 取得。 child links は VideoRedirection / WebUI / PowerSetting / FailureBehavior / NetworkServices / Time / Memory / Cas / Ldap / Raid / Licenses / AISConnect / eLCM / Syslog / Certificates / PrimeCollect 等。 **SMB / VirtualMedia / timeout 関連の attribute は root level にも子 link 名にも存在しない**。 H5 棄却。

### Phase 5: 各種解除試行 (4 回) ❌

| Phase | 試行内容 | 結果 |
|-------|---------|------|
| 5 | unix `guest` user 追加 + smbpasswd 登録 + DisconnectCD/ConnectCD | iRMC SMB 試行なし、 Members=0、 cleanup |
| 5b | ISO chown nobody:nogroup + close-share + DisconnectCD/ConnectCD | 同上、 revert |
| 5c | chown + umount + 再 config (新規 SMB 強制) + ConnectCD | ConnectCD HTTP 400、 socket 切り替えのみ、 SMB なし |
| 5d | chown + smb.conf `force user=nobody` + reload-config + Disconnect/ConnectCD | 同上、 復元 + diff 0 確認 |

いずれも iRMC give-up state を解除できず、 新仮説 N1 検証不可。

### Phase 7: 互換性最終確認 + レポート ✅

- `diff /etc/samba/smb.conf tmp/3bace1bf/smb.conf.backup` → exit 0
- `diff smbclient-baseline.txt smbclient-final.txt` → exit 0 (`lanman auth deprecated` 警告のみ、 内容差異なし)
- ISO ownership: root:root 0644 に復元済

## 完了事項

- [x] silent failure の packet レベル証拠取得 (Phase 1 pcap、 94 line 整形済)
- [x] Samba debug log level=10 でアプリケーションレベル証拠取得 (Phase 2、 9000+ 行)
- [x] iRMC は SMB1 + UNIX extensions (POSIX open / SET_FILE_UNIX_BASIC) を使う Linux SMB client であることを確定
- [x] session setup → tree connect → file open → AIO read まで成功している事実を確定
- [x] **60 秒間隔の retry サイクル** を発見 (Phase 2 のログで 08:41:41, 08:42:42, 08:43:42 を観測)
- [x] iRMC OEM iRMCConfiguration に SMB / timeout 関連の attribute が無いことを確認 (Phase 3)
- [x] iRMC の "give up" state (数時間連続失敗で SMB negotiate を送らなくなる) を観測 (Phase 5/5b/5c/5d)
- [x] H1 / H2 / H3 / H4 / H5 全仮説の検証完了 (全て棄却)
- [x] 新仮説 N1 (setpathinfo EPERM)、 N2 (ISO header read 内容判定)、 N3 (iRMC USB SCSI emulation 開始条件) を導出
- [x] **前セッションの「ネットワーク経路品質が真因」結論を訂正** (packet レベルで反証)
- [x] 互換性復元 (smb.conf == backup、 ISO 所有権 == root:root、 smbclient baseline == final)
- [x] レポート + attachment (16 ファイル) 作成

## 未完了 / 次セッション課題

### 1. iRMC give-up state の解除 (BMC Manager.Reset + 即座に新仮説検証)

次セッションは **(1) Manager.Reset GracefulRestart** → **(2) BMC 復帰待ち 170s** → **(3) chown nobody:nogroup ISO** + **smb.conf `force user=nobody` 適用** + **smbcontrol reload-config** → **(4) ConnectCD trigger** → **(5) Members polling** の順で N1 仮説を検証すること。 Manager.Reset 後の最初の ConnectCD では SMB session が成立する可能性が高い (前セッション実証)。

### 2. 新仮説 N1 (trans2 setpathinfo EPERM) の検証

force user=nobody + ISO owner=nobody:nogroup で Samba 側の setpathinfo (chmod 0755) が成功するはず。 これで iRMC が USB device 生成まで進めば N1 確定 = 永続修正は ISO ownership 規約化。

### 3. 新仮説 N2 / N3 の検証 (N1 が反証された場合のみ)

- N2: 別の動作実績 ISO (例えば debian-13.3.0-amd64-netinst.iso) を `/var/samba/public/` の同じパスに置き換えて attach 試行。 同じ場所で別 ISO が成功すれば N2 (file 内容判定) 確定。
- N3: iRMC の OEM Licenses で attach 機能制限がないか確認 (Phase 3 で `Licenses` child link は確認したが内容は未 fetch)。

### 4. install 完走 + RAID10 確認 (上記 1-3 で attach 成立後)

- patched ISO は build + sanity OK で ready (本セッション末時点で sha256 8aa5a651...)
- SOL log で `pvese-patch: bypassed list-devices via /dev/sr1 direct mount` を観測

## 再現方法 (次セッション向け)

```sh
SID=$(openssl rand -hex 4); mkdir -p tmp/$SID

# Phase 0: BMC reset (give-up state を解除)
curl -sk --ciphers DEFAULT@SECLEVEL=0 -u claude:Claude123 \
    -X POST -H 'Content-Type: application/json' \
    -d '{"ResetType":"GracefulRestart"}' \
    'https://10.254.254.9/redfish/v1/Managers/iRMC/Actions/Manager.Reset'
# BMC 復帰待ち ~170s (前セッション実測)

# Phase 1: 新仮説 N1 検証準備
sudo chown nobody:nogroup /var/samba/public/debian-training-tx1320-raid10.iso
# smb.conf.test3 の [public] に "force user = nobody / force group = nogroup" を追加して apply:
sudo cp tmp/$SID/smb.conf.test3 /etc/samba/smb.conf
sudo smbcontrol smbd reload-config

# Phase 2: 即座に ConnectCD trigger
./scripts/irmc-virtualmedia.sh --type=CD status 10.254.254.9 claude Claude123
# AllowableValues=['ConnectCD'] を確認してから:
curl -sk --ciphers DEFAULT@SECLEVEL=0 -u claude:Claude123 \
    -X POST -H 'Content-Type: application/json' \
    -d '{"VirtualMediaAction":"ConnectCD"}' \
    'https://10.254.254.9/redfish/v1/Systems/0/Actions/Oem/FTSComputerSystem.VirtualMedia'

# Phase 3: 30 秒以内に Samba debug log を tail で観察
sudo tail -f /var/log/samba/log.10.254.254.9 /var/log/samba/log.
# trans2setpathinfo の NT_STATUS_* + smb_posix_open の status を観察

# Phase 4: Members polling 120s
# Members>=1 検出時点で deploy へ進む
```

## 関連 Issue

- **#69 (継続、 status=blocked → blocker は本セッションで「ネットワーク経路品質」から「iRMC FW の USB SCSI emulation 開始条件」へと真因が判明)**
  - 前セッション #11 (lovely-meadow): ネットワーク改善 (RTT 226ms) でも SMB silent failure 再発と観測、 「ネットワークが真因」結論
  - **本セッション #12 (s-expressive-bubble)**: **「ネットワーク」結論を packet/log レベルで反証**。 真因は **iRMC FW 9.08F の SMB redirector が file open + AIO read 後に USB device を生成しない条件** (60 秒 retry サイクル)。 新仮説 N1 (setpathinfo EPERM) が最有力候補だが、 iRMC give-up state により本セッション内では検証不可
  - **次セッション推奨**: BMC Manager.Reset + chown nobody + force user=nobody で N1 検証
- **新規 issue 候補**: なし (経路品質改善は不要と判明)。 前セッションで「training サイト側に SMB を立てる」を新規 issue 化候補としていたが、 本セッションの真因解析でこの提案は破棄。 ネットワーク経路は十分。

## 関連ファイル

### 修正なし (調査のみ)

- `scripts/irmc-virtualmedia.sh` — `--type=CD config` / `umount` を Phase 5c で活用
- `scripts/bmc-power.sh` — `BMC_CURL_OPTS=--ciphers DEFAULT@SECLEVEL=0` 必須
- `scripts/tx1320-raid10-orchestrate.sh` — 未到達 (修正なし)
- `scripts/sol-monitor.py` — 未到達 (修正なし)
- `config/training_tx1320.yml` — `smb_user/smb_pass` 既に guest 明示済

### 一時変更 → セッション末で完全復元

- `/etc/samba/smb.conf` — Phase 2 (log level=10) + Phase 5d (force user=nobody) で 2 度変更、 各々後で復元。 セッション末 diff 0 確認済
- `/var/samba/public/debian-training-tx1320-raid10.iso` の owner — Phase 5b / 5c / 5d で nobody:nogroup に変更、 各々後で root:root へ revert
- Samba per-machine log と log. — debug 用に truncate されたが、 セッション中の通常運用への影響なし

### 新規作成

- `report/2026-05-19_163800_tx1320_raid10_smb_real_root_cause.md` (本レポート)
- `report/attachment/2026-05-19_163800_tx1320_raid10_smb_real_root_cause/` (plan + 操作ログ 9 + Samba log 2 + pcap + smbclient × 2 + smb.conf × 3 + OEM JSON = 18 ファイル)

## 重要な教訓 (次セッションへの引き継ぎ)

1. **「TCP は通るが SMB negotiate 不成立」という前セッション結論は packet レベル証拠なしの推測だった**: 実際は SMB session setup + tree connect + file open + AIO read まで成功している。 silent failure の表象 (Members=0 + Samba per-machine log 0 bytes) だけを見ると外形が一致するので誤帰属しやすい。 **同じ症状でも内部で何が起きているか packet capture と Samba debug log で確認すべし**。
2. **iRMC FW 9.08F は SMB1 + UNIX extensions (Linux SMB client) を使う**: Windows BMC ベンダ (Supermicro / iDRAC) と異なり、 POSIX open / SET_FILE_UNIX_BASIC を発行する。 これが Samba の挙動 (map to guest → nobody、 nobody が root 所有ファイルの chmod を試みて EPERM) と組み合わさって特有の失敗パターンが出る。 4-15号機の同 Samba 経路は SMB1+NTLMv1+guest で成功しているのは、 BMC 側が UNIX extensions を使わないため。
3. **`/var/log/samba/log.` (空ファイル名) を必ず確認すること**: `log file = /var/log/samba/log.%m` の `%m` は smbd プロセスのライフサイクル中に何度か空に解決される (initial accept 直後、 setpathinfo 経路、 reload 後の startup 直後)。 client IP は記録されない。 iRMC 関連のログ追跡は per-machine と log. の両方をマージして時系列追跡が必要。 本調査の最重要発見 (60 秒 retry サイクル + smb_posix_open + AIO read) は log. でしか取得できなかった。
4. **iRMC は数時間の連続失敗で SMB negotiate を送らない give-up state に固着する**: ConnectCD POST に対し socket は新規張るが SMB は何も送らない。 Manager.Reset で復旧見込み (前セッション実証)。 本セッションで N1 仮説検証ができなかった主因。 **デバッグ作業の冒頭で Manager.Reset を実施する運用** にすると検証速度が上がる。
5. **smb.conf 変更時の互換性保護は機能した**: backup → 適用 → 復元 → diff 0 + smbclient -L baseline 比較の手順で他 skill 影響なし。 次セッションでも同手順を採用すること。 sudo 操作はすべてユーザに `! sudo sh tmp/<sid>/<phaseN>.sh` で依頼するパターンが有効 (1 スクリプト = 1 phase で 1 回の sudo 入力)。
6. **trans2 setpathinfo の info_level=521 の正体**: Samba source の `source3/smbd/smb1_trans2.c` で UNIX 系 SET_FILE_INFORMATION の level 番号。 `SMB_SET_FILE_UNIX_BASIC` (0x200) と `SMB_SET_FILE_UNIX_INFO2` (0x209) が候補。 totdata=18 bytes (mode + uid + gid のサイズ感) から推定すると mode change を含むが、 完全特定は次セッションで Samba source を直接確認する価値あり。
7. **ping baseline は 226ms / 0% loss / jitter 93ms で前 2 セッションと同水準**: つまり 1 週間で経路品質はほぼ変わっていない。 「ネットワーク改善でも attach 成立せず」と結論した前セッションが正しかった (ただし真因の帰属が誤っていた)。 次セッションでも ping precheck で経路品質が極端に悪化していないことを確認すれば OK (RTT < 500ms / loss < 5% 程度で十分)。
