# Mangar

面向 iPad 的漫画绘画应用，使用 SwiftUI 和 Metal 构建，采用稀疏图块存储与 GPU 笔刷、图层合成架构。

## 功能

- **项目与页面**：书籍和无限制画布项目、独立页面文件、页面卡片、对开页排列及合并／拆分。
- **绘画**：铅笔、G 笔、针管笔、二值笔、油画笔、水彩笔及橡皮擦；支持笔尖素材、随机参数和压感／速度／倾斜响应曲线。
- **图层与选区**：图层文件夹、混合模式、单通道蒙版、网点、调整曲线，以及保留连续覆盖率的矩形／套索选区。
- **视图**：导航、标尺、透明对页与反面参考、书页和球面 3D 预览，以及普通平面图层视差。
- **存储与输出**：LZFSE 无损压缩、增量原子保存、透明合成缓存及 PNG 导出。
- **本地化**：简体中文、日文、英文，可跟随系统或在应用设定中选择。

详细行为和功能限制见[功能说明](docs/features.md)。

## 构建与运行

需要支持 Metal 的 iPad、iPadOS 17 或更新版本，以及安装了 iPadOS SDK 的 Xcode。画布绘画工具使用 Apple Pencil 输入。

使用 Xcode 打开 `Mangar.xcodeproj`。真机运行前，在 Git 忽略的 `Config/Signing.local.xcconfig` 中配置开发团队与 Bundle ID，选择目标设备并运行。

签名配置、命令行构建和测试步骤见[开发指南](docs/development.md)。

## 文档

- [文档索引](docs/README.md)
- [功能说明](docs/features.md)
- [开发指南](docs/development.md)
- [架构决策记录](docs/README.md#架构决策记录)

## 第三方组件与素材

- [平头油画笔素材：David Revoy，CC0](docs/third-party/oil-flat-chisel.md)
- [光谱颜料混色：Spectral.js，MIT](docs/third-party/spectral-mixing.md)
