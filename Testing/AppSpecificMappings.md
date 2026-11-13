# Codex / DeepSeek 前台 App 按键自动匹配测试

## 范围和状态

这是 fork 的公开源码独立实现，不使用官方私有 Plus 方案模块。仅匹配 `com.openai.codex` 和 `com.deepseek.dsh`；其他 App 使用当前基础映射。普通构建自动匹配默认关闭；隔离测试包在独立偏好域预置开启和已测 Codex 基础键位，不复制正式版数据，自定义按键仍需用户授权后启用。开启后 TV 单击全局发送无修饰 Tab，双击、长按不执行。语音触发设置不变。

本机已提供隔离测试构建入口；自动化、构建和实体设备验收各自独立，未做实体遥控器验收的项目保持待验证。DeepSeek 专属快捷键经用户确认尚未知，初始禁用，需要先在实体键盘验证后配置。

## 独立构建和存储边界

在功能分支执行 `SAYALL_ISOLATED_APP_MAPPING_TEST=1 scripts/package-local-test-app.sh`。脚本只生成 `~/Downloads/SayAll-AppSwitching-Test/build-N/SayAll.app`，不停止、安装或启动 App。公开构建可能不包含官方包中的组合动作、回眸增强、会员或其他私有功能。

测试包身份为 `com.kevin.sayall.app-switching-test`，偏好设置与正式版不同；应用数据位于 `Application Support/SayAllAppSwitchingTest/`，日志也使用独立目录。独立 MCP helper 根据自身所属 App 识别隔离目录。不会导入或迁移正式版用户设置；测试包基础键位根据本文已确认方案生成，所以关闭自动匹配后 TV 也保持 Tab。

单实例锁刻意沿用正式版的历史锁，防止两个版本以任意启动顺序争用硬件。测试版检测到正式版运行时提示后退出；不会替用户结束正式版。真实硬件测试前请手动退出正式版，结束测试后退出测试版，再重新打开正式版。现有驱动继续使用，不运行安装器或更改系统默认音频设备。

## 准备

1. 确认正式版配置已有备份或记录，不在正式版导入测试配置。
2. 手动退出正式版，打开隔离测试 App；系统权限确认由用户操作。新应用身份可能需要重新授予蓝牙、输入监控、辅助功能权限。
3. 测试版使用独立偏好设置，因此需在自己的首次设置流程中选择已安装的兼容麦克风，完成遥控器连接和权限步骤。不要重装驱动。
4. 在测试版启用自定义按键，再进入“APP 适配”，开启“启用 Codex / DeepSeek 自动匹配”。该开关不改基础按键映射；关闭后回到原基础映射。

## 用例与预期

| 用例 | 操作 | 预期 |
| --- | --- | --- |
| Codex 自动匹配 | 鼠标将 Codex 切到前台；按左右、确定、返回、上下、主页长按、菜单长按 | 分别发送已配置的 Codex 会话切换、Enter、Esc、滚动、⌘N、⌃⇧G；一次动作一次响应 |
| DeepSeek 初始安全状态 | 切到 DeepSeek，按左右、主页长按、菜单单击和长按 | 未设置的专属快捷键不执行，不能泄漏 Codex 快捷键 |
| DeepSeek 专属配置 | 先用电脑键盘验证需要的快捷键，再在 APP 适配页选择 DeepSeek 并逐项设置 | 保存后只对 DeepSeek 生效，重启测试版仍保留 |
| 通用动作 | DeepSeek 前台，按确定、返回、上下、音量和主页 | Enter、Esc、滚动、音量；主页仅聚焦前台输入框，不唤起 Codex |
| TV 全局 | Codex、DeepSeek、其他 App 分别按 TV | 单击只发送 Tab，不带 Command/Option/Control/Shift；双击和长按无额外动作 |
| 未匹配 App | 切到 Safari 等应用，使用非 TV 按键 | 使用测试版的基础映射，不错误套用任一 App 的专属操作 |
| 关闭功能 | 关闭自动匹配后再次操作 | 所有按键包括 TV 回到测试版原基础映射 |
| 按住中切 App | 按住滚动/音量键，再用鼠标切 App | 旧动作取消，松开不补发旧动作，不留下修饰键或连发 |
| 语音回归 | 两个 App 中分别按住说话、松开，再连续重复 | 保留原 Fn 生命周期，首字尾字完整，不自动发送 |
| 正式版保护 | 正式版运行时尝试启动测试版；反向启动也验证 | 不同时接管蓝牙/HID，不自动关闭任一已运行 App |
| 配置保护 | 退出测试版后重新打开正式版 | 之前测好的 Codex 方案、TV=Tab、语音配置仍在 |

Codex 菜单单击跳待处理会话，以及审批框确定批准/返回拒绝，继续保留用户此前的三项待验证状态；测试包构建不代表这些场景通过。

## 失败判定和日志

错误应用收到专属快捷键、TV 打开 Command-Tab 切换器、DeepSeek 未设置动作却触发 Codex 功能、切 App 后继续连发、正式版映射变化、同时接管硬件，均判定失败。停止测试，不覆盖正式版配置。

设置保存日志为 `APP MAPPING phase=completed result=settings_saved enabled=true|false`；它仅证明设置保存。既有 HID/快捷键日志只能证明事件提交，目标 App 最终效果需用户观察。测试日志位于独立命名空间，不记录聊天内容。问题反馈附按键、手势、前台应用类别、发生顺序及 App 构建号，不附私人聊天或设备标识。

## 自动化验证边界

- `AppSpecificMappingsTests`：精确匹配、未知 App 回退、TV 固定、DeepSeek 安全默认值和编辑、持久化、旧不透明动作抑制、损坏配置。
- `TestBuildIsolationTests` / `IsolatedMCPPathsTests`：独立目录、启动互斥策略、独立 helper 的目录选择。
- `ApplicationInstanceGuardTests`：同一历史锁只允许一个持有者。
- 本机只有 Command Line Tools，缺少 XCTest。常规 `swift test --disable-keychain` 无法完成；使用仓库外临时清单排除唯一依赖 XCTest 的 `SupplementalSettingsIntegrationTests.swift`，其余 Swift Testing 用例执行。此排除未改入仓库。
- 所有 UI、蓝牙、权限、语音和真实遥控器用例仍需人工验收，不把静态截图、模拟事件或构建成功当作真机通过。
