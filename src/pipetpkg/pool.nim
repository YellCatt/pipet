import std/httpclient

import types

proc newHttpClientPool*(maxSize: int; timeoutMs: int): HttpClientPool =
  result = HttpClientPool(maxSize: maxSize, timeoutMs: timeoutMs, available: @[])
  for i in 0 ..< maxSize:
    result.available.add(newHttpClient(timeout = timeoutMs))

proc borrowClient*(pool: HttpClientPool): HttpClient =
  if pool.available.len > 0:
    result = pool.available.pop()
  else:
    result = newHttpClient(timeout = pool.timeoutMs)

proc returnClient*(pool: HttpClientPool; client: HttpClient; discardClient: bool = false) =
  if discardClient:
    client.close()
  elif pool.available.len < pool.maxSize:
    pool.available.add(client)
  else:
    client.close()
