#!/bin/bash

config="$(dirname -- "${BASH_SOURCE[0]}")/bugly.local.sh"
if [ ! -f "$config" ]; then
    echo '请先按 README 创建 bugly.local.sh。'
    exit 2
fi
source "$config"
: "${JAR_PATH:?请配置 JAR_PATH}"
: "${APP_ID:?请配置 APP_ID}"
: "${APP_KEY:?请配置 APP_KEY}"
: "${BUNDLE_ID:?请配置 BUNDLE_ID}"
PLATFORM="Android"
INPUT_MAPPING="${INPUT_MAPPING:-}"


# 1. 检查 Java 环境和 Jar 包
if ! command -v java &> /dev/null; then
    echo "❌ 错误: 未检测到 java 环境，请先安装 Java。"
    exit 1
fi

if [ ! -f "$JAR_PATH" ]; then
    echo "❌ 错误: 找不到 Bugly 上传工具 jar 包："
    echo "   路径: $JAR_PATH"
    exit 1
fi

# 2. 校验 mapping 路径
INPUT_MAPPING="${2:-$INPUT_MAPPING}"
if [ "$#" -eq 0 ] && [ ! -d "$INPUT_MAPPING" ] && [ ! -f "$INPUT_MAPPING" ]; then
    read -r -p "请输入 mapping 路径：" INPUT_MAPPING
fi
if [ ! -d "$INPUT_MAPPING" ] && [ ! -f "$INPUT_MAPPING" ]; then
    echo "找不到 mapping 路径：$INPUT_MAPPING"
    exit 1
fi

# 3. Android 平台 Native SO 符号表参数处理 (可选)
# 如果存在 .so 文件，可以指定 inputSymbol 目录，否则默认和 mapping 路径一致以通过 jar 包参数校验
INPUT_SYMBOL="$INPUT_MAPPING"

# 4. 输入版本号 (必须)
if [ "$#" -gt 0 ]; then
    APP_VERSION=$1
    if [ -z "$APP_VERSION" ]; then
        echo '版本号不能为空。'
        exit 1
    fi
else
while true; do
    read -p "请输入本次上传的 APP 版本号 (例如: 1.0.0): " APP_VERSION
    if [ -n "$APP_VERSION" ]; then
        break
    else
        echo "❌ 版本号不能为空，请重新输入。"
    fi
done
fi

# 5. 可选：输入 Build 编号 (Android 平台可选)
# read -p "请输入 Build 编号 (如 2，若没有则直接回车跳过): " BUILD_NO

# 6. 执行上传
echo ""
echo "🚀 开始上传符号表到 Bugly..."
echo "--------------------------------------------------"
echo "ℹ️  JAR路径:     $JAR_PATH"
echo "ℹ️  Bundle ID:   $BUNDLE_ID"
echo "ℹ️  Version:     $APP_VERSION"
if [ -n "$BUILD_NO" ]; then
echo "ℹ️  Build No:    $BUILD_NO"
fi
echo "ℹ️  Platform:    $PLATFORM"
echo "ℹ️  Mapping 路径: $INPUT_MAPPING"
echo "--------------------------------------------------"

# 用参数数组保留路径、版本号和凭据的原始边界。
args=(-appid "$APP_ID" -appkey "$APP_KEY" -bundleid "$BUNDLE_ID"
      -version "$APP_VERSION" -platform "$PLATFORM"
      -inputMapping "$INPUT_MAPPING" -inputSymbol "$INPUT_SYMBOL")
if [ -n "$BUILD_NO" ]; then
    args+=(-buildNo "$BUILD_NO")
fi
java -jar "$JAR_PATH" "${args[@]}"

RESULT=$?
if [ $RESULT -eq 0 ]; then
    echo "=================================================="
    echo "🎉 上传成功！"
    echo "=================================================="
else
    echo "=================================================="
    echo "❌ 上传失败，退出码: $RESULT"
    echo "=================================================="
fi
exit "$RESULT"
