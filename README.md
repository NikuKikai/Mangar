# Mangar

供自己和家人使用的 iPad 漫画绘画 App，使用 SwiftUI 与 Metal 开发。

目前支持多页工程、分块画布、铅笔/G 笔/持续出墨针管笔/二值笔和橡皮擦、矩形与套索选区、套索填充、图层、文件夹、图形背景与单通道蒙版、撤销重做，以及 PNG 导出。启动时显示项目卡片；工程保存在 App 的 Documents 目录，也可通过「文件」访问和导入。绘画图块以 LZFSE 无损压缩并增量保存。旧版 `Mangar.mangar` 工程会出现在项目卡片中，首次保存时迁移存储格式。

使用 Xcode 打开 `Mangar.xcodeproj`，选择 iPad 后运行。项目最低支持 iPadOS 17。首次在自己的设备上运行前，把 `Config/Signing.local.xcconfig` 中的团队 ID 和 Bundle ID 改为自己的值；该文件不会进入 Git。

界面以即时响应为原则：不使用淡入淡出、缩放、弹簧等装饰性过渡动画。SwiftUI 根视图及独立悬浮面板使用 `immediateUI()`，按钮使用 `ImmediateButtonStyle`；UIKit 属性更新禁止隐式动画。

笔刷代码按 `Mangar/Brushes/{Model,Presets,Runtime,GPU,UI}` 划分。架构决策见 [ADR 0007](docs/adr/0007-brush-engine-v1.md)。左侧工具栏提供铅笔按钮，以及右滑展开并释放选择的墨水笔按钮（G 笔、针管笔、二值笔）；参数面板只显示当前工具参数，大小与 topbar 同步；大小、流量、不透明度可分别配置压力、速度、倾斜的平滑响应曲线和开关。铅笔倾斜时尺寸增大，每支笔独立记忆尺寸等参数，颜色在笔刷间共享，均属于应用设置。G 笔和针管笔的出墨量影响宽度、内部保持原色；针管笔快速移动会变细、按住不动时持续扩墨；二值指笔尖边缘不抗锯齿，不限制颜色选择。

在支持 Metal 的 Mac 上执行 `Tests/BrushEngine/run.sh` 可运行生产 GPU 内核检查（无需连接 iPad）。
