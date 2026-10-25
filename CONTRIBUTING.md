# Contributing

欢迎提交 bug 报告、界面改进和新的服务适配器。

## 开始

需要 macOS 13+ 和 Swift 5.9+。克隆后运行：

```sh
swift build
swift test
swift run QuotaBar --demo
```

如果只有 Command Line Tools 且缺少 XCTest，可运行 `./scripts/test-core.sh`（需要 Python 3）。

提交 PR 时说明问题、修改后的行为和验证方式。涉及数据解析或缓存新鲜度时，请加入有意义的测试。不要上传真实账户快照、会话正文、token、Cookie、证书私钥或 `.env`。

## 服务适配器

优先使用服务公开文档支持的接口。未知额度不能当成 0% 或 100%；必须保留原始观察时间，并处理过期和独立缺失的窗口。没有实际账户联调时，请明确说明。

## 发布

正式发布仅包含 Apple Silicon 的已公证 DMG。CI 产物未公证，不能作为公开安装包。发布者应使用自己的 Developer ID Application 证书、公证并验证 Gatekeeper；GitHub Release 只上传最终 DMG，校验文件可作为可选附加资产，不上传临时 ZIP 或源码压缩包。
