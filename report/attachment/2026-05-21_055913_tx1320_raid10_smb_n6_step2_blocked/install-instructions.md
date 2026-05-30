# patched smbd を 10.1.6.1 にインストールする手順

本ディレクトリ内の `samba-patched-full.tar.gz` には Samba 4.19.5 (Ubuntu 24.04 配置で再 build) + 1 文字 typo patch (`SMB1SERVER` → `WITH_SMB1SERVER`) が含まれている。

## 内容物

| ファイル | 説明 |
|---------|------|
| `samba-patched-full.tar.gz` | 全 patched binary + shared libs (build dir from 10.1.6.6) — 約 2 MB |
| `smbd-patched` | patched smbd 単独 (RUNPATH=`/home/ubuntu/samba-build/samba-4.19.5/bin/shared` 依存) — 約 98 KB |

両者とも build host = 10.1.6.6 (Ubuntu 24.04.3 LTS, samba 4.19.5+dfsg-4ubuntu9.4) で 10.1.6.1 と同じソース・同じ ABI。

## SHA256

```
0ff2a3438c250770fdbf29332513649bda932ed2721ddd34087d936a46e1f6c4  smbd-patched
d6de6cd4b48aebf3379baadfb16288007e376eb092da0df0aba02a58b81ff2ca  samba-patched-full.tar.gz
```

## 検証 (10.1.6.6 上)

```sh
ssh ubuntu@10.1.6.6 \
    ~/samba-build/samba-4.19.5/bin/default/source3/smbd/smbd --version
# Version 4.19.5
```

## 10.1.6.1 へのインストール手順 (要 sudo パスワード)

### 方法 A — system smbd を差し替え (推奨)

```sh
# 1. バックアップ
sudo cp /usr/sbin/smbd /usr/sbin/smbd.orig.$(date +%s)

# 2. samba 停止
sudo systemctl stop smbd nmbd

# 3. patched smbd を install
sudo cp tmp/efc9ff28/smbd-patched /usr/sbin/smbd

# 4. smbd の依存 lib を解決する
#    patched binary は build host の RUNPATH を持つので
#    `/home/ubuntu/samba-build/samba-4.19.5/bin/shared` 配下を期待する。
#    最も簡単なのは tarball を /opt 等に展開して LD_LIBRARY_PATH を通す
#    か、 ldconfig で system 配下に追加する。
#    ただし system にも libsecrets3-samba4.so.0 (versioned) は存在するため、
#    `chrpath` でビルド済 binary の RUNPATH を空にしてからシステム lib を
#    使わせるのが本道。

# 5. systemd service の Environment= に LD_LIBRARY_PATH を追加するか、
#    /opt/samba-patched/lib を ldconfig に登録
sudo tar xzf tmp/efc9ff28/samba-patched-full.tar.gz -C /opt/samba-patched/
echo '/opt/samba-patched/shared
/opt/samba-patched/shared/private' | sudo tee /etc/ld.so.conf.d/samba-patched.conf
sudo ldconfig

# 6. 起動 + 確認
sudo systemctl start smbd nmbd
sudo systemctl status smbd
smbclient -L //10.1.6.1/ -U guest%guest
```

### 方法 B — patched samba をフル install (より確実、 既存 deb を上書き)

10.1.6.6 上で `make install --keepconfig` または `dpkg-buildpackage` で .deb を作成して 10.1.6.1 に `dpkg -i` する。 ABI 整合性が完全に保証されるが時間がかかる。

```sh
# 10.1.6.6 上で
cd ~/samba-build/samba-4.19.5
sudo make install -j2

# まとめて /usr 配下にコピーされるので、 dpkg と共存しないよう
# 注意 (--keepconfig オプションが必要)。 推奨は方法 A の差し替え。
```

### 方法 C — RUNPATH を上書きしてシステム lib に switch

```sh
# 10.1.6.1 上で
sudo apt install -y chrpath
sudo cp tmp/efc9ff28/smbd-patched /usr/sbin/smbd.patched
sudo chrpath -r '/usr/lib/x86_64-linux-gnu/samba' /usr/sbin/smbd.patched
sudo /usr/sbin/smbd.patched --version
# Version 4.19.5
# (versioned libs を見つけられれば成功)
```

ただし NEEDED が unversioned (例: `libsecrets3-samba4.so`) であれば、 versioned `.so.0` とは合致しない。 system に unversioned alias を作る必要あり:

```sh
cd /usr/lib/x86_64-linux-gnu/samba/
for f in lib*.so.*; do
    base=$(echo "$f" | sed 's/\.so\..*/\.so/')
    if [ ! -e "$base" ]; then
        sudo ln -s "$f" "$base"
    fi
done
```

## 検証手順 (patched smbd 稼働後)

```sh
cd /home/ubuntu/projects/pvese

# 1. iRMC config を 10.1.6.1 のまま (本セッション完了時の状態)、 host を power-on
export BMC_SCHEME=https BMC_CURL_OPTS="--ciphers DEFAULT@SECLEVEL=0" BMC_PATCH_REQUIRES_ETAG=1
./scripts/bmc-power.sh boot-override 10.254.254.9 claude Claude123 Cd UEFI
./scripts/bmc-power.sh forceoff 10.254.254.9 claude Claude123 || true
sleep 8
./scripts/bmc-power.sh on 10.254.254.9 claude Claude123

# 2. Members polling (前セッションと同じ手順)
for i in $(seq 1 24); do
    sleep 5
    curl -sk --ciphers DEFAULT@SECLEVEL=0 -u claude:Claude123 \
        https://10.254.254.9/redfish/v1/Managers/iRMC/VirtualMedia \
        | grep -oE '"Members@odata.count"[^,]*' | head -1
done
# 期待: Members@odata.count >= 1 になれば patched smbd で attach 成功

# 3. local Samba log 確認 (patched では INVALID_LEVEL ではなく成功する想定)
sudo grep -E 'level = 513|SMB_QUERY_POSIX_FS_INFO' /var/log/samba/log.* | head -10
# 期待: level = 513 は出るが INVALID_LEVEL が消える

# 4. install 実走 (attach 成立後)
./scripts/tx1320-raid10-orchestrate.sh deploy config/training_tx1320.yml
./scripts/tx1320-raid10-orchestrate.sh monitor config/training_tx1320.yml
```

## rollback

```sh
sudo systemctl stop smbd nmbd
sudo cp /usr/sbin/smbd.orig.<timestamp> /usr/sbin/smbd
# あるいは
sudo apt install --reinstall samba
sudo systemctl start smbd nmbd
```
