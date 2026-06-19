import std/[httpclient, httpcore, json, os, re, strutils, tables, times]

import logger, types, pool, request, jsonutils

proc execHttpRequest*(tc: TestCase; pool: HttpClientPool; retryCount: int; retryDelayMs: int): tuple[status: int, body: string, durationSec: float, error: string] =
  let start = epochTime()
  let url = buildUrl(tc.url, tc.params)
  let (reqBody, contentType, multipart) = selectRequestBody(tc)

  gLogger.debug("准备发送 HTTP 请求", {
    "id": tc.id,
    "method": tc.httpMethod,
    "url": url,
    "headers_count": $tc.headers.len,
    "body_len": $reqBody.len,
    "expect_status": $tc.expectStatus,
    "retry_count": $retryCount,
    "retry_delay_ms": $retryDelayMs
  }.toTable)

  var resp: Response
  var lastError = ""
  var attempt = 0
  let maxAttempts = retryCount + 1

  while attempt < maxAttempts:
    attempt += 1
    var client = pool.borrowClient()
    try:
      client.headers = newHttpHeaders()
      for k, v in tc.headers:
        client.headers[k] = v
      if contentType.len > 0 and not tc.headers.hasKey("Content-Type"):
        client.headers["Content-Type"] = contentType

      resp = case tc.httpMethod
        of "GET":
          if multipart != nil: client.request(url, HttpGet, multipart = multipart)
          elif reqBody.len > 0: client.request(url, HttpGet, body = reqBody)
          else: client.get(url)
        of "POST":
          if multipart != nil: client.post(url, multipart = multipart)
          else: client.post(url, body = reqBody)
        of "PUT":
          if multipart != nil: client.put(url, multipart = multipart)
          else: client.put(url, body = reqBody)
        of "PATCH":
          if multipart != nil: client.request(url, httpMethod = HttpPatch, multipart = multipart)
          else: client.request(url, httpMethod = HttpPatch, body = reqBody)
        of "DELETE":
          if multipart != nil: client.request(url, httpMethod = HttpDelete, multipart = multipart)
          else: client.request(url, httpMethod = HttpDelete, body = reqBody)
        else:
          gLogger.error("未知 HTTP 方法", {"method": tc.httpMethod}.toTable)
          pool.returnClient(client)
          return (status: 0, body: "", durationSec: 0.0, error: "未知 HTTP 方法: " & tc.httpMethod)
      lastError = ""
      pool.returnClient(client)
      break
    except CatchableError as e:
      lastError = e.msg
      pool.returnClient(client, discardClient = true)
      if attempt < maxAttempts:
        gLogger.warn("请求失败，准备重试", {"id": tc.id, "attempt": $attempt, "error": e.msg}.toTable)
        if retryDelayMs > 0:
          sleep(retryDelayMs)
      else:
        gLogger.error("请求异常", {"id": tc.id, "attempt": $attempt, "error": e.msg}.toTable)

  if lastError.len > 0:
    return (status: 0, body: "N/A", durationSec: 0.0, error: lastError)

  let durationSec = epochTime() - start
  let actualStatus = resp.code.int
  let actualBody = resp.body

  gLogger.debug("收到 HTTP 响应", {
    "id": tc.id,
    "status": $actualStatus,
    "body_len": $actualBody.len,
    "duration_s": formatFloat(durationSec, ffDecimal, 3)
  }.toTable)

  return (status: actualStatus, body: actualBody, durationSec: durationSec, error: "")

proc runTest*(tc: TestCase; pool: HttpClientPool; retryCount: int = 0; retryDelayMs: int = 0): TestResult =
  let expectBodyStr = $tc.expectBody
  let tags = tc.tags.join(",")
  let (actualStatus, actualBody, durationSec, error) = execHttpRequest(tc, pool, retryCount, retryDelayMs)

  if error.len > 0:
    return TestResult(
      id: tc.id, desc: tc.desc, status: "FAIL", durationSec: durationSec,
      expectStatus: tc.expectStatus, actualStatus: actualStatus,
      diff: "请求异常: " & error,
      actualBody: actualBody,
      expectBody: expectBodyStr,
      tags: tags
    )

  if actualStatus != tc.expectStatus:
    gLogger.info("状态码不符", {
      "id": tc.id,
      "expect": $tc.expectStatus,
      "actual": $actualStatus
    }.toTable)
    return TestResult(
      id: tc.id, desc: tc.desc, status: "FAIL", durationSec: durationSec,
      expectStatus: tc.expectStatus, actualStatus: actualStatus,
      diff: "状态码不符: 期望 " & $tc.expectStatus & ", 实际 " & $actualStatus,
      actualBody: actualBody,
      expectBody: expectBodyStr,
      tags: tags
    )

  var actualBodyJson: JsonNode
  try:
    actualBodyJson = parseJson(actualBody)
  except JsonParsingError:
    let preview = actualBody[0 ..< min(200, actualBody.len)]
    gLogger.info("响应不是合法 JSON", {"id": tc.id, "preview": preview}.toTable)
    return TestResult(
      id: tc.id, desc: tc.desc, status: "FAIL", durationSec: durationSec,
      expectStatus: tc.expectStatus, actualStatus: actualStatus,
      diff: "响应不是合法 JSON: " & preview,
      actualBody: actualBody,
      expectBody: expectBodyStr,
      tags: tags
    )

  let diffs = jsonDiff(tc.expectBody, actualBodyJson, "", tc.matchMode)
  if diffs.len > 0:
    gLogger.info("JSON 字段差异", {"id": tc.id, "diffs": diffs.join(" | ")}.toTable)
    return TestResult(
      id: tc.id, desc: tc.desc, status: "FAIL", durationSec: durationSec,
      expectStatus: tc.expectStatus, actualStatus: actualStatus,
      diff: diffs.join(" | "),
      actualBody: actualBody,
      expectBody: expectBodyStr,
      tags: tags
    )

  gLogger.debug("用例断言通过", {"id": tc.id}.toTable)
  TestResult(
    id: tc.id, desc: tc.desc, status: "PASS", durationSec: durationSec,
    expectStatus: tc.expectStatus, actualStatus: actualStatus,
    diff: "",
    actualBody: actualBody,
    expectBody: expectBodyStr,
    tags: tags
  )

proc parseSseLine(line: string): JsonNode =
  ## 解析 SSE 的 data: {...} 行
  let trimmed = line.strip()
  if not trimmed.startsWith("data:"):
    return nil
  let jsonStr = trimmed[5..^1].strip()
  if jsonStr == "[DONE]":
    return nil
  try:
    return parseJson(jsonStr)
  except:
    return nil

proc extractSseDeltaContent(node: JsonNode): string =
  ## 从 OpenAI 格式的 SSE 节点中提取 delta.content
  result = ""
  if node == nil or not node.hasKey("choices") or node["choices"].kind != JArray:
    return
  for choice in node["choices"]:
    if choice.kind != JObject or not choice.hasKey("delta"):
      continue
    let delta = choice["delta"]
    if delta.kind == JObject and delta.hasKey("content"):
      result.add(delta["content"].getStr())

proc evalStreamAssert(sa: StreamAssert; aggregatedContent: string; node: JsonNode; chunkCount: int): bool =
  ## 判断单个流式断言是否匹配
  if chunkCount < sa.minChunks:
    return false
  case sa.kind
  of "contains":
    return sa.pattern in aggregatedContent
  of "regex":
    try:
      return match(aggregatedContent, re(sa.pattern))
    except CatchableError:
      return false
  of "json_path":
    let parts = sa.pattern.split('.')
    let value = getJsonPath(node, parts)
    return value != nil
  else:
    return false

proc runStreamTest*(tc: TestCase; pool: HttpClientPool): TestResult =
  let start = epochTime()
  let expectBodyStr = $tc.expectBody
  let tags = tc.tags.join(",")
  let (actualStatus, actualBody, durationSec, error) = execHttpRequest(tc, pool, 0, 0)

  if error.len > 0:
    return TestResult(
      id: tc.id, desc: tc.desc, status: "FAIL", durationSec: durationSec,
      expectStatus: tc.expectStatus, actualStatus: 0,
      diff: "请求异常: " & error,
      actualBody: "N/A",
      expectBody: expectBodyStr,
      tags: tags
    )

  if actualStatus != tc.expectStatus:
    gLogger.info("状态码不符", {
      "id": tc.id,
      "expect": $tc.expectStatus,
      "actual": $actualStatus
    }.toTable)
    return TestResult(
      id: tc.id, desc: tc.desc, status: "FAIL", durationSec: durationSec,
      expectStatus: tc.expectStatus, actualStatus: actualStatus,
      diff: "状态码不符: 期望 " & $tc.expectStatus & ", 实际 " & $actualStatus,
      actualBody: actualBody,
      expectBody: expectBodyStr,
      tags: tags
    )

  var aggregatedContent = ""
  var chunkCount = 0
  for line in actualBody.splitLines():
    let node = parseSseLine(line)
    if node == nil:
      continue
    chunkCount += 1
    aggregatedContent.add(extractSseDeltaContent(node))

    for sa in tc.streamAsserts:
      if evalStreamAssert(sa, aggregatedContent, node, chunkCount):
        gLogger.info("流式断言匹配", {
          "id": tc.id,
          "kind": sa.kind,
          "pattern": sa.pattern,
          "chunks": $chunkCount
        }.toTable)
        return TestResult(
          id: tc.id, desc: tc.desc, status: "PASS", durationSec: epochTime() - start,
          expectStatus: tc.expectStatus, actualStatus: actualStatus,
          diff: "",
          actualBody: actualBody,
          expectBody: expectBodyStr,
          tags: tags
        )

  if tc.expectBody.kind != JNull:
    let finalJson = %*{"aggregated_content": aggregatedContent, "chunk_count": chunkCount}
    let diffs = jsonDiff(tc.expectBody, finalJson, "", tc.matchMode)
    if diffs.len > 0:
      gLogger.info("流式最终断言差异", {"id": tc.id, "diffs": diffs.join(" | ")}.toTable)
      return TestResult(
        id: tc.id, desc: tc.desc, status: "FAIL", durationSec: epochTime() - start,
        expectStatus: tc.expectStatus, actualStatus: actualStatus,
        diff: diffs.join(" | "),
        actualBody: actualBody,
        expectBody: expectBodyStr,
        tags: tags
      )

  gLogger.debug("流式用例断言通过", {"id": tc.id, "chunks": $chunkCount}.toTable)
  TestResult(
    id: tc.id, desc: tc.desc, status: "PASS", durationSec: epochTime() - start,
    expectStatus: tc.expectStatus, actualStatus: actualStatus,
    diff: "",
    actualBody: actualBody,
    expectBody: expectBodyStr,
    tags: tags
  )
