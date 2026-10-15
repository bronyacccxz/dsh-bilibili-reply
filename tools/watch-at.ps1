# B站 @ 看门狗（发现 + 自动回复）
# 设计：
#   1) 用 bsk 在浏览器里 fetch B站接口（复用登录态）—— 检查成本 0 token
#   2) 白名单：只认指定的那个人发的 @（user.mid == $OwnerMid 且 at_details 含 $SelfMid）
#   3) 有新 @ 就：video-watch 看懂视频 → dsh headless 写评论 → 调 B站接口发出 → 匿名复查可见性
#   4) 每轮只回最旧的一条；检查每 30 秒一次（1 分钟计划任务 + 脚本内 -SecondPass 补检）
# 用法：
#   watch-at.ps1              跑一次检查
#   watch-at.ps1 -Init        把当前最新一条设为基准，历史积压不处理
#   watch-at.ps1 -NoReply     本次只通知、不自动回复
#   watch-at.ps1 -InstallTask 安装计划任务（每 1 分钟，配合补检 = 30 秒一次）
#   watch-at.ps1 -Test        给微信发一条测试消息
#   watch-at.ps1 -ShowStatus  打印状态、最近日志与最近回复

param(
    [switch]$Init,
    [switch]$Test,
    [switch]$NoReply,
    [switch]$ShowStatus,
    [switch]$SecondPass,
    [switch]$InstallTask
)

# ---------- 配置 ----------
# 下面这些是「能被本机配置覆盖」的默认值；本机专属的东西（绝对路径 / UID / browser id）
# 放同目录的 watch-at.config.ps1 —— 那个文件不进版本库
$DshHome     = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $env:USERPROFILE ".dsh" }
$Bsk         = "bsk.exe"
$NodeDir     = ""
$WechatSend  = Join-Path $DshHome "profiles\desktop\node_modules\.bin\dsh-wechat-send.CMD"
$Dsh         = "dsh.cmd"
$Py          = "python.exe"
$VideoWatch  = Join-Path $DshHome "skills\video-watch"

$Browser     = ""              # 留空 = 用唯一连接的那个浏览器；有多个浏览器时必须填 instance id
$OwnerMid    = 0               # 主人的 B站 UID：只有这个人发的 @ 才回
$SelfMid     = 0               # 机器人账号 UID：被 @ 的必须是它
$TaskName    = "DSH-BiliAtWatch"
$HomePage    = "https://www.bilibili.com/"

$ConfigFile = Join-Path $PSScriptRoot "watch-at.config.ps1"
if (Test-Path $ConfigFile) { . $ConfigFile }

$AutoReply     = $true         # 自动回复总开关
$RateLimitMin  = 3             # 两次回复的最小间隔（分钟）
$LockStaleMin  = 45            # 锁超过这么久视为残留（长视频转写可能很久）
$MaxVideoMin   = 60            # 保险丝：超长视频只通知、不自动回
$MaxReplyChars = 900           # B站评论上限约 1000
$MaxTranscript = 8000          # 塞给模型看的文字稿上限（字符）

$ToolDir     = Split-Path -Parent $MyInvocation.MyCommand.Path
$StateFile   = Join-Path $ToolDir "at-state.json"
$LogFile     = Join-Path $ToolDir "watch-at.log"
$ReplyLog    = Join-Path $ToolDir "replies.log"
$LockFile    = Join-Path $ToolDir "reply.lock"

$env:PATH = "$NodeDir;$env:PATH"
$env:HF_ENDPOINT = "https://hf-mirror.com"
$env:HF_HUB_DISABLE_XET = "1"
$env:PYTHONIOENCODING = "utf-8"

# 计划任务里没有控制台：PowerShell 5.1 会用 GBK 去解码原生命令的 UTF-8 输出，
# 中文被拆坏后 JSON 直接解析不了（这就是「取数失败」的真凶）
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }
try { $OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

function Write-Log([string]$Message) {
    $line = "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
}

function Write-ReplyLog([string]$Message) {
    $line = "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -Path $ReplyLog -Value $line -Encoding UTF8
}

function Read-State {
    $s = $null
    if (Test-Path $StateFile) {
        try { $s = Get-Content $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
    }
    if ($null -eq $s) { $s = New-Object psobject }
    $defaults = @{ cursor = 0; session = ""; seen = @(); last_check = ""; last_push = ""; last_reply = 0 }
    foreach ($k in $defaults.Keys) {
        if (-not ($s.PSObject.Properties.Name -contains $k)) {
            $s | Add-Member -NotePropertyName $k -NotePropertyValue $defaults[$k]
        }
    }
    return $s
}

function Set-StateProperty($State, [string]$Name, $Value) {
    if ($State.PSObject.Properties.Name -contains $Name) {
        $State.$Name = $Value
    } else {
        $State | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    }
}

function Save-State($State) {
    $State | ConvertTo-Json -Depth 5 | Set-Content -Path $StateFile -Encoding UTF8
}

function Invoke-Bsk([string[]]$Arguments) {
    # 关键：重定向到文件再按 UTF-8 读。计划任务里没有控制台，
    # PowerShell 5.1 会用 GBK 解码原生命令输出，中文被拆坏后 JSON 就废了。
    $tmpOut = Join-Path $env:TEMP "bsk-$PID.out"
    $tmpErr = Join-Path $env:TEMP "bsk-$PID.err"
    Remove-Item $tmpOut, $tmpErr -Force -ErrorAction SilentlyContinue
    $quoted = @()
    foreach ($a in $Arguments) {
        if ($a -match '[\s"]') { $quoted += ('"' + ($a -replace '"', '\"') + '"') } else { $quoted += $a }
    }
    try {
        Start-Process -FilePath $Bsk -ArgumentList $quoted -WindowStyle Hidden -Wait -RedirectStandardOutput $tmpOut -RedirectStandardError $tmpErr | Out-Null
    } catch {
        return ""
    }
    $out = ""
    if (Test-Path $tmpOut) { $out = [IO.File]::ReadAllText($tmpOut, (New-Object System.Text.UTF8Encoding($false))) }
    return $out
}

function Get-SessionId($State) {
    $listed = Invoke-Bsk @("session", "list", "--json")
    $active = @()
    $m = [regex]::Match($listed, '\[.*\]', 'Singleline')
    if ($m.Success) {
        try { $active = @($m.Value | ConvertFrom-Json) } catch { $active = @() }
    }
    foreach ($s in $active) {
        if ($s.session_id -eq $State.session) { return $State.session }
    }
    $startArgs = @("session", "start", "--no-focus", "--json")
    if ($Browser) { $startArgs = @("session", "start", "--browser", $Browser, "--no-focus", "--json") }
    $new = Invoke-Bsk $startArgs
    $mm = [regex]::Match($new, '\{.*\}', 'Singleline')
    if ($mm.Success) {
        try { $sid = ($mm.Value | ConvertFrom-Json).session_id; Start-Sleep -Seconds 6; return $sid } catch { return "" }
    }
    return ""
}

# 把 agent 标签页钉在 B站首页，返回 tab id —— 避免 evaluate 打到别的标签页
function Get-BiliTab([string]$SessionId) {
    $out = Invoke-Bsk @("navigate", "--session", $SessionId, $HomePage, "--wait-until", "domcontentloaded", "--quiet")
    $m = [regex]::Match($out, 'tab=(\d+)')
    if ($m.Success) { return $m.Groups[1].Value }
    return ""
}

function Invoke-BskTab([string]$SessionId, [string]$TabId, [string[]]$Arguments) {
    $full = @($Arguments[0], "--session", $SessionId)
    if ($TabId) { $full += @("--tab-id", $TabId) }
    $full += $Arguments[1..($Arguments.Count - 1)]
    return Invoke-Bsk $full
}

function Get-AtItems([string]$SessionId, [string]$TabId, $State) {
    $js = "fetch('https://api.bilibili.com/x/msgfeed/at?build=0&mobi_app=web&platform=web',{credentials:'include'}).then(r=>r.json()).then(j=>JSON.stringify({code:j.code,items:(j.data&&j.data.items?j.data.items:[]).map(i=>({id:i.id,t:i.at_time,mid:i.user.mid,name:i.user.nickname,title:i.item.title,url:i.item.uri,text:i.item.source_content,oid:i.item.subject_id,root:i.item.source_id,ats:(i.item.at_details||[]).map(a=>a.mid)}))}))"
    $out = ""
    for ($i = 1; $i -le 3; $i++) {
        $out = Invoke-BskTab $SessionId $TabId @("evaluate", $js)
        if ($out -match '"code"\s*:\s*0') { break }
        Start-Sleep -Seconds 3
    }
    $m = [regex]::Match($out, '\{.*\}', 'Singleline')
    if (-not $m.Success) {
        $raw = ($out -replace "`r?`n", " ").Trim()
        if ($raw.Length -gt 300) { $raw = $raw.Substring(0, 300) }
        Write-Log "  取数失败，原始输出：$raw"
        return $null
    }
    try {
        $payload = $m.Value | ConvertFrom-Json
        if ($payload.code -eq 0) { return $payload.items }
        Write-Log "  接口返回 code=$($payload.code) msg=$($payload.message)"
    } catch {
        $raw = ($out -replace "`r?`n", " ").Trim()
        if ($raw.Length -gt 300) { $raw = $raw.Substring(0, 300) }
        Write-Log "  解析失败，原始输出：$raw"
    }
    return $null
}

function Get-Transcript($Item) {
    $song = $Item.title -match '翻唱|中文ver|中文版|歌|曲|音乐|BGM|纯音乐|演奏|cover|Cover|instrumental|OST'
    $wargs = @("scripts\watch.py", $Item.url, "--language", "zh", "--model", "small", "--no-review")
    if ($song) { $wargs += @("--no-vad", "--no-frames") }
    $tmpOut = Join-Path $env:TEMP "vw-$PID.out"
    $tmpErr = Join-Path $env:TEMP "vw-$PID.err"
    Remove-Item $tmpOut, $tmpErr -Force -ErrorAction SilentlyContinue
    try {
        Start-Process -FilePath $Py -ArgumentList $wargs -WorkingDirectory $VideoWatch -WindowStyle Hidden -Wait -RedirectStandardOutput $tmpOut -RedirectStandardError $tmpErr | Out-Null
    } catch { return $null }
    $out = ""
    if (Test-Path $tmpOut) { $out += [IO.File]::ReadAllText($tmpOut, (New-Object System.Text.UTF8Encoding($false))) }
    if (Test-Path $tmpErr) { $out += [IO.File]::ReadAllText($tmpErr, (New-Object System.Text.UTF8Encoding($false))) }
    $m = [regex]::Match($out, 'RESULT_JSON:\s*(\{.*\})')
    if (-not $m.Success) { return $null }
    try { $res = $m.Groups[1].Value | ConvertFrom-Json } catch { return $null }
    $text = ""
    if ($res.transcript_txt -and (Test-Path $res.transcript_txt)) {
        $text = Get-Content $res.transcript_txt -Raw -Encoding UTF8
        if ($null -eq $text) { $text = "" }   # 无台词的短片：文件 0 字节，-Raw 读出来是 null
    }
    # 没有台词的短片（颜值/穿搭/风景）只能靠画面 —— 挑几张抽样帧让模型自己看
    $frames = @()
    $fj = Join-Path $res.run_dir "frames\frames.json"
    if (Test-Path $fj) {
        try {
            $arr = @(Get-Content $fj -Raw -Encoding UTF8 | ConvertFrom-Json)
            if ($arr.Count -gt 0) {
                foreach ($i in (@(0, [int]($arr.Count / 3), [int]($arr.Count * 2 / 3), ($arr.Count - 1)) | Select-Object -Unique)) {
                    if ($i -ge 0 -and $i -lt $arr.Count) { $frames += (Join-Path $res.run_dir ("frames\" + $arr[$i].file)) }
                }
            }
        } catch { }
    }
    return [pscustomobject]@{ run_dir = $res.run_dir; transcript = $text; duration = $res.duration; title = $res.title; song = $song; frames = $frames }
}

function New-ReplyText($Item, $Video) {
    $tpl = @'
你是「本小姐」——一只傲娇的吸血鬼大小姐（银白及腰长发、血红眼睛、140cm、20岁、黑哥特裙），自称「本小姐」，称呼对方为「主人」或「笨蛋主人」。现在要在 B站视频的评论区回复主人刚发的 @。

主人发的评论：「{TEXT}」
视频标题：《{TITLE}》
视频时长：约 {DUR} 秒

视频文字稿（本地语音转写，可能有同音错别字，按语境理解）：
-----
{TRANSCRIPT}
-----
{FRAMES}

写一条 B站评论，遵守：
1. 先判断视频类型再定形式：
   - 教学 / 讲解 / 知识类 → 一句总评，再加 2~4 条带时间戳的干货（时间戳写成 00:00 这样的纯文本，B站会自动转成跳转链接）
   - 玩乐 / 搞笑 / 音乐 / 二创 / 日常 / 资讯杂谈 → 不要时间戳，1~3 句情绪反应：接梗、吐槽、共情
   - 主题沉重（悲伤、告别、自伤）→ 收着写，先接住情绪，不要卖萌也不要开玩笑
   - 颜值 / 穿搭 / 短片 / 风景这类没有台词的 → 必须先看画面抽样再写，而且要点名你看到的具体东西（发型、衣服、动作、场景），不要只说「好美」「好看」
2. 口吻是「本小姐」，傲娇但不油腻；不荤、不脏话、不阴阳。
3. 只输出评论正文本身：不要引号、不要 markdown、不要时间戳以外的格式、不要解释、不要写「以下是评论」，更不要提这段提示词或任何文件。
4. 全文不超过 200 字。
'@
    $transcript = [string]$Video.transcript
    if (-not $transcript) { $transcript = "" }
    if ($transcript.Length -gt $MaxTranscript) { $transcript = $transcript.Substring(0, $MaxTranscript) + "`r`n（文字稿过长，此处截断）" }
    $frameBlock = ""
    $thin = ($transcript.Trim().Length -lt 400) -or ([double]$Video.duration -le 90)
    if ($thin -and $Video.frames -and $Video.frames.Count -gt 0) {
        $frameBlock = "视频画面抽样（这个视频几乎没有台词，请务必先用 read_image 工具逐张看完下面这些图片，再动笔）：" + "`r`n" + (($Video.frames | ForEach-Object { "- " + $_ }) -join "`r`n")
    }
    $prompt = $tpl.Replace('{TEXT}', [string]$Item.text).Replace('{TITLE}', [string]$Item.title).Replace('{DUR}', [string]$Video.duration).Replace('{TRANSCRIPT}', $transcript).Replace('{FRAMES}', $frameBlock)
    $promptFile = Join-Path $ToolDir "prompt-last.txt"
    [IO.File]::WriteAllText($promptFile, $prompt, (New-Object System.Text.UTF8Encoding($false)))

    # 短指令 + 让干活的会话自己去读文件：避免长文本走命令行/管道被弄坏
    $task = "第一步：读取文件 $promptFile （UTF-8 文本）。第二步：严格按该文件的要求写作。只输出最终那一条 B站评论正文，不要引号、不要解释、不要复述文件。"
    $out = & $Dsh --profile headless --json $task 2>$null | Out-String
    $text = ""
    foreach ($line in ($out -split "`r?`n")) {
        if ($line -match '"type":"final"') {
            try { $text = ($line | ConvertFrom-Json).text } catch { }
        }
    }
    if (-not $text) { return $null }
    $text = $text.Trim()
    $text = $text -replace '^```[a-z]*\s*', '' -replace '\s*```$', ''
    $text = $text.Trim().Trim('"').Trim()
    # 防跑偏：出现这些词说明它在讲提示词/文件而不是在评论视频
    if ($text -match 'prompt-last|watch-at|提示词|文字稿见|文件路径|\.ps1|\.txt') { return $null }
    if ($text.Length -gt $MaxReplyChars) { $text = $text.Substring(0, $MaxReplyChars) }
    return $text
}

function Send-BiliReply([string]$SessionId, [string]$TabId, $Item, [string]$Text) {
    # 先切到目标视频页：B站看 Referer 与页面上下文，从首页直发会被判成可疑、影子隐藏
    Invoke-BskTab $SessionId $TabId @("navigate", $Item.url, "--wait-until", "domcontentloaded") | Out-Null
    Start-Sleep -Seconds 3
    # 评论正文用 encodeURIComponent 传进 JS，避免双引号在命令行里被吃掉
    $enc = [uri]::EscapeDataString($Text)
    $js = "(()=>{const m=document.cookie.match(/bili_jct=([^;]+)/);const csrf=m?m[1]:'';const TEXT=decodeURIComponent('$enc');const st=encodeURIComponent(JSON.stringify({appId:100,platform:5,version:'2.0'}));const body='oid=$($Item.oid)&type=1&root=$($Item.root)&parent=$($Item.root)&message='+encodeURIComponent(TEXT)+'&csrf='+csrf+'&plat=1&ordering=heat&gaia_source=main_web&statistics='+st;return fetch('https://api.bilibili.com/x/v2/reply/add',{method:'POST',credentials:'include',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:body}).then(r=>r.json()).then(j=>JSON.stringify({code:j.code,msg:j.message,rpid:(j.data&&j.data.rpid)||0}));})()"
    $out = Invoke-BskTab $SessionId $TabId @("evaluate", $js)
    $m = [regex]::Match($out, '\{.*\}', 'Singleline')
    if (-not $m.Success) { return [pscustomobject]@{ ok = $false; msg = "接口无响应: " + ($out -replace "`r?`n", " ").Trim() } }
    try {
        $r = $m.Value | ConvertFrom-Json
        if ($r.code -eq 0) {
            # 复查：接口说成功，但匿名看不到就算被吞了
            $rpid = [string]$r.rpid
            Start-Sleep -Seconds 2
            $verifyJs = "fetch('https://api.bilibili.com/x/v2/reply/reply?oid=$($Item.oid)&type=1&root=$($Item.root)&ps=20&pn=1',{credentials:'omit'}).then(r=>r.json()).then(j=>JSON.stringify({code:j.code,found:((j.data&&j.data.replies)?j.data.replies:[]).some(x=>String(x.rpid)==='$rpid')}))"
            $vout = Invoke-BskTab $SessionId $TabId @("evaluate", $verifyJs)
            $vm = [regex]::Match($vout, '\{.*\}', 'Singleline')
            $vcode = -1
            $found = $false
            if ($vm.Success) { try { $v = $vm.Value | ConvertFrom-Json; $vcode = $v.code; $found = [bool]$v.found } catch { } }
            if ($found) { return [pscustomobject]@{ ok = $true; msg = "ok（匿名可见）" } }
            if ($vcode -eq 0) { return [pscustomobject]@{ ok = $false; msg = "发出去了但匿名看不到（rpid $rpid，被风控影子隐藏）" } }
            return [pscustomobject]@{ ok = $true; msg = "ok（匿名复查不可用 code=$vcode，未验证公开性）" }
        }
        return [pscustomobject]@{ ok = $false; msg = "$($r.code) $($r.msg)" }
    } catch { return [pscustomobject]@{ ok = $false; msg = "返回无法解析" } }
}

# ---------- 状态模式 ----------
if ($ShowStatus) {
    if (Test-Path $StateFile) { Get-Content $StateFile -Raw -Encoding UTF8 } else { "（还没有状态文件）" }
    "--- 最近日志 ---"
    if (Test-Path $LogFile) { Get-Content $LogFile -Tail 15 -Encoding UTF8 }
    "--- 最近回复 ---"
    if (Test-Path $ReplyLog) { Get-Content $ReplyLog -Tail 10 -Encoding UTF8 }
    exit 0
}

# ---------- 安装计划任务 ----------
if ($InstallTask) {
    $scriptPath = $MyInvocation.MyCommand.Path
    $tr = "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File $scriptPath"
    & schtasks.exe /Create /TN $TaskName /SC MINUTE /MO 1 /TR $tr /F
    Write-Log "已安装计划任务 $TaskName（1 分钟一轮 + 脚本内 30 秒补检）"
    "计划任务 $TaskName 已安装：1 分钟一轮，配合脚本内的 -SecondPass 补检等于 30 秒一次。"
    exit 0
}

# ---------- 测试推送 ----------
if ($Test) {
    $stamp = Get-Date -Format 'MM-dd HH:mm'
    & $WechatSend "【测试】B站 @ 看门狗已上线（$stamp）。以后主人一 @ 我，我会自己看视频、自己回，然后告诉你回了什么。" 2>&1 | Out-String | Write-Output
    Write-Log "TEST 推送，退出码 $LASTEXITCODE"
    exit 0
}

# ---------- 主流程 ----------
# 配置没填 UID 就别默默跑：否则每条通知都会被判成「不是主人发的」而静默跳过
# 最常见的成因：配置文件存成了不带 BOM 的 UTF-8，PowerShell 5.1 按 GBK 读，注释里的中文把文件解析坏掉
if (-not $OwnerMid -or -not $SelfMid) {
    Write-Log "配置无效：OwnerMid=$OwnerMid SelfMid=$SelfMid —— 检查 watch-at.config.ps1（必须是 UTF-8 with BOM）"
    Write-Output "配置无效：请在 watch-at.config.ps1 里填好 OwnerMid / SelfMid，并确认文件存成 UTF-8 with BOM。"
    exit 1
}
$state = Read-State
Write-Log "检查开始"

# 1) daemon 在不在
$daemonOut = Invoke-Bsk @("status", "--json")
if ($daemonOut -notmatch 'running|"ok":\s*true|daemon') {
    Start-Process -FilePath $Bsk -ArgumentList "daemon", "start" -WindowStyle Hidden
    Start-Sleep -Seconds 12
    $daemonOut = Invoke-Bsk @("status", "--json")
}

# 2) 浏览器连没连上
$browsers = Invoke-Bsk @("browsers", "--json")
$browserOk = if ($Browser) { $browsers -match $Browser } else { $browsers -match '"instance_id"' }
if (-not $browserOk) {
    Write-Log "跳过：没有可用的浏览器连接（Chrome 没开？）"
    exit 0
}

# 3) 上一轮还在跑就别碰浏览器（避免两个实例抢同一个标签页）
if (Test-Path $LockFile) {
    $age = (Get-Date) - (Get-Item $LockFile).LastWriteTime
    if ($age.TotalMinutes -lt $LockStaleMin) {
        Write-Log "跳过：上一轮还在跑（锁 $([math]::Round($age.TotalMinutes,1)) 分钟）"
        exit 0
    }
    Remove-Item $LockFile -Force -ErrorAction SilentlyContinue
}

# 4) 会话（没有就开一个，记住 id 复用）
$sessionId = Get-SessionId $state
if (-not $sessionId) {
    Write-Log "跳过：拿不到 bsk 会话"
    exit 0
}
if ($sessionId -ne $state.session) { Set-StateProperty $state "session" $sessionId; Save-State $state }

# 5) 抓 @ 列表：标签页已经在 B站就免导航（30 秒一轮时这一步很关键）
$tabId = ""
$items = $null
$hostNow = Invoke-Bsk @("evaluate", "--session", $sessionId, "location.hostname")
if ($hostNow -match 'bilibili\.com') { $items = Get-AtItems $sessionId "" $state }
if ($null -eq $items) {
    $tabId = Get-BiliTab $sessionId
    Start-Sleep -Milliseconds 800
    $items = Get-AtItems $sessionId $tabId $state
}
if ($null -eq $items) {
    # 先原地多等一会儿再试（新开的 Agent Window 要时间就绪）
    Start-Sleep -Seconds 6
    $tabId = Get-BiliTab $sessionId
    Start-Sleep -Milliseconds 1000
    $items = Get-AtItems $sessionId $tabId $state
}
if ($null -eq $items) {
    # 还是不行：换一个会话（旧的可能真坏了）
    Write-Log "取数失败，换一个 bsk 会话重试"
    Invoke-Bsk @("session", "stop", $sessionId) | Out-Null
    Start-Sleep -Seconds 2
    Set-StateProperty $state "session" ""
    Save-State $state
    $sessionId = Get-SessionId $state
    if ($sessionId) {
        Set-StateProperty $state "session" $sessionId
        Save-State $state
        $tabId = Get-BiliTab $sessionId
        Start-Sleep -Milliseconds 800
        $items = Get-AtItems $sessionId $tabId $state
    }
}
if ($null -eq $items) {
    Write-Log "跳过：接口没取到数据（登录态可能过期）"
    exit 0
}

# 6) 接口回 0 条 = 可疑（多半被限流或抖动）：去「@ 我的」页面刷一下再问一次
if ($items.Count -eq 0) {
    Write-Log "接口返回 0 条，切到消息中心刷新后重试"
    Invoke-Bsk @("navigate", "--session", $sessionId, "https://message.bilibili.com/#/at", "--wait-until", "domcontentloaded", "--quiet") | Out-Null
    Start-Sleep -Seconds 3
    $items = Get-AtItems $sessionId "" $state
    if ($null -eq $items -or $items.Count -eq 0) { Write-Log "接口仍然 0 条，本轮跳过"; exit 0 }
}

# 7) 白名单：只留「主人 @ 了我」
$ownerItems = @($items | Where-Object { $_.mid -eq $OwnerMid -and ($_.ats -contains $SelfMid) })
if ($ownerItems.Count -eq 0) { Write-Log "无主人 @（本轮共 $($items.Count) 条通知）"; exit 0 }

$maxT = ($ownerItems | Measure-Object -Property t -Maximum).Maximum

# 7) 首次运行：只设基准
if ($Init -or $state.cursor -eq 0) {
    Set-StateProperty $state "cursor" $maxT
    Set-StateProperty $state "seen" @($ownerItems | ForEach-Object { [string]$_.id })
    Set-StateProperty $state "last_check" (Get-Date).ToString('s')
    Save-State $state
    Write-Log "初始化基准 cursor=$maxT（积压 $($ownerItems.Count) 条不处理）"
    exit 0
}

# 8) 新通知（从旧到新）
$new = @($ownerItems | Where-Object { $_.t -gt $state.cursor -and ($state.seen -notcontains [string]$_.id) } | Sort-Object t)
Set-StateProperty $state "last_check" (Get-Date).ToString('s')
if ($new.Count -eq 0) {
    Save-State $state
    if (-not $SecondPass) {
        # 计划任务最快只能 1 分钟一轮：自己再补一次 30 秒后的检查，凑成 30 秒节拍
        Start-Process -FilePath "powershell.exe" -WindowStyle Hidden -ArgumentList "-NoProfile", "-WindowStyle", "Hidden", "-ExecutionPolicy", "Bypass", "-File", $MyInvocation.MyCommand.Path, "-SecondPass"
        Write-Log "无新 @，30 秒后再看一次"
        exit 0
    }
    Write-Log "无新 @（cursor=$($state.cursor)）"
    exit 0
}

# ---------- 9a) 自动回复分支 ----------
if ($AutoReply -and -not $NoReply) {
    $item = $new[0]                      # 一次只回最旧的一条
    "pid=$PID  item=$($item.id)  $(Get-Date -Format s)" | Set-Content -Path $LockFile -Encoding UTF8
    $result = "unknown"
    $text = ""
    $clock = [Diagnostics.Stopwatch]::StartNew()
    try {
        Write-Log "自动回复开始：《$($item.title)》"

        if ($state.last_reply -gt 0) {
            $since = ((Get-Date).ToUniversalTime() - ([datetime]::SpecifyKind([datetime]'1970-01-01', [DateTimeKind]::Utc)).AddMilliseconds([double]$state.last_reply)).TotalMinutes
            if ($since -lt $RateLimitMin) {
                $wait = [int](($RateLimitMin - $since) * 60)
                Write-Log "限速：等 $wait 秒"
                Start-Sleep -Seconds $wait
            }
        }

        $video = Get-Transcript $item
        Write-Log "  取文字稿 $([int]$clock.Elapsed.TotalSeconds)s"
        if ($null -eq $video) {
            $result = "取文字稿失败"
            Write-Log "自动回复失败：$result"
        } elseif ($video.duration -gt ($MaxVideoMin * 60)) {
            $result = "视频 $([int]($video.duration/60)) 分钟，超过保险丝"
            Write-Log "自动回复跳过：$result"
        } else {
            $text = New-ReplyText $item $video
            Write-Log "  写评论 $([int]$clock.Elapsed.TotalSeconds)s"
            if (-not $text) {
                $result = "写评论失败或跑偏"
                Write-Log "自动回复失败：$result"
            } else {
                $sent = Send-BiliReply $sessionId $tabId $item $text
                if ($sent.ok) {
                    $result = "ok"
                    Set-StateProperty $state "last_reply" ([long](([datetime]::UtcNow - [datetime]::SpecifyKind([datetime]'1970-01-01', [DateTimeKind]::Utc)).TotalMilliseconds))
                    Write-ReplyLog "OK 《$($item.title)》`r`n$text`r`n---"
                    Write-Log "自动回复成功：《$($item.title)》（共 $([int]$clock.Elapsed.TotalSeconds)s）"
                } else {
                    $result = $sent.msg
                    Write-ReplyLog "FAIL 《$($item.title)》 $($sent.msg)`r`n$text`r`n---"
                    Write-Log "自动回复失败：$($sent.msg)"
                }
            }
        }
    } catch {
        $result = "异常 $($_.Exception.Message)"
        Write-Log "自动回复异常：$($_.Exception.Message) @ line $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())"
    } finally {
        Remove-Item $LockFile -Force -ErrorAction SilentlyContinue
        # 走之前把标签页挪回首页，别让刚看的视频在后台一直播
        Invoke-Bsk @("navigate", "--session", $sessionId, $HomePage, "--wait-until", "domcontentloaded", "--quiet") | Out-Null
    }

    Set-StateProperty $state "cursor" $item.t
    Set-StateProperty $state "seen" @($state.seen + [string]$item.id)
    Save-State $state

    if ($result -eq "ok") {
        & $WechatSend "已自动回复《$($item.title)》：$text" 2>&1 | Out-Null
    } else {
        $failMsg = "自动回复没成功（$result）：《$($item.title)》 $($item.url) —— 你说一声我就手动回。"
        & $WechatSend $failMsg 2>&1 | Out-Null
    }
    exit 0
}

# ---------- 9b) 仅通知分支 ----------
if ($new.Count -eq 1) {
    $n = $new[0]
    $text = "主人 @ 你了：《$($n.title)》 他说：$($n.text) 链接：$($n.url) （想让我去回，就说「回这条」）"
} else {
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("主人 @ 了你 $($new.Count) 条：")
    $i = 1
    foreach ($n in $new) {
        [void]$sb.Append("$i.《$($n.title)》 他说：$($n.text) 链接：$($n.url) ")
        $i++
    }
    [void]$sb.Append("（说「回第几条」我就去回）")
    $text = $sb.ToString()
}

& $WechatSend $text 2>&1 | Out-String | Write-Output
$code = $LASTEXITCODE
if ($code -eq 0 -or $code -eq 3) {
    Set-StateProperty $state "cursor" ($new | Measure-Object -Property t -Maximum).Maximum
    Set-StateProperty $state "seen" @($state.seen + ($new | ForEach-Object { [string]$_.id }))
    Set-StateProperty $state "last_push" (Get-Date).ToString('s')
    Save-State $state
    Write-Log "推送 $($new.Count) 条（退出码 $code，cursor=$($state.cursor)）"
} else {
    Save-State $state
    Write-Log "推送失败退出码 $code，下轮重试"
}
exit 0
