# Awake Skill

让 AI 助手按指定时间保持电脑运行：自动识别 **macOS / Windows**，支持开启、查询、提前关闭和到期恢复。

```text
/awake 30分钟
/awake 2小时
/awake 初始化
/awake 配置
/awake 状态
/awake 关闭
```

## 安装 Skill

克隆此仓库，将其中的 `awake` 文件夹复制到你的 AI 客户端 Skill 目录。Codex 默认目录为 `~/.codex/skills/awake`（Windows 为 `$HOME\.codex\skills\awake`）；已有同名私人 Skill 时先备份，不直接覆盖。其他支持 SKILL.md 的客户端使用各自的 Skill 目录。

```sh
git clone https://github.com/Hype-yolo/awake-skill.git
```

Skill 安装与系统控制器安装是两步。首次运行时，助手按当前操作系统引导管理员安装：

- [macOS 安装、卸载与原理](awake/references/macos.md)
- [Windows 安装、卸载与原理](awake/references/windows.md)

首次开启（或 `/awake 初始化`）会询问以后是否连接手机热点，以及准确的热点名称，完成首次连接后将偏好保存在本机用户目录。也可选择保留现有网络，支持离线本地任务。之后 `/awake 30分钟` 自动复用偏好，不重复询问；`/awake 配置` 可修改。热点不可用时不会悄悄跳过并开始计时。

配置文件不包含密码，不进入仓库。热点密码由用户在系统界面输入并由系统保存。Mac 配置工具需要 Python 3，控制器首次安装需要管理员验证，之后仅专用操作可免重复认证；Windows 配置工具使用内置 PowerShell 5.1，但电源操作仍需要管理员权限/UAC，**不是首次配置后永久免认证**。两平台均检查实际权限和控制器状态，不把保存配置视为安装完成。

详情见 [首次初始化与配置流程](awake/references/setup.md)。此流程不依赖 Amphetamine 或其定位触发器；需要助手具备系统 Wi-Fi 界面操作能力，无法操作时会说明阻塞。

## 为什么分两套实现

macOS 使用专用 root 控制器与 launchd 定时恢复。Windows 的普通唤醒 API 不能覆盖合盖动作，需要临时电源设置与独立的恢复任务。两者共享自然语言入口，系统权限与恢复逻辑分别实现。

这是限时工具，不检测 AI 任务是否完成。支持 1–1440 分钟，重复开启替换截止时间。不要把运行中的笔记本放进密闭包内。

## 验证与限制

本项目提供离线测试和持续集成。通过测试不等于已在你的电脑合盖实测。Windows 硬件、Modern Standby、厂商固件或企业策略可能不允许目标设置；失败应保留具体错误，不承诺所有设备兼容。macOS 的 disablesleep 行为也需按设备验证。

初始发布不宣称 Windows 或 Mac 物理合盖测试已通过。具体测试结果见 [VALIDATION.md](VALIDATION.md)。

## 来源与许可

从个人使用的 awake Skill 整理而来。此公开仓库拥有独立历史，只包含通用代码、文档与测试，不包含私人配置。MIT License，Copyright (c) 2026 Hype-yolo。
