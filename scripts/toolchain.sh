#!/bin/bash
# 选择可用的 Swift 工具链(供其他脚本 source)。
#
# Command Line Tools 缺少 SwiftUI / Testing 宏插件的默认搜索路径,
# 直接编译 App 或跑测试会报 "plugin for module 'XXXMacros' not found"。
# 统一优先使用完整 Xcode / Xcode-beta 的 DEVELOPER_DIR。
for _DEVELOPER in \
  /Applications/Xcode.app/Contents/Developer \
  /Applications/Xcode-beta.app/Contents/Developer
do
  if [ -d "$_DEVELOPER" ]; then
    export DEVELOPER_DIR="$_DEVELOPER"
    break
  fi
done
unset _DEVELOPER
