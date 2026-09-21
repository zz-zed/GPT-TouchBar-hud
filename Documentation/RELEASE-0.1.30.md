# v0.1.30 正式发布记录

2026-09-21。**GPT TouchBar HUD v0.1.30 / Build 33 已正式发布，并设为 Latest。**

- [发布页](https://github.com/zz-zed/GPT-TouchBar-hud/releases/tag/v0.1.30)
- 源码提交：`5918205b4a1aa61490e09e26cee4eaf01f87ce9d`；标签：`v0.1.30`。
- [主分支 CI](https://github.com/zz-zed/GPT-TouchBar-hud/actions/runs/35568921551)：双架构通过。
- [标签 CI](https://github.com/zz-zed/GPT-TouchBar-hud/actions/runs/35569583070)：双架构构建与发布通过。

## 本次变化

“设置 → 通用 → 刘海常驻形态”提供 Compact / Peek 两项，未保存过选择时默认 Peek。已有 false / true 偏好分别保持 Compact / Peek；设置界面与实际面板共用读取逻辑，不重置显示模式或隐藏状态。原生预览默认 Peek，支持 `--compact`；轮廓、动画和详情交互沿用 v0.1.29。README 同步更新功能与数据来源说明。

## 正式安装包

| 架构 | 字节数 | SHA-256 |
| --- | ---: | --- |
| arm64 | 3145013 | `d78ed7a45e5b7751ca8c34260940692f85374b60b5c8627a78eb0c844c93c14a` |
| x86_64 | 3225504 | `ce664c38739387d40f71d6dea6e2fb33fb2e1fca2851bcc5c0adb9f204a68168` |

两个 DMG 均从公开 Release 下载。SHA256SUMS.txt、GitHub 附件摘要、DMG 完整性、只读挂载、0.1.30 / Build 33、应用标识、主程序和 HookEmitter 架构、minos 11.0、严格签名、第三方声明及首次打开助手 CDHash 绑定均校验通过。

## 验证

本地设置布局检查通过 158 项；原生检查最终通过 417 项、416 帧及真实 WindowServer 点击验证。一次本地静止指针用例受到外部鼠标移动干扰，未改断言，原样复验通过。
标签 CI：arm64 原生 422 项 / 186 帧，x86_64 原生 422 项 / 100 帧；两端均通过任务、更新、几何、首次打开助手、41 项 Hook 测试和签名检查。

[机器可读发布清单](validation/release-0.1.30-publication.json) 保存源码、CI 和附件对应关系。原始日志和下载包位于本地 `build/release-evidence/publish-0.1.30/`。未替换或启动用户已安装的 App。

## 验收边界

实体刘海接缝、全屏、多屏和唤醒仍需真机验收；未完成实际 macOS 11 运行和正式安装路径自动更新完整链路验收。安装包采用 ad-hoc 签名，未经过 Apple 公证。
