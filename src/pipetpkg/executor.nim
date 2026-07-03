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

      let methodEnum = case tc.httpMethod
        of "GET": HttpGet
        of "POST": HttpPost
        of "PUT": HttpPut
        of "PATCH": HttpPatch
        of "DELETE": HttpDelete
        else:
          gLogger.error("未知 HTTP 方法", {"method": tc.httpMethod}.toTable)
          pool.returnClient(client)
          return (status: 0, body: "", durationSec: 0.0, error: "未知 HTTP 方法: " & tc.httpMethod)

      resp = if multipart != nil:
               client.request(url, httpMethod = methodEnum, multipart = multipart)
             elif methodEnum == HttpGet and reqBody.len == 0:
               client.get(url)
             else:
               client.request(url, httpMethod = methodEnum, body = reqBody)
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

proc formatConditionInfo*(c: Condition): tuple[url: string, headers: string, body: string] =
  let finalUrl = buildUrl(c.url, c.params)
  let (reqBody, contentType, multipart) = selectConditionBody(c)
  var allHeaders = initTable[string, string]()
  for k, v in c.headers:
    allHeaders[k] = v
  if contentType.len > 0 and not allHeaders.hasKey("Content-Type"):
    allHeaders["Content-Type"] = contentType
  let hJson = newJObject()
  for k, v in allHeaders:
    hJson[k] = %v
  let bodyStr = if multipart != nil: "(multipart)" else: reqBody
  result = (url: finalUrl, headers: $hJson, body: bodyStr)

proc execConditionHttpRequest*(c: Condition; pool: HttpClientPool): tuple[status: int, body: string, durationSec: float, error: string] =
  let start = epochTime()
  let url = buildUrl(c.url, c.params)
  let (reqBody, contentType, multipart) = selectConditionBody(c)

  gLogger.debug("准备发送条件 HTTP 请求", {
    "id": c.id,
    "type": c.typ,
    "method": c.httpMethod,
    "url": url,
    "headers_count": $c.headers.len,
    "body_len": $reqBody.len
  }.toTable)

  var resp: Response
  var lastError = ""
  var client = pool.borrowClient()
  try:
    client.headers = newHttpHeaders()
    for k, v in c.headers:
      client.headers[k] = v
    if contentType.len > 0 and not c.headers.hasKey("Content-Type"):
      client.headers["Content-Type"] = contentType

    let methodEnum = case c.httpMethod
      of "GET": HttpGet
      of "POST": HttpPost
      of "PUT": HttpPut
      of "PATCH": HttpPatch
      of "DELETE": HttpDelete
      else:
        gLogger.error("未知 HTTP 方法", {"method": c.httpMethod}.toTable)
        pool.returnClient(client)
        return (status: 0, body: "", durationSec: 0.0, error: "未知 HTTP 方法: " & c.httpMethod)

    resp = if multipart != nil:
             client.request(url, httpMethod = methodEnum, multipart = multipart)
           elif methodEnum == HttpGet and reqBody.len == 0:
             client.get(url)
           else:
             client.request(url, httpMethod = methodEnum, body = reqBody)
    pool.returnClient(client)
  except CatchableError as e:
    lastError = e.msg
    pool.returnClient(client, discardClient = true)
    gLogger.error("条件请求异常", {"id": c.id, "error": e.msg}.toTable)

  if lastError.len > 0:
    return (status: 0, body: "N/A", durationSec: 0.0, error: lastError)

  let durationSec = epochTime() - start
  let actualStatus = resp.code.int
  let actualBody = resp.body

  gLogger.debug("收到条件 HTTP 响应", {
    "id": c.id,
    "status": $actualStatus,
    "body_len": $actualBody.len,
    "duration_s": formatFloat(durationSec, ffDecimal, 3)
  }.toTable)

  return (status: actualStatus, body: actualBody, durationSec: durationSec, error: "")

proc runCondition*(c: Condition; pool: HttpClientPool; vars: var Table[string, string]): tuple[ok: bool, diff: string, actualBody: string] =
  let (reqUrl, reqHeaders, reqBody) = formatConditionInfo(c)
  let (actualStatus, actualBody, durationSec, error) = execConditionHttpRequest(c, pool)

  if error.len > 0:
    return (false, "条件请求异常: " & error, actualBody)

  if actualStatus != c.expectStatus:
    return (false, "条件状态码不符: 期望 " & $c.expectStatus & ", 实际 " & $actualStatus, actualBody)

  if c.extract.len > 0:
    let extracted = extractVars(actualBody, c.extract)
    for k, v in extracted:
      vars[k] = v
      gLogger.info("条件提取上下文变量", {"key": k, "value": v, "condition": c.id}.toTable)

  return (true, "", actualBody)

proc formatRequestInfo*(tc: TestCase): tuple[url: string, headers: string, body: string] =
  let finalUrl = buildUrl(tc.url, tc.params)
  let (reqBody, contentType, multipart) = selectRequestBody(tc)
  var allHeaders = initTable[string, string]()
  for k, v in tc.headers:
    allHeaders[k] = v
  if contentType.len > 0 and not allHeaders.hasKey("Content-Type"):
    allHeaders["Content-Type"] = contentType
  let hJson = newJObject()
  for k, v in allHeaders:
    hJson[k] = %v
  let bodyStr = if multipart != nil: "(multipart)" else: reqBody
  result = (url: finalUrl, headers: $hJson, body: bodyStr)

proc runTest*(tc: TestCase; pool: HttpClientPool; retryCount: int = 0; retryDelayMs: int = 0): TestResult =
  let expectBodyStr = $tc.expectBody
  let tags = tc.tags.join(",")
  let (reqUrl, reqHeaders, reqBody) = formatRequestInfo(tc)
  let (actualStatus, actualBody, durationSec, error) = execHttpRequest(tc, pool, retryCount, retryDelayMs)

  if error.len > 0:
    return TestResult(
      id: tc.id, desc: tc.desc, httpMethod: tc.httpMethod, url: reqUrl, requestHeaders: reqHeaders, requestBody: reqBody, status: "FAIL", durationSec: durationSec,
      expectStatus: tc.expectStatus, actualStatus: actualStatus,
      diff: "请求异常: " & error,
      actualBody: actualBody,
      expectBody: expectBodyStr,
      tags: tags
    )

  var diffs: seq[string] = @[]

  if actualStatus != tc.expectStatus:
    diffs.add("状态码不符: 期望 " & $tc.expectStatus & ", 实际 " & $actualStatus)
    gLogger.info("状态码不符", {"id": tc.id, "expect": $tc.expectStatus, "actual": $actualStatus}.toTable)

  var actualBodyJson: JsonNode
  try:
    actualBodyJson = parseJson(actualBody)
  except JsonParsingError:
    if diffs.len == 0:
      let preview = actualBody[0 ..< min(200, actualBody.len)]
      gLogger.info("响应不是合法 JSON", {"id": tc.id, "preview": preview}.toTable)
      return TestResult(
        id: tc.id, desc: tc.desc, httpMethod: tc.httpMethod, url: reqUrl, requestHeaders: reqHeaders, requestBody: reqBody, status: "FAIL", durationSec: durationSec,
        expectStatus: tc.expectStatus, actualStatus: actualStatus,
        diff: "响应不是合法 JSON: " & preview,
        actualBody: actualBody,
        expectBody: expectBodyStr,
        tags: tags
      )
    else:
      return TestResult(
        id: tc.id, desc: tc.desc, httpMethod: tc.httpMethod, url: reqUrl, requestHeaders: reqHeaders, requestBody: reqBody, status: "FAIL", durationSec: durationSec,
        expectStatus: tc.expectStatus, actualStatus: actualStatus,
        diff: diffs.join(" | "),
        actualBody: actualBody,
        expectBody: expectBodyStr,
        tags: tags
      )

  if tc.expectBody.kind != JNull:
    let bodyDiffs = jsonDiff(tc.expectBody, actualBodyJson, "", tc.matchMode)
    if bodyDiffs.len > 0:
      diffs.add(bodyDiffs)
      gLogger.info("JSON 字段差异", {"id": tc.id, "diffs": bodyDiffs.join(" | ")}.toTable)

  if diffs.len > 0:
    return TestResult(
      id: tc.id, desc: tc.desc, httpMethod: tc.httpMethod, url: reqUrl, requestHeaders: reqHeaders, requestBody: reqBody, status: "FAIL", durationSec: durationSec,
      expectStatus: tc.expectStatus, actualStatus: actualStatus,
      diff: diffs.join(" | "),
      actualBody: actualBody,
      expectBody: expectBodyStr,
      tags: tags
    )

  gLogger.debug("用例断言通过", {"id": tc.id}.toTable)
  TestResult(
    id: tc.id, desc: tc.desc, httpMethod: tc.httpMethod, url: reqUrl, requestHeaders: reqHeaders, requestBody: reqBody, status: "PASS", durationSec: durationSec,
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
  let (reqUrl, reqHeaders, reqBody) = formatRequestInfo(tc)
  let (actualStatus, actualBody, durationSec, error) = execHttpRequest(tc, pool, 0, 0)

  if error.len > 0:
    return TestResult(
      id: tc.id, desc: tc.desc, httpMethod: tc.httpMethod, url: reqUrl, requestHeaders: reqHeaders, requestBody: reqBody, status: "FAIL", durationSec: durationSec,
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
      id: tc.id, desc: tc.desc, httpMethod: tc.httpMethod, url: reqUrl, requestHeaders: reqHeaders, requestBody: reqBody, status: "FAIL", durationSec: durationSec,
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
          id: tc.id, desc: tc.desc, httpMethod: tc.httpMethod, url: reqUrl, requestHeaders: reqHeaders, requestBody: reqBody, status: "PASS", durationSec: epochTime() - start,
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
        id: tc.id, desc: tc.desc, httpMethod: tc.httpMethod, url: reqUrl, requestHeaders: reqHeaders, requestBody: reqBody, status: "FAIL", durationSec: epochTime() - start,
        expectStatus: tc.expectStatus, actualStatus: actualStatus,
        diff: diffs.join(" | "),
        actualBody: actualBody,
        expectBody: expectBodyStr,
        tags: tags
      )

  gLogger.debug("流式用例断言通过", {"id": tc.id, "chunks": $chunkCount}.toTable)
  TestResult(
    id: tc.id, desc: tc.desc, httpMethod: tc.httpMethod, url: reqUrl, requestHeaders: reqHeaders, requestBody: reqBody, status: "PASS", durationSec: epochTime() - start,
    expectStatus: tc.expectStatus, actualStatus: actualStatus,
    diff: "",
    actualBody: actualBody,
    expectBody: expectBodyStr,
    tags: tags
  )
