# Takes 开发说明

面向想自己构建、修改或发布 Takes 的开发者。普通用户请看 [README](../README.md)。产品方案见 [PRODUCT.md](PRODUCT.md)。

## 构建与运行

需要 macOS 15+、Xcode 26、[XcodeGen](https://github.com/yonaskolb/XcodeGen)（`brew install xcodegen`）。

```sh
./scripts/build.sh            # 生成 Takes.xcodeproj 并构建到 build/Takes.app
open build/Takes.app
```

首次启动会引导授权：屏幕录制（必需）、辅助功能（点击框选、按键显示）、麦克风、摄像头。

`build.sh` 首次运行时会调用 `scripts/setup-signing.sh`，在单独的钥匙串 `takes-signing.keychain-db` 里创建本地自签名证书「Takes Local Signing」。之后每次构建签名都相同，系统授权不会因重新构建而失效。

## 发布与更新

App 内置自动更新：每天检查一次 GitHub 仓库 [ai-suifeng/takes](https://github.com/ai-suifeng/takes) 的最新 Release，有新版本时弹窗提示，点「立即更新」自动下载、校验签名、替换并重启。菜单栏「检查更新…」和设置里的「更新」可以手动检查。

发布新版本（需要先 `gh auth login`）：

```sh
./scripts/release.sh 0.2.0 "这次更新的内容"
```

脚本会改版本号、构建通用二进制（Apple 芯片 + Intel）、打包 `dist/Takes-0.2.0.zip` 和固定名称的 `dist/Takes.zip`，并创建 GitHub Release。

**注意**：更新包必须和已安装的 App 签名一致才会安装，所以每次发布都要在保存「Takes Local Signing」证书的这台 Mac 上构建（证书在 `~/Library/Keychains/takes-signing.keychain-db`，请备份）。

官网在 `website/`（纯静态页面，可直接用 GitHub Pages 部署），下载按钮指向 `releases/latest/download/Takes.zip`。宣传视频工程在 `promo/`（HyperFrames，`cd promo && npx hyperframes render`）。

## 功能清单（按阶段）

| 阶段 | 功能 |
|---|---|
| P0 录制 | 全屏 / 窗口 / 区域（多屏时高亮标出将录制的屏幕，点其他屏幕即可切换；录制中该屏幕有红色描边）；麦克风 / 摄像头下拉选择设备并提示未授权；系统声音 + 麦克风 + 摄像头；倒计时；**暂停 / 继续**（每次暂停切成一段；暂停时录制区域变灰并提示「已暂停」）；**重录这一段 / 删除上一段**；继续前显示上一段画面的半透明叠影帮助对齐 |
| P1 历史 | 资料库按日期分组；缩略图、时长、段数、App；收藏、标签、重命名；移到废纸篓或彻底删除（可同时删除导出文件）；崩溃 / 断电后自动恢复未完成的录制 |
| P2 美化 | 光标重绘（平滑、放大、静止隐藏、点击波纹）；按点击自动缩放并平滑跟随；背景渐变 / 纯色、边距、圆角、阴影、比例；段间淡入淡出；快捷键显示；摄像头画中画；剪映式剪辑：在片段或波形上拖动选中一段（或按 I / O 标记）后一键删除或试听，鼠标悬停即预览该处画面，0.5×–2× 倍速播放；在播放头分割、向左 / 向右裁剪、拖动片段两端裁剪、删除片段，后面的内容自动接上；缩放轨道上左右拖拽即可选出要放大的时间段，选中缩放后在预览上拖动方框调整放大区域；预览悬停显示录制画面尺寸和背景边距；时间线声音波形（按采样时间戳精确对齐，显示的是实际会听到的音量）；声音增强（自动把讲解音量提到约 −16 LUFS，带压缩、限幅和降噪门）；撤销重做；MP4 / GIF 导出（可自定义文件名和保存位置）并自动拷贝到剪贴板 |
| P2.5 配音 | 编辑器里按 R（或点「配音」）从播放头开始，倒计时后边播放边录麦克风，给没有声音的视频补音；每段声音按播放器时钟定位到它录制时对应的帧，之后删减画面时声音跟着走；重录会覆盖原来那一段，可只删配音保留画面，可单独调音量并参与声音增强，录音时原声静音 |
| P3 讲解 | 录制时按住 Fn 点击：通过辅助功能读取按钮真实边界，自动画出贴合的高亮框（可选聚光灯 / 放大镜、自动编号 ①②③）；录制中 ⌥⌘D 打开画笔 / 荧光笔 / 箭头 / 矩形，支持激光笔淡出；编辑器里可增删改所有标注 |
| P4 隐私 | 手动打码（马赛克 / 模糊 / 色块）并可「跟随移动」；本地 OCR 扫描邮箱、手机号、身份证、银行卡、密钥、IP 一键打码；录制时隐藏指定 App 与系统通知；资料库可按画面中出现过的文字搜索 |

## 结构

```
Takes/
├── App/         入口、全局状态、权限、设置、快捷键、菜单栏
├── Model/       项目包格式（meta / events / edit）与几何类型
├── Recording/   ScreenCaptureKit 录制、分段写入、输入事件、录制工具条与 HUD
├── Library/     资料库扫描、崩溃恢复、历史界面
├── Render/      时间线映射、光标 / 镜头轨迹、Core Image 合成器、导出
├── Editor/      编辑器（预览画布、时间线、检查器）
├── Annotation/  点击智能框选（AX）、录制中实时标注
└── Privacy/     OCR、敏感信息检测、打码跟踪、画面文字索引
```

核心思路是录制与渲染分离：录制时不录光标，单独记录鼠标 / 点击 / 按键事件轨（`events.jsonl`）；所有缩放、光标、标注、打码都存成数据（`edit.json`），由同一个自定义合成器同时用于预览和导出，因此全部可以事后修改。

每次录制是一个 `.takes` 文件夹（默认在 `~/Movies/Takes`）：

```
xxx.takes/
├── meta.json             录制信息、片段列表、标签
├── segments/take-001.mov 每段一个文件（HEVC + 系统声音 + 麦克风），分片写入便于崩溃恢复
├── segments/camera-001.mov
├── events.jsonl          输入事件
├── live-annotations.json 录制中产生的标注
├── edit.json             编辑决策
├── ocr.json              画面文字索引
└── thumbnail.jpg
```

## 自测

```sh
build/Takes.app/Contents/MacOS/Takes --selftest /tmp/takes-selftest
```

会真实录制屏幕的一小块区域（含暂停、录制中重录、暂停后删段），然后打开编辑模型、渲染样帧、导出 MP4 和 GIF、运行敏感信息扫描和打码跟踪，最后录一次窗口。需要从已有屏幕录制权限的终端运行。

配音对齐单独测：`--voiceover-test <目录>` 把已知时间点的脉冲送过真实的播放器时钟、录音、合成和导出，测量成片里的误差（含麦克风丢帧、剪辑后、重新打开）；加 `--mic` 则用扬声器放滴声、真实麦克风收音，测整个回路（会发声；要有麦克风权限，用 `open -n build/Takes.app --args ...` 启动才算 App 自己的权限）。

调试参数：`--library <目录>` 临时使用另一个资料库，`--open <xxx.takes>` 直接打开编辑器，`--demo bar|hud` 显示录制工具条 / 直接开始区域录制，`--render <xxx.takes> <秒> <out.png>` 按当前编辑渲染一帧，`--export <xxx.takes> <out.mp4>` 按当前编辑导出，`--install-update <zip>` 直接安装一个更新包（测试更新流程）。这些参数不会写入用户设置。

调试参数（截图用）：`--open <xxx.takes>` 时可再加 `--tab <style|cursor|zoom|annotations|privacy|media>`、`--seek <秒>`、`--select zoom|blur|voiceover|clip[:序号]`，打开后把编辑器置于对应状态。
