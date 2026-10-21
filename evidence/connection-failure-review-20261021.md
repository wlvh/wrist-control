# 连接失败审查交接（2026-10-21）

范围：读取已有日志、源码和签名产物，准备本地审查包。没有重启、修改配对或密钥、续签、重新安装腕控或安排新的手表动作。继续保持 [PR #6](https://github.com/wlvh/wrist-control/pull/6) 为 Draft，不合并或关闭未验收 issues。

实际安装仍为 0.3.0 build 5，源码 f936f72b2c1596afbd931febc37529fe52367ee2。本轮整理前 HEAD 为 7c0bd08cf5bcd8f69a6ee4cdb0704b3798fdbd5a。以下是重新读取实际记录后对既有摘要的修正。

## 需要优先审查的三个事实

### 故障阶段发生过变化

早期 build 3 的 Watch 累计日志有 31 次 connected、31 次 subscribed、31 次 hello 发送记录、30 次 att_write_failed，另有 15 次 connect_failed。对应早期 Mac 运行记录初始应用密钥读取 -25300、31 次订阅、零身份验证成功。后来另一轮 Mac 读取状态变为 0，保存窗口没有订阅；build 4/5 主要表现为 didConnect 前的 CBErrorDomain code 15。

当前尝试尚未进入应用认证，并不排除早期应用错误影响了后续系统状态。早期代码把缺少应用密钥或认证失败返回为 ATT insufficientAuthentication，后来改为普通失败并增加密钥预检。这一代码问题与后续 MIC 的因果关系仍未证实；早期 Watch 没记录具体 ATT NSError 域与码。

### 0.2 对照的 Mac 日志标错了版本

baseline-mac-observed.json 内嵌为 0.3.0 build 4 / bb2ad65，与 build4-mac-failed.json 属于同一 runID。不能把文件名当作版本证据。

本轮再次核对原 0.2 的 37 个文件与 253ff29 完全一致，保留的 Mac/Watch 签名产物均为 0.2.0 build 2、严格签名校验通过；当时安装元数据、使用者反馈、0.2 格式 Watch 日志及同时间段系统 MIC 记录均存在。但缺少可独立绑定同轮 0.2 Mac 进程的运行日志，不能把对照写成已经完全隔离 0.3 影响。

### PacketLogger 缺配置，和腕控失败分开讨论

2026-10-21 00:08:37–00:09:19 的 bluetoothd 完整保存窗口共 974 条记录，其中原记录 40–43 为：

    00:08:37.413467  Must pass external authorization
    00:08:37.431279  PacketLogger authenticated
    00:08:37.431287  Starting Live Logging
    00:08:37.431288  Bluetooth Profile Required

此前按消息正文包含 PacketLogger 等词的筛选遗漏了后两行。工具获准访问服务不代表日志配置已启用。预检无 HCI/ACL/SCO/ISO 数据，停止时仅一个工具自身 Note；没有有效 .pklg 或受控 Watch 失败包采集。

Apple 当前提供的 macOS 日志 PDF 标注 Copyright 2022，要求安装日志描述文件后重启，配置 3 天过期；本轮未安装、未重启。官方来源为 [Profiles and Logs](https://developer.apple.com/feedback-assistant/profiles-and-logs/?name=bluetooth)。这只说明采集流程，不能据此承诺修复腕控。

## 当前可支持的结论

- build 4 的 15 次连接失败在同一块 Watch 的本地时钟上，距离发现约 1.308–1.540 秒，中位数 1.348 秒；没有应用 10 秒准备超时事件。
- build 5 的早期 4 次失败包含在后续同一 runID 的累计 15 次中，新增是 11 次。两份快照不能相加。
- Mac 蓝牙恢复后的系统窗口有同一匿名 Watch peer 的 11 次 MIC，方向为 Mac Peripheral；代表性序列为低层连接 → IncomingLTK → 加密失败 → MIC 断开。
- 系统也出现过同一匿名 peer 的加密成功记录，其方向/用途需单独核对，不能当腕控成功或全部方向均失败。
- 50 秒旧日志流在 22:16:17 已结束，实际失败窗口约从 22:18:25 开始；该流零 MIC 不支持“没有错误”。
- 没有原始 HCI 包、没有双方系统密钥比较、没有证明哪个设备导致 MIC。内部 761/182 不擅自映射为标准错误号。
- 没有执行 Mac 普通重启，不能声称有效或无效；即使未来现象随重启改变，也需要控制变量才能归因。

## 交付与下一步

本地审查包包含报告、给审核员的问题、25 份脱敏日志派生文件、完整 0.2/已安装 build 5 源码、build 3/4 连接文件、差异、截图和仅用 Python 标准库复算数量的脚本。日志保留原数组的记录号、时间、错误域/码、角色和稳定匿名对应，附原始/派生 SHA-256；原始文件与匿名表留在忽略目录，不上传 GitHub。

请独立审查连接生命周期、取消/重试、早期 ATT 行为及对照证据，再选择一个能区分假设的最小实验。本轮没有继续修改系统，也没有把重启当作根因或修复结论。A/点击及四模式真机验收仍未通过。
