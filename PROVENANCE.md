# 1.0 Preview 来源与重写范围

## 历史边界

较早的私人构建集成过 Caldis/Mos，采用其 CC BY-NC 4.0 许可。编写本版的人机协作过程已经接触过该项目源码，因此本版不能声明为严格净室实现，也不能用改名来证明任何许可义务消失。旧私人源码和安装包未被重新许可或包含在本目录中。

参考项目：https://github.com/Caldis/Mos
历史许可：https://creativecommons.org/licenses/by-nc/4.0/

## 本版新写的平滑模块

- `Sources/ScrollTrajectory.swift`：每个输入脉冲有起点、距离、时长与已输出距离。以 S(u)=10u³−15u⁴+6u⁵ 计算有限累计位移，帧输出是相邻累计位移的差。独立进行距离守恒、时钟抖动和内存边界测试。
- `Sources/SmoothScrollEngine.swift`：按需启动 NSScreen display link；主线程原生像素事件输出；保留分数像素余量；切换目标和反向时取消旧轨迹；不创建第二个事件 tap。相位型触控板／连续输入不进入该引擎。
- `Sources/ScrollProfile.swift`：新配置模型，使用像素、毫秒、倍率及 bundle identifier 应用规则。不读取第三方 UserDefaults，不复用旧参数转换。
- `Sources/SmoothSettingsView.swift`：新布局与调节单位。控制键沿用本项目已有的组合键录制拦截器，不包含旧第三方单键录制实现。
- `SmoothChecks/`：独立预期值与原生接收端测试，不带历史上游源码或逐帧对照测试。

本版没有包含历史平滑模块的源码文件、旧峰值过滤器、旧插值器、旧阶段状态机、旧 CVDisplayLink 派生文件、第三方配置导入器或其源码对照测试。用户可感知的平滑／反转／应用规则等功能是设计目标，不表示算法逐帧一致或设置数值可互换。

这份记录描述实际工程更换范围，不能替代针对具体发行场景的法律判断，也不是“没有任何版权风险”的保证。

## 继续保留的来源

原生捏合字段参考、Apple Silicon DDC 参考，以及 BetterDisplay 本地通知接口参考的 MIT 署名和全文仍在 `THIRD_PARTY_NOTICES.md`，并随二进制分发。它们没有因平滑模块重写而删除。

## 宣传片素材

`Promo/Promo.swift` 绘制原创电脑、人体工学鼠标和界面示意，`Promo/music.py` 合成原创配乐。公开工程不包含旧宣传片所用的 Logitech 官网产品渲染图、下载页面或素材包。产品名称仅说明适用设备，无厂商标志、赞助或背书声明。系统字体与 SF Symbols 在 macOS 上调用，不随源码附带字体文件。
