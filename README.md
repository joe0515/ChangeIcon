# ChangeIcon

ChangeIcon 是一个原生 macOS 小工具，用来快速替换应用图标，并在系统浅色/深色模式变化时自动切换对应图标。

## 功能

- 拖拽 `.app` 到侧边栏直接添加，或通过 ⌘O 打开选择面板
- 拖拽图标文件到方案详情，或从剪贴板粘贴图片
- 侧边栏按应用名称或路径搜索，右键可复制路径或在 Finder 中显示
- 为浅色模式和深色模式分别指定 `.icns`、`.png`、`.jpg` 或 `.tiff`
- 图标形状处理：支持原始、圆角、圆形、超椭圆四种遮罩
- 从文件夹批量导入图标包，按应用名和 `light` / `dark` / `浅色` / `深色` 等关键词自动匹配
- 批量应用全部方案，带进度指示
- 监听系统外观变化，应用保持运行时自动切换
- 菜单栏常驻，显示快捷方案列表，可快速应用或刷新
- 图标预览缓存，减少应用列表和图标包预览反复解码
- 首次替换前备份原始图标，可一键恢复
- 导出/导入图标方案 (JSON)，方便分享和迁移
- 导出当前图标为 PNG 文件
- 撤销上一步操作 (⌘Z)
- 拖拽图标到 Dock 图标即可快速应用到已启用方案
- 写入 `/Applications` 等受保护位置时，会弹出 macOS 管理员授权
- 可在设置中开启登录时启动

## 快捷键

| 快捷键 | 功能 |
|--------|------|
| `⌘O` | 添加应用 |
| `⌘R` | 应用当前外观图标 (选中方案) |
| `⇧⌘R` | 应用当前外观图标 (全部方案) |
| `⇧⌘B` | 批量应用全部方案 |
| `⇧⌘F` | 刷新图标缓存 |
| `⌘Z` | 撤销上一步操作 |
| `⌫` | 移除当前方案 |

## 构建

```zsh
./scripts/build_app.sh release
```

构建产物位于：

```text
build/ChangeIcon.app
```

## 使用提示

替换图标后 macOS 可能需要几秒刷新图标缓存。ChangeIcon 会重新注册目标应用、刷新 QuickLook 缓存，并重启 Dock、Finder 与 SystemUIServer 来加速刷新。

## 项目结构

```
ChangeIcon/
├── Package.swift              # Swift Package Manager 配置
├── README.md
├── Resources/
│   └── Info.plist             # App Bundle 配置
├── Sources/
│   ├── ChangeIconApp.swift    # @main 入口 + 菜单栏命令
│   ├── AppDelegate.swift      # Dock 拖拽处理
│   ├── Models.swift           # 数据模型
│   ├── ContentView.swift      # 主界面
│   ├── IconSchemeStore.swift  # 数据持久化 + 撤销 + 导入导出
│   ├── IconApplier.swift      # 图标替换引擎
│   ├── AppearanceMonitor.swift # 外观监听
│   ├── IconPreviewCache.swift # 图标缓存
│   ├── SettingsView.swift     # 设置
│   └── MenuBarView.swift      # 菜单栏
└── scripts/
    └── build_app.sh           # 构建脚本
```
