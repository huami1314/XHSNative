# XHSNative

小红书 iOS 液态玻璃插件。iOS 26 及以上用系统的液态玻璃，更早的系统用插件画的仿玻璃（由 [@5hux1n](https://github.com/5hux1n) 适配）。

> **测试环境**：小红书 `9.55` · iOS `27.0`

## 功能

- **底部标签栏**：支持拖动排序、隐藏和滚动收起，搜索入口独立显示，可与发布对调，可显示文字。
- **首页顶栏**：液态边缘效果，及部分布局调整，频道可隐藏、排序、改名，可隐藏红线。
- **液态玻璃**：覆盖图文笔记、视频、搜索、评论、消息和个人页，支持分项开关，部分控件可调不透明度。低系统上没有消息顶栏和私聊输入栏，多了模糊程度和底栏图标、文字大小。
- **保存**：笔记和评论里的图片、实况、视频无水印保存，可解除作者的保存限制。
- **其他**：禁用点点 AI，双击放大笔记图片。

设置入口在小红书「设置」→「XHSNative」。

## 安装

[Releases](https://github.com/huami1314/XHSNative/releases) 里有：

- `XHSNative-<版本号>.dylib`：注入 IPA 用。
- `com.huami.xhsnative_<版本号>_iphoneos-arm64.deb`：无根越狱。
- `com.huami.xhsnative_<版本号>_iphoneos-arm64e.deb`：roothide。

## 编译

在装有 [roothide/theos](https://github.com/roothide/theos) 的机器运行：

```bash
make                          # dylib
make package                  # 无根 deb
make package SCHEME=roothide  # roothide deb
```

产物都在 `packages` 目录。

## 声明与许可

- 本项目采用 [MIT](LICENSE) 许可证。
- 仅用于学习研究目的，侵删。
