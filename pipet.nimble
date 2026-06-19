version       = "0.1.0"
author        = "pipet authors"
description   = "A simple PSV-based API testing tool"
license       = "MIT"
srcDir        = "src"

requires "nim >= 1.6.0"
requires "yaml >= 2.0.0"

bin = @["pipet"]
binDir = "dist/pipet"

task release, "Build release binary":
  exec "nim c --nimcache:releasecache -d:release --opt:size -o:dist/pipet/pipet.exe src/pipet.nim"

task package, "Package exe and resources into dist/pipet":
  rmDir "dist"
  releaseTask()
  cpFile "config.yaml", "dist/pipet/config.yaml"
  mkdir "dist/pipet/tests"
  for f in listFiles("tests"):
    if f.endsWith(".psv"):
      cpFile f, "dist/pipet/" & f
  echo "打包完成: dist/pipet/"
  echo "可分发内容: pipet.exe、config.yaml、tests/*.psv"

task dist, "Alias for package task":
  packageTask()
