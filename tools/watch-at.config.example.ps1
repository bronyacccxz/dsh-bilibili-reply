# 复制成 watch-at.config.ps1，再按本机情况改（这个文件不会被提交）
# 它是「覆盖」用的：只写你要改的那几行也行，其余保持 watch-at.ps1 里的默认值

# ---- 可执行文件：不在 PATH 里就必须写绝对路径 ----
$Bsk        = "C:\path\to\bsk.exe"                     # BrowserSkill CLI
$NodeDir    = "C:\path\to\node\bin"                    # 只为让 dsh-wechat-send 找到 node；不需要就留空
$WechatSend = Join-Path $DshHome "profiles\desktop\node_modules\.bin\dsh-wechat-send.CMD"
$Dsh        = "C:\path\to\dsh.cmd"                     # DeepSeek Harness CLI（-InstallTask / headless 用）
$Py         = "C:\path\to\python.exe"                  # 跑 video-watch 的 python
$VideoWatch = Join-Path $DshHome "skills\video-watch"   # video-watch 技能目录

# ---- 账号与浏览器 ----
$Browser    = ""              # 留空 = 用唯一连接的那个浏览器；有多个就填 instance id（bsk browsers）
$OwnerMid   = 0               # 主人的 B站 UID（https://api.bilibili.com/x/web-interface/nav 里 data.mid）
$SelfMid    = 0               # 机器人账号 UID（就是被 @ 的那个号）

# ---- 计划任务 ----
$TaskName   = "DSH-BiliAtWatch"

# ---- 可选：覆盖脚本里的其它阈值 ----
# $AutoReply     = $true      # 关掉就只通知、不自动回复
# $RateLimitMin  = 3          # 两次回复最小间隔（分钟）
# $LockStaleMin  = 45         # 锁过期（分钟）
# $MaxVideoMin   = 60         # 超过这个时长的视频只通知不自动回
