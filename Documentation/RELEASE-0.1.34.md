# v0.1.34 正式发布记录

2026-09-27。**GPT TouchBar HUD v0.1.34 / Build 37 已正式发布并设为 Latest。**

- [正式 Release](https://github.com/zz-zed/GPT-TouchBar-hud/releases/tag/v0.1.34)；标签指向源码提交 `7ad2f1846a636dba362d9afa18897e16695036f8`。
- [main 双架构构建](https://github.com/zz-zed/GPT-TouchBar-hud/actions/runs/36316684241)与[标签发布工作流](https://github.com/zz-zed/GPT-TouchBar-hud/actions/runs/36317425696)均成功。发布工作流只复用该提交的同一轮 Apple Silicon / Intel 构建，没有重新编译或回退到其他提交。
- 正式说明与标签提交中的 `RELEASE_NOTES.md` 一致。Release 公开、非预发布，四份预期附件齐全。

## 公开产物核验

| 附件 | 字节数 | SHA-256 |
| --- | ---: | --- |
| `GPT-TouchBar-HUD-0.1.34-arm64.dmg` | 3,626,620 | `ee50d23664027dde8c851fd1de403d0be8d87b89cc26797ee056b93a1cff2a4b` |
| `GPT-TouchBar-HUD-0.1.34-x86_64.dmg` | 3,738,360 | `307ba3f8ecd5021c8cc0628abe70ca54143bbe208aa8059003bb70872d072655` |
| `SHA256SUMS.txt` | 201 | `0d60a6d003e4625a3dd5b242f219f707ec0cecb1e808416c208c334abec751e1` |
| `build-manifest.json` | 4,010 | `2fd61018d8d7845d417d1bd6932f0d60bba6f2310365ce2055762ec626d8978f` |

上述附件从公开 Release 重新下载，逐一与 GitHub 摘要和大小比对；两份 DMG 另与 `SHA256SUMS.txt` 和构建清单核对。DMG 完整性、只读挂载、包内版本 0.1.34 / Build 37、应用标识、主程序及 helper 架构、macOS 11.0 最低系统标记、严格签名、首次打开助手 CDHash 绑定均通过。挂载卷已卸载。[机器可读核验清单](validation/release-0.1.34-publication.json)保存来源和附件结果，下载文件留在本地 `build/release-evidence/publish-0.1.34/`。

## 边界

未替换或启动已安装应用。Intel 构建由 GitHub Actions 的 Intel runner 验证；真实 macOS 11 运行、实体 Touch Bar / 刘海完整场景，以及正式安装路径的自动更新端到端仍待相应设备验收。安装包为 ad-hoc 签名，未经 Apple 公证。升级前需退出所有旧版实例。
