# Nova Launchpad

macOS 原生离线应用启动器，当前处于阶段一开发中。需要 macOS 14 或更高版本以及 Swift 6 命令行工具；无需完整 Xcode。

```sh
./scripts/build.sh
open 'build/Nova Launchpad.app'
./scripts/test.sh
```

运行后输入名称搜索，回车打开当前页第一个结果，Esc 清除搜索或隐藏窗口；支持触控板两指滑动实时跟随与弹性吸附翻页，亦可点击底部分页指示圆点或按键盘左右方向键平滑翻页，点击空白背景可退出。应用隐藏后可点击 Dock 图标重新打开；菜单中的“重新扫描应用”可手动刷新，Command-Q 退出。

布局保存在 `~/Library/Application Support/NovaLaunchpad/layout.json`。扫描目前覆盖系统、用户和全局 Applications 目录，使用 FSEvents 合并目录变更；尚未补充 Launch Services 注册应用及外置磁盘布局保留。当前构建为本地未签名版本。Swift Package 构建在当前机器的 Command Line Tools 上存在 PackageDescription 链接错误，提供的脚本使用 `swiftc` 直接构建。

界面完全参考 macOS 原生 Launchpad 进行对齐：采用 7 列 × 5 行全屏网格排布，图标尺寸固定为 80×80 pt，图标与名称间距锁定为 8 pt，彻底释放底部呼吸空间；翻页动画基于全屏横向联动多页容器实现整屏边缘平移滑入滑出，并支持触控板跟手物理手势与 Rubber-banding 弹性阻尼。拖动排序、文件夹、全局快捷键属于后续阶段。
