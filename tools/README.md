# 看门狗（tools/）—— 让技能自己盯着

**发现 + 自动回复。** 一有人 @ 你，脚本自己看视频、自己写评论、自己发出去，然后用微信告诉你回了什么。

## 节拍：每 30 秒一次

Windows 计划任务的最小重复间隔是 **1 分钟**（`PT30S` 会被拒），所以设计成
**任务每 1 分钟一轮 + 脚本内补一次 30 秒后的检查**（`-SecondPass`），合起来等于 30 秒一次。

**检查成本 0 token**：脚本直接在已登录的浏览器里调 B 站接口，模型完全不参与；
只有真要回复时才会叫一次模型。标签页已经在 B 站域内时不会刷新页面，一轮开销 = 一次接口请求。

## 一次运行做什么

```
① 检查（0 token）     bsk 在登录着的浏览器里 fetch /x/msgfeed/at
② 白名单筛选          user.mid == $OwnerMid 且 at_details 含 $SelfMid
③ 有新 @ 且没在忙     → 抓最旧的那一条（一次只回一条，多条自然排队）
④ 看视频              video-watch：下载 → 转写；歌曲类自动 --no-vad；
                      没台词的短片会把 3 张抽样帧交给模型自己看
⑤ 写评论              dsh --profile headless 按 prompt-last.txt 写一条
⑥ 发出去              先切到那条视频页（Referer 要对），再 POST /x/v2/reply/add
⑦ 复查可见性          用匿名请求再拉一次列表，看不到就算失败（防影子隐藏）
⑧ 收尾                标签页挪回首页（别让视频在后台一直播），微信告诉主人回了什么
```

## 快速开始

```powershell
cd <技能目录>\tools
Copy-Item watch-at.config.example.ps1 watch-at.config.ps1   # 填路径、$OwnerMid、$SelfMid

.\watch-at.ps1 -Init          # 首次接入：把当前最新一条设为基准，历史积压不处理
.\watch-at.ps1 -Test          # 给微信发一条测试消息，验证通道
.\watch-at.ps1 -InstallTask   # 安装计划任务（1 分钟一轮 + 脚本内 30 秒补检）
.\watch-at.ps1 -ShowStatus    # 看状态、最近日志、最近回复
.\watch-at.ps1 -NoReply       # 临时只通知、不自动回复
```

> `-InstallTask` 会让计划任务指向当前脚本的绝对路径。路径里有空格就自己用
> `schtasks /Create /TN <名字> /SC MINUTE /MO 1 /TR "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File \"<路径>\"" /F` 建。

## 文件

| 文件 | 作用 |
|---|---|
| `watch-at.ps1` | 看门狗本体 |
| `watch-at.config.example.ps1` | 配置模板：复制成 `watch-at.config.ps1` 再填（那份不进版本库） |
| `at-state.json` | 运行状态：游标 cursor、已处理 id、复用的 bsk 会话、上次回复时间 |
| `watch-at.log` | 运行日志（含各阶段耗时与失败原因） |
| `replies.log` | 每条自动回复的正文存档 |
| `prompt-last.txt` | 最近一次给模型看的提示词（含文字稿），排障用 |
| `reply.lock` | 正在回复的锁，防两个实例抢同一个标签页 |

## 踩过的坑（都已在脚本里修掉）

1. **计划任务里 PowerShell 5.1 会用 GBK 解码原生命令输出** —— 没有控制台时，
   bsk 吐出的 UTF-8 JSON 被拆坏，症状是「取数失败」，但手动跑又好好的（手动跑的控制台是 UTF-8）。
   ✅ 所有原生命令改成**重定向到文件 + 按 UTF-8 读**。
2. **发表评论必须像网页客户端** —— 从首页直调接口、只带基本参数时，B 站返回 `code 0`、
   自己看得见、**别人看不见**（风控影子隐藏）。✅ 先 `navigate` 到那条视频页再发，并补上
   `plat=1&ordering=heat&gaia_source=main_web&statistics={appId:100,platform:5,version:"2.0"}`。
3. **发布后必须复查** —— 用匿名请求（`credentials:'omit'`）再拉一次，看不到就判失败并推送告警。
4. **长提示词不能走管道喂 `dsh headless`** —— `.cmd` 会把长参数弄坏，模型收到残缺任务后
   会去读工作区文件、写出一段与视频无关的废话。✅ 只传一句短指令，让它自己读 `prompt-last.txt`。
5. **新开的 bsk 会话要几秒才就绪** —— 建完立刻用必然失败。✅ 建完等 6 秒；取数失败先原地重试，再换会话。
6. **空转写文件读出来是 `$null`** —— 无台词的短片，`transcript.txt` 是 0 字节，
   `Get-Content -Raw` 返回 null，后面 `.Trim()` 直接抛异常。✅ 读出来补成空串。
7. **时间戳要 `SpecifyKind(Utc)`** —— 否则 `[datetime]'1970-01-01Z'` 被当成 +08:00，限速判断差 8 小时。

## 规则与阈值（都在 `watch-at.ps1` 开头，可被配置文件覆盖）

| 项 | 默认 | 说明 |
|---|---|---|
| `$OwnerMid` / `$SelfMid` | 必填 | 白名单：只回这个人，且被 @ 的必须是机器人账号 |
| `$AutoReply` | `$true` | 关掉就只通知、不自动回复 |
| `$RateLimitMin` | 3 分钟 | 两次回复的最小间隔 |
| `$LockStaleMin` | 45 分钟 | 锁过期时间（长视频转写可能很久） |
| `$MaxVideoMin` | 60 分钟 | 超过就只通知、不自动回 |
| `$MaxReplyChars` | 900 | B 站评论上限约 1000 |
| `$MaxTranscript` | 8000 字符 | 超长文字稿截断后再给模型 |

## 已知限制

- **浏览器要开着**；没开只写一行日志就退出，不会误报。
- 关机/睡眠期间的 @ 会在下次开机后按游标补上（一次只回一条）。
- **微信配额**：一个回复窗口 10 条，每条回复只推 1 条；被拒（退出码 3）会排队，下次说话时补发。
- **登录态过期**：日志出现「接口没取到数据」；重新登录即可。
- **成本**：检查 0 token；每条回复一次 headless 会话（约 5～8k 输入 token）。
