# sshfilepipe

sshfilepipe は、SSHサーバー上の FIFO を中継点として、2台の端末間でファイルやディレクトリをストリーム転送するスクリプトです。

転送ファイル本体は SSH サーバー上に保存されません。
送信側と受信側が同じ SSH サーバー、同じ channel を指定することで、FIFO 経由で tar ストリームを受け渡します。

## Features

* SSH サーバーを中継してファイル/ディレクトリを転送
* サーバー上に転送ファイル本体を保存しない
* FIFO によるストリーム転送
* ファイル単体とディレクトリの両方に対応
* gzip 圧縮あり/なしを選択可能
* Windows / macOS / Linux 対応

## Requirements

### Windows

Windows では PowerShell 版を使用してください。

* PowerShell 7.X (デフォルトでインストールされている **Windows PowerShell 5.1** ではなく、**PowerShell 7.x** を使用してください。)
* OpenSSH client
* tar

使用するスクリプト:

```powershell
sshfilepipe.ps1
```

### macOS / Linux

macOS / Linux では shell script 版を使用してください。

* bash
* ssh
* tar
* mkfifo

使用するスクリプト:

```bash
sshfilepipe.sh
```

実行権限を付与してください。

```bash
chmod +x sshfilepipe.sh
```

## Usage

### Windows

```powershell
.\sshfilepipe.ps1 send|get -s USER@HOST -p PATH [-c CHANNEL] [-n]
```

### macOS / Linux

```bash
./sshfilepipe.sh send|get -s USER@HOST -p PATH [-c CHANNEL] [-n]
```

## Options

| Option                | Description                                                   |
| --------------------- | ------------------------------------------------------------- |
| `send`                | 指定したファイルまたはディレクトリを送信します                                       |
| `get`                 | 受信した内容を指定ディレクトリに展開します                                         |
| `-s`, `--server`      | SSH 接続先。`ssh` コマンドに渡す `USER@HOST` を指定します                      |
| `-p`, `--path`        | ローカルパス。`send` では送信元、`get` では受信先ディレクトリ                         |
| `-c`, `--channel`     | 転送用チャンネル名。同じ server/channel の send と get が接続されます。デフォルトは `001` |
| `-n`, `--no-compress` | gzip 圧縮せずに tar ストリームで転送します                                    |
| `-h`, `--help`        | ヘルプを表示します                                                     |

## Examples

### Windows

受信側を先に起動します。

```powershell
.\sshfilepipe.ps1 get -s user@example.com -c room1 -p .\recv
```

別の端末からディレクトリを送信します。

```powershell
.\sshfilepipe.ps1 send -s user@example.com -c room1 -p .\send
```

ファイルを1つ送信します。

```powershell
.\sshfilepipe.ps1 send -s user@example.com -c room1 -p .\send\memo.txt
```

圧縮なしで転送します。

```powershell
.\sshfilepipe.ps1 get  -s user@example.com -c room1 -p .\recv -n
.\sshfilepipe.ps1 send -s user@example.com -c room1 -p .\send -n
```

### macOS / Linux

受信側を先に起動します。

```bash
./sshfilepipe.sh get -s user@example.com -c room1 -p ./recv
```

別の端末からディレクトリを送信します。

```bash
./sshfilepipe.sh send -s user@example.com -c room1 -p ./send
```

ファイルを1つ送信します。

```bash
./sshfilepipe.sh send -s user@example.com -c room1 -p ./send/memo.txt
```

圧縮なしで転送します。

```bash
./sshfilepipe.sh get  -s user@example.com -c room1 -p ./recv -n
./sshfilepipe.sh send -s user@example.com -c room1 -p ./send -n
```

## How it works

1. 受信側で `get` を起動します。
2. SSH サーバー上に FIFO が作成されます。
3. 送信側で `send` を起動します。
4. 送信側はファイルまたはディレクトリを tar ストリームにします。
5. tar ストリームが SSH 経由で FIFO に書き込まれます。
6. 受信側は FIFO から読み取った tar ストリームをローカルに展開します。
7. 転送終了後、FIFO は削除されます。

FIFO は以下のような名前で作成されます。

```text
/tmp/sshfilepipe_<channel>
```

例:

```text
/tmp/sshfilepipe_room1
```

## Notes

* `get` を先に起動してから `send` を起動してください。
* `send` と `get` は同じ `server` と `channel` を指定してください。
* 同じ `server/channel` で同時に複数転送すると FIFO 名が衝突します。
* サーバーのディスクには転送ファイル本体を保存しません。
* FIFO は転送終了時に自動削除されます。
* 通信経路は SSH によって暗号化されます。
* SSH サーバー上で `mkfifo` が使用できる必要があります。

## Compression

デフォルトでは gzip 圧縮ありの tar ストリームを使用します。

```bash
tar -czf -
```

`-n` または `--no-compress` を指定すると、圧縮なしの tar ストリームを使用します。

```bash
tar -cf -
```

LAN 内転送や、CPU が弱い端末では `--no-compress` の方が速い場合があります。

## License

[![SUSHI-WARE LICENSE](https://img.shields.io/badge/license-SUSHI--WARE%F0%9F%8D%A3-blue.svg)](https://github.com/MakeNowJust/sushi-ware)
