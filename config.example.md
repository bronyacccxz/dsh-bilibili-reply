# 配置模板

> **复制这个文件成 `config.md`，然后填下面的值。**
> `SKILL.md` 会读 `config.md`；没有它技能无法核对身份。

## 必须填

| 项 | 值 | 说明 |
|---|---|---|
| `owner_name` | `在这里填你的 B 站昵称` | **发 @ 的人**。通知里显示的昵称必须等于它，否则不回复。 |
| `self_name` | `在这里填机器人账号昵称` | **执行回复的账号**（建议小号）。 |
| `self_uid` | `在这里填机器人账号 UID` | 辅助核对，可选。 |

### 怎么拿这两个值

1. 在浏览器里登录**机器人账号**，打开 <https://www.bilibili.com> 确认右上角已登录
2. 打开 <https://api.bilibili.com/x/web-interface/nav>
3. 从返回的 JSON 里读：
   - `data.uname` → 填进 `self_name`
   - `data.mid` → 填进 `self_uid`
4. `owner_name` 填**你自己**的昵称（就是你会用来 @ 它、也会在上面发评论的那个号）

## 可选

| 项 | 值 | 说明 |
|---|---|---|
| `persona` | （留空） | 评论的语气。留空 = 中性友好。也可以指向你自己的人设文件。 |
| `video_watch_path` | （留空） | `video-watch` 技能目录的绝对路径。留空则按默认位置找。 |
| `max_replies_per_hour` | `3` | 自己给风控加的软限制，本技能会遵守。 |

## 填完长这样（示例）

```markdown
| owner_name | 我的B站昵称 |
| self_name  | reply-bot  |
| self_uid   | 12345678   |
| persona    | （留空）    |
```

---

## 核对用清单（技能每次回复前会走一遍）

```
① 打开 message.bilibili.com/#/at
② 找【最新一条】通知（看时间戳，不要盲取第一条）
③ 通知里的发 @ 人昵称 == owner_name ?
④ 点评论文本 → 跳转到视频
⑤ 视频评论区里那条评论的作者昵称 == owner_name ?
⑥ 评论里 @ 的账号 == self_name ?
⑦ 全部对上才回复
```
