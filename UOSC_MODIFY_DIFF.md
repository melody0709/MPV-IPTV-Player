# uosc 5.12 定制版修改记录

> 本文档记录了对官方 uosc 5.12 源码的所有修改点，用于后续升级时迁移。
> 官方源码：https://github.com/tomasklaen/uosc
> 基础版本：5.12.0

## 修改清单

### `scripts/uosc/main.lua`

| 修改点 | 位置 | 用途 |
|--------|------|------|
| `navigate_item_or_iptv_group` | `bind_command('next'/'prev')` 区域 | IPTV 播放时上下按钮走 epg 组内切台，普通文件保持原行为 |
| `expand-submenu` 消息处理器 | 文件末尾消息注册区 | 供 epg 在菜单已打开时动态展开指定子菜单 |
| `open-menu` 增强 | 文件末尾消息注册区 | 新增 `anchor_x` / `anchor_offset` 参数，控制菜单位置 |

### `scripts/uosc/elements/Menu.lua`

| 修改点 | 位置 | 用途 |
|--------|------|------|
| 菜单项 `subtitle` 字段 | 类型定义、尺寸计算、绘制区域 | 支持双行副标题（频道名下显示当前节目） |
| 菜单级 `subtitle_font_size` / `menu_min_width` | 类型定义、宽度计算 | 按菜单级别独立控制副标题字号和最小宽度 |
| 选中副标题跑马灯 | 类型定义、`get_subtitle_marquee_offset`、副标题绘制区域 | 菜单级 `subtitle_marquee` 开启后，仅选中且超宽的副标题横向滚动，切换条目重新计时 |
| 移除默认子菜单右箭头 | 菜单序列化初始化区域 | 去掉所有子菜单默认 `>` 箭头，减少视觉噪音 |
| 展开后居中滚动 | `activate_selected_item` 子菜单展开分支 | 展开后将 `selected_sub_index` 对应项滚动到可视中间 |
| 日期桶悬停交互增强 | 类型定义、宽度计算、悬停交互 | 新增 `no_hover_expand`/`no_hover_select`，新增 `menu_max_width` 锁定列宽 |
| 搜索框左对齐绘制 | Query/Placeholder 绘制区域 | 光标和文本从左对齐起点绘制，而非居中 |
| `search_items` 支持 `search_key` | `search_items` 函数 | 搜索时优先用 `search_key` 匹配，显示时用完整标题并正确高亮 |
| `activate_selected_item` 增强 | `activate_selected_item` 方法 | 优先执行 value（播放），同时保留子菜单可展开功能 |
| 禁用横向补间动画 | `activate_selected_item` 子菜单展开分支 | 分组/日期桶展开与返回父级改为无动画切换，消除抖动 |
| 键盘搜索转发 | `get_menu` 附近及搜索输入处理 | 新增 `get_search_target_menu`，支持子菜单将键盘输入转发到根菜单搜索框 |

### `scripts/uosc/elements/TopBar.lua`

| 修改点 | 位置 | 用途 |
|--------|------|------|
| 顶部标题追加 IPTV 频道信息 | `init` / `register_observers` / `update_render_titles` | 监听 epg 透出的 `is_iptv_active`/`current_group_name`/`current_channel_name`，在同一行追加"组名 > 频道名" |

### `scripts/uosc/lib/menus.lua`

| 修改点 | 位置 | 用途 |
|--------|------|------|
| `toggle_menu_with_items` 增强 | 文件开头 | `Menu:is_open()` 不传参数，确保任何类型菜单都能被正确关闭 |

## 升级迁移步骤

1. 备份当前 `scripts/uosc/` 目录
2. 用新版 uosc 覆盖 `scripts/uosc/`
3. 根据上方清单，在新版中找到对应函数/区域，重新应用修改
4. 用 `git diff scripts/uosc/` 对比确认所有修改点已迁移
5. 测试四级菜单、组内切台、EPG 搜索、顶部标题等功能
