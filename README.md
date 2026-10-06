# Mangar

供自己和家人使用的 iPad 漫画绘画 App，使用 SwiftUI 与 Metal 开发。

目前支持多页工程、分块画布、画笔和橡皮擦、选区、图层与文件夹、撤销重做，以及 PNG 导出。启动时显示项目卡片；工程保存在 App 的 Documents 目录，也可通过「文件」访问和导入。绘画图块以 LZFSE 无损压缩并增量保存。旧版 `Mangar.mangar` 工程会出现在项目卡片中，首次保存时迁移存储格式。

使用 Xcode 打开 `Mangar.xcodeproj`，选择 iPad 后运行。项目最低支持 iPadOS 17。首次在自己的设备上运行前，把 `Config/Signing.local.xcconfig` 中的团队 ID 和 Bundle ID 改为自己的值；该文件不会进入 Git。
