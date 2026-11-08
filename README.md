# iPhone 前台交互版 Harness

0.3.1/build 4：针对用户在 iOS 16.6.1 工作区选择器遇到的 AbortSignal.any 缺失错误，增加仅在原生接口缺失时启用的兼容脚本。通过 WKUserScript 在页面脚本执行前注入，保持官方前端和后端认证不变。缺失 API、取消传播、取消原因、输入校验及嵌套组合等六组本地检查通过；真机工作区流程仍需复测。Safari 17.4 才加入此接口，见 [WebKit 发布说明](https://webkit.org/blog/15063/webkit-features-in-safari-17-4/)。

已验证的第二版启动检查保持不变。本目录是下一版独立源码。用户已授权本次及本项目后续常规源码更新、云端构建和测试 App 更新；越狱、系统修改和由助手发起的付费模型调用仍另行确认。交互版在补齐 CoreGraphics 后已完成云端编译和 IPA 校验，并通过 Sideloadly 更新成功；用户照片已确认官方中文前端首次渲染成功，当前等待工作区与模型配置。

目标为在 App 内显示官方 dsh Web 界面，支持前台持续运行、停止和导出状态。仍固定 @deepseek-ai/dsh 0.2.1-rc.5，沿用第二版已在手机验证过的 NodeMobile 库及两个加载器补丁。本版未接入跨 App 截图、触控和后台执行。

## 已实现

- UIKit 按钮启动独立 Node 线程；Worker 承载官方 Harness，避免其退出路径结束 UIKit 宿主。
- WKWebView 使用临时数据存储，保留官方 cookie 验证。主页面导航只允许当前 Harness 的 127.0.0.1 地址和端口，阻止外部页面及新窗口导航。
- 原生容器监听随机的 loopback 端口，通过每次新生成的随机 nonce 验证 Node 桥接消息。启动 URL 经 socket 在内存中传递，不写入文件或导出日志。
- ready 后保持 Harness 服务运行；停止按钮发送带 nonce 的命令；断开桥接时也清理服务。检查超时或清理失败时终止 Worker。
- 导出仅包含状态、检查结果和预先定义的错误代码；丢弃可能含配置值的原始上游日志。模型凭据不通过电脑或构建任务提供。
- 工作目录使用 iOS 文件保护属性。该版本只支持前台，停止后需要从多任务界面关闭 App 再重新打开，避免重复初始化 NodeMobile。

## 依赖修复

为修复此前审计的上游问题，锁定四个传递依赖 overrides：zod 4.6.7、undici 8.12.2、fflate 0.8.3、@modelcontextprotocol/client 2.3.0。dsh 自身版本未变。此次 npm audit --omit=optional 结果为 0 项已知漏洞，详见 dependency-audit.json；这不表示所有安全风险均已排除，也不覆盖预编译运行库和已打包的前端内部代码。

对应上游公告：[Zod](https://github.com/advisories/GHSA-mrhx-c7xc-m3w5)、[Undici](https://github.com/advisories/GHSA-4w7w-5xrc-9h26)、[fflate](https://github.com/advisories/GHSA-px8p-9vwx-vf98)、[MCP client](https://github.com/advisories/GHSA-6prh-2h8m-c8cw)。

## 本地验证和实际限制

verify-interactive.mjs 在 Windows Node 24.16.0 上启动真实官方 Harness，而非替身。三条端到端流程全部通过：认证后页面返回 200 且服务持续运行，正常停止清理后退出；错误 nonce 被拒绝；原生桥接断开后清理。三条流程均验证未认证访问返回 401，报告、日志没有启动 URL、cookie 或 nonce。测试未提交模型任务或提供模型密钥。结果见 verification.json。

JavaScript 和 Python 语法检查已通过，构建流程使用只读仓库权限、手动触发和锁定依赖安装；CI 增加依赖审计检查。云端依赖审计、原生 Objective-C++ / WKWebView 编译链接及签名验证均通过；安装完成。手机界面显示、交互和模型调用仍未验证。成功构建为 42494574927，源码提交 b74ba808e876fe8480e325aeb17dff1b44cd8a09。

应用声明 NSAllowsLocalNetworking，不开启任意公网明文访问。Apple 文档说明 iOS 10–16 默认允许 IP 地址本地连接；本项目仅导航至 loopback 服务。[Apple 文档](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowslocalnetworking)

## 拟进行的第三次构建

仍使用原公开仓库及 Bundle ID；显示名“DeepSeek助手”，0.3.0/build 3。云端执行手动 macOS 构建，产物经校验后再用 Sideloadly 更新测试 App。本次及后续常规构建和测试更新已获用户明确授权。

首次手机验收先确认界面能显示、操作和停止，不要求模型密钥。随后由用户在手机界面配置模型，再验证一次对话；对模型调用及手机控制的实现情况分别记录。安装任何越狱组件仍需单独授权。
