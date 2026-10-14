# Mangar

供自己和家人使用的 iPad 漫画绘画 App，使用 SwiftUI 与 Metal 开发。

目前支持多页工程、分块画布、铅笔/G 笔/持续出墨针管笔/二值笔和橡皮擦、矩形与套索选区、套索填充、图层、文件夹、纯色背景与单通道蒙版、撤销重做，以及 PNG 导出。启动时显示项目卡片；工程保存在 App 的 Documents 目录，也可通过「文件」访问和导入。绘画图块以 LZFSE 无损压缩并增量保存。

使用 Xcode 打开 `Mangar.xcodeproj`，选择 iPad 后运行。项目最低支持 iPadOS 17。首次在自己的设备上运行前，把 `Config/Signing.local.xcconfig` 中的团队 ID 和 Bundle ID 改为自己的值；该文件不会进入 Git。

界面以即时响应为原则：不使用淡入淡出、缩放、弹簧等装饰性过渡动画。SwiftUI 根视图及独立悬浮面板使用 `immediateUI()`，按钮使用 `ImmediateButtonStyle`；UIKit 属性更新禁止隐式动画。

笔刷代码按 `Mangar/Brushes/{Model,Presets,Runtime,GPU,UI}` 划分。架构决策见 [ADR 0007](docs/adr/0007-brush-engine-v1.md)。左侧工具栏提供铅笔按钮，以及右滑展开并释放选择的墨水笔按钮（G 笔、针管笔、二值笔）；参数面板只显示当前工具参数，大小与 topbar 同步；大小、流量、不透明度可分别配置压力、速度、倾斜的平滑响应曲线和开关。着墨方式（颜料/墨水）、笔尖二值化和累积模式均可调整。铅笔倾斜时尺寸增大，每支笔独立记忆尺寸等参数，颜色在笔刷间共享，均属于应用设置。G 笔和针管笔的出墨量影响宽度、内部保持原色；针管笔快速移动会变细、按住不动时持续扩墨；二值指笔尖边缘不抗锯齿，不限制颜色选择。

在支持 Metal 的 Mac 上执行 `Tests/BrushEngine/run.sh` 可运行生产 GPU 内核检查（无需连接 iPad）。

笔尖素材直接在笔刷参数面板中设置，通过「+」从文件导入图片。导入通道可选透明度或灰度（黑色着墨）；最多 16 张素材，最长边 1024 像素。可设宽高比、偏角、固定/运笔/笔倾方向及顺序/随机素材选择。笔刷资源的持久化结构位于 Application Support/BrushResources，定义修订与 R8 素材分开保存；当前颜色不属于资源配方。历史笔画冻结素材与完整参数。笔刷库及创建、复制、重命名等管理界面暂不提供。详见 [ADR 0008](docs/adr/0008-brush-resources-and-image-tips.md)。

工具栏的油画笔组当前提供一支「平头油画笔」，使用 David Revoy 的 CC0 `chisel_streaks.png` 刷毛素材，随运笔方向旋转，压感控制大小与颜料流量，参数独立记忆。油彩现在支持拾色、光谱颜料混合与颜料耗尽；不包含厚度模拟。素材来源与许可见 [第三方素材记录](docs/third-party/oil-flat-chisel.md)。

新增水彩工具组及「水彩洗染笔」。笔刷参数中的「媒介」可选择普通、油彩、水彩，湿笔可调拾色量、混色强度、颜料量和携色距离，水彩另有含水量、颗粒强度与边缘积色。颜料量为 0 可携带当前图层已有颜色；每笔重新装载颜料。混色读取本笔开始前的当前图层，透明区域不当成黑色；没有跨图层合成取样。水彩是确定性的洗染近似，不模拟笔后流体扩散或真实纸张含水量。参考 [ADR 0009](docs/adr/0009-wet-paint-and-pigment-mixing.md) 和 [Spectral.js MIT 授权记录](docs/third-party/spectral-mixing.md)。

选区存在时，topbar 的工具属性左侧可切换蓝色连续覆盖率观察、反转或清除选区。油漆桶参考当前编辑图层或蒙版，可设置容差与闭合间隙，并支持选区和透明色。图层曲线按钮紧邻网点按钮；点击启用、下滑展开参数。RGB 总曲线及独立通道实时预览，参数区与网点互斥，两个效果可同时启用。详见 [ADR 0011](docs/adr/0011-selection-inspection-bucket-and-layer-curves.md)。

界面支持中文、日文、英文，默认跟随系统或 iPad 设置中的 App 语言，也可在应用设定中指定；不改写已有项目和图层名称。翻译集中于 `Mangar/Localization/Localizable.xcstrings`。构建后执行 `Tests/Localization/run.sh` 检查三语资源和动态文本；详见 [ADR 0012](docs/adr/0012-system-language-localization.md)。

编辑菜单或项目管理右上角菜单 →「应用设定」可立即切换语言，也可选择「跟随系统」。设定自动保存，当前项目保持打开。

新建项目可选择「书籍」或「无限制」。无限制项目使用普通多页卡片，X、Y 轴分别设置起始（−∞ 或 0）和终止（固定坐标值或 +∞）。两种类型共用稀疏画布、按需图块缓存和 GPU 多级显示。背景为锁定的白色纯色图层，油漆桶在无限制项目中禁用。PNG 的有限轴保留设定尺寸，无限轴取内容范围；单张最多 16384 px/轴、6400 万像素。详见 [ADR 0014](docs/adr/0014-unrestricted-canvas.md)。

画布工具只接受 Apple Pencil，手指用于视口和历史手势。编辑 topbar 可切换像素标尺；右侧导航显示页面和旋转视口，可点按／拖动定位，回正和 100% 缩放按钮位于导航标题栏，100% 保持原视口中心内容位置。有效可见内容进入视口时对应图层眼睛高亮。详见 [ADR 0015](docs/adr/0015-viewport-rulers-and-navigation.md)。
