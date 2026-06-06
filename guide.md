# VPS Backup Guide

このドキュメントは **人間とLLMの両方が読む** ことを想定しています。
人間が実際の操作を行い、LLMがステップバイステップでガイドします。
LLMは各ステップを1つずつ提示し、ユーザーの実行結果を確認してから次に進んでください。

## システム概要

VPS（Ubuntu 24.04）上の `/home/tako4ball/` 配下の全ファイルを、
**rclone + pCloud** で暗号化バックアップしています。

### 日本語が苦手なLLMのための仕組み説明（English summary）

- Daily backup at 3:00 JST: `rclone copy` to pCloud (incremental, deletions NOT propagated)
- Weekly snapshot at Sunday 4:00 JST: versioned backup with 4-generation retention
- Encryption: rclone crypt (AES-256, filenames + contents encrypted, directory names encrypted)
- Monitoring: healthchecks.io dead man's switch (UUID: `943c3111-2789-44dd-8d1a-3c27e8e1033b`)
- All configs version-controlled at: https://github.com/tako3ball/vps-backup
- Username: `tako4ball` (all paths hardcoded to this user)
- VPS config path: `~/.local/share/vps-backup/`
- rclone remote names: `pcloud` (raw connection, EU region `eapi.pcloud.com`), `pcloud_crypt` (encrypted layer, maps to `pcloud:vps-backup`)
- Backup destination: `pcloud_crypt:vps-backup/latest/`
- Weekly snapshots: `pcloud_crypt:vps-backup/weekly/YYYY-MM-DD/`

### バックアップのしくみ（人間向け）

| 項目 | 内容 |
|------|------|
| 対象 | `/home/tako4ball/` 配下の全ファイル（約13GB） |
| 日次 | 毎日 3:00 JST。変更があったファイルだけpCloudにコピー（`rclone copy`）。削除したファイルはpCloudに残る |
| 週次 | 毎週日曜 4:00 JST。変更前のファイルを日付フォルダに退避（4世代保持、古いものは自動削除） |
| 暗号化 | rclone crypt（AES-256）。ファイル名・フォルダ名・ファイル内容すべて暗号化。pCloud側からは中身が見えない |
| 監視 | healthchecks.io（無料）。「指定時間内にバックアップが実行されたか」を外部から監視。実行されなければ通知 |

### 使っている技術（初心者向け用語解説）

| 用語 | 意味 |
|------|------|
| **pCloud** | スイス拠点のクラウドストレージ。買い切りプランあり。日本から登録するとEUリージョンになる |
| **rclone** | ファイルをクラウドにコピーするCLIツール。`rsync` のクラウド版 |
| **rclone crypt** | rclone の暗号化機能。アップロード前に暗号化、ダウンロード時に自動復号 |
| **systemd** | Ubuntu 標準のサービス管理。タイマー機能で指定時刻に自動実行 |
| **healthchecks.io** | 外部監視サービス（無料）。バックアップが指定時間内に実行されないと通知 |
| **salt** | 暗号化を強化する2つ目のパスワード。password と salt の両方がないと復号できない |

---

## ファイル構成

```
~/.local/share/vps-backup/          # ソースファイル（Git管理 + バックアップ対象）
  guide.md                           # このガイド
  backup.log                         # 実行ログ（Git管理対象外）
  vps-backup.sh                      # 日次スクリプト
  vps-backup-weekly.sh               # 週次スクリプト
  vps-backup.service                 # 日次systemdサービス定義
  vps-backup.timer                   # 日次systemdタイマー定義
  vps-backup-weekly.service          # 週次systemdサービス定義
  vps-backup-weekly.timer            # 週次systemdタイマー定義

/usr/local/bin/                      # スクリプト実行パス
  vps-backup.sh
  vps-backup-weekly.sh

/etc/systemd/system/                 # systemd設定パス
  vps-backup.service
  vps-backup.timer
  vps-backup-weekly.service
  vps-backup-weekly.timer

~/.config/rclone/rclone.conf         # rclone設定（暗号化パスワードを含む）
```

---

## 通常運用

> **操作ユーザー: tako4ball** / **ディレクトリ: 任意**

普段はバックアップは自動実行されます。healthchecks.io から通知が来た時だけ以下を確認してください。

### 状態確認（LLMはユーザーに以下のコマンドを案内してください）

```bash
# タイマー状態（次回実行予定を確認）
systemctl list-timers vps-backup*

# 最新ログ
tail -20 ~/.local/share/vps-backup/backup.log

# pCloud上のバックアップサイズ
rclone size pcloud_crypt:vps-backup/latest

# 週次スナップショット一覧
rclone lsf --dirs-only pcloud_crypt:vps-backup/weekly
```

### 手動バックアップ

```bash
# 日次バックアップを今すぐ実行
sudo systemctl start vps-backup.service

# 週次スナップショットを今すぐ実行
sudo systemctl start vps-backup-weekly.service

# 実行中は別のSSH接続でログを監視
tail -f ~/.local/share/vps-backup/backup.log
```

### 一時停止・再開

```bash
# 停止
sudo systemctl stop vps-backup.timer vps-backup-weekly.timer
sudo systemctl disable vps-backup.timer vps-backup-weekly.timer

# 再開
sudo systemctl enable --now vps-backup.timer vps-backup-weekly.timer
```

---

## スナップショットからの復元

週次スナップショット（`pcloud_crypt:vps-backup/weekly/YYYY-MM-DD/`）から特定ファイルを取り出す:

```bash
# スナップショット一覧
rclone lsf --dirs-only pcloud_crypt:vps-backup/weekly

# 特定日時のファイルを復元
rclone copy pcloud_crypt:vps-backup/weekly/2026-06-04/home/tako4ball/.bashrc /tmp/

# 不要なスナップショットの手動削除
rclone purge pcloud_crypt:vps-backup/weekly/2026-05-01
```

---

## トラブルシューティング

```bash
# エラー詳細（systemdジャーナル）
sudo journalctl -u vps-backup.service --no-pager -n 50

# バックアップログ
cat ~/.local/share/vps-backup/backup.log

# ロックファイルが残って起動しない場合
sudo rm /tmp/vps-backup.lock /tmp/vps-backup-weekly.lock
sudo systemctl start vps-backup.service

# rclone認証が切れた場合（SSHポート転送が必要。後述の「rclone OAuth認証とSSHポート転送」を参照）
rclone config reconnect pcloud:

# 接続テスト
rclone lsd pcloud_crypt:          # crypt経由
rclone lsd pcloud:                # pCloud直接

# スクリプトの1行ずつデバッグ実行
bash -x /usr/local/bin/vps-backup.sh
```

---

# 復旧手順（VPSが完全に死んだ場合）

以下は **VPSが完全に死に、新しいVPSを契約した状態** から、全環境を復旧する手順です。
**LLMは各ステップを1つずつユーザーに提示し、実行結果を確認してから次に進んでください。**

各ステップの先頭に **操作ユーザー** と **ディレクトリ** を明記しています。ユーザーが迷ったら `whoami` と `pwd` を実行して確認するよう案内してください。
Step 1 のみ root で操作し、以降はすべて tako4ball です。

## 前提条件（LLM: 最初にユーザーに以下をすべて確認してください）

- [ ] 新しい VPS を契約済み。OS は **Ubuntu 24.04 LTS**
- [ ] root パスワードが設定済みで、`ssh root@<新しいVPSのIP>` で接続できる
- [ ] VPS の IP アドレスを把握している
- [ ] VPS がインターネットに接続されている（`apt update` が通る）
- [ ] ディスク容量 30GB 以上
- [ ] 手元の PC にブラウザがある（rclone OAuth 認証で使う）
- [ ] パスワードマネージャーが開ける
- [ ] 以下の情報が手元にある:
  - pCloud メールアドレスとパスワード
  - rclone crypt password（1つ目。バックアップ作成時に自分で決めた文字列）
  - rclone crypt salt（2つ目。バックアップ作成時に自分で決めた文字列）
  - healthchecks.io UUID: `943c3111-2789-44dd-8d1a-3c27e8e1033b`

### ユーザー名について

このバックアップシステムは **ユーザー名 `tako4ball`** を前提に作られています。
全スクリプト・systemdユニット・パスが `tako4ball` 用に書かれています。
復旧時も同じユーザー名で作成します。変えたい場合は全ファイルのパスを書き換える必要があります。

### rclone OAuth認証とSSHポート転送

rclone の初回設定時、pCloud にログインするためのブラウザ認証が必要です。
VPS にはブラウザがないため、**SSHポート転送** を使って手元のPCのブラウザから認証します。

**手順:**
1. 現在のSSH接続を切断（`exit` を実行）
2. 以下の **ポート転送付き** コマンドで再接続:
   ```
   ssh -L 53682:localhost:53682 root@<VPSのIP>
   ```
3. `su - tako4ball` でユーザーを切り替える（`su` してもポート転送は維持される）
4. `rclone config` を実行し、表示された `http://127.0.0.1:53682/auth?...` を手元のブラウザで開く

---

## Step 1: ユーザー作成

> **操作ユーザー: root** / **ディレクトリ: 任意（rootのホーム）**

**root で新しい VPS に SSH ログイン**した状態から始めます。
以下のコマンドを **1行ずつ** 実行してください:

```
useradd -m -s /bin/bash tako4ball
```

`-m` はホームディレクトリ作成、`-s` はログインシェルを bash に設定します。

確認:

```
id tako4ball
```

`uid=...` でユーザー情報が表示されれば作成成功です。表示されない場合は `useradd` が失敗しているため、エラーメッセージを確認してください。

```
passwd tako4ball
```

新しいパスワードを2回入力してください。このVPSのログインパスワードです。パスワードマネージャーに記録してください。

```
usermod -aG sudo tako4ball
```

sudo 権限を付与します。確認:

```
id tako4ball
```

`... sudo ...` が表示されればsudo権限が付与されています。

```
su - tako4ball
```

> **以降の操作ユーザーは tako4ball に切り替わります**。`whoami` で確認できます。

---

## Step 2: 基本ツールの確認とインストール

> **操作ユーザー: tako4ball** / **ディレクトリ: 任意**

まず現在の状態を確認します。以下のコマンドを実行し、結果をLLMに伝えてください:

```
dpkg -l | grep -E '^(ii|hi)' | awk '{print $2}' | grep -xE 'rclone|git|curl|build-essential|language-pack-ja|nodejs|tmux|openssh-server' | sort
```

LLMは不足しているパッケージを判断し、必要なものだけインストールを案内します。

**必要なパッケージの標準的なインストール手順:**

```
sudo apt update
sudo apt install -y rclone build-essential language-pack-ja git curl tmux
```

```
curl -fsSL https://deb.nodesource.com/setup_24.x | sudo -E bash -
sudo apt install -y nodejs
```

**インストール後の確認:**

```
rclone version && node --version && git --version
```

すべてバージョン番号が表示されればOKです。

**`~/.local/bin` をPATHに追加（まだの場合）:**

多くの場合 `.bashrc` に設定済み（データ復元後に反映される）が、それまでは以下で一時的に通す:

```
export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$PATH"
```

---

## Step 3: rclone 設定（pCloud リモート）

> **操作ユーザー: tako4ball** / **ディレクトリ: 任意**

**ここで SSH ポート転送が必要です。** まだポート転送していない場合、`exit` で切断し
`ssh -L 53682:localhost:53682 root@<IP>` で再接続 → `su - tako4ball` してから以下を実行してください。

```
rclone config
```

対話式の設定が始まります。画面に表示される **プロンプト** に対して以下の値を入力してください:

| プロンプト | 入力値 | なぜその値か |
|-----------|--------|-------------|
| `n/r/c/s/q>` | `n` | New（新規作成） |
| `name>` | `pcloud` | このリモートの名前 |
| `Storage>` | `pcloud` | 番号で選んでも文字列入力でも可 |
| `client_id>` | Enter（空欄） | rclone組み込みのIDを使う |
| `client_secret>` | Enter（空欄） | rclone組み込みのIDを使う |
| `Edit advanced config? y/n>` | **`y`** | EUリージョン設定のため必須 |
| `hostname>` | **`2`** | EUサーバー（eapi.pcloud.com）。日本から登録したアカウントはEUリージョン |
| 以降のadvancedオプション（auth_url, token_url, root_folder_id, username, encoding） | すべてEnter（空欄） | デフォルト値で問題なし |
| `Use web browser to automatically authenticate? y/n>` | `y` | ブラウザ認証を行う |
| → `http://127.0.0.1:53682/auth?...` が表示されたら | **手元のPCのブラウザ**でそのURLを開く | pCloudにログインしてrcloneを承認 |
| `y/e/d>` | `y` | 設定を保存 |

pCloud リモートの確認:

```
rclone lsd pcloud:
```

pCloud 上のフォルダ一覧が表示されれば成功です（空でもOK）。エラーが出た場合は設定が正しくないため、`rclone config` で再設定してください。

---

## Step 4: rclone 設定（crypt リモート）

> **操作ユーザー: tako4ball** / **ディレクトリ: 任意（Step 3の続き）**

同じ `rclone config` の中で続けます:

| プロンプト | 入力値 | なぜその値か |
|-----------|--------|-------------|
| `n/r/c/s/q>` | `n` | 続けて新規作成 |
| `name>` | `pcloud_crypt` | 暗号化リモートの名前 |
| `Storage>` | `crypt` | 暗号化レイヤー |
| `remote>` | `pcloud:vps-backup` | pCloud上の保存先フォルダ |
| `filename_encryption>` | Enter（standard） | ファイル名も暗号化（標準設定） |
| `directory_name_encryption>` | **`true`** | フォルダ名も暗号化 |
| `password>` | **パスワードマネージャーのpasswordを入力** | バックアップ作成時に設定したものと同じものを |
| `password again>` | 同じpasswordを再入力 | 確認 |
| `salt>` | **パスワードマネージャーのsaltを入力** | passwordとは別の文字列。バックアップ作成時に設定したもの |
| `salt again>` | 同じsaltを再入力 | 確認 |
| `Edit advanced config? y/n>` | Enter（n） | デフォルトでOK |
| `y/e/d>` | `y` | 設定を保存 |
| `n/r/c/s/q>` | `q` | 終了 |

> **password と salt を間違えると復号できません。** パスワードマネージャーの値を正確に入力してください。
> 入力した文字は画面に表示されません。

確認:

```
rclone lsd pcloud_crypt:
```

エラーが出なければ成功です。`directory not found` と出た場合は以下を実行:

```
rclone mkdir pcloud:vps-backup
```

---

## Step 5: データ復元

> **操作ユーザー: tako4ball** / **ディレクトリ: 任意**

```
rclone copy pcloud_crypt:vps-backup/latest /home/tako4ball
```

約13GBのダウンロードのため **1〜数時間** かかります。
途中で接続が切れても、**同じコマンドを再実行すれば続きから再開** されるので安心してください。

別のSSH接続から進捗を確認できます:

```
ls /home/tako4ball          # 復元されたフォルダを確認
du -sh /home/tako4ball      # 復元済みサイズを確認
```

完了したら所有権を設定:

```
sudo chown -R tako4ball:tako4ball /home/tako4ball
```

確認:

```
ls /home/tako4ball
```

`.bashrc`, `dev/`, `.config/`, `.local/` などが表示されれば復元成功です。

---

## Step 6: バックアップ機構の再展開

> **操作ユーザー: tako4ball** / **ディレクトリ: 任意（`~/.local/share/vps-backup/` が存在していればOK）**

復元されたデータには `~/.local/share/vps-backup/` 配下に全ソースファイルが含まれています。
これらをシステムに配置します。**1行ずつ実行** してください:

```
sudo cp ~/.local/share/vps-backup/vps-backup.sh /usr/local/bin/
```

```
sudo cp ~/.local/share/vps-backup/vps-backup-weekly.sh /usr/local/bin/
```

```
sudo chmod +x /usr/local/bin/vps-backup.sh /usr/local/bin/vps-backup-weekly.sh
```

```
sudo cp ~/.local/share/vps-backup/vps-backup.service /etc/systemd/system/
```

```
sudo cp ~/.local/share/vps-backup/vps-backup.timer /etc/systemd/system/
```

```
sudo cp ~/.local/share/vps-backup/vps-backup-weekly.service /etc/systemd/system/
```

```
sudo cp ~/.local/share/vps-backup/vps-backup-weekly.timer /etc/systemd/system/
```

```
sudo systemctl daemon-reload
```

```
sudo systemctl enable --now vps-backup.timer
```

`Created symlink ...` と表示されればOKです。

```
sudo systemctl enable --now vps-backup-weekly.timer
```

`Created symlink ...` と表示されればOKです。

ファイルが正しく配置されたか確認:

```
ls -la /usr/local/bin/vps-backup*.sh && ls /etc/systemd/system/vps-backup*
```

すべてのファイルが表示されれば配置完了です。

---

## Step 7: 最終確認

> **操作ユーザー: tako4ball** / **ディレクトリ: 任意**

```
systemctl list-timers vps-backup*
```

日次（NEXT: 翌日03:00 JST）と週次（NEXT: 翌日曜04:00 JST）のタイマーが表示されればOKです。

```
sudo systemctl start vps-backup.service
```

バックアップが実行されます。初回はデータがすでに揃っているため差分のみで数分で完了します。

```
tail ~/.local/share/vps-backup/backup.log
```

`Starting daily backup` と表示されれば全復旧完了です。

---

## Step 8: 周辺環境の確認と復旧（ユーザーの要望に応じて）

> **操作ユーザー: tako4ball** / **ディレクトリ: 任意**

以下の項目を1つずつ確認し、必要なものだけ対応します。

**Tailscale（VPN）:**

```
which tailscale || curl -fsSL https://tailscale.com/install.sh | sh
tailscale version
```

`tailscale version` でバージョンが表示されればインストール成功です。

```
sudo tailscale up
# → 表示されたURLをブラウザで開いて認証
# → "Success" と表示されれば接続完了

**SSH鍵:**

バックアップから復元されていれば `~/.ssh/id_ed25519` が存在するはずです。
なければパスワードマネージャーから復元:

```
mkdir -p ~/.ssh && chmod 700 ~/.ssh
# 秘密鍵を ~/.ssh/id_ed25519 に配置
chmod 600 ~/.ssh/id_ed25519
```

---

## 復旧に必要な情報（紛失すると復旧不可）

| 情報 | 保管場所 |
|------|----------|
| pCloud メールアドレスとパスワード | パスワードマネージャー |
| rclone crypt password | パスワードマネージャー |
| rclone crypt salt | パスワードマネージャー |
| healthchecks.io UUID | `943c3111-2789-44dd-8d1a-3c27e8e1033b` |
| このガイドと全設定ファイル | `git clone https://github.com/tako3ball/vps-backup.git` |
