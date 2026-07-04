version       = "0.1.0"
author        = "pipet authors"
description   = "A simple PSV-based API testing tool"
license       = "MIT"
srcDir        = "src"

requires "nim >= 2.0.0"
requires "yaml >= 2.0.0"
requires "regex >= 0.1.0"

bin = @["pipet"]
binDir = "dist/pipet"

task release, "Build release binary (fully static, no external .so/.dll)":
  exec "nim c --nimcache:releasecache -d:release --opt:size --dynlibOverride:ssl --dynlibOverride:crypto -o:dist/pipet/pipet.exe src/pipet.nim"

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