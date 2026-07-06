import std/httpclient
import bearssl

import types

proc newHttpClientPool*(maxSize: int; timeoutMs: int): HttpClientPool =
  result = HttpClientPool(maxSize: maxSize, timeoutMs: timeoutMs, available: @[])
  for i in 0 ..< maxSize:
    var client = newHttpClient(timeout = timeoutMs)
    client.sslContext = newSslContext()
    result.available.add(client)

proc borrowClient*(pool: HttpClientPool): HttpClient =
  if pool.available.len > 0:
    result = pool.available.pop()
  else:
    var client = newHttpClient(timeout = pool.timeoutMs)
    client.sslContext = newSslContext()
    result = client

proc returnClient*(pool: HttpClientPool; client: HttpClient; discardClient: bool = false) =
  if discardClient:
    client.close()
  elif pool.available.len < pool.maxSize:
    pool.available.add(client)
  else:
    client.close()