# iPhone Node 24 运行环境检查包

这份工程供“只有 Windows、能登录 GitHub”的用户在云端 Mac 编译一个 iPhone 测试 App。目标设备为 iPhone 12 / iOS 16.6.1（20G81）。

2026-11-05：已在用户授权下创建[公开测试仓库](https://github.com/DveRise/iphone-dsh-runtime-probe)，[首次 GitHub Actions 构建](https://github.com/DveRise/iphone-dsh-runtime-probe/actions/runs/42051269447)成功。用户仍只需要 Windows；iOS 编译由 GitHub 托管 Mac 执行。

它是官方 DeepSeek Harness 移植之前的运行环境验证，**尚未包含 dsh，也不是完整手机 Agent**。先确认 Node、ESM、中文处理、文件与网络功能，再处理 dsh 和手机自动化插件。

## 当前完成情况

- 已下载维护者的 Node 24.22.1-0 iOS 完整版预编译库。
- SHA-256 同时匹配发布页资产 digest 与发布者的 SHA256SUMS。
- 已在 Windows 解析实际二进制：真机 arm64 / iPhoneOS，最低系统 14.0，构建 SDK 26.5；配置上不排除 iOS 16.6.1，但这不证明实机运行成功。
- 本工程的原生宿主、JS 探测及手动云端构建流程已准备。
- 已通过本地 Python 语法检查、workflow YAML 解析及手动触发/只读权限检查；同一份 JS 的六项检查在 Windows Node v24.16.0 上全部通过，结果见 verification 目录。
- 已通过云端 macOS 编译、ad-hoc 签名校验和构建产物上传；生成 MobileRuntimeProbe.ipa 与 build-report.json。
- **尚未安装或测试真机。** 编译与 Windows JS 检查通过，不代表 iOS 运行能力检查已经通过。

## 检查什么

用户打开测试 App，点击“开始检查”，保持在前台。检查 Node 版本、ESM 主入口、中文 Intl、App 目录读写、loopback HTTP/fetch，以及不需要密钥的 npm HTTPS 元数据请求。页面可导出 JSON 结果及日志。

不调用模型、不读屏或点击手机其他 App。尚不验证子进程、原生扩展、锁屏和后台运行。每次启动进程仅启动一次 Node；重新测试需退出并重新打开 App。

## 如何从 Windows 使用云端构建

仓库与第一次构建已经完成。后续若需要重新编译，可按以下步骤手动触发；工作流不会因文档提交自动运行。

在已授权的仓库中：

1. 将本目录的内容放在仓库根目录，保留 `.github/workflows/build-ios.yml`。
2. 在 GitHub 的 Actions 中选择 **Build iPhone runtime probe**，手动运行。
3. 成功后下载名为 `iphone-runtime-probe` 的 artifact，取得 IPA 和 build-report.json。
4. 先检查构建报告，再确定用户同意的签名/安装方式；本工程不自动安装到手机。

无需向构建任务提供 Apple ID、Apple 开发者证书、模型 API Key 或手机数据。测试 IPA 使用 ad-hoc 哈希签名，不具备常规开发者配置文件，不能直接当成 App Store 应用点击安装；具体安装路线仍待确定，TrollStore 和越狱组件仍须另行授权。

[GitHub 文档](https://docs.github.com/en/actions/reference/runners/github-hosted-runners) 说明标准托管 runner 在公开仓库免费使用；私有仓库消耗账号包含的计算额度，超额可能计费。公开仓库会公开本工程代码。当前流程仅手动触发、20 分钟上限、不自动发布 Release。

## 可检查的文件

- `runtime_archive.py`：校验固定摘要、选择真机切片、解析最低系统版本。
- `build_ios.py`：云端获取同一份运行库，编译宿主并生成 IPA；只在 macOS 执行。
- `app/main.mm`：原生前台入口、日志及结果分享。
- `app/probe.mjs`：无需依赖或密钥的运行能力检查。
- `.github/workflows/build-ios.yml`：只读仓库权限、手动触发的云端编译。

本地只读校验命令：

```text
python runtime_archive.py /path/to/nodejs-mobile-ios-24.22.1-0.zip
```

## 运行库来源

这是社区维护者的预发布构建，不是 DeepSeek 的 iOS 产品。固定来源：[v24.22.1-0](https://github.com/fogtape/nodejs-mobile/releases/tag/v24.22.1-0)。完整 iOS ZIP 的 SHA-256 为 `3fa1b8fb0720768b01c2e0dae3a17e788476e8c1613a1d9a54e206793b45326e`。

构建时将该版本的 Node LICENSE 一并放进测试 App。[维护者构建说明](https://github.com/fogtape/nodejs-mobile/blob/d4aedf536d035bf4eeab7a7a6e18b73d154d0ea5/docs/BUILDING.md) 和发布说明是此流程的来源。实际产物、账号权限及设备运行结果仍要分别验证。
