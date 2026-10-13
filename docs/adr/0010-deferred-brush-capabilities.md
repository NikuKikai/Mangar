# ADR 0010：后续笔刷能力暂缓

- 日期：2026-10-14
- 状态：已接受，低优先级

## 决策

当前笔刷配置能够定义现有引擎支持的行为，但不代表覆盖 CSP 全部能力。以下能力记录为后续扩展，目前不实施：

- 手抖稳定器、速度相关修正及落笔后修正。
- 独立于压力的起收笔渐变、长度或百分比控制和收笔延长。
- 素材纸纹及缩放、旋转、反相、亮度、对比度、混合模式和按落点/整笔应用。
- 间距、宽高比、纹理、颜料等更多参数动态，随机角度、笔尖翻转。
- 色相、饱和度、明度动态和随机变化、副颜色混合。
- 独立粒子尺寸、密度、分布和方向的喷散系统。
- Ribbon 路径变形、往返及单次素材序列。
- 双重笔刷、保留 RGB 的彩色笔尖。
- 笔刷自身与同层像素的混合模式（独立于图层混合模式）。
- 更多混色行为、晕染宽度、模式和亮度修正。

用户决定以上项目目前优先级不高。重新启动相关工作时再确定顺序；漫画勾线与铅笔质感可优先考虑稳定器、起收笔、素材纸纹和更多参数动态。当前湿笔使用不可变笔前图层采样及颜料库，并非 CSP 各混色模式的一一对应实现。

## 参考

- https://help.clip-studio.com/en-us/manual_en/810_subtools/C.htm
- https://help.clip-studio.com/en-us/manual_en/810_subtools/S.htm
- https://help.clip-studio.com/en-us/manual_en/810_subtools/T.htm
- https://help.clip-studio.com/en-us/manual_en/810_subtools/B.htm
- https://help.clip-studio.com/en-us/manual_en/810_subtools/I.htm
- https://help.clip-studio.com/en-us/manual_en/810_subtools/Number.htm
