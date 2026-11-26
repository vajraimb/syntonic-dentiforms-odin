# Odin 与 C++：在这个项目里的对比

同一个程序写了两遍：一遍是 Aras 的 C++ 重制版，一遍是这个仓库里的 Odin 移植版。逐像素对照的结果是两者画得一样（见[验证报告](port-report.md)），所以语言没有改变结果，改变的是达到这个结果要写多少东西。

先说清楚这个对比的边界：

- **Odin 版是以 C++ 版为底稿移植出来的。** 它有 C++ 版当规格说明，是同一个程序的第二次重写。下面有些简化（比如用枚举代替继承）在 C++ 里同样做得到，不是 Odin 独有的能力。
- **C++ 版不是稻草人。** 它是 Aras 2026 年去掉多余抽象之后的版本，已经是相当干净的 C++。
- **平台覆盖不对等。** C++ 版有持续集成，覆盖 Windows、Linux、macOS 和网页；Odin 版只在 Apple Silicon 的 macOS 上构建过。
- **没有比较性能。**

移植和本文由 AI 助手（ZCode）完成。

## 规模

| | C++ 重制版 | Odin 移植版 |
|---|---|---|
| 源文件 | 33 个（17 个 `.cpp` 加 16 个头文件） | 19 个 |
| 行数 | 5146 | 4580 |
| 头文件 | 1405 行 | 没有这个概念 |
| `new` 和 `delete` | 约 50 处 | 3 处 `new`，1 处 `free` |
| 动态分配的容器 | `std::vector`、`std::string` | 2 个动态数组，其余是定长数组 |
| 平台和配置的条件编译 | 22 处预处理器指令 | 5 处 `when` |
| 构建配置 | 406 行（CMake、presets、持续集成） | 2 个脚本，71 行 |
| 编译整个项目 | 没有测 | 约 2.9 秒；第一次构建另加约 15 秒编译 C 库 |

行数少了 11%。按模块看，有三类情况：

| 情况 | 例子 |
|---|---|
| 变少了 | 数学 621 → 392，相机 172 → 110，动画 395 → 296，场景 1002 → 811，音乐播放 282 → 237 |
| 没变 | 管线 294 → 296 |
| 变多了 | 主程序 147 → 490，渲染 480 → 549，数据文件 234 → 297 |

变少的地方，省掉的就是下面说的那些东西。变多的地方和语言无关：`screenshot.odin` 的 215 行顶替了新版 sokol 里已经没有的一组库函数，`rendering.odin` 多出来的是顶点缓冲池，`data_tables.odin` 是生成的数据表。

## 优势

### 1. 没有头文件

C++ 里每个模块都是一对文件：头文件里声明一遍，源文件里定义一遍。`Scene.h` 需要 `#pragma once`，需要列出它依赖的头文件，需要写 `public:` 和 `protected:`。Odin 里一个模块就是一个文件，函数签名只写一次，没有依赖列表要维护，因为依赖就是 `import`，而且不需要头文件守护。

16 个头文件一共 1405 行。其中 `SceneData.h` 是数据表，`Maths.h` 大半是实现；剩下的 800 多行基本是纯声明和访问器，Odin 版里一行都不需要。

### 2. 数据就是数据

C++ 版的 `Scene` 拥有一批堆上分配的对象：

```cpp
// Scene.h
std::vector<SceneMesh> mMeshes; // owns meshes
// Scene.cpp
Scene::~Scene()
{
    int n = mMeshes.size();
    for (int i = 0; i < n; ++i)
        delete mMeshes[i].mesh;
}
```

`mMeshes` 里放的是指针 `MeshEntity *mesh`，对象另外 `new` 出来。`std::vector` 扩容时会搬动元素，放在里面的对象地址会变，而别处保存着这些对象的地址（比如六面墙各是哪个实体）；析构函数再逐个 `delete`。同样的模式在 `SceneTeeth` 里又出现了一遍，光那一个文件就有 18 处 `new` 或 `delete`。

Odin 版（[scene.odin](../scene.odin#L33)）：

```odin
Scene :: struct {
	meshes:     [SCENE_MAX_MESHES]Scene_Mesh,
	mesh_count: int,
	...
}

Scene_Mesh :: struct {
	entity: Mesh_Entity,
	...
}
```

`Mesh_Entity` 直接放在定长数组里，按值存放。没有分配，没有析构，没有“谁拥有谁”的问题：场景是全局变量，程序结束它才消失。整个移植版只有 3 处 `new`，2 个动态数组。

这不是说 C++ 做不到同样的写法，`std::array` 加值语义也可以。区别在于 C++ 里那是一种需要自觉的选择，Odin 里这是最顺手的写法。

### 3. 没有继承，用枚举区分几种情况

C++ 版的场景是一个基类加两个派生类，靠两个虚函数分派：

```cpp
// Scene.h
virtual void initialize();
virtual void evaluateMeshes(float t);
// SceneTeeth.h
class SceneTeeth : public Scene
```

Odin 没有继承。场景带一个种类，不同的那两步是一个 `switch`（[scene.odin](../scene.odin#L19)、[scene.odin](../scene.odin#L71)）：

```odin
Scene_Kind :: enum int {
	OUTER,
	NORMAL,
	TEETH,
}

scene_initialize :: proc(s: ^Scene) {
	#partial switch s.kind {
	case .OUTER:  scene_out_initialize(s)
	case .NORMAL: scene_initialize_hierarchy(s, scene_data(s.number))
	case .TEETH:  scene_teeth_initialize(s)
	}
}
```

这里只有三种场景、两个不同的步骤，`switch` 比类层次更直接：想看“牙齿场景的初始化有什么不同”，搜索 `case .TEETH` 就到了，不用在几个文件里找重写。`SceneOut.h`、`SceneOut.cpp`、`SceneTeeth.h` 加起来的 105 行，在 Odin 版里并进了 `scene.odin` 和 `scene_teeth.odin`。

Aras 自己在 2004 年的版本里砍掉了大量继承，剩下的这一点是合理保留的。Odin 的作用是不给你继承这个选项。

### 4. 条件编译是被检查的代码

C++ 版用预处理器处理平台差异：

```cpp
#ifdef _WIN32
    #include <direct.h>
    #define chdir _chdir
#else
    #include <unistd.h>
#endif
```

没有选中的分支预处理器不看，编译器也看不到，所以写错了要等到那个平台上才发现。

Odin 用 `when`，所有分支都会被类型检查（[screenshot.odin](../screenshot.odin#L22)）：

```odin
SCREENSHOTS :: ODIN_OS == .Darwin && ODIN_ARCH == .arm64
...
when SCREENSHOTS {
	...
}
```

调试版、发布版、Apple Silicon、其它架构，都是这样表达的。移植版只有 5 处，是因为它只管了一个平台；C++ 版的 22 处里有相当一部分是它多支持三个平台付出的代价。

### 5. 默认更严一点

- **变量默认是零值。** `desc: sg.Pipeline_Desc` 声明出来就是全零；C++ 版每一处都要写 `= {}`。
- **数字类型不自动转换。** `x := 0.0` 推断出来是双精度的 `f64`，拿去和 `f32` 混用直接是编译错误。C++ 会悄悄把运算提升成双精度，不报错，只是变慢或者结果差一点。
- **边界检查默认开着。** 调试版带边界检查，发布版用 `-no-bounds-check` 关掉。
- **可疑的写法直接报错。** `return` 之后还有代码、常量声明少了 `=`、给过程参数取地址、文件名以下划线开头，这些都过不了编译。移植时每一种都撞到过，每次都是一条明确的错误信息，改一行就好。
- **`odin check . -vet -strict-style` 通过。** 未使用的变量、变量遮蔽之类的问题在编译前就被报出来。

Hmm — "x := 0.0 推断出来是 f32 的双精度版本 f64" awkward. Rephrase: "`x := 0.0` 推断出来是双精度的 `f64`，拿去和 `f32` 混用直接是编译错误。"

Wait, is that accurate? In Odin, `x := 0.0` gives f64 (untyped float literal default type is f64). ✓. Then using x with f32 → compile error (no implicit conversion) ✓.

"C++ 会悄悄把整段运算提升成双精度" — e.g., `float a; double b = 0.0; auto c = a * b;` → double. Yes, C++ promotes implicitly. ✓

### 6. 向量就是数组

Odin 的定长数组支持逐元素的 `+`、`-`、`*`、`/`，数组和标量相乘也可以。所以移植版里向量就是数组：

```odin
Vector3 :: [3]f32
```

`v1 + (v2 - v1) * alpha` 这样的写法直接可用，不需要为它定义任何东西。C++ 版为此给 `Vector3` 定义了 7 个运算符，给矩阵乘法定义了 1 个。

这是一个小的便利，不是大的节省：C++ 版的其它数学类型本来也是用具名函数写的。

### 7. 工具链

C++ 版要 406 行构建配置：CMake 的源文件列表、预设、两个持续集成流程。Odin 的编译器自己发现目录里的源文件，整个项目编译约 2.9 秒，不需要构建系统。移植版只有两个脚本共 71 行：一个编译 sokol 绑定的 C 库并调用编译器，一个生成 shader。

## 代价

### 1. 用 C 调用约定的过程没有上下文

Odin 的过程默认带一个隐式的 `context`（里面是分配器等东西）。声明成 `proc "c"` 的过程没有，因为 C 的调用者不会传。所以每个回调的开头都要装上默认的：

```odin
init :: proc "c" () {
	context = runtime.default_context()
	...
```

音频线程上的辅助函数也要标成 `proc "contextless"`，因为它们在回调里被调用，拿不到上下文。移植版有 12 个 `proc "c"`、4 个 `contextless` 过程。C++ 没有这个概念，回调就是普通函数。

### 2. 切片和字符串不拥有内存

Odin 的字符串和切片只是一段内存的视图。从文件缓冲区里读出一个名字，得到的是一个指向缓冲区的字符串；文件一关，它就悬垂了。移植时这里出过错：一条断言失败，追下去才发现名字指向了已经释放的内存。修法是显式拷贝一份（`strings.clone`）。

C++ 的 `std::string` 自动拷贝，原版用 `fgetc` 一个字节一个字节拼出来的 `std::string` 没有这个问题。

### 3. `copy` 按元素个数算

移植时最隐蔽的一个错误：

```odin
copy(transmute([]u8)anim.sample_data, data)
```

本意是按字节拷贝。但 `transmute` 不改变长度，`[]f32` 有 909 个元素，转成 `[]u8` 还是 909 个元素，于是只拷了 909 字节而不是 3636 字节。画面因此和原版差得很远。C++ 版是 `memcpy(dest, src, bytes)`，按字节计，没有这个歧义。修法是用 `mem.copy` 并显式写出字节数。

### 4. 生态还年轻

- `sokol-shdc` 能生成 Odin 代码，但输出里没有 `package` 和 `import` 两行，要自己补上（`tools/build_shaders.sh` 做的就是这件事）。
- sokol 的绑定要另外编译 C 库。
- 移植用的是 `dev-2026-11` 版的编译器。有些写法和网上教程里的不一样，比如 `foreign` 块的形式、常量声明必须带 `=`、`matrix` 是关键字所以变量得改名。每一条都不难，但加起来是不少来回。
- 发布版和调试版的构建都不是逐字节可复现的。发布版嵌着源文件的绝对路径，换一个目录构建校验和就不同；调试版即使在同一个目录里，每次构建也都不同，因为调试信息里带着随机命名的临时路径。都不影响运行，只是没法用校验和确认“这是同一份构建”。

### 5. 没有运算符重载

矩阵乘法只能写成 `matrix_mul(a, b)`。C++ 版的 `m = mrx * mrz * mry` 一眼能读，Odin 版是 `matrix_mul(matrix_mul(mrx, mrz), mry)`。数组和标量、数组和数组的运算有，数组和矩阵的没有。

Odin 有内置的矩阵类型，但它有自己的约定。这个 demo 用的是行向量的约定，为了和原版逐位一致，移植版用二维定长数组照搬，乘法写成具名函数。

## 没有差别的地方

- **填描述结构的代码一样长。** `Pipelines.cpp` 是 294 行，`pipelines.odin` 是 296 行。给图形库填参数的时候，两种语言没有高下。
- **跨线程的代码几乎一一对应。** `std::atomic<uint64_t>` 加上 `fetch_add`，对应 `sync.atomic_add_explicit(..., .Relaxed)`；`std::mutex` 对应 `sync.Mutex`。C++ 版用了 pimpl 把实现藏起来，Odin 版不需要，但那是设计选择，不是语言强制的。
- **画面一样。** 这是最重要的一条。

## 结论

对这个项目这一类的程序——一个人写的、几千行的、架在 C 库之上的图形程序——Odin 省掉的东西是实打实的：头文件、构建系统、所有权方面的样板。行数少 11%，文件数少 42%，需要自己管理的堆分配从约 50 处降到 4 处。

付出的是生态方面的代价：绑定要自己编译，工具的输出要自己补，编译器还在变，资料跟不上。还有几处比 C++ 更容易出错的地方，主要是切片和字符串不拥有内存。

两个版本画出来的画面一样。选语言决定的是写起来有多顺手、以后改起来有多放心，不决定效果。
