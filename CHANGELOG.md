# ChangeIcon v0.6.0

> 发布日期：2026-06-17

---

## 🚀 新增：sudoers 免密码授权（macOS 27 兼容）

### 功能说明
- 新增 `SudoersManager` 模块，支持在 `/etc/sudoers.d/` 中安装 NOPASSWD 规则
- 首次使用引导用户完成一次性配置（弹一次管理员密码）
- 配置完成后，**后续所有图标切换完全免密码**
- 原有 osascript 弹窗路径完整保留作为降级回退

### 三层降级策略
1. **Tier 1**：sudoers 已配置 → `sudo -n` 零弹窗直接执行
2. **Tier 2**：未配置（首次） → NSAlert 引导 → 用户接受则安装规则
3. **Tier 3**：用户拒绝或安装失败 → 回退 osascript（保持 v0.5.5 行为）

### 安全加固
- `seticon_helper` 新增参数验证白名单（路径前缀、扩展名、文件存在性）
- sudoers 规则路径锁定，visudo 双重语法验证 + 失败自动回滚

### 文件变更
- `Sources/SudoersManager.swift` — 新建（~350 行）
- `Sources/IconApplier.swift` — 重构（+~120 行，保留原路径）
- `seticon_helper.swift` — 安全加固（+~35 行）
- `Sources/SettingsView.swift` — UI 集成
- `Sources/ChangeIconApp.swift` — 注入 SudoersManager
- `Sources/PermissionGuideView.swift` — 权限引导页（新增管理员授权行）

---

## 🔧 v0.6.0 问题修复 (2026-06-10 晚间)

### 修复 1：管理员授权安装失败（权限引导页）
- **现象**：权限引导页点击「去开启」弹窗输入密码后，sudoers 规则未实际安装
- **根因**：`osascript do shell script with administrator privileges` 环境 PATH 最小化，`visudo`(/usr/sbin) 等命令路径不可达
- **修复**：`makeInstallScript()` 所有命令改用绝对路径 (`/usr/sbin/visudo`, `/bin/cat`, `/bin/rm`)，osascript 使用 `/bin/bash`，添加错误弹窗提示

### 修复 2：权限引导页布局调整
- 管理员授权行移至辅助控制权限**上方**，确保用户在开启辅助控制（触发自动跳转主界面）前先看到管理员授权

### 修复 3：引导页 install() 后多余的 checkConfiguration()
- **现象**：引导页安装成功但状态未更新
- **根因**：`install()` 成功后额外调用 `checkConfiguration()`，内部 Process 调用时序问题可能覆盖 `isConfigured = true`
- **修复**：移除多余调用，与 SettingsView 行为一致

### 修复 4：checkConfiguration() 假阴性误判
- **现象**：引导页配置成功后，打开设置界面仍显示「未开启」
- **根因**：`checkConfiguration()` 用 `sudo -n true` 验证 NOPASSWD，但 sudoers 规则仅覆盖 `seticon` helper，不覆盖 `true` 命令 → **100% 假阴性**
- **修复**：简化为仅检查文件存在性（文件在 install 时已通过 visudo 验证）；移除 `runSudoNonInteractive()` 死代码

### 涉及文件
- `Sources/SudoersManager.swift` — 多项修复
- `Sources/PermissionGuideView.swift` — 布局调整 + 错误处理
- `Sources/SettingsView.swift` — 状态同步修复

---

# ChangeIcon v0.5.5

## 🔧 macOS 27 Beta 兼容性

### 系统行为变化
macOS 27 beta 进一步加强了 `/Applications/` 目录的写入保护。`NSWorkspace.setIcon()` 对 `/Applications/` 下所有应用均返回 `false`，导致图标切换必须通过管理员授权路径完成。

### 当前行为
- **每次图标切换（手动/自动）均需输入一次管理员密码** — 这是 macOS 27 的安全策略限制，非软件缺陷
- 批量处理机制确保一次切换仅弹出 **一次** 密码提示（而非每个目标应用一次）
- 授权通过后，`seticon` helper 会自动 `chown` 应用包所有权，但在 macOS 27 beta 下该所有权变更可能被系统重置

### 技术说明
- 尝试使用 `Security.framework` 的 `AuthorizationExecuteWithPrivileges` 实现会话级授权缓存，但该 API 在 macOS 27 SDK 中已被标记为不可用
- 替代方案 `SMJobBless`（安装持久化特权 Helper）需要 Developer ID 签名，当前 ad-hoc 签名项目无法使用
- 将持续关注 macOS 27 后续 beta 版本的行为变化，评估是否需要引入签名流程

---

# ChangeIcon v0.5.5

> 发布日期：2026-06-10

---

## 🆕 新特性

- 双架构支持：同时提供 Apple Silicon (arm64) 和 Intel (x86_64) DMG 安装包

## 🔧 Bug 修复

### 应用管理权限检测
- **移除自动检测** — macOS 无公开 API 可靠检测 `kTCCServiceSystemPolicyAppBundles`（App Management vs Automation 服务类别不同，ad-hoc 签名下 TCC 数据库 `client` 字段不可预测）
- 权限引导页及设置页改为手动步骤：「去开启」按钮 + 系统设置路径说明

### 权限引导弹窗
- 引导窗口仅在 SIP 保护的系统应用场景弹出，不再对管理员授权失败重复弹窗
- 三个按钮均正确关闭弹窗（`needsPermissionSetup = false`）

### 管理员授权
- 批量处理：多个 root 拥有的应用合并为单次 `osascript` 授权，一次密码输入处理全部
- `seticon` helper 内置 `chown`：授权执行后自动将应用所有权从 root 改为当前用户，后续切换无需密码
- 修复 AppleScript 语法错误（双引号转义 → 单引号路径）
- 修复 chown uid/gid 传递错误（root 进程 `getuid()` 返回 0 → 改为主进程传入真实用户 ID）

### UI 修复
- 软件设置界面内容居中
- 应用管理权限行下方添加系统设置开启路径

## 📦 构建

| 文件 | 架构 | 大小 |
|------|------|------|
| `ChangeIcon-0.5.5-arm64.dmg` | Apple Silicon | 16 MB |
| `ChangeIcon-0.5.5-x86_64.dmg` | Intel | 16 MB |
