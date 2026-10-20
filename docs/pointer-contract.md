# 0.3 G0：公共合同与文件责任

入口 #2，分包 #3/#4/#5。公共类型与最小示例测试见 `PointerContract.swift` / `PointerContractTests.swift`；接口 SHA 在唯一 Draft 集成 PR 中记录。此提交不代表已实现 G1 或完成新真机验收。

- 姿态统一为设备到 Core Motion 参考系的右手四元数；q/-q 等价。`referenceID` 在运动服务重建时更新，时刻是 Watch 单调秒。统一长轴 +y 指向，+z 表面法向；表冠左侧旋转面内基底 180°，右腕反转 B 的解剖翻转符号。实际“向右／向上”仍须真机核对。
- A 用指向射线的 heading/elevation，B 用 roll/elevation，C 用相对中立姿态的二维偏角计算速度。角度差必须用包裹差，不能直接裸减。D 保留固定标定锚点，不能逐次重新归零。
- `PointerScreen` 是 Quartz 全局逻辑坐标，右正、下正；Retina scale 只用于上下文失效，不乘到事件坐标。相对映射返回位移，主线加到实际当前光标并裁剪，超界部分丢弃；模块不得保留屏外欠账。
- 映射实现 `PointerMapping.begin/update/reset`。A/B/C 的 begin 只建立基线，返回 none；D 可用有效模型返回 absolute。`stop(reason)` 结果让主线结束周期，不自动重启。C 只在新样本到达时按 Watch 样本时间差积分，不在断流时延续最后速度。
- `MovementLease` 区分 reading/preparing/moving/paused。Watch 在明确开始、停止、点击、切模式和首次表冠冻结时递增 cycle。Mac 确认新周期和稳定新姿态后才进入 moving；关闭的周期不因后到姿态重开。总暂停恢复到 reading。
- 点击用 `(authenticatedSession, ClickRequest.id)` 唯一编号，同一 Watch 单调时钟记录触摸间隔。Mac 冻结当前已处理位置后执行完整 down/up，不等待未来姿态；首击立即，第二击只增加一对。每次实际输出复核资格；若 down 已提交，up 是优先的有限释放清理，不能把一次资格变化留下为按住状态。
- 样本发送前年龄、Mac 队列年龄、Mac 本地许可分别检查，不能相减两个设备的时钟。初值分别为 80/60/150 ms（最后一项为断流）；软性能目标可实测调整。保留一个最新姿态；滚轮增量继续合并，不能只留最后一条。
- `CalibrationBinding` 绑定屏幕含布局版本、参考系／referenceID、佩戴。与移动 cycle 分离，冻结可复用；布局 ID 每次 Mac 进程重启重新建立。磁盘系数不能自动成为可用模型。标定／练习期间 `OutputScope` 禁止外部输出。

| 责任 | 文件范围 |
| --- | --- |
| 主开发 #2 | 本公共文件、A、状态／协议／认证、采样、WatchModel、MacBluetooth、SystemWheel/SystemPointer、DisplayGeometry、App 主界面、工程／签名／安装 |
| B/C #3 | `Shared/Sources/WristCore/BCMappings.swift`、`Tests/WristCoreTests/BCMappingsTests.swift`、最小接入例子 |
| D #4 | `Shared/Sources/WristCore/PointingCalibration.swift`、`MacApp/CalibrationWindow.swift`、`Tests/WristCoreTests/PointingCalibrationTests.swift` |
| 验收 #5 | `Shared/Sources/WristCore/PointerPractice.swift`、`MacApp/PracticeWindow.swift`、相应独立测试、`docs/pointer-validation.md` |

各包只改分配文件。接口缺口先通知主开发；主开发改合同并记录新 SHA，不同时修改公共核心。映射测试测试生产类，UI 窗口不得自行采样、建立连接或调用 CGEvent。

## 当前环境与回退

2026-10-20 核对 main 为 `253ff2971d18fb4170b4abc2f32573339bb8a311`，工作区干净。macOS 27.0.1 (26A434)、Xcode 27.1 (27A9275)、Swift 6.4。已存在的 Mac/Watch 开发 profile 分别于 2026-09-30 / 2026-09-29 UTC 过期；原证书仍在，专用钥匙串处于锁定状态。设备初查均未连接，真实系统版本和续签结果另记，不能沿用旧值。

本地 `rollback/0.2-253ff29` 和私有完整 bundle 保留 0.2 源码。需要回退时从此 ref 建独立目录，复用被忽略的本地签名配置，以 Xcode 正常续签两个 scheme；不覆盖 main，不重置／替换已有配对密钥。旧安装包过期不影响源码重新签名。原始设备／签名记录留在 `build/private/0.3/`，不提交。
