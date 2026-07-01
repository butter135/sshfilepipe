# sshfilepipe.ps1
# SSHサーバー上のFIFOを中継点にして、2端末間でファイル/ディレクトリをストリーム転送する

# ============================================================
# 引数
# ============================================================

$Server = ""
$Channel = "001"
$Mode = ""
$Path = ""
$NoCompress = $false
$Help = $false

# ============================================================
# 設定
# ============================================================

$ScriptName = Split-Path -Leaf $PSCommandPath

$SshOptions = @(
    "-o", "ServerAliveInterval=30",
    "-o", "ServerAliveCountMax=120",
    "-o", "TCPKeepAlive=yes"
)

# ============================================================
# ヘルプ・エラー処理
# ============================================================

function Show-Help
{
    Write-Host @"
sshfilepipe - SSHサーバー上のFIFOを中継点にして、2端末間でファイル/ディレクトリをストリーム転送するスクリプト

Usage:
  .\$ScriptName send|get -s USER@HOST -c CHANNEL -p PATH
  .\$ScriptName -h

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
  .\$ScriptName get -s user@example.com -c room1 -p .\recv

  # ディレクトリを送る
  .\$ScriptName send -s user@example.com -c room1 -p .\send

  # ファイルを1つ送る
  .\$ScriptName send -s user@example.com -c room1 -p .\send\memo.txt

  # 圧縮なしで送る
  .\$ScriptName get  -s user@example.com -c room1 -p .\recv -n
  .\$ScriptName send -s user@example.com -c room1 -p .\send -n

Notes:
  - get を先に起動してから send を起動する
  - send/get は同じ server と channel を指定する
  - FIFO名は /tmp/sshfilepipe_<channel> になる
  - サーバーのディスクには転送ファイル本体を保存しない
  - FIFOは転送終了時に自動削除される
  - 同じ server/channel で同時に複数転送するとFIFO名が衝突する
"@
}

function Usage-Error
{
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    Write-Error "Error: $Message"
    Write-Host ""
    Write-Host "Try: .\$ScriptName -h"
    exit 1
}

# ============================================================
# チャンネル名検証
# ============================================================

function Validate-Channel
{
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value))
    {
        Usage-Error "-c CHANNEL is required"
    }

    if ($Value -notmatch '^[a-zA-Z0-9._-]+$')
    {
        Usage-Error "CHANNELには英数字、'.'、'_'、'-' のみ使用できます: $Value"
    }
}

# ============================================================
# リモートbash生成
# ============================================================

function New-RemoteSendScript
{
    param(
        [Parameter(Mandatory = $true)]
        [string]$Pipe,

        [int]$WaitSeconds = 300
    )

    @"
PIPE='$Pipe'
WAIT_SECONDS=$WaitSeconds

i=0
while [ "`$i" -lt "`$WAIT_SECONDS" ]; do
    if [ -p "`$PIPE" ]; then
        echo "getter found. start sending..." >&2
        cat > "`$PIPE"
        exit `$?
    fi

    i=`$((i + 1))
    echo "waiting getter... `$i/`$WAIT_SECONDS seconds" >&2
    sleep 1
done

echo "FIFO not found after waiting. Start get first: `$PIPE" >&2
exit 1
"@
}

function New-RemoteGetScript
{
    param(
        [Parameter(Mandatory = $true)]
        [string]$Pipe
    )

    @"
PIPE='$Pipe'

echo "creating fifo: `$PIPE" >&2
rm -f "`$PIPE"
mkfifo "`$PIPE" || exit 1
trap 'rm -f "`$PIPE"' EXIT
echo "waiting sender..." >&2
cat "`$PIPE"
"@
}

# ============================================================
# 引数パース
# ============================================================

if ($args.Count -eq 0)
{
    Usage-Error "MODE send|get is required"
}

switch ($args[0])
{
    "send"
    {
        $Mode = "send"
        $args = $args[1..($args.Count - 1)]
    }
    "get"
    {
        $Mode = "get"
        $args = $args[1..($args.Count - 1)]
    }
    "-h"
    {
        Show-Help
        exit 0
    }
    "--help"
    {
        Show-Help
        exit 0
    }
    "help"
    {
        Show-Help
        exit 0
    }
    default
    {
        Usage-Error "MODE must be send or get"
    }
}

$i = 0
while ($i -lt $args.Count)
{
    switch ($args[$i])
    {
        { $_ -in @("-s", "--server") }
        {
            $i++
            if ($i -ge $args.Count)
            {
                Usage-Error "-s USER@HOST is required"
            }
            $Server = $args[$i]
        }

        { $_ -in @("-c", "--channel") }
        {
            $i++
            if ($i -ge $args.Count)
            {
                Usage-Error "-c CHANNEL is required"
            }
            $Channel = $args[$i]
        }

        { $_ -in @("-p", "--path") }
        {
            $i++
            if ($i -ge $args.Count)
            {
                Usage-Error "-p PATH is required"
            }
            $Path = $args[$i]
        }

        { $_ -in @("-n", "--no-compress") }
        {
            $NoCompress = $true
        }

        { $_ -in @("-h", "--help") }
        {
            Show-Help
            exit 0
        }

        default
        {
            Usage-Error "unknown option: $($args[$i])"
        }
    }

    $i++
}

if ([string]::IsNullOrWhiteSpace($Mode))
{
    Usage-Error "MODE send|get is required"
}

if ([string]::IsNullOrWhiteSpace($Server))
{
    Usage-Error "-s USER@HOST is required"
}

if ([string]::IsNullOrWhiteSpace($Path))
{
    Usage-Error "-p PATH is required"
}

Validate-Channel $Channel

# ============================================================
# 共通変数
# ============================================================

$Pipe = "/tmp/sshfilepipe_$Channel"

Write-Host "Mode: $Mode"
Write-Host "Server: $Server"
Write-Host "Channel: $Channel"
Write-Host "Pipe: $Pipe"
Write-Host "Path: $Path"

# ============================================================
# 本体
# ============================================================

switch ($Mode)
{
    "send"
    {
        if (-not (Test-Path -LiteralPath $Path))
        {
            Usage-Error "送信元が存在しません: $Path"
        }

        $ResolvedPath = (Resolve-Path -LiteralPath $Path).Path
        $Item = Get-Item -LiteralPath $ResolvedPath

        if ($Item.PSIsContainer)
        {
            # ディレクトリの場合: その中身を送る
            $TarBase = $ResolvedPath
            $TarTarget = "."
            Write-Host "[send] directory contents: $TarBase -> ${Server}:$Pipe"
        } else
        {
            # ファイルの場合: 親ディレクトリに移動して、ファイル名だけをtarに入れる
            $TarBase = Split-Path -Parent $ResolvedPath
            $TarTarget = Split-Path -Leaf $ResolvedPath
            Write-Host "[send] file: $ResolvedPath -> ${Server}:$Pipe"
        }

        $RemoteSend = New-RemoteSendScript -Pipe $Pipe

        if ($NoCompress)
        {
            & tar -cvf - -C "$TarBase" "$TarTarget" |
                & ssh @SshOptions "$Server" "$RemoteSend"
        } else
        {
            & tar -czvf - -C "$TarBase" "$TarTarget" |
                & ssh @SshOptions "$Server" "$RemoteSend"
        }

        if ($LASTEXITCODE -ne 0)
        {
            Write-Error "send に失敗しました。get 側が先に起動しているか、server と channel が一致しているか確認してください。"
            exit 1
        }
    }

    "get"
    {
        New-Item -ItemType Directory -Force -Path $Path | Out-Null

        Write-Host "[get] ${Server}:$Pipe -> $Path"

        $RemoteGet = New-RemoteGetScript -Pipe $Pipe

        if ($NoCompress)
        {
            & ssh @SshOptions "$Server" "$RemoteGet" |
                & tar -xvf - -C "$Path"
        } else
        {
            & ssh @SshOptions "$Server" "$RemoteGet" |
                & tar -xzvf - -C "$Path"
        }

        if ($LASTEXITCODE -ne 0)
        {
            Write-Error "get に失敗しました。send 側が正常に送信したか確認してください。"
            exit 1
        }
    }
}
