# 首次初始化与本机网络偏好

此流程由 AI 助手执行，配置脚本只负责读写配置，不代替 Wi-Fi UI、管理员验证或电源控制器。不依赖 Amphetamine，不创建持续扫描 Wi-Fi 的后台触发器。每次调用开启时才连接和验证。

## 读取与保存

以当前交互用户身份读写，不能用 sudo、SYSTEM 或另一管理员账户的用户目录保存偏好。路径相对于实际安装的 Skill 目录（不是固定的仓库工作目录）；先解析 Skill 绝对路径，命令参数按当前 shell 正确引用。

macOS 需要可用的 Python 3，仅使用标准库。先检查 `python3 --version`；不可用时明确缺少此依赖，由用户安装 Python 3 后继续，不临时把配置写在仓库里。

```sh
python3 scripts/macos/config.py read
python3 scripts/macos/config.py save --mode existing
# 名称是示例；用用户确认的真实名称作为一个正确引用的参数。
python3 scripts/macos/config.py save --mode hotspot --ssid 'My Phone'
```

macOS 默认文件：`~/Library/Application Support/AwakeSkill/config.json`，写入文件权限 0600。

Windows 使用原生 Windows PowerShell 5.1；配置脚本不需要管理员权限：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\windows\config.ps1 -Action read
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\windows\config.ps1 -Action save -Mode existing
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\windows\config.ps1 -Action save -Mode hotspot -Ssid 'My Phone'
```

上述执行策略仅作用于该次 PowerShell 进程，不修改系统策略；若组织策略阻止执行，报告限制，不绕过组织策略。

Windows 默认文件：当前用户 LocalApplicationData 下的 `AwakeSkill\config.json`。保留用户目录的访问权限；不放到共享目录、ProgramData 或仓库内。命令中的 SSID 若含单引号需按 PowerShell 字面量规则转义；不得把原始名称拼入可执行代码。

缺失文件返回 `{"state":"missing"}`，不创建文件。有效配置包含：

```json
{
  "version": 1,
  "platform": "macos",
  "network": {"mode": "hotspot", "ssid": "My Phone"}
}
```

Windows 的 platform 为 `windows`；保留网络时 network 为 `{"mode":"existing","ssid":null}`。不保存密码、令牌、管理员凭据或“已授权永久免验证”的标记。配置不在不同电脑之间自动同步；另一平台的配置、未知版本或损坏 JSON 必须报告，保留原文件，不能当作缺失直接覆盖。用户要求修复时先将原文件重命名为带时间戳的备份，确认原配置路径已空出，再重新配置；只复制备份仍会被脚本拒绝覆盖。脚本的自定义路径参数仅用于隔离测试，不用于正常调用。

## 首次询问与前置条件

1. 先检查当前系统控制器/权限是否具备（读对应平台文档）。Mac 已安装则用 `sudo -n ... status` 验证；不存在时准备安装，不运行失败的启动。Windows 检查原生 PowerShell 5.1 和管理员身份，缺少权限就说明需要一次当前操作的系统授权。不要为了检查而启动新会话或改电源策略。
2. 没有偏好时集中询问：“以后每次开启前，连接指定手机热点，还是保留当前网络？若连接热点，请提供热点名称，或从系统 Wi-Fi 列表选择。”已有明确答案直接采用。不要猜测列表中唯一的手机就是用户目标。
3. 选择热点后，用当前系统 Wi-Fi 界面连接精确名称。首次配对/热点密码由用户在系统窗口处理；系统可记住网络，助手不收集密码。Mac 的 Instant Hotspot 取决于 Apple 账户/家人共享、附近设备及 Wi-Fi/蓝牙条件；Windows 通常需手机先开启可发现的个人热点并完成首次连接。不要承诺自动唤醒任何手机热点。
4. 验证目标网络已连接，再验证 HTTPS 联网。只有验证通过才将新热点写入配置并回读比对；验证失败保留已有配置，不启动、不延长防睡眠。选择保留当前网络可直接保存该偏好，不强制联网，因此离线本地任务也可使用。
5. 完成必要的控制器安装/权限准备。Mac 使用平台安装器，由用户在系统/终端完成一次管理员验证，此后只放行专用控制器的有限操作。Windows 不安装宽泛免密提权规则、不关闭 UAC；当前每次电源操作须在管理员 PowerShell 中执行，普通助手会话需用户完成提升后才能继续。配置可以先保存，权限未完成时报告“网络偏好已保存，电源控制尚待授权”，下次不重问网络。
6. `setup` 到此结束，不为演示擅自开始防睡眠。若原请求带时长，权限满足后继续：热点模式在安装耗时后再次确认连接与联网，再启动原请求并验证截止时间与恢复机制。安装中断后可重入，实际状态检查始终优先于磁盘偏好。

## 后续每次开启

- 读取并验证配置，检查当前控制器和权限。不要重复安装正常工作的控制器，也不要只凭配置存在跳过状态检查。
- `existing`：保留当前网络，不切换、不要求热点、允许离线任务。
- `hotspot`：用当前系统 Wi-Fi UI 验证 SSID，已连接目标则不重连，否则连接保存的目标。目标不在附近、拒绝权限、无 UI 能力、需要密码或联网失败时，明确阻塞，已有会话不变；用户明确选择本次跳过热点后才按覆盖继续。不要循环重试授权弹窗。
- 系统 UI 必须显示实际目标已连接。可在 Mac 用 `curl --max-time 15 --fail --silent --show-error https://captive.apple.com/hotspot-detect.html` 检查 Success；Windows 用 `Invoke-WebRequest -UseBasicParsing -TimeoutSec 15 -Uri https://captive.apple.com/hotspot-detect.html` 检查 HTTP 200 且响应包含 Success。这是联网检查，不传递热点名；工具失败不能声称成功。系统 UI 工具的权限/确认要求仍然有效。
- 联网验证不是热点永久在线保证。自动加入热点设置无法保证从已有 Wi-Fi 主动切换；不要把它当成连接已完成。
- 启动并按平台文档回读状态、截止时间和恢复任务。报告配置验证与物理合盖实测的区别。

## 修改、停止与隐私

`/awake 配置` 时显示现有网络偏好并询问需要修改的项，已给定新偏好则直接验证保存。用户只临时换网不写配置。停止/到期不主动断开热点。卸载 Skill 不自动删除偏好；用户要求清除配置时只处理上述当前用户文件，不删系统已保存 Wi-Fi 密码。

SSID 是用户配置数据，不放进提交、发行附件、CI 日志或公开问题报告。测试使用虚构名称与临时目录。首次本机验收应依次验证：配置回读、下次调用不重问、目标联网、短时会话到期恢复；合盖持续运行仍需用户在实际设备上测试。
