# 开发工具箱

**用 Agent 写代码，用工具箱跑真机。**

改完代码，从 Mac 菜单栏选一台 Android 或鸿蒙设备，打包、安装、启动。遇到问题，顺手截屏或按包名查日志。平时只做这些操作，可以关掉 Android Studio 或 DevEco Studio，省下 IDE 常驻占用的内存。

项目仍需安装对应的构建工具和 SDK。打包时，工具箱会调用 Gradle 或 Hvigor。

![开发工具箱的打包页面，展示 Android 和鸿蒙的 Debug、Release 操作](docs/images/build.png)

*公开版界面实拍，顶部设备为演示数据。*

## 能做什么

- **打包并运行。** 生成 Android APK 或鸿蒙 HAP。只想发包，可以单独打包并在 Finder 定位产物。
- **抓图和查日志。** 手机截图自动复制到剪贴板，也能把上一次截图存到桌面。实时查看 logcat 和 hilog，按应用、标签、级别或关键词筛选，常用条件可以收藏。
- **腾出磁盘空间。** 先盘点历史产物，再预览可清理的目录和占用。确认后，符合条件的目录才会移入废纸篓。
- **处理发布杂活。** 按版本上传 Bugly Mapping，或为匹配版本的 Antigravity 安装社区中文补丁。

## 从源码启动

准备 macOS 13 或更新版本和包含 Swift 5.9 或更新版本的 Xcode Command Line Tools。本版本从源码构建，打开项目根目录后运行下面两条命令。

```sh
./build.sh
open 开发工具箱.app
```

构建脚本会编译 Swift 源码、签名本地应用并运行自检。请让应用和仓库中的脚本留在同一目录。

想先试设备功能，可以连接已授权的手机，从「手机截图」或「设备日志」开始。要打包自己的应用，再填写下面的项目配置。

## 配置自己的项目

```sh
cp -n toolbox.example.plist toolbox.local.plist
open -e toolbox.local.plist
```

编辑 `toolbox.local.plist`，重新打开应用以刷新按钮。项目目录使用绝对路径或以 `~/` 开头，产物路径相对于项目目录。只填写需要使用的功能。

- **先跑 Android**。将 `AndroidProject` 指向含有 `gradlew` 的项目根目录，例如 `~/Projects/ExampleAndroid`，将 `AndroidPackage` 填为实际的 application ID，例如 `org.example.android`。标准 `:app` 模块可先用模板中的 Debug 任务和元数据路径。打开工具箱，点击「打包 Debug」。
- **先跑鸿蒙**。将 `HarmonyProject` 指向 DevEco Studio 工程根目录。按项目填写 `HarmonyPackage`、`HarmonyAbility` 和 `HarmonyModule`，再填写 Debug 对应的 `HarmonyDebugProduct` 和 `HarmonyDebugHap`。例如模块是 `entry`、目标是 `default`，模块字段可填 `entry@default`。HAP 路径以 DevEco Studio 实际生成的已签名文件为准。

修改后可运行 `plutil -lint toolbox.local.plist` 检查格式。先确认单独打包能找到产物，再选中已授权的设备点击「运行」。Android 构建需要 JDK 和 Android SDK，鸿蒙构建需要 DevEco Studio 及相应 SDK。

| 配置 | 用途 |
| --- | --- |
| `AndroidProject`、`AndroidPackage` | Android 项目目录及应用包名。运行应用和日志筛选 `package:mine` 需要包名。 |
| `AndroidDebugTask`、`AndroidReleaseTask`、对应的 `Metadata` 字段 | Gradle 任务和各自的 `output-metadata.json` 路径。目前支持单 APK 输出。打包默认使用 Java 21，也可通过 `JAVA_HOME` 指定。 |
| `AndroidChannelTask`、`AndroidChannelDirectory`、`AndroidMappingDirectory` | 可选的渠道重打包任务、渠道包目录和 Mapping 目录。 |
| `HarmonyProject`、`HarmonyPackage`、`HarmonyAbility`、`HarmonyModule` | 鸿蒙项目目录、应用包名、启动 Ability 和 Hvigor 模块。 |
| `HarmonyDebugProduct`、`HarmonyReleaseProduct`、对应的 `Hap` 字段 | Debug 和 Release 使用的 product 与已签名 HAP 路径。 |
| `ExtraProject` | 可选的第三个项目，只用于清理和历史产物查看。 |
| `AndroidCleanupDirectories`、`HarmonyCleanupDirectories`、`ExtraCleanupDirectories` | 各项目可重建的相对目录。默认留空。只在预览后确认时，才会把符合条件的目录移入废纸篓。 |
| `AndroidHistoryDirectories`、`HarmonyHistoryDirectories`、`ExtraHistoryDirectories` | 各项目要盘点的产物目录。历史盘点只读。 |

清理要求项目路径指向 Git 工作树根目录，候选文件须被 Git 忽略且未被跟踪，并且整组超过 21 天未修改。只把确定可重建的目录放进清理列表。

Android 打包和设备日志使用 `~/Library/Android/sdk/platform-tools/adb`。鸿蒙打包及设备日志使用 `/Applications/DevEco-Studio.app` 内的工具。截图脚本会查找这两个常用安装位置，也会从 `PATH` 查找 adb 和 hdc。

## 配置 Bugly 上传

```sh
cp -n bugly.example.sh bugly.local.sh
chmod 600 bugly.local.sh
```

在本地文件中填写你自己的 Bugly App ID、App Key、包名和上传工具 JAR 的绝对路径。`INPUT_MAPPING` 可填默认 Mapping 路径。上传脚本会用 Bugly JAR 的命令行参数传入密钥。

`toolbox.local.plist`、`bugly.local.sh` 和构建生成的二进制均已加入 Git 忽略规则。

## 反馈问题

欢迎通过 Issues 反馈。请附上 macOS 版本、使用的功能、复现步骤和相关输出。提交前请移除密钥、本机路径、设备序列号和业务日志中的敏感信息。
