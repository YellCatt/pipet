import types

proc newHttpClientPool*(maxSize: int; timeoutMs: int): HttpClientPool =
  result = HttpClientPool(maxSize: maxSize, timeoutMs: timeoutMs, available: @[])

proc borrowClient*(pool: HttpClientPool): HttpClient =
  discard

proc returnClient*(pool: HttpClientPool; client: HttpClient; discardClient: bool = false) =
  discard