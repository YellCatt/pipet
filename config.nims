# 使用 BearSSL 实现纯 Nim HTTPS 支持
# - nre 替代 std/re：零外部依赖（不需要 libpcre.so）
# - BearSSL 纯 Nim TLS 实现，无需系统 OpenSSL
# -d:ssl 启用 HTTPS 支持
-d:ssl
--path:"nim-regex/src"
# begin Nimble config (version 2)
when withDir(thisDir(), system.fileExists("nimble.paths")):
  include "nimble.paths"
# end Nimble config