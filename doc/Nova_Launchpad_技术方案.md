# Nova Launchpad — macOS 全屏应用启动器技术方案

版本：V1.0  
目标平台：macOS 26/27（以目标机器实际版本验证）  
技术栈：Swift 6、AppKit、Core Animation、NSCollectionView  
产品定位：免费、离线、原生、轻量的旧版 Launchpad 替代品

## 1. 项目目标

以 LaunchOS 的全屏网格和操作体验为参考，避免 LaunchMat 使用中遇到的卡顿；独立实现，不复制商业软件代码或素材。支持 Dock 一键显示、安装卸载应用自动更新、搜索、分页、排序与文件夹。无需登录、遥测、网络服务或常驻更新进程。

### 功能优先级

| 优先级 | 功能 | 验收要点 |
|---|---|---|
| P0 | 全屏应用网格 | 无独立 Space 的覆盖窗口，适配屏幕尺寸和刘海区域 |
| P0 | Dock 唤起 | 点击 Dock 图标打开，重复激活可关闭，单实例 |
| P0 | 应用发现与自动刷新 | 新装应用出现，卸载应用消失，不破坏自定义排序 |
| P0 | 搜索与启动 | 输入即筛选，回车启动，Esc 清除/关闭 |
| P0 | 分页与动画 | 触控板滑动、鼠标操作，流畅且不阻塞主线程 |
| P0 | 完全离线 | 无联网 SDK、统计或账号，运行时不主动请求网络 |
| P1 | 拖动排序 | 跨页拖动、保存布局、撤销异常拖动 |
| P1 | 文件夹 | 拖动创建、命名、移出、文件夹内排序 |
| P1 | 全局快捷键 | 可配置、冲突提示、可靠注册和注销 |
| P1 | 多显示器 | 在当前目标显示器显示，处理屏幕插拔 |
| P2 | 登录启动 | 使用系统支持的登录项机制 |
| P2 | 捏合手势 | 可选，先验证系统手势冲突和 API 可行性 |

## 2. 技术架构

- **入口与生命周期**：`NSApplicationDelegate`，单进程、单实例，应用常驻但窗口可隐藏。
- **窗口层**：AppKit `NSWindow` 或经测试合适的 `NSPanel`，无边框覆盖当前显示器；不调用 `toggleFullScreen()` 创建独立 Space。
- **网格层**：`NSCollectionView` + 自定义布局/Cell，按需创建视图、复用 Cell、局部更新。
- **动画层**：Core Animation，使用 `CALayer` 的 transform/opacity，避免主线程高频重排。
- **数据层**：`AppScanner`、`AppIndex`、`LayoutStore`、`IconCache`、`SearchIndex`。
- **系统接口**：`NSWorkspace`、Launch Services、FSEvents、`NSRunningApplication`；按可用性和文档选择公开 API。
- **持久化**：`Codable` + JSON，原子写入、版本迁移、损坏恢复。
- **诊断**：`OSLog`、可选本地性能指标；默认不上传任何数据。

### 建议目录

```text
NovaLaunchpad/
  App/
    AppDelegate.swift
    AppCoordinator.swift
  Window/
    LauncherWindowController.swift
    DisplayCoordinator.swift
  UI/
    AppGridViewController.swift
    AppCell.swift
    PageController.swift
    SearchController.swift
    FolderController.swift
  Services/
    AppScanner.swift
    AppWatcher.swift
    IconCache.swift
    SearchIndex.swift
    HotkeyManager.swift
  Models/
    AppRecord.swift
    LayoutModel.swift
  Storage/
    LayoutStore.swift
    SettingsStore.swift
  Tests/
    AppScannerTests.swift
    LayoutStoreTests.swift
    AppWatcherTests.swift
```

## 3. 关键设计

### 3.1 窗口与 Dock

- 窗口预创建、隐藏时保留实例；显示时刷新必要的视觉状态，而非重新扫描磁盘。
- 处理 Dock 激活事件、Esc、切换 App、点击外部区域以及屏幕/Space 变化。
- 使用公开的窗口层级和 `collectionBehavior`；在多显示器、全屏应用、Stage Manager、Mission Control 中逐项测试。
- Dock 图标保持正常可固定；如提供菜单栏模式，不要意外隐藏 Dock 图标。
- 背景优先使用轻量材质或缓存图像，避免每帧重新模糊整个屏幕。

### 3.2 应用发现和自动更新

扫描范围包括 `/Applications`、`/System/Applications`、`~/Applications`，并通过 Launch Services 补充注册的应用；外部磁盘按挂载状态处理。不能假定所有 App 都位于这些目录。

```swift
struct AppRecord: Codable, Identifiable {
    var id: String             // 持久稳定的内部 ID
    var bundleIdentifier: String?
    var displayName: String
    var bundlePath: String
    var isUserHidden: Bool
}
```

- Bundle ID 不保证唯一：同一 App 的多个副本、无 Bundle ID App、路径变化都要处理。
- `FSEvents` 监听主要目录，配合系统通知；事件合并、防抖约 300–800ms。
- 后台扫描后做差异比较，主线程仅应用增量 UI 更新。
- 卸载时自动移除无效图标，但布局中的其他项目和文件夹保持不变。
- 区分暂时不可用的外置磁盘与真正卸载，避免误删用户布局。
- 提供手动“重新扫描应用”入口作为兜底。

### 3.3 图标缓存与流畅度

- 图标通过 `NSWorkspace` 获取，缩放到目标尺寸后缓存。
- 使用 `NSCache` 控制内存，缓存键包含 App 标识、尺寸、必要的版本/修改信息。
- 图标解码、缩放在后台完成；仅在主线程更新可见 Cell。
- 预加载当前页及相邻页；禁止每次显示窗口时重新读取全部图标。
- 翻页使用层动画和轻量布局更新，避免全网格同步重建。
- 搜索使用预建索引，输入防抖仅在确有必要时启用。

### 3.4 排序、分页与文件夹

布局模型与应用索引分离，按页面、文件夹和有序 App ID 保存。拖动结束时才持久化；拖动过程中只更新必要 Cell。支持跨页边缘停留翻页、文件夹创建/解散、应用移出文件夹，以及布局文件版本迁移。

建议存储路径：

```text
~/Library/Application Support/NovaLaunchpad/layout.json
~/Library/Application Support/NovaLaunchpad/settings.json
```

写入采用临时文件 + 原子替换；解析失败时备份损坏文件并回退到默认布局。

### 3.5 快捷键与手势

- 默认提供可配置全局快捷键，避免抢占 macOS 系统快捷键。
- Esc 关闭；方向键/触控板滑动翻页；输入文本进入搜索。
- 捏合手势列为 P2：先调研公开 API 能否稳定捕获，不能依赖私有系统手势或注入系统进程。

### 3.6 隐私与安全

- 不集成 Firebase、遥测、广告、云同步、更新检查或网络 SDK。
- 不申请不必要的辅助功能、屏幕录制、完全磁盘访问权限。
- 不修改系统 Launchpad 数据库、不注入 Dock/Finder、不调用私有 API。
- 发布时使用 Developer ID 签名与公证；测试版本可本地构建。
- 可通过 Little Snitch 等工具验证应用进程不主动联网。

## 4. 性能指标（目标，需实测）

| 指标 | 目标 |
|---|---|
| 常驻后再次打开 | 典型场景 ≤100ms 到可交互 |
| 翻页动画 | 常规 60Hz 屏幕稳定接近 60fps，高刷屏尽量跟随刷新率 |
| 后台空闲 CPU | 接近 0% |
| 后台常驻内存 | 尽量 ≤60MB，随 App 数量和图标缓存调整 |
| App 增删同步 | 目录事件稳定后数秒内更新 |
| 搜索反馈 | 输入后立即响应，不阻塞 UI |

使用 Instruments（Time Profiler、Allocations、Core Animation）在 100、300、600 个应用的模拟数据下测量。指标为工程目标，不是预先保证。

## 5. 开发阶段

### 阶段一：可用 MVP

1. 创建原生 macOS 工程与窗口管理。
2. 实现应用扫描、图标缓存、全屏网格和应用启动。
3. 完成 Dock 唤起、Esc 关闭、分页与搜索。
4. 接入应用目录监听，实现安装/卸载自动刷新。
5. 加入布局持久化基础和本地日志。

**验收**：启动台可快速打开；卸载应用后图标自动消失；不需要联网。

### 阶段二：交互完善

1. 拖动排序、跨页拖动。
2. 文件夹创建、编辑、解散。
3. 全局快捷键、多显示器适配。
4. 处理 Mission Control、Stage Manager、外接显示器与不同 Space。

**验收**：排序和文件夹重启后保持一致，拖动过程不卡顿。

### 阶段三：性能与发布

1. Instruments 性能分析，修复卡顿与内存增长。
2. 增加配置迁移、错误恢复、手动重新扫描。
3. 完成自动化测试、签名、公证、DMG 打包。
4. 视公开 API 可行性增加捏合手势。

## 6. 测试清单

- 首次启动、再次打开、连续快速开关 50 次。
- 安装、卸载、重命名、移动 App；App 位于外接磁盘及其断开/重连。
- 同 Bundle ID 多副本、无 Bundle ID、辅助工具、系统应用过滤。
- 100/300/600 个图标；快速翻页、快速搜索、拖动跨页。
- 双显示器、不同缩放比例、刘海屏、Dock 自动隐藏。
- Mission Control、Stage Manager、全屏其他应用、睡眠唤醒。
- 权限拒绝、布局 JSON 损坏、升级后数据迁移。
- 完全断网使用、检查是否产生主动网络请求。

## 7. Codex 实施约束

1. 先输出模块划分和开发任务，再逐阶段提交可编译代码。
2. 所有系统交互使用公开 API；遇到限制明确说明，不以私有 API 绕过。
3. 主线程只处理 UI；扫描、图标处理和磁盘操作放后台。
4. 每个阶段都提供构建、运行和测试命令。
5. 优先修复性能问题，不为简单 UI 引入 Electron 或 WebView。
6. 参考 LaunchOS 的用户体验，但不复制其代码、图标素材或商业资源。
7. 如参考 LaunchMat 源码，先检查 GPL-3.0 的义务；不复制代码时保持独立实现。
8. 每次功能变更补充回归测试，重点检查应用卸载后仍显示的情况。

## 8. 给 Codex 的启动指令

> 请根据本技术方案从零创建 Nova Launchpad macOS 原生应用。使用 Swift 6 + AppKit + NSCollectionView + Core Animation。先实现阶段一 MVP，保证可编译运行。优先实现流畅的全屏网格、Dock 单击唤起、应用自动发现与卸载后及时消失、搜索和分页。所有功能必须离线，不引入网络 SDK 或私有 API。先审查开发环境与目标 macOS 版本，给出阶段任务与文件结构，再逐项实现并测试；不要一次性堆叠所有功能。
