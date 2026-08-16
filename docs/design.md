# DSH Remote 设计系统（design.md）

> **新功能、新组件、新页面动工前必读。** 本文件是本项目唯一的视觉真相源；
> 实现细节以 `lib/ui/theme.dart`（NekoTheme）为准，本文档解释「为什么这么定」与「怎么用」。

## 1. 设计立场

DSH Remote 是一只「住在手机里的猫娘搭档」——它首先是个**生产力工具**（聊天、审批、管理会话），
其次才是可爱的。所以我们的风格是：

**「清新的粉彩工具」——动漫气质通过签名元素和配色点到为止，信息层级永远优先于装饰。**

反例（明确不要）：
- 不要大面积渐变、描边发光、斜切角等「花哨二次元」
- 也不要冷淡到只剩黑白灰的「极简克制」
- 我们取中间态：柔和的冷白底 + 奶蓝/樱粉双色点睛 + 少量薄荷绿状态色

## 2. 设计令牌（Tokens）

### 色板（浅色 `NekoTheme.light`）

| 令牌 | 色值 | 用途 |
|---|---|---|
| `milkBlue` primary | `#5E9FD6` | 主操作（按钮、选中态、链接感） |
| `sakuraPink` secondary | `#F2A0B5` | 用户气泡、发送钮、强调点缀 |
| `mint` tertiary | `#7FC8A9` | 运行中/成功状态 |
| `creamBg` | `#F6F8FB` | 页面底色（scaffold） |
| `bubbleBlue` | `#EFF6FC` | 助手气泡底（浅色模式） |
| `bubblePink` | `#FCE9EF` | 用户气泡底 |
| `ink` onSurface | `#3E4756` | 正文 |
| `onSurfaceVariant` | `#66707F` | 次要文字、标签、图标（**文字用色的最低对比度基准**） |
| `outlineSoft` outline | `#C9D4E2` | **仅边框/分割线，禁止用作文字色** |
| error | `#D97A7A` | 错误（柔和的西瓜红，非刺眼正红） |

深色变体 `NekoTheme.dark`（暗夜粉彩）：`nightBg #252B38` 底、`nightBlue #8FC1E8`、
`nightPink #E8A2B6`——规则与浅色一一对应，禁止硬编码浅色色值进组件。

### 字阶

| 角色 | 规格 | 用途 |
|---|---|---|
| `displaySmall` | 30 / w800 / 字距 0.5 | 页面 hero（仅设置页首屏） |
| `titleLarge` | 19 / w700 | AppBar 标题 |
| `titleMedium` | 16 / w600 | 卡片/弹层标题 |
| `titleSmall` | 13 / w700 / 字距 0.4 | 分组节标题（全大写感、灰蓝色） |
| `bodyLarge` | 15.5 / 行高 1.55 | 聊天气泡正文 |
| `bodyMedium` | 14 / 1.5 | 列表主文字 |
| `bodySmall` | 12 / 1.45 | 次要说明（onSurfaceVariant） |

字体保持系统默认（中文渲染最稳），性格靠**字重与字距**而非更换字体。

### 形状与间距

- 圆角阶梯：chip/小标签 20（全圆角）→ 气泡/输入框 18~24 → 卡片 18 → 页面容器 14
- 卡片**零阴影**，用 `outlineVariant` 1px 描边分层（深色模式下同理）
- 页面水平边距 12~16；列表项内边距垂直 8~10；节间距 16

## 3. 签名元素（唯一的记忆点，别处保持安静）

1. **NekoHero**（`assets/splash/neko_companion_1024.png` 猫娘主视觉）：
   与启动图、应用图标保持同一角色。用于**主机选择页的空状态 hero**
   （多主机改造后原独立连接页已移除，hero 落在新首页的空态邀请上）。
   必须使用明确的正方形尺寸约束，禁止随页面宽度拉伸或遮挡标题。
2. **NekoMascot**（`theme.dart` 的 CustomPainter 线稿猫脸 + 腮红）：
   只用于**空状态**（空列表、空会话），不再用于连接页 hero 或常规列表项。
3. **猫耳用户气泡** `CatEarBubbleShape`：用户消息右上顶出小三角耳。
4. **PawIcon 爪印**：仅用于**主发送钮**与设置页「连接」主按钮。
5. 色彩点缀本身也是签名：用户=樱粉、助手=奶蓝、运行中=薄荷。

> 新增签名元素需要修改本文件并说明理由。Chanel 规则：做完设计后删掉一处装饰再提交。

## 4. 组件模式（写新 UI 时从这里抄）

| 场景 | 模式 |
|---|---|
| 页面骨架 | `Scaffold` + 无阴影 AppBar（底色 = scaffold 底色）+ `titleLarge` 左对齐标题 |
| 卡片 | `Card`（主题已定为零阴影+圆角+描边）或直接 `Container` 用同样规则 |
| 列表分组 | `_SectionHeader` 式 `titleSmall` 节标题 + 圆角 ListTile |
| 次级操作入口 | 右上角 ⋮ `PopupMenuButton`；批量操作用长按 + bottom sheet |
| 底部弹层 | `showModalBottomSheet` + `showDragHandle: true` + `SafeArea` |
| 可折叠内容 | `_Collapsible` 模式：小图标 + w600 标签 + expand 箭头，图标/文字一律 `onSurfaceVariant` |
| 空状态 | NekoMascot(72~88) + 一句行动指引 + 主按钮 |
| 错误 | `errorContainer` 卡片，直接说明原因与修复动作，不道歉 |
| 状态点 | 8px 圆点 + 12px 文字，颜色语义：mint=正常、secondary=过渡中、error=失败 |
| 主按钮 | `FilledButton`（圆角 24）；图标按钮用 `IconButton.filled` + secondary 底 |

## 5. 内容语气（Copy）

- 面向「主人在使用手机」：动作词开头（「新建会话」「选择此目录」），不堆术语
- 错误信息说「发生了什么 + 怎么修」，例：「连接失败：无法访问 10.x.x.x:3081。确认 relay 已启动且手机在同一 Wi-Fi。」
- 空状态是邀请：「还没有会话，去发起第一段对话吧」
- 中文界面；技术标识符（方法名、路径）保持英文原文
