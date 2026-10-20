# D 五点标定接入

`PointingCalibration` 使用中心点固定 heading/elevation 锚点；角度差包裹到连续局部区间，五点最小二乘同时拟合水平和垂直的两个斜率与截距。它不是速度增益。相同朝向给相同位置，`DPointingMapping.reset()` 只结束本次移动，保留有效模型。

标定窗口只接收共同姿态流。主线进入 `OutputScope.calibration`、停止运动并隔离滚轮/点击后，创建 `CalibrationWindowController(screen:appKitFrame:onCompletion:)`，调用 `showWindow(nil)`，转发 `ingest(sample:receivedAtMac:)`。`screen` 是 Quartz 全局逻辑坐标；`appKitFrame` 是同一块 NSScreen 的 frame。窗口内容坐标已翻转为左上原点，不乘 Retina scale。窗口不采样、不连接 BLE、不调用系统输入。

完成回调为 `(PointingCalibration?) -> Void`：非空模型应立即交给独立新目标验证；空值表示取消。两条路径均返回阅读态，不自动开启移动。主线在断线、锁屏、资格丢失、参考重建或显示布局变化时调用 `invalidate(reason:)` 并清除活跃 D 周期。回调前若需要解释取消原因，可读取 `cancellationReason`。窗口每点倒数 3 秒，再自动采约 0.5 秒；稳定采样或拟合失败保留其他点。界面反馈在样本锁定后开始。

模型绑定 `calibrationID: UUID`、屏幕及进程内布局 ID、参考系/referenceID、佩戴配置；记录模型版本、原始五个采样窗、方向覆盖、矩阵条件与训练残差。模型故意不提供 Codable。主线必须每次进程启动建立新 layoutID；运动服务重建必须更新 referenceID，不能把磁盘系数恢复为可用标定。采样时间只在 Watch 自己的时钟内相减；窗口队列年龄只用 Mac 单调时钟。

`StableAttitudeCollector(binding:configuration:)` 的 `append(sample:screen:)` 在足够时长和数量后一次返回 `StableAttitudeWindow`，提供 `meanSample`、原始 `samples`、实测 `sampleRateHz`、RMS 与最大角偏离；失败清掉当前窗口。q/-q 对齐到同一半球后计算归一化均值。默认 0.5 秒、至少 10 个新样本，RMS ≤ 0.015 rad，最大偏离 ≤ 0.035 rad。超时、逆序、跳变、无效姿态或上下文变化拒绝采集。这些是初始试验阈值，尚未获得真机有效性证据。

五点归一化目标是中心 `(0.5,0.5)` 和顺时针四角 `(0.1,0.1)`、`(0.9,0.1)`、`(0.9,0.9)`、`(0.1,0.9)`。覆盖检查要求两轴跨度至少 0.08 rad、点间至少 0.025 rad、二维较窄方向的 RMS 展开至少 0.015 rad。中心化后的两维几何先做秩检查，再要求条件数 ≤ 25；训练归一化 RMS ≤ 0.10、最大误差 ≤ 0.18。有限数值检查贯穿拟合及预测。只有这些检查通过才产生模型。

`predict(sample:screen:)` 返回裁到该屏幕的绝对逻辑位置；`predictRaw(sample:screen:)` 和 `predictionError(sample:screen:target:)` 保留未裁剪位置，供盲指误差测量。正常边缘外推有界：在训练角度包围盒每边额外允许半个跨度，且距固定锚点不超过 1.2 rad；超出时明确失败，不能靠裁剪把坏数据变成合法角落。九目标验证必须先锁定稳定窗、再揭示落点，排除训练目标，并按 `calibrationID` 单独记录原坐姿与扰动坐姿结果。

自动测试命令：`swift test --scratch-path build/d-tests --filter PointingCalibrationTests`。测试直接使用生产实现，覆盖交叉轴已知映射和未训练点、q/-q、跨 ±π、四种佩戴、退化与病态、无效值、独立未裁剪误差、屏幕偏移/Retina、上下文失效、坏点重采及冻结复用。自动测试与窗口编译不等于真实标定、九目标盲指或准确度通过；本轮真机结果继续待测。
