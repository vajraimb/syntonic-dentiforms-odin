# 技术特点分析

[Syntonic Dentiforms](https://github.com/aras-p/SyntonicDentiforms) 是立陶宛小组 Nesnausk! 在 Breakpoint 2004 发的 demo，拿过 scene.org 的 Breakthrough Performance 奖。它当时是 Windows 上的 Direct3D 9 程序；2026 年 Aras Pranckevičius 用 sokol 重制了它，把 2.4 万行代码缩到 6 千行（[博文](https://aras-p.info/blog/2026/04/13/Syntonic-Dentiforms-redux/)）。这个仓库里的 Odin 移植版是 4580 行，shader 一共 528 行。

它的效果不是靠引擎堆出来的，而是靠几个很省的办法，每个办法只用一个量，并且用到底。本文逐个说明这些办法，最后谈谈它的品味从哪里来。

文中引用的代码都在这个仓库里。shader 与 C++ 版逐字相同。

## 一帧是怎么画出来的

内景的一帧按下面的顺序绘制，代码在 [`demo_update`](../demo.odin#L461)：

| 顺序 | 做什么 | 画到哪里 |
|---|---|---|
| 1 | 阴影图：从灯的位置把场景画一遍 | 1024×1024 的深度图 |
| 2 | 镜面反射：对每面看得见的墙，把相机镜像过去再画一遍 | 最多 6 张半分辨率的图 |
| 3 | 主画面：带阴影的光照，再叠上镜面墙 | 全尺寸，4 倍多重采样 |
| 4 | 二维层：致谢文字、节拍提亮、转场闪光 | 主画面 |
| 5 | 辉光：缩到 1/4、模糊 4 遍、加回主画面 | 两张 1/4 尺寸的图 |
| 6 | 输出到窗口 | 窗口 |

最费的是第 2 步：算上阴影图和主画面，场景最多要画 8 遍。外景简单得多，只有主画面和后处理。

## 1. alpha 通道被当成“发光蒙版”

光照 shader 只有几行（[lib_lighting.glsl](../fx/lib_lighting.glsl#L44)）：

```glsl
res.rgb = vec3(diff + spec);
res.a = spec;
```

`diff` 是漫反射乘 0.5，`spec` 是 16 次幂的高光。RGB 是正常的颜色，alpha 被拿来存高光的强度。

后面的辉光模糊**只读 alpha**（[postBlurStep.glsl](../fx/postBlurStep.glsl#L24)）。所以不需要另外画一遍“哪里该发光”：高光自然发光，纯黑背景（清屏时 alpha 是 0）不发光。镜面墙以 25% 的不透明度叠上去之后，alpha 变成原来的四分之三加 0.06，所以墙有一层很淡的光。

模糊在 1/4 分辨率下做 4 遍，每遍在四个角上各采一次，间距逐遍增大（[ping_pong_blur](../rendering.odin#L197)）。模糊的结果乘上一个固定的暖白色 `(1, 0.97, 0.92)`，再按加法叠回主画面（[render_bloom](../rendering.odin#L215)）。

齿轮像雾里的抛光金属，主要靠这一条。

## 2. 镜面房间：对每面墙把相机镜像过去，再画一遍

房间是个立方体，六面墙在离原点 10 个单位的地方。对视野里的每面墙，把相机矩阵沿墙面翻折（[reflect_matrix](../demo.odin#L204)、[render_wall_reflections](../demo.odin#L223)），用镜像后的相机把场景再画一遍，存进一张半分辨率的图。墙面再按投影坐标去取这张图，以 25% 的不透明度叠上去（[renderReflective.glsl](../fx/renderReflective.glsl#L30)）。

反射在几何上是正确的，所以有“齿轮无限延伸”的纵深感。代价是一帧最多要把场景画 8 遍。两个办法压住它：看不见的墙按视锥剔除，反射只画到半分辨率。

## 3. 一盏灯，光斑的形状来自一张贴图

内景只有一盏聚光灯。光照 shader 在阴影图的投影坐标上采样一张贴图 `SPOT_LIGHT`，把结果乘进阴影（[renderLitShadowed.glsl](../fx/renderLitShadowed.glsl#L98)）。于是灯的形状是一张图，不是 shader 里的公式。画面里那些边界分明的大块亮区是“打”出来的。

阴影用一张 1024 的阴影图。滤波是 Ignacio Castaño 的优化（[sampleShadow](../fx/renderLitShadowed.glsl#L49)）：5×5 的效果只需要 9 次采样，而不是 25 次。阴影图里画的是物体的背面，用来减少阴影边缘的条纹。

## 4. 一切都是时间的函数，音乐就是时钟

没有物理，也没有模拟。齿轮的变换是 `初始角度 + 角速度 × t`，再沿父子层级乘起来（[scene_evaluate_hierarchy](../scene.odin#L172)）。相机和灯是手工调好的动画曲线，按 t 采样（[animation_sample](../animation.odin#L110)）。

t 取自音频线程已经交给声卡的采样数（[vorbis_player_get_time](../music_player.odin#L87)）。所以画面跟着声音走，掉帧也不会漂。

任何一帧都能单独算出来。调试模式能逐帧拖动，[验证报告](port-report.md)里的逐帧对照也靠这一点。

## 5. 转场是“闪白”，不是“淡黑”

同一个 alpha 机制在这里又用了一次。场景切换时的叠层是黑色的加法混合（[demo.odin](../demo.odin#L644)、[OVERLAY1 管线](../pipelines.odin#L183)）：RGB 加的是 0，只往 alpha 里加值。辉光链路把它变成整屏的暖白闪光。alpha 最多加 1，所以场景切换时整屏泛白。

到指定的帧，画面会几乎定住 3.75 秒（[demo.odin](../demo.odin#L496)），致谢的一行字沿一条红线飞进来，进出各闪一下，alpha 最多加 0.5。

节拍另有一层。一条手工画的节拍曲线 `Synch.danim` 里的 `BeatBox`，在当前时刻和前后各采一次，三个值相加乘 0.08，用来提亮整屏（[demo.odin](../demo.odin#L623)）。`OVERLAY2` 管线的混合方式是“目标颜色乘以源颜色，再加目标颜色”，所以是按比例提亮：亮处闪得明显，暗处几乎不动。

## 6. 最后一场的卡通上色是 2004 年的老办法

最后一场把前面的黑白画面变成黄紫配色的漫画（[scene_teeth_render_stuff](../scene_teeth.odin#L369)）：

- **查表上色。** 把画面按 (alpha, 红色) 两个值去查一张二维色表 `COLOR_LUTS`（[postToon.glsl](../fx/postToon.glsl#L22)）。
- **差分描边。** 比较当前像素和左右上下四个邻居的红色通道，差得大的地方压暗（[postToon.glsl](../fx/postToon.glsl#L26)）。
- **模糊蒙版。** 把牙齿放大 6 倍画成纯白，缩到 1/4 分辨率后模糊 5 遍，再拿它的值去查另一张表 `ALPHA_EDGE`（[postComposeToon.glsl](../fx/postComposeToon.glsl#L22)）。牙齿背后就出现一团边缘柔和的色块。

## 7. 数据极简

每个顶点 16 字节：三个 `f32` 的位置，加压缩成 4 个字节的法线（八面体压缩，[gfx.odin](../gfx.odin#L12)）。

动画是等间隔采样的曲线。每条曲线的采样点数相同，不动的曲线只存一个值；位置线性插值，旋转用四元数球面插值（[animation.odin](../animation.odin#L4)）。

| 数据 | 大小 |
|---|---|
| 49 个模型加 13 个动画文件 | 1.1 MB |
| 19 张贴图 | 1.0 MB |
| 音乐 | 4.4 MB |

整个 demo 最大的文件是音乐。

## 品味从哪里来

这一节是解读，不是作者的说法。

- **一个主意到处复用。** 高光、辉光、转场闪光，都来自同一个 alpha 通道。
- **配色克制。** 正片基本是黑、白、暖白，大片颜色留到最后一场。暖白色是有意的：纯白的辉光像相机过曝，偏暖一点像光。
- **辉光是材质，不是滤镜。** 光从物体自己身上发出来，而不是给整张图加特效。
- **剪辑感。** 镜头、灯、停顿都是手工调出来的曲线和帧号，代码只是忠实回放。品味更多在那些动画数据里，不在渲染代码里。
- **手绘和幽默。** 致谢、牙齿、问候都是画的二维素材，牙齿贴图用一串名字命名。

Aras 的重制也是同一个态度。他说 22 年前的代码“全是没必要的抽象和设计模式”，动画系统从 14 个类和接口缩成了 3 个结构体。

## 想读代码的话

最短的两份 shader 是 [lib_lighting.glsl](../fx/lib_lighting.glsl)（光照全文 52 行）和 [postToon.glsl](../fx/postToon.glsl)（查色表加描边，40 行）。主循环在 [demo.odin](../demo.odin#L461)。
