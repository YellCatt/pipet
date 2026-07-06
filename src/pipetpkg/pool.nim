import types

proc newHttpConfig*(timeoutMs: int; retryCount: int; retryDelayMs: int): HttpConfig =
  HttpConfig(timeoutMs: timeoutMs, retryCount: retryCount, retryDelayMs: retryDelayMs)