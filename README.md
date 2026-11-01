# 微博 iOS 客户端（参考 Android 版实现）

一个用 **SwiftUI** 原生开发的微博第三方客户端，界面与核心功能参考自开源的 Android 微博客户端，**并沿用其数据层方案**。

> ⚠️ 本项目为非官方、仅供学习与技术参考的第三方客户端，与微博（新浪）官方无任何关联。请遵守微博开放平台及相关使用条款，勿用于商业或违规用途。

## 参考来源 / Reference

本项目的整体设计、功能拆解以及「登录 + 取数」的数据层思路，均参考自以下开源 Android 项目：

- **Android 原项目**：[`gaoxipeng/Android_16_Weibo`](https://github.com/gaoxipeng/Android_16_Weibo)
- 原项目基于 Jetpack Compose + Kotlin 实现；本仓库用 SwiftUI 复刻其核心功能。

数据层方案（与原项目一致）：

1. 通过 **WKWebView** 打开微博网页登录页，登录成功后从 `WKWebsiteDataStore` 读取 Cookie；
2. 携带该 Cookie，配合桌面端 `User-Agent`、Referer、XSRF-Token 等请求头，直接调用微博的 web 接口（如 `/ajax/statuses/*`、`m.weibo.cn/api/container/getIndex` 等）获取信息流、评论、用户、话题等数据；
3. 后续所有接口请求复用同一套 Cookie / 请求头封装（`WeiboHTTP`、`WeiboSession`、`CookieJar`）。

## 已实现功能

- 首页时间线（最新微博 / 好友圈 / 热门 / 同城 / 我的收藏 / 我的赞 等多频道切换）
- 微博详情、评论 / 转发 / 点赞
- 个人主页（资料、微博列表、相册）
- 搜索（用户、话题、关键词）
- 发微博（文字、图片、@、#话题#）
- 图片 / 视频浏览
- 设置与多账号管理（Cookie 持久化）

## 技术栈

- SwiftUI（iOS 17+）
- 手写的 `project.pbxproj`（Xcode 工程）
- 离线优先：首屏 JSON 内存 + 磁盘缓存（`FeedCache`），进入页面秒开旧内容、后台静默刷新
- 增量刷新：下拉刷新时保留已有微博，仅把新增微博插入到列表最前

## 构建与运行

```bash
# 打开工程
open Weibo.xcodeproj
```

- `PRODUCT_BUNDLE_IDENTIFIER` 当前为占位值 `com.example.myweibo`，请替换为你自己的 Bundle ID；
- 需要自备 Apple 开发者签名（证书 / 描述文件）才能在真机运行；
- 首次使用请通过 App 内网页登录获取 Cookie，之后即可拉取真实数据；
- 也可通过 `-demo` 启动参数进入演示模式查看全部界面（无需登录）。

## 目录结构（节选）

```
Weibo/
├── App/            # App 入口、全局状态、设置、账号
├── Core/           # 网络层 WeiboHTTP / WeiboSession / CookieJar / FeedCache / 解析器
├── Models/         # 数据模型
└── UI/             # SwiftUI 界面（时间线 / 详情 / 个人主页 / 搜索 / 发布 / 设置 等）
```
