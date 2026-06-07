# VPS Backup Guide

このドキュメントは **人間とLLMの両方が読む** ことを想定しています。
人間が実際の操作を行い、LLMがステップバイステップでガイドします。
LLMは各ステップを1つずつ提示し、ユーザーの実行結果を確認してから次に進んでください。

## 目次

### 通常運用・トラブルシューティング
- [ ] [システム概要](#システム概要) — バックアップの仕組みと用語解説
- [ ] [ファイル構成](#ファイル構成) — 全ファイルの配置場所
- [ ] [通常運用](#通常運用) — 状態確認・手動実行・一時停止
- [ ] [スナップショットからの復元](#スナップショットからの復元)
- [ ] [トラブルシューティング](#トラブルシューティング)

### 復旧手順（VPS完全消失時）
- [ ] [前提条件の確認](#前提条件llm-最初にユーザーに以下をすべて確認してください)
- [ ] [Step 1: ユーザー作成](#step-1-ユーザー作成) — root → tako4ball
- [ ] [Step 2: 基本ツールの確認とインストール](#step-2-基本ツールの確認とインストール) — 不足パッケージを確認して導入
- [ ] [Step 3: rclone 設定（pCloud リモート）](#step-3-rclone-設定pcloud-リモート) — SSHポート転送必須
- [ ] [Step 4: rclone 設定（crypt リモート）](#step-4-rclone-設定crypt-リモート) — 暗号化レイヤー
- [ ] [Step 5: データ復元](#step-5-データ復元) — 全データをpCloudからダウンロード（データ量に応じて時間変動）
- [ ] [Step 6: バックアップ機構の再展開](#step-6-バックアップ機構の再展開) — スクリプトとsystemdユニットを配置
- [ ] [Step 7: 最終確認](#step-7-最終確認) — タイマー動作・バックアップ実行テスト
- [ ] [Step 8: 周辺環境](#step-8-周辺環境の確認と復旧ユーザーの要望に応じて) — Tailscale・SSH鍵
- [ ] [復旧に必要な情報](#復旧に必要な情報紛失すると復旧不可) — パスワードマネージャーに保管すべきもの

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
| 対象 | `/home/tako4ball/` 配下の全ファイル |
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

# 週次スナップショット一覧（スナップショットが1つもない場合は何も表示されない）
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

# 特定日時のファイルを復元（日付は実際のスナップショット日付に置き換える）
rclone copy pcloud_crypt:vps-backup/weekly/YYYY-MM-DD/home/tako4ball/.bashrc /tmp/

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
sudo rm /tmp/vps-backup.lock
sudo systemctl start vps-backup.service

# rclone認証が切れた場合（SSHポート転送が必要。ssh -p <ポート> -L 53682:localhost:53682 root@<IP> で再接続してから実行。ポート22の場合は -p 22 省略可）
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

### このセクションの表記について

このセクションでは以下のプレースホルダーを使っています。LLMは実際の値に置き換えてユーザーに提示してください:

| プレースホルダー | 意味 | 確認方法 |
|-----------------|------|---------|
| `<IP>` | 新しいVPSのIPアドレス | VPS会社の管理画面、またはVPS上で `curl -4 ifconfig.me` |
| `<ポート>` | SSHのポート番号 | VPS会社の管理画面。通常は `22`（指定がなければ22と仮定してOK） |

`<ポート>` が `22` の場合は `-p 22` を省略できます（以下「ポート22の場合は省略可」と記載）。

### LLMへの指示（このセクションを読んだLLMは必ず従うこと）

1. まずユーザーに「前提条件」のチェックリストを1項目ずつ確認し、すべて満たしているか検証する。特に **IPアドレスとSSHポート番号は必須**
2. 条件が揃ったら Step 1 から開始する
3. **1ステップにつき1コマンドずつ**ユーザーに提示する。一度に複数コマンドを出さない。`<IP>` と `<ポート>` は事前に確認した実際の値に置き換える
4. ユーザーがコマンドを実行したら、その出力を確認し、期待される結果と一致するか判断する
5. 期待通りなら次へ。期待通りでなければ、ガイド内の **IF** 分岐に従って対処を案内する
6. ユーザーが混乱したら `whoami` と `pwd` を実行させ、現在のユーザーとディレクトリを確認する
7. 目次のチェックボックスを Step 完了ごとに埋めるようユーザーに促す

各ステップの先頭に **操作ユーザー** と **ディレクトリ** を明記しています。
Step 1 のみ root で操作し、以降はすべて tako4ball です。
`sudo` が必要なコマンドには `sudo` が付いています。付いていないコマンドは一般ユーザーで実行します。
`sudo` 実行時にパスワードを求められたら、Step 1 で `passwd tako4ball` に設定したパスワードを入力してください。
**出力が何もないコマンド**（`sudo cp` や `sudo systemctl daemon-reload` など）は、出力がなくても成功です。エラーがある場合のみメッセージが表示されます。

## 前提条件（LLM: 最初にユーザーに以下をすべて確認してください）

- [ ] 新しい VPS を契約済み。OS は **Ubuntu 24.04 LTS**
- [ ] VPS の **IP アドレス** を把握している（VPS会社の管理画面に表示される。わからなければ `curl -4 ifconfig.me` をVPS上で実行）
- [ ] VPS の **SSH ポート番号** を把握している（通常は `22`。VPS会社の管理画面に記載）
- [ ] root パスワードが設定済みで、`ssh -p <ポート> root@<IP>` で接続できる
- [ ] VPS がインターネットに接続されている（`apt update` が通る）
- [ ] ディスク容量がバックアップデータより十分大きいこと（現在の容量は後述の確認コマンドで把握できる）
- [ ] 手元の PC にブラウザがある（rclone OAuth 認証で使う）
- [ ] パスワードマネージャーが開ける
- [ ] このガイドを読めている（新しいVPS上で `git clone https://github.com/tako3ball/vps-backup.git` して入手、または事前の保存から参照）
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
2. 以下の **ポート転送付き** コマンドで再接続（`<IP>` と `<ポート>` は実際の値に置き換える。ポートが22の場合は `-p 22` を省略可）:
   ```
   ssh -p <ポート> -L 53682:localhost:53682 root@<IP>
   ```
   Windows の PowerShell でも同じコマンドが使えます。PuTTY を使っている場合は Connection → SSH → Tunnels で `Source port: 53682`, `Destination: localhost:53682` を追加してください。
3. `su - tako4ball` でユーザーを切り替える（`su` してもポート転送は維持される）
4. `rclone config` を実行し、表示された `http://127.0.0.1:53682/auth?...` を手元のブラウザで開く

---

## Step 1: ユーザー作成

> **操作ユーザー: root** / **ディレクトリ: 任意（rootのホーム）**
> **前提: 前提条件のチェックリストがすべて満たされていること**

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
> **前提: Step 1 完了（`whoami` が `tako4ball` であること）**

まず現在の状態を確認します。以下のコマンドを実行し、結果をLLMに伝えてください:

```
dpkg -l | grep -E '^(ii|hi)' | awk '{print $2}' | grep -xE 'rclone|git|curl|build-essential|language-pack-ja|nodejs|tmux|openssh-server' | sort
```

LLMは不足しているパッケージを判断し、必要なものだけインストールを案内します。

**判定基準（LLM向け）:**
以下の8パッケージが必要です。`dpkg` の出力に含まれているものはインストール済み、含まれていないものだけインストールしてください:

```
rclone git curl build-essential language-pack-ja nodejs tmux openssh-server
```

**インストール手順:**

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

**`~/.local/bin` をPATHに追加:**

以下を実行して PATH を確認:

```
echo $PATH | grep ".local/bin" && echo "FOUND" || echo "NOT_FOUND"
```

- `FOUND` と表示された → PATH設定済み。何もしなくてOK
- `NOT_FOUND` と表示された → 以下で一時的に追加:

```
export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$PATH"
```

（データ復元後に `.bashrc` から自動反映されるため、これは一時的な措置です）

---

## Step 3: rclone 設定（pCloud リモート）

> **操作ユーザー: tako4ball** / **ディレクトリ: 任意**
> **前提: Step 2 完了（`rclone version` が通ること） + SSHポート転送が有効であること**

**ここで SSH ポート転送が必要です。** まだポート転送していない場合、`exit` で切断し
`ssh -p <ポート> -L 53682:localhost:53682 root@<IP>` で再接続 → `su - tako4ball` してから以下を実行してください（ポート22の場合は `-p 22` 省略可）。

```
rclone config
```

画面に質問が1つずつ表示されます。**表示された質問に対して答えを入力し Enter** を押すと次に進みます。
以下の表の **プロンプト（画面に表示される質問）** の列を見て、対応する **入力値** を入力してください。
表にない質問が出た場合は Enter で飛ばして構いません。

初回実行時は `No remotes found - make a new one` と表示されます。もし既存のリモートが表示された場合は、過去の失敗した設定の残りなので `d` で削除してから進めてください。

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
| → **IF** ブラウザで「接続できません」エラー | SSHポート転送が効いていない。一度 `exit` し、`ssh -p <ポート> -L 53682:localhost:53682 root@<IP>` で再接続して `rclone config` からやり直し（ポート22の場合は `-p 22` 省略可） | |
| → **IF** pCloudログイン後「Invalid redirect_uri」エラー | `hostname` が `2`（EU）になっていない可能性。`rclone config` で `pcloud` リモートを削除→再作成 | |
| `y/e/d>` | `y` | 設定を保存 |

pCloud リモートの確認:

```
rclone lsd pcloud:
```

pCloud 上のフォルダ一覧が表示されれば成功です（空でもOK）。エラーが出た場合は設定が正しくないため、`rclone config` で再設定してください。

---

## Step 4: rclone 設定（crypt リモート）

> **操作ユーザー: tako4ball** / **ディレクトリ: 任意（Step 3の続き）**
> **前提: Step 3 完了（`rclone lsd pcloud:` が通ること）。Step 3 の `rclone config` を終了していないこと**

Step 3 の `rclone config` を **終了せずに** そのまま続けます。もし誤って終了（`q`）してしまった場合は、もう一度 `rclone config` を実行し、pCloud リモートが表示されることを確認してから暗号化リモートを作成してください。

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
| `Option password2.` → `y/g/n>` | **`y`** | 自分でsaltを入力する |
| `Enter the password:` | **パスワードマネージャーのsaltを入力** | passwordとは別の文字列。バックアップ作成時に設定したもの |
| `Confirm the password:` | 同じsaltを再入力 | 確認 |
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
> **前提: Step 3 と Step 4 が完了していること（`rclone lsd pcloud_crypt:` が通ること）。このステップに進む前に、パスワードマネージャーの password と salt が正しいことを確認済みであること**

```
rclone copy pcloud_crypt:vps-backup/latest /home/tako4ball
```

データ量に応じて時間がかかります。事前にバックアップサイズを確認するには:

```
rclone size pcloud_crypt:vps-backup/latest
```

**IF** 途中で接続が切れた、またはエラーで止まった → **同じコマンドを再実行**すれば続きから再開される。再実行して問題なければ続行。

**IF** `directory not found` エラー → crypt remote の設定ミス。Step 4 の `rclone lsd pcloud_crypt:` で確認し、エラーが出るなら `rclone config` で `pcloud_crypt` を再設定。

**IF** `invalid_access_token` エラー → rclone 認証切れ。`rclone config reconnect pcloud:` で再認証してから再実行。

**IF** 実行中に `Can't follow symlink without -L/--copy-links` という NOTICE が表示される → これは正常な警告で無視してよい。symlink はコピーされないが、実体は別途バックアップされている。

進捗は別のSSH接続（新しいターミナルを開いて `ssh -p <ポート> tako4ball@<IP>`）から確認できます:

```
ls /home/tako4ball
du -sh /home/tako4ball
```

別のSSH接続を開けない場合は、`Ctrl+C` で中断しても安全です（再実行すれば続きから再開します）。

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
> **前提: Step 5 完了（`ls /home/tako4ball` で `.bashrc` や `dev/` が表示されること）**

復元されたデータには `~/.local/share/vps-backup/` 配下に全ソースファイルが含まれています。
**IF** このディレクトリが存在しない → Step 5 の復元が完了していない。`ls ~/.local/share/vps-backup/` で確認し、なければ Step 5 を再実行。
存在すれば、以下をシステムに配置します。**1行ずつ実行** してください:

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
> **前提: Step 6 完了（`systemctl is-enabled vps-backup.timer` が `enabled` を返すこと）**

```
systemctl list-timers vps-backup*
```

**IF** 日次（NEXT: 翌日03:00 JST）と週次（NEXT: 翌日曜04:00 JST）のタイマーが表示された → OK。次に進む。

**IF** 何も表示されない → Step 6 の `systemctl enable` が失敗している。以下を確認:
```
sudo systemctl status vps-backup.timer
sudo systemctl status vps-backup-weekly.timer
```
エラーが出ている場合は `sudo systemctl enable --now vps-backup.timer` を再実行。

```
sudo systemctl start vps-backup.service
```

バックアップが実行されます。復元直後はデータが揃っているため、変更ファイルのみの転送で済みます。

```
cat ~/.local/share/vps-backup/backup.log
```

`Starting daily backup` と表示されれば全復旧完了です。ファイルが存在しない場合は `sudo systemctl start vps-backup.service` が完了していない可能性があるため、`sudo journalctl -u vps-backup.service --no-pager -n 20` でエラーを確認してください。

最後に、https://healthchecks.io にブラウザでアクセスし、`vps-backup` チェックのステータスが「緑（正常）」になっていることを確認してください。これで監視も復旧したことになります。

---

## Step 8: 周辺環境の確認と復旧（必須ではない。必要に応じて実施）

> **操作ユーザー: tako4ball** / **ディレクトリ: 任意**
> **前提: Step 5 完了（データが復元されていること）。Step 6-7 の完了は必須ではない**

以下の項目を1つずつ確認し、必要なものだけ対応します。

**Tailscale（VPN）:**

```
which tailscale || curl -fsSL https://tailscale.com/install.sh | sh
tailscale version
```

`tailscale version` でバージョンが表示されればインストール成功です。

```
sudo tailscale up
```

表示されたURLをブラウザで開いて認証します。`Success` と表示されれば接続完了です。

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
