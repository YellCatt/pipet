import std/[json, os, strutils, tables, times, uri]
import regex
import puppy

import logger, types, pool, request, jsonutils

proc checkHttpsSupport*(url: string): string =
  return ""

proc tableToHttpHeaders(headers: Table[string, string]): HttpHeaders =
  result = emptyHttpHeaders()
  for k, v in headers:
    result[k] = v

proc buildMultipartBody(textFields: Table[string, string], fileFields: Table[string, string]): tuple[contentType: string, body: string] =
  var entries: seq[MultipartEntry] = @[]
  for key, val in textFields:
    entries.add(MultipartEntry(name: key, payload: val))
  for key, filePath in fileFields:
    if fileExists(filePath):
      let fileData = readFile(filePath)
      entries.add(MultipartEntry(name: key, fileName: extractFilename(filePath), payload: fileData))
    else:
      gLogger.warn("上传文件不存在", {"field": key, "path": filePath}.toTable)
  result = encodeMultipart(entries)

proc execHttpRequest*(tc: TestCase; config: HttpConfig): tuple[status: int, body: string, durationSec: float, error: string] =
  let start = epochTime()
  let url = buildUrl(tc.url, tc.params)

  let (reqBody, contentType, multipartFields) = selectRequestBody(tc)

  gLogger.debug("准备发送 HTTP 请求", {
    "id": tc.id,
    "method": tc.httpMethod,
    "url": url,
    "headers_count": $tc.headers.len,
    "body_len": $reqBody.len,
    "expect_status": $tc.expectStatus,
    "retry_count": $config.retryCount,
    "retry_delay_ms": $config.retryDelayMs
  }.toTable)

  var lastError = ""
  var attempt = 0
  let maxAttempts = config.retryCount + 1

  let headers = tableToHttpHeaders(tc.headers)

  while attempt < maxAttempts:
    attempt += 1
    try:
      var resp: Response
      let timeoutSec = float32(config.timeoutMs) / 1000.0
      case tc.httpMethod.toUpperAscii
      of "GET":
        resp = get(url, headers = headers, timeout = timeoutSec)
      of "POST":
        if multipartFields.text.len > 0 or multipartFields.files.len > 0:
          let (multipartContentType, multipartBody) = buildMultipartBody(multipartFields.text, multipartFields.files)
          var multipartHeaders = headers
          multipartHeaders["Content-Type"] = multipartContentType
          resp = post(url, body = multipartBody, headers = multipartHeaders, timeout = timeoutSec)
        elif reqBody.len > 0:
          var contentHeaders = headers
          if contentType.len > 0:
            contentHeaders["Content-Type"] = contentType
          resp = post(url, body = reqBody, headers = contentHeaders, timeout = timeoutSec)
        else:
          resp = post(url, headers = headers, timeout = timeoutSec)
      of "PUT":
        var putHeaders = headers
        if contentType.len > 0:
          putHeaders["Content-Type"] = contentType
        resp = put(url, body = reqBody, headers = putHeaders, timeout = timeoutSec)
      of "PATCH":
        var patchHeaders = headers
        if contentType.len > 0:
          patchHeaders["Content-Type"] = contentType
        resp = patch(url, body = reqBody, headers = patchHeaders, timeout = timeoutSec)
      of "DELETE":
        resp = delete(url, headers = headers, timeout = timeoutSec)
      else:
        gLogger.error("未知 HTTP 方法", {"method": tc.httpMethod}.toTable)
        return (status: 0, body: "", durationSec: 0.0, error: "未知 HTTP 方法: " & tc.httpMethod)

      lastError = ""

      let durationSec = epochTime() - start
      return (status: resp.code, body: resp.body, durationSec: durationSec, error: "")

    except CatchableError as e:
      lastError = e.msg
      if attempt < maxAttempts:
        gLogger.warn("请求失败，准备重试", {"id": tc.id, "attempt": $attempt, "error": e.msg}.toTable)
        if config.retryDelayMs > 0:
          sleep(config.retryDelayMs)
      else:
        gLogger.error("请求异常", {"id": tc.id, "attempt": $attempt, "error": e.msg}.toTable)

  return (status: 0, body: "N/A", durationSec: 0.0, error: lastError)

proc formatConditionInfo*(c: Condition): tuple[url: string, headers: string, body: string] =
  let finalUrl = buildUrl(c.url, c.params)
  let (reqBody, contentType, multipartFields) = selectConditionBody(c)
  var allHeaders = initTable[string, string]()
  for k, v in c.headers:
    allHeaders[k] = v
  if contentType.len > 0 and not allHeaders.hasKey("Content-Type"):
    allHeaders["Content-Type"] = contentType
  let hJson = newJObject()
  for k, v in allHeaders:
    hJson[k] = %v
  let bodyStr = if multipartFields.files.len > 0: "(multipart)" else: reqBody
  result = (url: finalUrl, headers: $hJson, body: bodyStr)

proc execConditionHttpRequest*(c: Condition; config: HttpConfig): tuple[status: int, body: string, durationSec: float, error: string] =
  let start = epochTime()
  let url = buildUrl(c.url, c.params)

  let (reqBody, contentType, multipartFields) = selectConditionBody(c)

  gLogger.debug("准备发送条件 HTTP 请求", {
    "id": c.id,
    "type": c.typ,
    "method": c.httpMethod,
    "url": url,
    "headers_count": $c.headers.len,
    "body_len": $reqBody.len
  }.toTable)

  var lastError = ""
  let headers = tableToHttpHeaders(c.headers)
  try:
    var resp: Response
    case c.httpMethod.toUpperAscii
    of "GET":
      resp = get(url, headers = headers)
    of "POST":
      if multipartFields.text.len > 0 or multipartFields.files.len > 0:
        let (multipartContentType, multipartBody) = buildMultipartBody(multipartFields.text, multipartFields.files)
        var multipartHeaders = headers
        multipartHeaders["Content-Type"] = multipartContentType
        resp = post(url, body = multipartBody, headers = multipartHeaders)
      elif reqBody.len > 0:
        var contentHeaders = headers
        if contentType.len > 0:
          contentHeaders["Content-Type"] = contentType
        resp = post(url, body = reqBody, headers = contentHeaders)
      else:
        resp = post(url, headers = headers)
    of "PUT":
      var putHeaders = headers
      if contentType.len > 0:
        putHeaders["Content-Type"] = contentType
      resp = put(url, body = reqBody, headers = putHeaders)
    of "PATCH":
      var patchHeaders = headers
      if contentType.len > 0:
        patchHeaders["Content-Type"] = contentType
      resp = patch(url, body = reqBody, headers = patchHeaders)
    of "DELETE":
      resp = delete(url, headers = headers)
    else:
      gLogger.error("未知 HTTP 方法", {"method": c.httpMethod}.toTable)
      return (status: 0, body: "", durationSec: 0.0, error: "未知 HTTP 方法: " & c.httpMethod)

    let durationSec = epochTime() - start
    return (status: resp.code, body: resp.body, durationSec: durationSec, error: "")

  except CatchableError as e:
    lastError = e.msg
    gLogger.error("条件请求异常", {"id": c.id, "error": e.msg}.toTable)

  return (status: 0, body: "N/A", durationSec: 0.0, error: lastError)

proc runCondition*(c: Condition; config: HttpConfig; vars: var Table[string, string]): tuple[ok: bool, diff: string, actualBody: string] =
  let (reqUrl, reqHeaders, reqBody) = formatConditionInfo(c)
  let (actualStatus, actualBody, durationSec, error) = execConditionHttpRequest(c, config)

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
  let (reqBody, contentType, multipartFields) = selectRequestBody(tc)
  var allHeaders = initTable[string, string]()
  for k, v in tc.headers:
    allHeaders[k] = v
  if contentType.len > 0 and not allHeaders.hasKey("Content-Type"):
    allHeaders["Content-Type"] = contentType
  let hJson = newJObject()
  for k, v in allHeaders:
    hJson[k] = %v
  let bodyStr = if multipartFields.files.len > 0: "(multipart)" else: reqBody
  result = (url: finalUrl, headers: $hJson, body: bodyStr)

proc runTest*(tc: TestCase; config: HttpConfig): TestResult =
  let expectBodyStr = $tc.expectBody
  let tags = tc.tags.join(",")
  let (reqUrl, reqHeaders, reqBody) = formatRequestInfo(tc)
  let (actualStatus, actualBody, durationSec, error) = execHttpRequest(tc, config)

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

  if tc.expectBody.kind != JNull:
    var actualBodyJson: JsonNode
    try:
      actualBodyJson = parseJson(actualBody)
      let bodyDiffs = jsonDiff(tc.expectBody, actualBodyJson, "", tc.matchMode)
      if bodyDiffs.len > 0:
        diffs.add(bodyDiffs)
        gLogger.info("JSON 字段差异", {"id": tc.id, "diffs": bodyDiffs.join(" | ")}.toTable)
    except JsonParsingError:
      let preview = actualBody[0 ..< min(200, actualBody.len)]
      gLogger.info("响应不是合法 JSON", {"id": tc.id, "preview": preview}.toTable)
      if diffs.len == 0:
        return TestResult(
          id: tc.id, desc: tc.desc, httpMethod: tc.httpMethod, url: reqUrl, requestHeaders: reqHeaders, requestBody: reqBody, status: "FAIL", durationSec: durationSec,
          expectStatus: tc.expectStatus, actualStatus: actualStatus,
          diff: "响应不是合法 JSON: " & preview,
          actualBody: actualBody,
          expectBody: expectBodyStr,
          tags: tags
        )
      else:
        diffs.add("响应不是合法 JSON: " & preview)

  if tc.bodyRegex.len > 0:
    let pattern = tc.bodyRegex
    let isNegated = pattern.startsWith("!")
    let regexPattern = if isNegated: pattern[1..^1] else: pattern
    try:
      let regex = re2(regexPattern)
      if isNegated:
        if actualBody.contains(regex):
          diffs.add("响应体不应匹配正则模式: " & pattern)
          gLogger.info("响应体非正则匹配失败", {"id": tc.id, "pattern": pattern}.toTable)
      else:
        if not actualBody.contains(regex):
          diffs.add("响应体不匹配正则模式: " & pattern)
          gLogger.info("响应体正则匹配失败", {"id": tc.id, "pattern": pattern}.toTable)
    except CatchableError as e:
      diffs.add("body_regex 正则表达式无效: " & pattern & "，错误: " & e.msg)

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
  if chunkCount < sa.minChunks:
    return false
  case sa.kind
  of "contains":
    return sa.pattern in aggregatedContent
  of "regex":
    try:
      return aggregatedContent.contains(re2(sa.pattern))
    except CatchableError:
      return false
  of "json_path":
    let parts = sa.pattern.split('.')
    let value = getJsonPath(node, parts)
    return value != nil
  else:
    return false

proc runStreamTest*(tc: TestCase; config: HttpConfig): TestResult =
  let start = epochTime()
  let expectBodyStr = $tc.expectBody
  let tags = tc.tags.join(",")
  let (reqUrl, reqHeaders, reqBody) = formatRequestInfo(tc)
  let (actualStatus, actualBody, durationSec, error) = execHttpRequest(tc, config)

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