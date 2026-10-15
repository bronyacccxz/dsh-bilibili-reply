# bilibili-reply

[English](README.en.md)

一个 **AI Agent 技能**：让 AI 读懂你在 B 站 @ 它的视频，然后回你一条**带可跳转时间戳**的评论。

```
你 @ 一个视频  →  AI 本地看懂视频（文字稿 + 关键画面）  →  生成回复  →  自动发到你的评论区
```

## 它解决什么

普通 AI 没法处理「B 站 @ 通知 + 视频内容」这条链路：

- @ 通知里**只有评论文字，没有视频链接** —— 得先找到是哪个视频
- 视频内容**得先看懂** —— 需要转文字 + 看关键画面
- 回复**要发在对的地方** —— 发错位置对方收不到通知

这个技能把整条链路固定下来，并踩平了几个真实的坑。

---

# ⚠️ 前置条件（必读）

**这个技能不是装进任何 AI 就能用。** 它需要「AI 能操控一个已登录 B 站的浏览器」——**没有这一条，技能完全无法工作**（读不到 B 站，也发不了评论）。

| # | 前置 | 说明 | 链接 |
|---|---|---|---|
| 1 | **DeepSeek Harness（DSH）** | 技能运行在它的 Agent 上 | <https://github.com/deepseek-ai/deepseek-harness> |
| 2 | **pnpm** | DSH 用它管理插件 | <https://pnpm.io/installation> |
| 3 | **浏览器自动化**（关键） | 让 AI 能操作浏览器 —— 见下 | <https://github.com/Tencent/BrowserSkill> |
| 4 | **`video-watch` 技能** | 负责视频理解 | 见它的 README |

## 第 3 项：装浏览器自动化

推荐 **[BrowserSkill](https://github.com/Tencent/BrowserSkill)** —— 腾讯开源的浏览器自动化，⭐ 8.8k，MIT 许可。它提供 `bsk` CLI + 浏览器扩展，**让 AI 用你真实的、已登录的浏览器**，而不需要另开一个干净会话重新登录。

> **本项目实际使用的就是这一套。** 这是 monorepo，我们装的 DSH 插件是其中一个子包：
> - 仓库主页：<https://github.com/Tencent/BrowserSkill>
> - **DSH 插件子目录（含插件自己的 README）**：<https://github.com/Tencent/BrowserSkill/tree/main/packages/dsh-plugin-browserskill>
> - npm 包名：`@wxg-prc-cpg/browser-skill-dsh-plugin`

```text
① 按 BrowserSkill 的快速开始装 bsk CLI
   https://github.com/Tencent/BrowserSkill#quick-start

② 在 Chrome 或 Edge 里安装并连接 BrowserSkill 扩展

③ 确保 bsk 在「启动 dsh 时的 PATH」里
   —— 不在也行，稍后在插件配置里写 bskPath 绝对路径

④ 把 DSH 插件装进你的 profile（desktop / web 按你的实际用）
   dsh plugin --profile web add @wxg-prc-cpg/browser-skill-dsh-plugin
   dsh --profile web
```

**验证装好了**：在 DSH 对话里说

```text
/browser-skill 打开 bilibili.com 并总结页面
```

能返回页面内容 → 前置通了。

> **换别的浏览器自动化也可以。** 本技能需要的是「读页面 / 点击 / 填表单」这几样能力；`SKILL.md` 里的示例按 `browser_*` 工具写，换成你手上的工具即可，**流程逻辑不变**。

## 第 4 项：装 video-watch

本技能**依赖 `video-watch` 技能**做视频理解（本地转写 + 抽帧，不传云端）。请先按它自己的 README 装好：ffmpeg、faster-whisper 等。

> 它是独立项目，不随本仓库分发。搜索 `video-watch` 技能，或找提供该技能的 DSH 插件包安装。

---

# 快速开始（完整流程）

```text
① 装好上面 4 个前置
② git clone <本仓库地址> <DSH_HOME>/skills/bilibili-reply
③ cp config.example.md config.md   →  填写你的昵称和机器人账号
④ 在浏览器里登录你的 B 站账号（建议小号 —— 技能会用它发言）
⑤ 用主号在某个视频下发一条评论并 @ 那个小号
⑥ 对 AI 说：「我@你了，去看看」
⑦ 观察它：读通知 → 核对身份 → 分析视频 → 回评论
```

**第 ③ 步不能省** —— 技能靠昵称核对身份，没配就不知道该回谁。

---

## 功能

| 能力 | 说明 |
|---|---|
| **身份核对** | @ 列表里混着别人的通知；技能会逐项核对昵称，对不上就不回 |
| **视频理解** | 调 `video-watch`：本地转文字 + 抽帧，不传云端 |
| **按类型回复** | 教学类给**分章时间戳**；玩乐类给情绪反应；沉重内容克制处理 |
| **可跳转时间戳** | 用纯文本 `00:00` 格式，B 站会自动转成点击跳转 |
| **自动模式（可选）** | 自带看门狗脚本：每 30 秒自动检查 @，命中就自己看视频、自己回，再推微信告诉你 |

## 实际效果

**教学类视频 —— 分章时间戳：**

![教学类视频的时间戳回复](examples/01-timestamps.png)

**玩乐类视频 —— 一句短情绪，不带时间戳：**

![玩乐类短回复](examples/02-emotion.png)

*（截图里对方的昵称和头像已打码。）*

## 用法

对 AI 说：

> 我@你了，去看看

或者：

> 去 B 站看看最新那条 @，回一下

或者干脆让它自己盯着：

```powershell
cd tools
.\watch-at.ps1 -Init          # 首次接入：把当前最新一条设为基准
.\watch-at.ps1 -InstallTask   # 装计划任务，之后每 30 秒自己检查一次
```

装完之后你只要 @ 它，30 秒内它自己就回了 —— 检查不花模型 token，只有回复时才叫一次模型。

## 设计要点（踩过的坑）

这几条是真金白银换来的，都写进 `SKILL.md` 了：

| 坑 | 后果 | 现在的做法 |
|---|---|---|
| **盲取 @ 列表第一条** | 点错别人的视频、发错评论 | 逐项**核对昵称**，7 步清单 |
| **用视频顶部输入框回复** | 变成独立评论，**对方收不到通知** | 用通知里的「回复」按钮发内联回复 |
| **点用户名** | 跳到对方主页 | 点**评论文本** |
| **歌曲类视频转写 0 段** | AI 拿不到文字，只能硬读几十张图 → 又慢又烧钱 | 加 `--no-vad` 重跑（实测 0 段 → 57 段） |
| **猜抽帧文件名** | 读图直接失败 | 从 `frames.json` 的 `file` 字段取真实文件名 |

## 注意事项

- **会以你的身份在公开评论区发言。** 请确认内容得体。
- **建议用小号**，并遵守 `max_replies_per_hour` 之类的自设限制。
- **B 站有风控**：连发过多会弹验证码或接口返回 `-352`。别刷。
- 本技能**不做**云端音视频处理，全部本地。

## 目录结构

```
bilibili-reply/
├── SKILL.md            技能本体（AI 读这个）
├── config.example.md   配置模板 —— 复制成 config.md 并填写
├── tools/              自动模式：看门狗脚本 + 配置模板 + 说明（可选）
├── examples/           真实回复截图（已打码）
├── README.md           中文说明
├── README.en.md        English
└── LICENSE
```

## 许可

MIT，见 [LICENSE](LICENSE)。
