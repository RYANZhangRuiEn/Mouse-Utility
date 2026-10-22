# 1.0 Preview 4 来源与实现范围

Preview 4 的版本比较、GitHub 只读请求、可关闭检查和原生提醒窗口为项目内新实现，使用 Foundation／AppKit，不引入更新框架、Mos 源码或远程安装逻辑。网络与本地状态范围见 `PRIVACY.md`。

## 历史边界

较早的私人构建集成过 Caldis/Mos，采用其 CC BY-NC 4.0 许可。编写本版的人机协作过程已经接触过该项目源码，因此本版不能声明为严格净室实现，也不能用改名来证明任何许可义务消失。旧私人源码和安装包未被重新许可或包含在本目录中。

参考项目：https://github.com/Caldis/Mos
历史许可：https://creativecommons.org/licenses/by-nc/4.0/

## 本版新写的平滑模块

- `Sources/ScrollTrajectory.swift`：每个输入脉冲有起点、距离、时长与已输出距离。以 S(u)=10u³−15u⁴+6u⁵ 计算有限累计位移，帧输出是相邻累计位移的差。独立进行距离守恒、时钟抖动和内存边界测试。
- `Sources/SmoothScrollEngine.swift`：按需启动有限后台计时器；主线程原生像素事件输出；保留分数像素余量；切换目标和反向时取消旧轨迹；普通滚动通过本项目新写的 `ScrollRoutingTap.swift` 在 annotated-session 尾部按真实目标应用分流；早期监听只做手势仲裁。生成事件使用独立标记，按住横移仅转换一次。原生触控板保留时序，Logitech 后台进程标记的鼠标连续输入可进入引擎。
- `Sources/ScrollProfile.swift`：新配置模型，使用像素、毫秒、倍率及 bundle identifier 应用规则。不读取第三方 UserDefaults，不复用旧参数转换。
- `Sources/SmoothSettingsView.swift`：新布局与调节单位。控制键沿用本项目已有的组合键录制拦截器，不包含旧第三方单键录制实现。
- `SmoothChecks/`：独立预期值与原生接收端测试，不带历史上游源码或逐帧对照测试。

本版没有包含历史平滑模块的源码文件、旧峰值过滤器、旧插值器、旧阶段状态机、旧 CVDisplayLink 派生文件、第三方配置导入器或其源码对照测试。用户可感知的平滑／反转／应用规则等功能是设计目标，不表示算法逐帧一致或设置数值可互换。

这份记录描述实际工程更换范围，不能替代针对具体发行场景的法律判断，也不是“没有任何版权风险”的保证。

## 继续保留的来源

原生捏合字段参考、Apple Silicon DDC 参考，以及 BetterDisplay 本地通知接口参考的 MIT 署名和全文仍在 `THIRD_PARTY_NOTICES.md`，并随二进制分发。它们没有因平滑模块重写而删除。

## 宣传片素材

`Promo/Promo.swift` 绘制原创电脑、人体工学鼠标和界面示意，`Promo/music.py` 合成原创配乐。公开工程不包含旧宣传片所用的 Logitech 官网产品渲染图、下载页面或素材包。产品名称仅说明适用设备，无厂商标志、赞助或背书声明。系统字体与 SF Symbols 在 macOS 上调用，不随源码附带字体文件。

## Preview 2 同步范围与设备协议

自动学习进度、自定义格数、独立重置、学习状态、静默启动、关于窗口、圆环指针反馈回调、直接显示桌面等，迁入的是本项目自用分支中的宿主程序贡献。没有迁入该分支的 Mos 核心、配置类型、旧平滑包装或私人震动驱动文件。公开版继续使用有限五次轨迹、像素／毫秒配置和独立应用规则。

`Sources/MouseDeviceFeatures.swift`、`HIDPPLink.swift`、`MasterMouseController.swift` 为本次单独编写的 Swift 协议适配层，使用 IOKit 非独占设备访问，不分发 Solaar、OpenLogi 或 Logitech 的驱动代码。其协议事实参考：

- [Logitech HID++ 2.0 官方报文说明](https://github.com/Logitech/cpg-docs/blob/master/hidpp20/README.rst)：7／20 字节包、设备槽位、特征索引、操作号和软件标识。
- [Logitech HiRes Wheel 0x2121 v0 文档镜像](https://lekensteyn.nl/files/logitech/x2121_hires_wheel.pdf)：读取棘齿状态与状态通知，仅查询、不设置硬件滚轮模式。
- [OpenLogi 的 0x19B0 协议说明](https://openlogi.org/hidpp/features/x19b0-haptic-feedback)：能力掩码、配置、已知类型的震动脉冲。此项属于公开逆向资料，并非 Logitech 官方发布的震动规范。未复制该页示例或其 Rust 实现。

设备适配先读原强度，再写有限范围强度并读回实际值，只播放设备声明支持的已知脉冲；圆环结束后恢复自有改动，检测到其他应用的改动时不覆盖。模拟设备验证不能代替真实固件验证。本次没有声称严格净室、第三方算法等价或硬件手感完全一致。直接显示桌面仍使用系统未公开的 Dock 通知接口，存在系统兼容边界。

## Preview 3：投递与挡位修正

普通平滑输出继续由本项目实现。`ScrollOutput.swift` 保留原事件的窗口路由封装，只替换滚动载荷；单独反转直接修改原事件。后台时钟只在有未完成轨迹时启动，结束后停止。事件通过正常 session 事件流投递，以自己的标记避免再次处理。本次没有复制私人版的 Mos 插值器或帧状态机。

`WheelProfileSelection.swift` 是两版共享的本项目宿主代码，负责自动／手动选择、保存状态和按特征区分的协议数值解释。新增读取参考 [Enhanced SmartShift 0x2111 协议资料](https://openlogi.org/hidpp/features/x2111-smartshift-enhanced) 及 [Logitech 0x2110 原始说明镜像](https://lekensteyn.nl/files/logitech/x2110_smartshift.html)。只查询模式，不修改硬件模式、阈值或阻尼。SmartShift 临时自动释放时，设备仍可能报告配置中的棘齿模式；软件不以滚速猜测切挡。
