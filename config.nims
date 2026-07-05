# 默认启用 SSL 支持（HTTP/SMTP 均需），运行依赖系统 OpenSSL
switch("define", "ssl")
--dynlibOverride:pcre
# 本地使用已下载的 nim-regex 源码，避免远程依赖并方便交叉编译
--path:"nim-regex/src"
# begin Nimble config (version 2)
when withDir(thisDir(), system.fileExists("nimble.paths")):
  include "nimble.paths"
# end Nimble config
