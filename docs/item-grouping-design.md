# 历史条目分组显示（Grouping）设计方案

> 状态：设计稿，未实现。对应需求：同一个网站的多个账号/密码希望在弹窗列表中聚在一起显示，并带有统一标签。

## 需求场景

- 某些网站有多个登录账号（用户名+密码分别复制），希望这些条目在列表中相邻显示。
- 分组有一个统一的名字（tag），例如「GitHub」「公司OA」。
- 与置顶（pin）、敏感掩码（isSensitive）两个功能兼容。

## 数据模型

在 `HistoryItem`（`Maccy/Models/HistoryItem.swift`）上增加一个持久化字段即可，与 `pinOrder`/`isSensitive` 的加法一致（SwiftData 轻量迁移自动完成）：

```swift
// Optional group label, e.g. "GitHub". Items sharing the same label are
// sorted together in the popup list.
var groupName: String? = nil
// Manual ordering inside a group, mirroring pinOrder.
var groupOrder: Int = 0
```

为什么用字符串而不是单独的 Group 表：
- 单表最简单，分组名即标签，搜索、去重、删除都是纯字符串操作，与 Maccy 现有「无实体关系」的模型风格一致。
- 后续若需要分组级元数据（颜色、排序），再升级为 `@Model class ItemGroup`，通过 `groupName` 迁移即可。

## 排序

`Sorter.byPinned`（`Maccy/Sorter.swift`）扩展为三级比较：

1. 置顶项永远在最前（或最后，取决于「Pin to bottom」设置），置顶项之间按 `pinOrder`。
2. 非置顶项中，**有分组的排在无分组之前**，同组按 `groupName` 字母序 + `groupOrder`。
3. 无分组条目保持现有排序算法（最近复制时间等）不变。

新增 `item.groupName` 不参与去重判断（`supersedes` 不看分组），复制新条目时若与旧条目内容相同，在 `History.add` 的去重合并里补一行 `item.groupName = existingHistoryItem.groupName`（与 `pinOrder` 的合并写法相同）。

## UI

### 弹窗列表（主要工作量）

- `HistoryItemDecorator` 增加 `groupName` 透出。
- 分组**头部行**：工程里已有 `Views/ListHeaderView.swift`（当前用于置顶/历史分隔标题），复用它渲染组名行，样式用 `.secondary` 小字号 + 分组条目数量。
- `HistoryListView` / `MultipleSelectionListView` 目前是平铺 List。两种实现路径：
  1. **推荐**：保持平铺数据源，在 `History.items` 组装时插入「分组头」伪条目（新的轻量 Decorator 或 enum 包装），键盘导航跳过分组头。改动集中在列表数据组装处，风险最小。
  2. 彻底改为 `List { Section }`：结构更正统，但会重写键盘导航（`NavigationManager`）、多选（`Selection`）、滚动定位等大量逻辑，不建议第一步就做。

### 分组的创建/编辑入口

- 设置窗口新增「Groups」设置页，或直接放进现有 Pins 页：表格列出所有分组名及组内条目，支持重命名（重命名即批量更新所有成员的 `groupName`）、删除分组（成员变回普通条目，不删数据）。
- 弹窗工具栏（ToolbarView）在选中条目后增加「移入分组」按钮：点选后在弹出的菜单中选择已有分组或新建分组。
- 快捷方式：粘贴一个新条目时自动入组不做（无法可靠判断属于哪个网站），全部手动归组。

### 与搜索的交互

- `Search` 目前搜 `decorator.title`。扩展为同时匹配 `groupName`，这样输入「GitHub」能列出整组账号（掩码条目仍显示圆点，不泄露内容）。
- 搜索结果中分组头隐藏（结果平铺），与置顶项在搜索时的表现一致。

## 实施步骤（建议 3 个 PR 量级）

1. 模型加 `groupName`/`groupOrder` + Sorter 排序规则 + 去重合并保留分组（纯数据层，易测试）。
2. Pins/Groups 设置页 CRUD + 工具栏「移入分组」。
3. 弹窗列表分组头渲染 + 键盘导航跳过 + 本地化。

## 与本阶段两个功能的关系

- 分组复用本次引入的两个模式：持久化整数字段做手动排序（`pinOrder` 的做法 → `groupOrder`），以及显示层装饰不改动真实内容（掩码的做法 → 分组头也是纯显示）。
- 掩码条目入组后：组头显示组名，成员行仍显示 `displayTitle`（别名或圆点），预览面板仍需点眼睛才显示。
