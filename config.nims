# 方案 C：彻底静态编译 —— 运行时不加载任何外部 .so/.dll
# - nre 替代 std/re：零外部依赖（不需要 libpcre.so）
# - --dynlibOverride:ssl/crypto/pcre：阻止 Nim 运行时动态加载
# - HTTPS 仍在代码层主动拒绝（当前编译不依赖 libssl）
--dynlibOverride:pcre
--dynlibOverride:ssl
--dynlibOverride:crypto
# 本地使用已下载的 nim-regex 源码，避免远程依赖并方便交叉编译
--path:"nim-regex/src"
# begin Nimble config (version 2)
when withDir(thisDir(), system.fileExists("nimble.paths")):
  include "nimble.paths"
# end Nimble config