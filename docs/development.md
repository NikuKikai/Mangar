# 开发指南

## 环境

- macOS 与安装了 iPadOS SDK 的 Xcode。
- 运行目标为 iPad，最低系统版本为 iPadOS 17。
- GPU 检查需要支持 Metal 的 Mac；不需要连接 iPad。
- 真机绘画交互使用 Apple Pencil，设备需完成开发者模式及签名信任配置。

## 签名与构建

使用 Xcode 打开根目录的 `Mangar.xcodeproj`。

真机运行前，创建 `Config/Signing.local.xcconfig`：

```xcconfig
MANGAR_DEVELOPMENT_TEAM = YOUR_TEAM_ID
MANGAR_BUNDLE_IDENTIFIER = org.example.Mangar
```

将占位团队 ID 替换为有效的开发团队 ID，并设置可用于该团队签名的 Bundle ID。共享配置 `Config/Signing.xcconfig` 会自动读取此文件；本地配置已加入 `.gitignore`，无需修改共享工程文件。

在 Xcode 中选择 `Mangar` scheme 和目标 iPad，构建并运行。也可在仓库根目录执行：

```sh
xcodebuild -project Mangar.xcodeproj \
  -scheme Mangar \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/mangar-derived \
  build
```

## 验证

### GPU、模型与存储

```sh
Tests/BrushEngine/run.sh
```

检查执行生产 Metal 内核，并覆盖笔刷确定性、图层效果、连续选区、稀疏图块、存储缓存、视差坐标转换及 3D 预览等路径。

### 本地化

资源完整性和格式占位符检查：

```sh
python3 Tests/Localization/check.py
```

完成设备构建后，验证实际应用包中的三语资源：

```sh
Tests/Localization/run.sh /tmp/mangar-derived/Build/Products/Debug-iphoneos/Mangar.app
```

布局、Apple Pencil 输入和触摸手势需结合真机交互验证。

## 代码结构

| 目录 | 职责 |
| --- | --- |
| `Mangar/Editor` | 文档模型、编辑会话、命令历史、页面布局与坐标规则 |
| `Mangar/Rendering` | 图块索引与驻留、LOD、选区、图层合成和画布视口 |
| `Mangar/Brushes` | 笔刷模型、预设、素材、运行时、GPU 内核与参数界面 |
| `Mangar/Preview3D` | 展示形式、布局、几何、渲染器及预览界面 |
| `Mangar/Storage` | 工程读写、图块压缩、快照与派生缓存 |
| `Mangar/UI` | 共享控件与面板 |
| `Mangar/Localization` | 语言选择、文本访问和三语资源 |
| `Tests` | GPU、模型、存储与本地化检查 |

## 实现约定

- 已提交的文档修改通过编辑命令执行。交互预览与正式数据分离，取消操作不修改已提交像素。
- 画面窗口、图层局部坐标、内容边界和脏区域分别管理。显示偏移不得搬移图块或删除窗口外数据。
- 笔刷执行、连续选区处理与图层合成使用 GPU；图块按需分配，保持可见范围查询与缓存预算一致。
- 界面保持紧凑、即时响应。使用 `ImmediateButtonStyle` 和 `immediateUI()`，禁止 UIKit 隐式动画；翻页等表达操作过程的动画单独管理。
- 界面文本集中在 `Localizable.xcstrings`，通过 `L10n` 访问。项目名、图层名等文档内容不随界面语言改写。
- 架构变更在 `docs/adr` 中记录适用范围、决策、约束及与既有决策的关系。
- 本地签名配置、用户工程、构建产物及临时检查输出不纳入版本控制。第三方代码与素材保留来源和许可记录。
