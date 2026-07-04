# 不启用 --define:ssl：允许在没有 OpenSSL 的系统上运行 HTTP 请求
# HTTPS 请求将在代码层面检测并给出友好提示
# begin Nimble config (version 2)
when withDir(thisDir(), system.fileExists("nimble.paths")):
  include "nimble.paths"
# end Nimble config