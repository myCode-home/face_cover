# 脸罩 FaceCover

[![自检](https://github.com/myCode-home/face_cover/actions/workflows/ci.yml/badge.svg)](https://github.com/myCode-home/face_cover/actions/workflows/ci.yml)

一个 macOS 小工具：录视频的时候，用一张图片盖住自己的脸，可以连系统里正在放的音乐一起录下来，
录完在「录像库」里统一回看。

打开摄像头 → 自动找到你的脸 → 把选好的图片贴上去 → 直接录成一个 `.mov` 文件。
**图片是合成进视频画面再编码的**，所以录出来的文件里脸是真的被挡住了，不是靠屏幕上的贴纸糊上去。

---

## 装 / 跑

**普通使用**：双击 `dist/FaceCover-0.2.0.dmg`，把「脸罩 FaceCover」拖进「应用程序」。
（已经装好了：`/Applications/FaceCover.app`）

**自己改代码**：

```bash
./build.sh          # 只编译，产出 dist/FaceCover.app
./package.sh        # 生成图标 → 编译 → 跑自检 → 出 DMG 和 ZIP
./test.sh           # 只跑自检
```

只需要 macOS 自带的 Command Line Tools，**不需要装完整的 Xcode**。

### 分发

`./package.sh` 会产出两个文件：

| 文件 | 用途 |
|---|---|
| `dist/FaceCover-0.2.0.dmg` | 双击挂载，拖进「应用程序」 |
| `dist/FaceCover-0.2.0.zip` | 发给别人 |

> ⚠️ 这个 App 是**本地 ad-hoc 签名**的。在你自己这台机器上直接能用；
> 但如果通过微信/网盘发给别人，对方 macOS 会拦下来说「无法验证开发者」。
> 对方可以右键点 App → 「打开」→ 再点一次「打开」，或者执行
> `xattr -d com.apple.quarantine /Applications/FaceCover.app`。
> 要彻底解决得买苹果开发者账号做公证（notarization）。

## 权限

第一次打开会弹权限窗口，按需要允许：

| 权限 | 什么时候需要 | 不给会怎样 |
|---|---|---|
| 摄像头 | 一直需要 | 用不了 |
| 麦克风 | 声音来源选了「麦克风」或「两个都要」时 | 只能录画面或系统声音 |
| **屏幕录制** | 声音来源选了「系统声音」或「两个都要」时 | 录不到系统声音 |

> **为什么录个系统声音要「屏幕录制」权限？**
> macOS 没有提供只录系统声音的接口，ScreenCaptureKit 是唯一入口，而它统一归在「屏幕录制」权限下。
> 我们只添加了音频输出、不加画面输出，并且把屏幕捕获尺寸压到 2×2、帧率压到 1fps，基本不产生开销。
> 授权后需要**重启 App** 才生效。

要是误点了「不允许」：到「系统设置 → 隐私与安全性 → 摄像头 / 麦克风 / 屏幕录制」里把「脸罩 FaceCover」勾上，
再重开 App。App 里也有一个直接跳转到「屏幕录制」设置页的按钮。

> ⚠️ 每次重新 `./build.sh` 都会改变 App 的签名指纹，macOS 可能把新版本当成一个新 App 重新问你一次权限。这是正常现象。

## 怎么用

1. 点 **猪头头套** 使用内置特效；也可以点 **选择自定义图片…**，或者直接把图片拖到左边的预览画面上
   （建议用正方形 PNG、背景透明，比如表情包、卡通头像、贴纸）
2. 图片会自动跟着你的脸动。大小/位置不合适就用右边的滑块微调
3. 在「声音来源」里选要录什么
4. 点 **开始录制**（或按 `⌘↩`），再点一次停止
5. 视频存到 `~/Movies/FaceCover/`
6. 点 **录像库** 打开列表回看（录完会自动刷新，不用手动点）

## 录像库

单独一个窗口，可以边录边看。每一条显示：

- **首帧缩略图**（点一下直接播放）
- 录制时间和文件名
- 时长、文件大小
- **播放** 按钮；`⋯` 菜单里有「在访达中显示 / 复制文件路径 / 删除」

删除是**移到废纸篓**，不是永久删除，误删还能捞回来。右键行也有同样的菜单。

顶部有刷新按钮、总数量和总大小。`~/Movies/FaceCover/` 里的 `.mov` 都会被列出来，
所以你自己拖进去的文件也会出现。

## 面板上的开关

| 选项 | 说明 |
|---|---|
| 猪头头套 | 内置毛绒头套，有透明面孔开口和立体阴影，会跟随人脸位置、大小及歪头角度并录进视频 |
| 自动跟随人脸 | 关掉之后图片固定在画面中间，用滑块手动挪到脸上 |
| 大小 | 图片宽度相对脸宽的倍数 |
| 左右 / 上下 | 相对脸的位置微调，上下正值是向下 |
| 画面镜像 | 像照镜子一样左右翻转。翻转的是整帧，但**图片本身不会被左右翻过来**，所以带文字的表情包不会变成镜像字 |
| 显示人脸检测框 | 在预览上画出检测到的人脸位置（绿框 + 中心十字）。**只画在预览上，不会进视频**。用来排查「遮罩有没有对准脸」 |
| 声音来源 | 不录声音 / 只录麦克风 / 只录系统声音 / 两者都录 |

## 排查问题

每次运行都会把采集参数和跟踪位置追加到 `~/Movies/FaceCover/诊断.txt`，长这样：

```
[2026-10-13T14:07:29Z] 采集连接 isVideoMirrored 原本=false 支持镜像=true 强制关闭后=false
[2026-10-13T14:07:31Z] 人脸中心x=0.574 | 贴图中心x=0.574 | 镜像=开 | 逐帧检测=是 | 已追踪=是
```

每秒一行。**「人脸中心」和「贴图中心」应该永远相等** —— 贴图位置就是从人脸位置推导出来的。
如果这两个数不相等，才是真的 bug，把文件发给我。

## 自检

不存在「靠眼睛看着像对」这回事。四条链路都有无头测试，不需要摄像头、不需要任何权限：

```bash
./test.sh
```

1. **合成逻辑**（`Tests/Compositor/`）—— 真的构造像素缓冲区、把图片画进去，再逐像素采样，
   验证位置、缩放、偏移、镜像；包含「人脸横向移动时遮罩必须同向」的回归测试。
2. **录制管线**（`Tests/Recorder/`）—— 真的录出 `.mov`，再用 `AVAssetImageGenerator`
   把帧解回来逐像素确认脸被挡住、镜像方向正确。时间戳故意从一个大数值开始，验证开头没有空白。
3. **人脸跟踪**（`Tests/Tracker/`）—— 喂正弦摆动的人脸，用互相关算相位延迟和同向比例。
4. **音频混音**（`Tests/Mixer/`）—— PCM 格式归一化、麦克风+系统声音相加、饱和处理、时间轴连续性、收尾不丢样本。
5. **录像库**（`Tests/Library/`）—— 真的录三段小视频丢进临时目录，验证扫描、排序、时长/大小读取、
   缩略图生成与缓存、以及删除会进废纸篓。

## 开发流程

`main` 分支有保护规则，**不能直接推**，改动一律走 PR：

```bash
git checkout -b fix/某个问题      # 从最新 main 开分支
# ...改代码...
./test.sh                        # 本地先跑自检
git commit -am "说明"
git push -u origin fix/某个问题
# 然后去 GitHub 开 PR，等 CI 绿了再合并
```

CI（`.github/workflows/ci.yml`）在 macOS runner 上跑 `./package.sh`，也就是
**生成图标 → 编译全部源码 → 82 项自检 → 出 DMG**，并把 DMG 作为构建产物上传。

> 注意 `./test.sh` 只编译被测试的那几个模块，**不覆盖 `CameraEngine` / `ContentView` 这些界面和采集代码**。
> 所以 CI 里额外跑了 `./build.sh`，不然 App 本身编译不过都发现不了。

## 代码结构

```
Sources/
  FaceCoverApp.swift      App 入口、窗口
  CameraEngine.swift      采集会话、每帧调度、录制落盘、声音来源分发
  FaceTracker.swift       人脸框平滑 + 速度补偿（有测试）
  Compositor.swift        图片合成 / 翻转 / 调试框（有测试）
  Recorder.swift          .mov 写入配置（有测试）
  RecordingLibrary.swift  录像库的扫描/元数据/删除（有测试）
  LibraryView.swift       录像库界面
  AppPaths.swift          录像与诊断文件的存放位置
  AudioSource.swift       声音来源枚举
  AudioMixer.swift        PCM 归一化 + 混音（有测试）
  SystemAudioCapture.swift ScreenCaptureKit 抓系统声音
  PreviewView.swift       预览视图 + 拖拽放图片
  ContentView.swift       界面
Tests/                    四个自检程序，见上
```

## 几个实现上的坑（改代码前值得看）

- **坐标系**：Vision 的人脸框是「归一化 + 左下角为原点」，`CGBitmapContext` 架在
  `CVPixelBuffer` 内存上时原点也在左下角，而 buffer 第 0 行对应画面顶部 —— 三者天然对齐，
  **不需要**做 Y 轴翻转。乱加翻转会导致上下颠倒。
- **镜像和检测的先后顺序**：必须「先翻转整帧 → 再检测人脸 → 再贴图」。
  检测和贴图在同一个坐标空间里，遮罩和人脸才不可能分岔。
  把翻转做在贴图内部（第一版就是这样）会让「左右」滑块在开镜像时方向反掉。
- **采集连接不能重复镜像**：`AVCaptureConnection.automaticallyAdjustsVideoMirroring` 默认是 `true`。
  必须显式关掉，否则整帧会被翻两次，方向就乱了。诊断文件里会记录原始值。
- **色彩空间**：用 sRGB，不要用 `CGColorSpaceCreateDeviceRGB()`，否则贴上去的图片会被转换一次
  色彩空间，颜色发灰偏色（实测纯洋红 (1,0,1) 会变成 (255,64,255)）。
- **速度外推会放大噪声**：人脸框平滑里用速度做外推时，速度增益必须压得很低（0.20），
  否则逐帧检测噪声会被 `leadTime` 放大，人不动的时候遮罩反而更抖。
- **混音要等齐**：麦克风和系统声音是两条独立的数据流。只看到一路攒够一块就发出去，
  会把另一路同一时间段的样本整段丢掉。必须等两边都够（或某一路超时静音）再合成。
- **录制起头**：`AVAssetWriter` 的 `startSession` 要等到录制后的第一帧才调用，
  并传这一帧的时间戳，否则视频开头会多出一大段空白。
- **SwiftUI 宏**：这台机器只有 Command Line Tools，`SwiftUIMacros` 插件不存在，
  所以 **`@State` 用不了**（`@StateObject` / `@ObservedObject` / `@Environment` 是传统 property wrapper，没影响）。
  拖拽逻辑因此放在 AppKit 的 `PreviewNSView` 里，删除确认用 `NSAlert` 而不是 `.alert` 修饰符。
- **临时目录的 URL 陷阱**：`NSTemporaryDirectory()` 返回 `/var/...`，而 `contentsOfDirectory` 返回解析后的
  `/private/var/...`，两者字符串不相等。自检里比文件名而不是比完整 URL。

## 图标

`Tools/IconGenerator/main.swift` 用 CoreGraphics 直接画出来，没有任何外部图片素材：
深色相机镜头（六边形光圈）+ 一道斜着盖上去的橙色面罩（带两侧耳带）+ 右上角录制红点。

```bash
swiftc -O -o /tmp/genicon Tools/IconGenerator/main.swift
/tmp/genicon /tmp           # 产出 AppIcon.png（1024）和 AppIcon-preview.png（多尺寸预览）
```

`package.sh` 会自动调用它，用 `sips` 缩出全套尺寸、`iconutil` 打成 `.icns` 塞进 App 包。
改图标只要改这个 Swift 文件。

- **本机 Swift 版本和 CI 不一样**：本机是 Swift 6.4（Command Line Tools），
  CI 是 Swift 5.10（macOS runner 上的 Xcode）。同一个写法在 6.4 下能过，在 5.10 下可能是**硬错误**。
  已经踩过一次：

  ```swift
  var result: T?
  Task { result = try? await operation(); semaphore.signal() }
  semaphore.wait()
  ```

  Swift 5.10 报 `error: mutation of captured var 'result' in concurrently-executing code`。
  正确写法是用一个加锁的引用类型把结果传出来。**本地 `./test.sh` 全绿不代表能在 CI 上编译**，
  改完必须看 CI。

## 已知限制

- 只能录系统**输出**的声音，不能单独录某个 App 的声音
- 没有人脸的时候，图片会停在最后识别到的位置（这是故意的：宁可贴纸悬空，也不要突然露出脸）
- 这个 App 只能录它自己的摄像头画面。**Zoom / 腾讯会议 / 微信视频**里看到的是原始画面，
  不会带上脸罩 —— 那种需求要做虚拟摄像头（系统扩展 + 苹果开发者账号），是另一个量级的工作
