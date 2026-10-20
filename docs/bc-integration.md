# B/C 纯映射接入

实现遵循 G0 `PointerMapping`，只计算相对位移，不采样、不连接蓝牙、不提交系统事件。生产类与合成轨迹测试分别是 `BCMappings.swift`、`BCMappingsTests.swift`。真机左右方向、串轴、手感和系统翻腕接管仍待同一安装版验收。

B 使用公共合同的 `roll/elevation`：翻转变化乘水平增益，抬起变化乘负的垂直增益，得到 Quartz 右正、下正坐标。A 的水平转向不会触发 B 水平移动。两个增益默认均为 **1600 逻辑点/弧度**，合法范围与 A 对齐，为有限值 `100 <= gain <= 8000`。角度差经过包裹，跨越 ±π 不产生整圈位移；停手停止。B 使用公共的表冠方向归一化，右腕反转翻转符号，抬起符号保持相同。

C 用开启时的姿态作中立：在该姿态的坐标里，当前 +y 指向射线的偏角构成二维输入，+x 对应向右、+z 对应向上。二维向量长度等于射线的总偏转角，因此同样幅度的斜向偏转与横向偏转速度相同，不把两个满速分量叠成更高速度。绕指向射线的纯翻转不会产生 C 位移。左右腕不改变 C 的数学方向，表冠方向仍按公共合同处理；真实身体动作的方向仍须真机核对。

`JoystickParameters` 可独立 Codable 保存，默认中立区 **1.5°**、满速角 **12°**、曲线指数 **1.5**、最高速度 **每秒一个当前屏宽**。这些是试验起点。合法值要求有限，`0 <= deadZoneRadians < fullSpeedRadians <= π/2`、`0 < exponent <= 8`、`0 < maxScreenWidthsPerSecond <= 4`；恢复设置后检查 `isValid`，`begin` 也会拒绝非法值。参数更改要结束旧周期，创建新映射，再显式开启。

C 在**每个新样本**到达时，以该样本计算的速度乘相邻 Watch 采样时间差。它不按回调次数累加，也不使用 Mac 与 Watch 时钟相减；采用当前速度近似这段时间的平均速度，所以合并快照后的动态轨迹存在正常的采样误差。该取舍让回中样本立即返回 `none`、反向样本立即反向，不混入上一帧速度；不保证任意急变轨迹在所有采样率下完全重合。没有新样本就没有新位移；外层仍须通过公共 150 ms 许可超时结束静默周期。下次样本间隙超过 150 ms、序号或时间不增、角跃迁超过合同阈值时，映射返回 `stop` 并清空，不能补走。

B 在公共特征无定义的接近竖直方向停止，也检查派生翻转/仰角的单步变化，防止漏掉中间竖直样本后出现 π 跳变。C 与世界竖直无关，允许以竖直姿态开启；但偏转超出中立前半球（超过 90°）停止，避免转到背后时二维方向翻转的歧义。两者均验证完整上下文；会话、周期、显示器布局或几何、参考系或佩戴改变会清空，不自行重建基线。调用者在模式切换、停止、点击/表冠冻结、锁屏/断线或失去资格时调用 `reset`，由公共状态机决定下一次明确开启。

接入示意；`begin` 必须只在新的移动周期已有稳定、新鲜基线后调用。实际输出由公共层在再次核验资格后完成：

```swift
var mapping: any PointerMapping = selectedMode == .b
    ? RollFollowingMapping(gainX: savedBGainX, gainY: savedBGainY)
    : TiltJoystickMapping(parameters: savedJoystickParameters)
let first = mapping.begin(sample: baseline, context: context) // A/B/C 为 none

switch mapping.update(sample: latestSample, context: context) {
case .relative(let delta):
    // 使用真实当前光标，不保存屏外虚拟位置；公共输出层再次核验资格。
    let target = context.screen.clamp(actualCursor + delta)
    submitThroughSharedOutput(target)
case .stop(let reason):
    endMovementCycle(reason) // 映射已经 reset，不能自动重开
case .none:
    break
case .absolute:
    break // B/C 不返回绝对位置
}
```

测试命令：`swift test --scratch-path build/bc-tests --filter BCMappingsTests`。2026-10-20 在本机 arm64 macOS 构建并通过 **17 项测试**。测试使用生产类，覆盖实际动作轴差异、q/-q、跨界、佩戴归一化、B 分段与边缘反向、C 中立/径向速度/限速/采样误差、完整上下文与失败后清空。所有结果属于数学和状态规则验证，不能作为手表、蓝牙、显示延迟或真实应用输入的验收证据。
