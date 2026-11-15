# 按住滚动干扰鼠标与应用切换（Build 276 历史候选）

> Build 276 已被用户实测否决：Codex 上下均不滚动。下文保留该阶段证据，不表示当前修复已成立。当前方案与验收见 [滚动兼容性回退记录](2026-11-15-codex-line-scroll-regression.md)。

## 触发条件与现场证据

在 Build 275、Codex 前台按住遥控器下键：用户报告鼠标回到窗口中间，无法点到 DeepSeek；改用电脑 Command+Tab 时，应用选择持续移到最后一项，无法选定 DeepSeek。松键停止滚动等稳定主路径此前已通过用户测试。

来源是本次用户现场反馈。没有可供重放的现场脱敏日志导出，本次没有读取/解密第三方内部文件或用户日志；调查使用当前源码、公开系统 API 定义、隔离事件投递测试及模拟 HID 报告。尚不能根据这些证据排除所有原生按键泄漏，也不能宣称新包真机验收已通过。

## 已确认的实现缺陷与实验

旧 `KeyboardInjector.postScrollWheel` 使用 HID 共享事件源，将 wheel 事件坐标指向前台窗口中心，再投递到全局 HID 事件流。目标仅是事件坐标，没有接收进程约束；既有连发有效性依赖前台 App 真正改变，未覆盖 Command+Tab 尚在选择阶段的窗口。

将旧函数原样行为提取到可注入投递边界，保留全局路由：`lineScrollIsAddressedToTheCapturedProcessWithoutHardwareModifiers`、`lineScrollCannotReachTheAppSwitcherOrAReplacedTarget` 和 `commandTabInterruptsScrollRepeatsBeforeTheFrontmostAppChanges` 失败。捕获结果显示没有指定目标 PID，Command 已按下而前台 PID 未变时，仍持续提交 wheel；见本地 `/tmp/sayall-scroll-routing-baseline-red.log`。测试拦住实际 OS 投递，不改变用户窗口。

因此可以确认“全局投递范围过宽，加上切换选择阶段未停止连发”这条缺陷路径，与现场现象一致；测试没有把原生 HID 泄漏确认为根因。系统 API 范围以 Apple 的 [CGEvent](https://developer.apple.com/documentation/coregraphics/cgevent) 和 SDK `CGEvent.h` 的事件流说明为依据。

取消路径另发现：HID 将任意动作返回 false 当作辅助功能权限失效，停止监视器并清除按住边沿。新增 `cancelledLineScrollPreservesHIDPermissionsAndHeldEdges` 用上下键真实格式的报告重放，确认取消滚动后出现权限误报，并因重复 held 报告重新触发滚动。失败证据为 `/tmp/sayall-scroll-cancel-red-2.log`；这不是用户曾遇到的另一个现场结论，而是修复联测确认的下游缺陷。

## 最小修复

- 行滚动使用独立事件源，清空事件修饰键，通过公开 `postToPid` 仅交给捕获的前台进程；不回退到全局 HID 投递。
- 以同一 PID 查询窗口位置，并在提交前再次检查目标。目标缺失/改变时停止本次动作。
- Command 按下时取消当前滚动，返回非提交结果，由既有交互控制器取消连发；松开 Command 不恢复旧的按住会话，需先松开遥控器再重新按下。
- HID 对行滚动的非提交结果仅取消动作，保留物理按住边沿，不清除设备状态、不误报辅助功能失效。真实权限撤销仍走原权限检查路径。
- 不改设置持久化、原生键过滤、语音链路、其他键位、翻页/到顶动作，也不安装、结束或启动旧 App。

## 验证与日志边界

1269 项 Swift Testing、91 个套件通过（24.242 秒），见 `/tmp/sayall-scroll-final-tests.log`。本机缺 XCTest，沿用仓库外临时清单排除 `SupplementalSettingsIntegrationTests.swift`，仓库清单未改。该记录不是完整 Xcode 测试通过声明。

自动化覆盖：指定目标、行数方向、无修饰投递、Command 取消、目标变化/缺失不投递、取消后无残留计时器、松键再按恢复，以及 HID 权限状态和重复报告不重启取消动作。既有语音、其他键位、设置保留与权限撤销用例一并运行。

日志 `SCROLL LINE phase=cancelled reason=command_modifier|target_changed|target_unavailable|event_unavailable external_result=unknown` 区分提交前取消原因；`HID ACTION cancelled ... reason=scroll_not_submitted` 表示动作未提交，不代表权限撤销。一次按住的计数和控制器终态沿用 `BUTTON HOLD`。正常每次 wheel 不新增日志；不记录 PID、窗口标题、坐标、输入内容或设备身份。API 提交不是可见滚动成功证据。

现场仍须验证：Codex/DeepSeek 正常上下滚动、光标不被拉回、按住下键时鼠标点选/Command+Tab 能选定目标、切 App 后不继续连发、松键无补发、重新按下恢复、首次语音和已测主键位。新候选通过这些用例前，本项保持待现场验证；正式版与当前测试版配置须保留。
