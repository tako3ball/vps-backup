# VPS Backup System

このドキュメントは **LLM（Claude などのAIアシスタント）がユーザーをガイドするためのプロンプト** です。
以下の手順に従って、ユーザーをステップバイステップで誘導してください。

## システム概要（LLM向けコンテキスト）

ユーザーは VPS（Ubuntu 24.04）上の `/home/tako4ball/` 配下を pCloud に暗号化バックアップしています。

- **ツール**: rclone（pCloud + crypt による AES-256 暗号化）
- **日次バックアップ**: 毎日 3:00 JST、`rclone copy` による増分（削除は伝播しない）
- **週次スナップショット**: 毎週日曜 4:00 JST、4世代保持
- **監視**: healthchecks.io（UUID: `943c3111-2789-44dd-8d1a-3c27e8e1033b`）
- **GitHub**: https://github.com/tako3ball/vps-backup （全設定ファイルを管理）
- **VPS上の設定パス**: `~/.local/share/vps-backup/`

ユーザー名は `tako4ball`。全スクリプト・パスがこのユーザー名を前提としている。

## 通常運用時のLLMガイド

ユーザーから「バックアップの状態を確認して」と言われたら、以下を実行:

```bash
systemctl list-timers vps-backup*
tail -20 ~/.local/share/vps-backup/backup.log
rclone size pcloud_crypt:vps-backup/latest
```

トラブルシューティングが必要な場合は、ユーザーに以下の該当コマンドを案内:

```bash
# エラー詳細
sudo journalctl -u vps-backup.service --no-pager -n 50

# ロックファイル削除
sudo rm /tmp/vps-backup.lock /tmp/vps-backup-weekly.lock

# rclone認証切れ
rclone config reconnect pcloud:

# 手動バックアップ実行
sudo systemctl start vps-backup.service

# 週次スナップショット手動実行
sudo systemctl start vps-backup-weekly.service

# タイマー一時停止
sudo systemctl stop vps-backup.timer vps-backup-weekly.timer
sudo systemctl disable vps-backup.timer vps-backup-weekly.timer

# タイマー再開
sudo systemctl enable --now vps-backup.timer vps-backup-weekly.timer
```

---

# 復旧手順（VPS完全消失時）

## LLM向け事前説明

以下は **VPS が完全に死に、新しい VPS を契約した状態** から開始する復旧手順です。
ユーザーをステップバイステップで誘導してください。各ステップのコマンドを **1つずつ** ユーザーに提示し、
実行結果を確認してから次に進んでください。一度に複数ステップを提示しないでください。

### 前提条件（ユーザーに最初に確認すること）

以下の条件がすべて満たされているか、ユーザーに確認してください:

1. 新しい VPS を契約済みで、OS は Ubuntu 24.04 LTS
2. root ユーザーのパスワードが設定済み
3. `ssh root@<新しいVPSのIP>` で root ログインできる
4. VPS がインターネットに接続されている
5. ディスク容量が 30GB 以上ある
6. ユーザーの手元にブラウザがある（rclone OAuth認証で必要）
7. 以下の情報をパスワードマネージャーから用意できる:
   - pCloud のメールアドレスとパスワード
   - rclone crypt の password（1つ目）
   - rclone crypt の salt（2つ目）
   - healthchecks.io UUID（`943c3111-2789-44dd-8d1a-3c27e8e1033b`）

条件が揃っていない場合は、揃えるよう案内してください。

### ユーザー名の注意

このバックアップシステムはユーザー名 `tako4ball` を前提としています。
復旧時も同じユーザー名で作成します。変える場合は全設定ファイルのパスを書き換える必要があります。

---

## Step 1: ユーザー作成

ユーザーに以下を伝えてください:

> 新しい VPS に **root で SSH ログイン**し、以下のコマンドを1行ずつ実行してください。

```
useradd -m -s /bin/bash tako4ball
```

> （`-m`: ホームディレクトリを作成、`-s`: シェルを bash に設定）

```
passwd tako4ball
```

> 新しいパスワードを2回入力してください。このパスワードはこのVPSのログイン用です。パスワードマネージャーに記録してください。

```
usermod -aG sudo tako4ball
```

> （sudo 権限を付与）

```
su - tako4ball
```

> 以降の作業はすべて tako4ball ユーザーで行います。

---

## Step 2: rclone インストール

```
sudo apt update && sudo apt install -y rclone
```

確認:

```
rclone version
```

> バージョン番号が表示されれば成功です。

---

## Step 3: rclone 設定（pCloud リモート）

**重要: SSH ポート転送が必要です。** 現在のSSH接続がポート転送なしの場合、
ユーザーに以下を案内してください:

> 1. `exit` を2回実行してSSH接続を切断
> 2. 以下のコマンドでポート転送付き再接続:
> ```
> ssh -L 53682:localhost:53682 root@<新しいVPSのIP>
> ```
> 3. 再接続後に `su - tako4ball` を実行

その後:

```
rclone config
```

以下の表に従ってユーザーを誘導してください。各プロンプトに対して指定された値を入力するよう伝えてください:

| プロンプト | 入力値 | 備考 |
|-----------|--------|------|
| `n/r/c/s/q>` | `n` | 新規作成 |
| `name>` | `pcloud` | リモート名 |
| `Storage>` | `pcloud` | 番号でも文字列でも可 |
| `client_id>` | 空欄Enter | rclone組み込みIDを使用 |
| `client_secret>` | 空欄Enter | rclone組み込みIDを使用 |
| `Edit advanced config? y/n>` | **`y`** | EUリージョン設定のため必須 |
| `hostname>` | **`2`** | EUサーバー(eapi.pcloud.com)を選択 |
| 以降の advanced オプション | すべて空欄Enter | auth_url, token_url, root_folder_id, username, encoding |
| `Use web browser to automatically authenticate? y/n>` | `y` | |
| → URL表示後 | ユーザーにURLをブラウザで開かせる | pCloudにログインしてrcloneを承認 |
| `y/e/d>` | `y` | 設定を保存 |

---

## Step 4: rclone 設定（crypt リモート）

同じ `rclone config` の中で続けます:

| プロンプト | 入力値 | 備考 |
|-----------|--------|------|
| `n/r/c/s/q>` | `n` | 続けて新規作成 |
| `name>` | `pcloud_crypt` | 暗号化リモート名 |
| `Storage>` | `crypt` | |
| `remote>` | `pcloud:vps-backup` | pCloud上の保存先 |
| `filename_encryption>` | 空欄Enter | standard |
| `directory_name_encryption>` | **`true`** | フォルダ名も暗号化 |
| `password>` | **パスワードマネージャーのpasswordを入力** | 表示されないので注意 |
| `password again>` | 同じpasswordを再入力 | |
| `salt>` | **パスワードマネージャーのsaltを入力** | passwordとは別の文字列 |
| `salt again>` | 同じsaltを再入力 | |
| `Edit advanced config? y/n>` | 空欄Enter | |
| `y/e/d>` | `y` | 設定を保存 |
| `n/r/c/s/q>` | `q` | 終了 |

確認:

```
rclone lsd pcloud_crypt:
```

> エラーが出なければ成功です。"directory not found" と出た場合は `rclone mkdir pcloud:vps-backup` を実行してください。

---

## Step 5: データ復元

```
rclone copy pcloud_crypt:vps-backup/latest /home/tako4ball
```

> 約13GBのダウンロードのため1〜数時間かかります。
> 途中で接続が切れても、**同じコマンドを再実行すれば続きから再開**されます。
> 別のSSH接続で `ls /home/tako4ball` や `du -sh /home/tako4ball` を実行すると進捗を確認できます。

完了後:

```
sudo chown -R tako4ball:tako4ball /home/tako4ball
```

確認:

```
ls /home/tako4ball
```

> `.bashrc`, `dev/`, `.config/`, `.local/` などのフォルダが表示されれば復元成功です。

---

## Step 6: バックアップ機構の再展開

復元されたデータには `~/.local/share/vps-backup/` 配下にスクリプトとsystemdユニットが含まれています。
以下のコマンドを **1行ずつ** 実行するよう案内してください:

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

> "Created symlink ..." と表示されれば成功です。

```
sudo systemctl enable --now vps-backup-weekly.timer
```

> "Created symlink ..." と表示されれば成功です。

---

## Step 7: 最終確認

```
systemctl list-timers vps-backup*
```

> 日次（NEXT: 翌日03:00 JST）と週次（NEXT: 翌日曜04:00 JST）のタイマーが表示されればOKです。

```
sudo systemctl start vps-backup.service
```

> バックアップが実行されます。データはすでに揃っているので差分のみで数分で完了します。

```
tail ~/.local/share/vps-backup/backup.log
```

> "Starting daily backup" と表示されれば全復旧完了です。

---

## Step 8: その他（ユーザーの要望に応じて）

```
# Tailscale
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up

# tmux
sudo apt install -y tmux

# SSH鍵（パスワードマネージャーから復元）
mkdir -p ~/.ssh && chmod 700 ~/.ssh
# 秘密鍵を ~/.ssh/id_ed25519 に配置し、chmod 600 ~/.ssh/id_ed25519
```

---

## 復旧に必要な情報（LLMがユーザーに確認する際の参照用）

ユーザーが以下の情報を紛失している場合、復旧は不可能です:

| 情報 | 保管場所 |
|------|----------|
| pCloud メールアドレスとパスワード | パスワードマネージャー |
| rclone crypt password | パスワードマネージャー（バックアップ設定時にユーザーが決めた文字列） |
| rclone crypt salt | パスワードマネージャー（バックアップ設定時にユーザーが決めた文字列、passwordとは別） |
| healthchecks.io UUID | `943c3111-2789-44dd-8d1a-3c27e8e1033b` |
| このガイド（GitHub） | `git clone https://github.com/tako3ball/vps-backup.git` |
