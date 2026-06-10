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
