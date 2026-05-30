# TX1320 iRMC SMB silent failure 深掘り調査計画 (Issue #69)

## Context

`report/2026-05-19_023431_tx1320_raid10_smb_blocked_persist.md` (lovely-meadow) + 親 `2026-05-18_101017_..._cdrom_patch_verify.md` (c-frolicking-starlight) は「拠点間 WAN latency が iRMC SMB redirector の内部 timeout を超えるため silent failure」と結論。 ただしこれは外形観測 (Members=0 + Samba log 0 bytes + TCP ESTABLISHED + ping RTT) からの推定で、 packet レベルの実証なし。 Samba debug は default log level、 iRMC OEM の SMB 関連設定値・Path MTU・MSS clamp の効果も未確認。

本セッションは **#69 silent failure の真因を packet と各レイヤのログで精密に診断** し、 観測の上で blocker 解消の試行も実施する。 deploy も attach 成立すれば本セッション内で行う。

**互換性制約**: Samba 10.1.6.1 は `os-setup` 等の他 skill (4-15号機 Supermicro/iDRAC 系) で SMB1 NT1 + NTLMv1 + guest を前提に使われている。 試験で smb.conf を改変した場合、 **セッション末に必ず元設定に復元 + smbd reload + ローカル smbclient で listing 成功を確認** する。

**目的の優先順**:
1. silent failure の発生箇所を packet レベルで確定 (どの SMB stage で止まるか) ← 最重要
2. blocker 解消候補 (MSS clamp / SMB2 enable / iRMC OEM 設定) を試行し、 attach 成立条件を見つける
3. 成立すれば本セッション内で deploy (#69 close を目指す)

不成立でも、 真因確定 + 経路改善案の新規 Issue 化で Issue #69 update。

## 仮説

| # | 仮説 | 検証手段 | 期待される観測 |
|---|------|---------|--------------|
| H1 | TCP 上で SMB1 negotiate request が iRMC から届かない、 または response が iRMC に届かない | tcpdump pcap | NEGOTIATE_PROTOCOL packet の有無 + retransmit |
| H2 | SMB1 negotiate は完了するが session setup で iRMC 内部 timeout | tcpdump pcap + Samba debug log | session setup request / response の有無 |
| H3 | Path MTU mismatch (tunnel MSS 1305 vs advmss 1448) で 1305+ byte の SMB1 packet が drop | tracepath + ping -M do + MSS clamp 試行 | 大きい packet drop の証拠、 MSS clamp 後 attach 成立 |
| H4 | iRMC が SMB2/3 を試して Samba `server max protocol = NT1` で reject される | Samba `server max protocol = SMB2_10` で reload 後 attach 成立 | attach 成立 (反証なら H1/H2/H3) |
| H5 | iRMC OEM 側に未確認の SMB/timeout 設定がある | `GET /redfish/v1/Managers/iRMC/Oem/ts_fujitsu/iRMCConfiguration/` 全 dump | timeout/SMB key 発見 |

## 実施フェーズ

### Phase 0: Pre-flight (~5 min)

1. **セッション tmp 作成**: Glob `*.jsonl` from `/home/ubuntu/.claude/transcripts` → 先頭 8 文字 → `mkdir -p tmp/<sid>`
2. **ping precheck**: `ping -c 30 -i 1 -W 2 10.254.254.9` で経路品質記録 (中止判定はしない、 観測ベースライン取得のみ)
3. **iRMC reachability**: `BMC_CURL_OPTS=... ./scripts/bmc-power.sh status 10.254.254.9 claude Claude123` + `./scripts/irmc-virtualmedia.sh --type=CD status 10.254.254.9 claude Claude123`
4. **smb.conf バックアップ**: Read `/etc/samba/smb.conf` → Write `tmp/<sid>/smb.conf.backup`。 互換性復元の基準ファイル
5. **Samba 復元検証手順を確認**: セッション末で実行する `smbclient -L //10.1.6.1 -U guest%guest -m NT1` (CLAUDE.md 的に sudo 不要、 ローカルでそのまま使える) を pre-flight でも 1 回実行して **基準動作** を採取

### Phase 1: パケットレベル証拠の確保 ★ 最重要 (~15 min)

1. **capture 開始 (ユーザ依頼)**: `! sudo tcpdump -i ens19 -nn -s 0 -w tmp/<sid>/smb-trigger.pcap 'host 10.254.254.9 and (tcp port 445 or tcp port 139 or icmp)'` を background で起動依頼。 私は pcap ファイル所有権が ubuntu になるよう `sudo chown ubuntu tmp/<sid>/smb-trigger.pcap` 等の後始末も合わせて依頼
2. **BMC clean state 担保**: 必要なら DisconnectCD → 10s 待機 → AllowableValues=`["ConnectCD"]` 確認
3. **trigger**: `./scripts/irmc-virtualmedia.sh --type=CD config ... guest guest` (PATCH 成功) + ConnectCD POST
4. **観察期間**: 90s polling、 5s 間隔 (途中で Members 値、 TCP `ss -nti '( sport = :445 )'` も `tmp/<sid>/`に記録)
5. **capture 停止 (ユーザ依頼)**: `! sudo pkill -INT tcpdump` + `sudo chown ubuntu tmp/<sid>/smb-trigger.pcap`
6. **解析**: `tcpdump -r tmp/<sid>/smb-trigger.pcap -nn -X 'tcp port 445'` を Bash で読み (sudo 不要)。 観測項目:
   - SYN/SYN-ACK/ACK の 3way 完了タイミング
   - 最初の SMB1 Negotiate Request の方向と byte 数
   - retransmit / out-of-order
   - 最後に届いた payload と方向
   - RST or FIN がどの段階で出るか

### Phase 2: Samba debug log (~10 min)

1. **smb.conf 改変版作成**: `tmp/<sid>/smb.conf.test` を Write。 元 [global] にだけ `log level = 10` を追加 (他は完全に維持)
2. **ユーザ依頼で適用**: `! sudo cp tmp/<sid>/smb.conf.test /etc/samba/smb.conf && sudo smbcontrol smbd reload-config`
3. **trigger + 60s 待機**: Phase 1 と同じ ConnectCD サイクル (capture は不要、 ログだけ)
4. **log 確認**: Read `/var/log/samba/log.10.254.254.9` と Read `/var/log/samba/log.smbd` (どちらも 0 bytes → 1 KB++ になるはず)
5. **復元**: `! sudo cp tmp/<sid>/smb.conf.backup /etc/samba/smb.conf && sudo smbcontrol smbd reload-config`
6. **復元検証**: `smbclient -L //10.1.6.1 -U guest%guest -m NT1` で Phase 0 と同じ結果が出ることを確認

### Phase 3: iRMC OEM 設定 dump (~5 min)

1. `curl -sk --ciphers DEFAULT@SECLEVEL=0 -u claude:Claude123 https://10.254.254.9/redfish/v1/Managers/iRMC/Oem/ts_fujitsu/iRMCConfiguration/` の full tree (子リンクを 1 階層 traverse) を `tmp/<sid>/oem-iRMCConfiguration.json` に保存
2. `grep -iE 'timeout|smb|negotiate|retry|cifs|samba'` で関連 key 列挙
3. 未確認の timeout 系 attribute (例 `SMBNegotiateTimeoutSeconds` 等) があれば値を記録

### Phase 4: Path MTU / MSS clamp 試行 (~15 min)

1. `tracepath 10.254.254.9` → 各 hop の MTU
2. `ping -M do -s 1472` (= 1500 - 28 IP/ICMP) → fragment しない最大 payload。 50 byte 単位で減らして PMTU 確定
3. 確定 PMTU から TCP MSS 推定値計算 (PMTU - 40)
4. **MSS clamp 試行 (ユーザ依頼)**: `! sudo iptables -t mangle -A POSTROUTING -p tcp -d 10.254.254.9 --tcp-flags SYN,RST SYN -j TCPMSS --set-mss <値>` で MSS を 200 byte 程度下げて適用
5. **trigger**: DisconnectCD → ConnectCD → 90s polling
6. attach 成立 (Members>=1) なら H3 確定 → Phase 6 へ
7. **rule 復元 (ユーザ依頼)**: `! sudo iptables -t mangle -D POSTROUTING ... <同じ rule>` で削除 + `sudo iptables -t mangle -L POSTROUTING -nv` で確認

### Phase 5: Samba `server max protocol` 上昇試行 (~10 min)

1. `tmp/<sid>/smb.conf.test2` を Write。 [global] に `server max protocol = SMB2_10` を追加 (NT1 を min として残す → SMB1/SMB2 両対応)
2. **ユーザ依頼で適用**: `! sudo cp tmp/<sid>/smb.conf.test2 /etc/samba/smb.conf && sudo smbcontrol smbd reload-config`
3. **trigger**: DisconnectCD → ConnectCD → 90s polling
4. attach 成立なら H4 確定 → Phase 6 へ
5. **復元**: `! sudo cp tmp/<sid>/smb.conf.backup /etc/samba/smb.conf && sudo smbcontrol smbd reload-config`
6. **復元検証**: `smbclient -L //10.1.6.1 -U guest%guest -m NT1` で Phase 0 と同じ結果確認

### Phase 6: deploy (条件付き、 ~25 min)

Phase 4 or Phase 5 で attach 成立した場合のみ:

1. SMB が attach した状態のまま deploy: `./oplog.sh ./scripts/tx1320-raid10-orchestrate.sh deploy config/training_tx1320.yml`
2. SOL monitor: `.venv/bin/python ./scripts/sol-monitor.py --bmc-ip 10.254.254.9 --bmc-user claude --bmc-pass Claude123 --log-file tmp/<sid>/sol.log --timeout 1800`
3. SOL 上で `pvese-patch: bypassed list-devices via /dev/sr1 direct mount` を grep
4. install 完走後、 DHCP IP 取得 → SSH で `lsblk` + `storcli64 /c0/vall show` → RAID10 healthy 確認

deploy 未到達なら Phase 7 へスキップ。

### Phase 7: 結論 + Issue 整理 + レポート (~15 min)

1. **真因の確定**:
   - H1/H2 のいずれかなら → pcap でどの SMB stage で停まるか引用
   - H3 (MSS) なら → 解決策確定
   - H4 (SMB2) なら → 解決策確定
   - 全て反証なら → ネットワーク経路品質 + iRMC FW bug の合算で経路改善が必要と確定
2. **Issue 整理**:
   - 経路品質改善 (training サイト側 SMB / 拠点間 link 調査) を新規 Issue 化 (※ ユーザ指示)
   - Issue #69 の最新状態を update + 必要なら owner release
3. **レポート**: `report/2026-05-19_<HHMMSS>_tx1320_raid10_smb_diagnosis.md` を作成、 attachment に pcap・Samba debug log・OEM dump・tracepath 結果を配置
4. **互換性最終確認**: smb.conf が backup と diff 0 であること、 smbd ステータス active、 ローカル smbclient OK

## 安全弁・中止条件

- **smb.conf 復元失敗**: Phase 2/5 で復元後の smbclient listing が前と差異 → 直ちにユーザに通知、 ユーザ手動で /etc/samba/smb.conf を確認依頼、 他作業中止
- **iptables rule 削除失敗**: Phase 4 で削除後の `iptables -t mangle -L POSTROUTING -nv` に rule が残る → ユーザに削除依頼、 他作業中止
- **iRMC が応答不能**: 5 連続で HTTP 5xx → Phase 7 へ skip、 deploy なし
- **deploy 中の失敗**: SOL ログで installer error → 通常の install 失敗扱い、 Phase 7 でレポートに記載

## 触る・触らないファイル

### 一時的に変更 (セッション末に復元、 直接編集はユーザ sudo)
- `/etc/samba/smb.conf` (Phase 2, 5) — backup は `tmp/<sid>/smb.conf.backup`
- iptables mangle POSTROUTING ルール (Phase 4)

### 読むだけ
- `/var/log/samba/log.10.254.254.9`, `/var/log/samba/log.smbd`
- 既存スクリプト: `scripts/irmc-virtualmedia.sh`, `scripts/bmc-power.sh`, `scripts/tx1320-raid10-orchestrate.sh`, `scripts/sol-monitor.py`
- 既存 config: `config/training_tx1320.yml`

### 新規作成 (`tmp/<sid>/`)
- `smb.conf.backup`, `smb.conf.test`, `smb.conf.test2`
- `smb-trigger.pcap`
- `oem-iRMCConfiguration.json`
- `tracepath.log`, `pmtu.log`
- polling/trigger 用シェルスクリプト群

### 新規作成 (`report/`)
- `report/2026-05-19_<HHMMSS>_tx1320_raid10_smb_diagnosis.md`
- `report/attachment/2026-05-19_<HHMMSS>_tx1320_raid10_smb_diagnosis/` (上記 tmp 成果物のコピー、 認証情報は redact)

## 検証 (end-to-end)

1. silent failure の停止 stage を packet レベルで特定できた (Phase 1 で 1 つ pcap stage 名引用可能)
2. smb.conf が backup と完全一致した状態でセッション終了 (Phase 0/2/5/7 で計 4 回確認)
3. iptables mangle POSTROUTING に試験 rule が残っていない (Phase 4 末、 Phase 7 末で確認)
4. ローカル smbclient で listing が Phase 0 と同じ結果になる (Phase 2 末、 Phase 5 末、 Phase 7 末)
5. (条件付き) Phase 4 or 5 で attach 成立 → Phase 6 で install 完走 → `lsblk` で /dev/sda ~1.8TB + storcli VD0 State=Optl 確認
6. レポート + 新規 Issue が作成され、 Issue #69 が update された

## 主な参考ファイル

- `scripts/irmc-virtualmedia.sh:131-142` — PATCH payload format (CDImage ラッパー、 If-Match quotes なし)
- `scripts/bmc-power.sh` — `BMC_CURL_OPTS=--ciphers DEFAULT@SECLEVEL=0` 必須
- `config/training_tx1320.yml:95-106` — SMB host/share/user/pass 定義
- `/home/ubuntu/.claude/projects/-home-ubuntu-projects-pvese/memory/training_tx1320_network_latency.md` — 既存結論メモ
- `/home/ubuntu/.claude/projects/-home-ubuntu-projects-pvese/memory/training_tx1320.md:105-130` — SMB attach の既知の落とし穴 (guest 明示・ConnectCD)
- `report/2026-05-19_023431_tx1320_raid10_smb_blocked_persist.md` — 前セッション (本セッションが調査対象)
- `report/2026-05-18_101017_tx1320_raid10_cdrom_patch_verify.md` — root cause 推定の根拠
