version       = "0.1.0"
author        = "pipet authors"
description   = "A simple PSV-based API testing tool"
license       = "MIT"
srcDir        = "src"

requires "nim >= 2.0.0"
requires "yaml >= 2.0.0"
# regex 使用本地 nim-regex/ 源码；其依赖 unicodedb 仍通过 nimble 安装
requires "unicodedb >= 0.13.2"

bin = @["pipet"]
binDir = "dist/pipet"

task release, "Build release binary":
  when defined(windows):
    exec "nimble build -d:release --opt:size"
  else:
    exec "nimble build -d:release --opt:size --passC:-static --passL:-static"

task package, "Package exe and resources into dist/pipet":
  rmDir "dist"
  releaseTask()
  cpFile "config.yaml", "dist/pipet/config.yaml"
  cpFile "README.md", "dist/pipet/README.md"
  cpDir "tests", "dist/pipet/tests"
  cpDir "data", "dist/pipet/data"
  echo "打包完成: dist/pipet/"
  echo "可分发内容: pipet.exe、config.yaml、README.md、tests/、data/"

task dist, "Alias for package task":
  packageTask()