# PersonalFinanceOS

PersonalFinanceOS 是面向 iPhone 和 iPad 的本地优先个人记账应用。支持收入、支出、转账和退款，以及账单导入、日历、分类统计和本地备份。应用使用 SwiftUI 和 SwiftData。

## 在模拟器运行

使用 Xcode 27.2 或兼容版本打开 `PersonalFinanceOS.xcodeproj`，选择 `PersonalFinanceOS` scheme 和 iOS 模拟器，运行应用。项目最低部署目标为 iOS 17.0。首次构建时，Swift Package Manager 会根据锁定版本下载依赖。

无签名命令行构建可使用以下命令。

```sh
xcodebuild -project PersonalFinanceOS.xcodeproj -scheme PersonalFinanceOS \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

## 运行相关单元测试

以下命令以 iPhone 16 模拟器为例。使用 `xcodebuild -project PersonalFinanceOS.xcodeproj -scheme PersonalFinanceOS -showdestinations` 查看本机可用的目标。CloudKit 配置测试需要模拟器 ad hoc 签名，以便测试进程加载 entitlements。

```sh
xcodebuild -project PersonalFinanceOS.xcodeproj -scheme PersonalFinanceOS \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -parallel-testing-enabled NO \
  -only-testing:PersonalFinanceOSTests/BillImportServiceTests \
  -only-testing:PersonalFinanceOSTests/PrivateCloudReplicaSessionTests \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- test
```

## 真机签名和 iCloud

在自己的 Apple Developer Team 下设置应用和测试目标的 Bundle ID。需要测试 iCloud 时，请使用自己的 CloudKit 容器，并同步更新 entitlements 和 `ModelContainerFactory.cloudContainerIdentifier`。请在独立的测试设备或测试账本中验证同步。

## 第三方依赖

Swift Package Manager 管理 CoreXLSX、XMLCoder 和 ZIPFoundation。许可证文本见 [第三方声明](PersonalFinanceOS/Resources/ThirdPartyNotices.txt)。

## Privacy

核心记账在本机保存。iCloud 同步为可选功能，使用自己配置的 CloudKit 容器。账本导入、导出、备份和诊断可能涉及隐私信息。请使用合成数据复现问题，公开 issue 中请勿上传账单、备份或带个人信息的截图。

## License

本项目的代码与文档采用 [MIT License](LICENSE)。第三方依赖适用各自的许可证。
