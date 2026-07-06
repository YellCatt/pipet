# 使用 Puppy HTTP 客户端库，原生支持 HTTPS
# - nre 替代 std/re：零外部依赖（不需要 libpcre.so）
# - Puppy 利用操作系统原生实现(WinHttp/CoreFoundation)，无需额外 TLS 库
--path:"nim-regex/src"
# begin Nimble config (version 2)
when withDir(thisDir(), system.fileExists("nimble.paths")):
  include "nimble.paths"
# end Nimble config