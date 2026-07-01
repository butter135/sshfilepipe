#!/usr/bin/env bash

# ============================================================
# 引数
# ============================================================

Server=""
Channel="001"
Mode=""
Path=""
NoCompress=0
Help=0

# ============================================================
# 設定
# ============================================================

ScriptName="$(basename "$0")"

SshOptions=(
    "-o" "ServerAliveInterval=30"
    "-o" "ServerAliveCountMax=120"
    "-o" "TCPKeepAlive=yes"
)

# ============================================================
# ヘルプ・エラー処理
# ============================================================

show_help() {
    cat <<EOF
sshfilepipe - SSHサーバー上のFIFOを中継点にして、2端末間でファイル/ディレクトリをストリーム転送するスクリプト

Usage:
  ./$ScriptName send|get -s USER@HOST -c CHANNEL -p PATH
  ./$ScriptName -h

Required:
  MODE            動作モード。send または get
                  send: Path のファイルまたはディレクトリを送信する
                  get : 受信した内容を Path に展開する

  -s, --server    SSH接続先
                  ssh コマンドにそのまま渡す USER@HOST
                  例: sample@example.com

  -p, --path      ローカルパス
                  send時: 送信元ファイルまたはディレクトリ
                  get時 : 受信先ディレクトリ。存在しなければ作成する

Options:
  -c, --channel   転送用チャンネル名
                同じ server/channel の send と get が接続される
                デフォルトは001
                例: 001, room1

  -n, --no-compress
                  圧縮せずに tar ストリームで転送する
                  LAN内やCPUが弱い端末向け

  -h, --help      このヘルプを表示する

Examples:
  # 受信側。先に起動して待ち受ける
  ./$ScriptName get -s user@example.com -c room1 -p ./recv

  # ディレクトリを送る
  ./$ScriptName send -s user@example.com -c room1 -p ./send

  # ファイルを1つ送る
  ./$ScriptName send -s user@example.com -c room1 -p ./send/memo.txt

  # 圧縮なしで送る
  ./$ScriptName get  -s user@example.com -c room1 -p ./recv -n
  ./$ScriptName send -s user@example.com -c room1 -p ./send -n

Notes:
  - get を先に起動してから send を起動する
  - send/get は同じ server と channel を指定する
  - FIFO名は /tmp/sshfilepipe_<channel> になる
  - サーバーのディスクには転送ファイル本体を保存しない
  - FIFOは転送終了時に自動削除される
  - 同じ server/channel で同時に複数転送するとFIFO名が衝突する
EOF
}

usage_error() {
    echo "Error: $1" >&2
    echo "" >&2
    echo "Try: ./$ScriptName -h" >&2
    exit 1
}

# ============================================================
# チャンネル名検証
# ============================================================

validate_channel() {
    local value="$1"

    case "$value" in
        "")
            usage_error "-c CHANNEL is required"
            ;;
        *[!a-zA-Z0-9._-]*)
            usage_error "CHANNELには英数字、'.'、'_'、'-' のみ使用できます: $value"
            ;;
    esac
}

# ============================================================
# リモートbash生成
# ============================================================

new_remote_send_script() {
    local Pipe="$1"
    local WaitSeconds="${2:-300}"

    cat <<EOF
PIPE='$Pipe'
WAIT_SECONDS=$WaitSeconds

i=0
while [ "\$i" -lt "\$WAIT_SECONDS" ]; do
    if [ -p "\$PIPE" ]; then
        echo "getter found. start sending..." >&2
        cat > "\$PIPE"
        exit \$?
    fi
    i=\$((i + 1))
    echo "waiting getter... \$i/\$WAIT_SECONDS seconds" >&2
    sleep 1
done

echo "FIFO not found after waiting. Start get first: \$PIPE" >&2
exit 1
EOF
}

new_remote_get_script() {
    local Pipe="$1"

    cat <<EOF
PIPE='$Pipe'

echo "creating fifo: \$PIPE" >&2
rm -f "\$PIPE"
mkfifo "\$PIPE" || exit 1
trap 'rm -f "\$PIPE"' EXIT
echo "waiting sender..." >&2
cat "\$PIPE"
EOF
}

# ============================================================
# 引数チェック
# ============================================================

if [ "$#" -eq 0 ]; then
    usage_error "MODE send|get is required"
fi

case "$1" in
    send|get)
        Mode="$1"
        shift
        ;;
    -h|--help|help)
        show_help
        exit 0
        ;;
    *)
        usage_error "MODE must be send or get"
        ;;
esac

while [ "$#" -gt 0 ]; do
    case "$1" in
        -s|--server)
            shift
            [ "$#" -gt 0 ] || usage_error "-s USER@HOST is required"
            Server="$1"
            ;;
        -c|--channel)
            shift
            [ "$#" -gt 0 ] || usage_error "-c CHANNEL is required"
            Channel="$1"
            ;;
        -p|--path)
            shift
            [ "$#" -gt 0 ] || usage_error "-p PATH is required"
            Path="$1"
            ;;
        -n|--no-compress)
            NoCompress=1
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            usage_error "unknown option: $1"
            ;;
    esac
    shift
done

if [ -z "$Mode" ]; then
    usage_error "MODE send|get is required"
fi

if [ -z "$Server" ]; then
    usage_error "-s USER@HOST is required"
fi

if [ -z "$Path" ]; then
    usage_error "-p PATH is required"
fi

validate_channel "$Channel"

# ============================================================
# 共通変数
# ============================================================

Pipe="/tmp/sshfilepipe_${Channel}"

echo "Mode: $Mode"
echo "Server: $Server"
echo "Channel: $Channel"
echo "Pipe: $Pipe"
echo "Path: $Path"

# ============================================================
# 本体
# ============================================================

case "$Mode" in
    send)
        if [ ! -e "$Path" ]; then
            usage_error "送信元が存在しません: $Path"
        fi

        ResolvedPath="$(cd "$(dirname "$Path")" && pwd)/$(basename "$Path")"

        if [ -d "$ResolvedPath" ]; then
            # ディレクトリの場合: その中身を送る
            TarBase="$ResolvedPath"
            TarTarget="."
            echo "[send] directory contents: $TarBase -> ${Server}:$Pipe"
        else
            # ファイルの場合: 親ディレクトリに移動して、ファイル名だけをtarに入れる
            TarBase="$(dirname "$ResolvedPath")"
            TarTarget="$(basename "$ResolvedPath")"
            echo "[send] file: $ResolvedPath -> ${Server}:$Pipe"
        fi

        RemoteSend="$(new_remote_send_script "$Pipe")"

        if [ "$NoCompress" -eq 1 ]; then
            tar -cvf - -C "$TarBase" "$TarTarget" |
                ssh "${SshOptions[@]}" "$Server" "$RemoteSend"
        else
            tar -czvf - -C "$TarBase" "$TarTarget" |
                ssh "${SshOptions[@]}" "$Server" "$RemoteSend"
        fi

        if [ "${PIPESTATUS[1]}" -ne 0 ]; then
            echo "send に失敗しました。get 側が先に起動しているか、server と channel が一致しているか確認してください。" >&2
            exit 1
        fi
        ;;

    get)
        mkdir -p "$Path"

        echo "[get] ${Server}:$Pipe -> $Path"

        RemoteGet="$(new_remote_get_script "$Pipe")"

        if [ "$NoCompress" -eq 1 ]; then
            ssh "${SshOptions[@]}" "$Server" "$RemoteGet" |
                tar -xvf - -C "$Path"
        else
            ssh "${SshOptions[@]}" "$Server" "$RemoteGet" |
                tar -xzvf - -C "$Path"
        fi

        if [ "${PIPESTATUS[1]}" -ne 0 ]; then
            echo "get に失敗しました。send 側が正常に送信したか確認してください。" >&2
            exit 1
        fi
        ;;
esac
