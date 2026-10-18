# 鼠环 1.0 Preview 宣传动画

44 秒，1920×1080，60 fps，H.264 + AAC 立体声，MP4。

顺序：品牌 → Mac 与 MX Master 4 示意 → 滚轮学习 → 圆环与子菜单 → 自定义按键 → 平滑滚动 → Preview 收尾。

画面全部由 Promo.swift 绘制，鼠标和电脑为原创产品示意，不含官网产品图片、商标图形、厂商视频或字体文件。系统字体和 SF Symbols 由 macOS 提供。功能动效不是实机录屏，不承诺所有设备的外形或效果完全一致。music.py 原创合成配乐与操作声，无外部音频素材。

```sh
PYTHON=python3 ./render.sh
```

需要支持 macOS 27 的 Swift 工具链与 numpy。主脚本输出无声画面，Finish.swift 添加音轨，并逐帧解码检查帧数、时间戳、尺寸与时长。可单独运行 render 的 `--stills` 模式检查分镜，第二个参数传入静帧输出目录。

本工程原创代码和绘图按项目 MIT 许可提供，Apple、Mac、Logitech、MX Master 等名称的商标权归相应权利人；没有官方关联。
