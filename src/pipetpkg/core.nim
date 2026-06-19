import std/[httpclient, httpcore, json, parsecsv, re, streams, strutils, tables, os, times]
import yaml/tojson
import logger

type
  TestCase* = object
    id*: string
    desc*: string
    httpMethod*: string
    url*: string
    headers*: Table[string, string]
    payload*: string
    params*: string
    form*: string
    json*: string
    body*: string
    expectStatus*: int
    expectBody*: JsonNode
    skip*: bool
    tags*: seq[string]

  TestResult* = object
    id*: string
    desc*: string
    status*: string
    durationSec*: float
    expectStatus*: int
    actualStatus*: int
    diff*: string
    actualBody*: string
    expectBody*: string
    skipFields*: string
    tags*: string

  HttpClientPool* = ref object
    maxSize*: int
    timeoutMs*: int
    available*: seq[HttpClient]

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

proc parseHeaders*(jsonStr: string): Table[string, string] =
  result = initTable[string, string]()
  let s = jsonStr.strip()
  if s.len == 0 or s == "{}": return
  try:
    let node = parseJson(s)
    for key, val in node:
      result[key] = val.getStr()
  except:
    discard

proc replaceVars*(s: string, vars: Table[string, string]): string =
  result = s
  if vars.len == 0 or result.len == 0:
    return
  gLogger.debug("变量替换前", {"input": s}.toTable)
  for key, val in vars:
    result = result.replace("{{" & key & "}}", val)
  gLogger.debug("变量替换后", {"output": result}.toTable)

proc parseTags*(s: string): seq[string] =
  result = @[]
  for tag in s.split(','):
    let t = tag.strip()
    if t.len > 0:
      result.add(t)

proc hasColumn*(parser: var CsvParser; name: string): bool =
  result = name in parser.headers

proc rowEntryOr*(parser: var CsvParser; name: string; default = ""): string =
  if parser.hasColumn(name): parser.rowEntry(name) else: default

proc loadCases*(filename: string, vars: Table[string, string]): seq[TestCase] =
  result = @[]
  if not fileExists(filename):
    gLogger.error("PSV 文件不存在", {"file": filename}.toTable)
    return

  gLogger.debug("开始加载用例", {"file": filename}.toTable)
  var s = newFileStream(filename)
  var parser: CsvParser
  parser.open(s, filename, separator='|')
  parser.readHeaderRow()
  gLogger.debug("读取 PSV 表头", {"headers": parser.headers.join(", ")}.toTable)

  var rowCount = 0
  while parser.readRow():
    rowCount += 1
    let skip = rowEntryOr(parser, "skip") == "1"
    let bodyStr = replaceVars(rowEntryOr(parser, "expected_body", "{}"), vars)
    let tagsStr = rowEntryOr(parser, "tags")
    let tags = parseTags(tagsStr)
    let tc = TestCase(
      id: rowEntryOr(parser, "id"),
      desc: rowEntryOr(parser, "desc"),
      httpMethod: replaceVars(rowEntryOr(parser, "method", "GET").toUpperAscii(), vars),
      url: replaceVars(rowEntryOr(parser, "url"), vars),
      headers: parseHeaders(replaceVars(rowEntryOr(parser, "headers", "{}"), vars)),
      payload: replaceVars(rowEntryOr(parser, "payload"), vars),
      params: replaceVars(rowEntryOr(parser, "params"), vars),
      form: replaceVars(rowEntryOr(parser, "form"), vars),
      json: replaceVars(rowEntryOr(parser, "json"), vars),
      body: replaceVars(rowEntryOr(parser, "body"), vars),
      expectStatus: parseInt(rowEntryOr(parser, "expected_status", "200")),
      expectBody: parseJson(bodyStr),
      skip: skip,
      tags: tags
    )
    gLogger.debug("解析用例行", {
      "row": $rowCount,
      "id": tc.id,
      "method": tc.httpMethod,
      "url": tc.url,
      "skip": $tc.skip,
      "tags": tagsStr
    }.toTable)
    result.add(tc)

  parser.close()
  gLogger.info("用例文件加载完成", {"file": filename, "rows": $rowCount, "loaded": $result.len}.toTable)

proc loadConfig*(filename: string): Table[string, string] =
  result = initTable[string, string]()
  if not fileExists(filename):
    gLogger.debug("配置文件不存在，使用空变量表", {"file": filename}.toTable)
    return
  try:
    gLogger.debug("开始加载 YAML 配置", {"file": filename}.toTable)
    var s = newFileStream(filename)
    defer: s.close()
    let docs = loadToJson(s)
    if docs.len == 0:
      gLogger.error("YAML 配置文件为空", {"file": filename}.toTable)
      return
    let node = docs[0]
    if node.kind != JObject:
      gLogger.error("YAML 配置根节点必须是对象")
      return
    for key, val in node:
      case val.kind
      of JString:
        result[key] = val.getStr()
        gLogger.debug("加载配置项", {"key": key, "value": result[key]}.toTable)
      of JInt:
        result[key] = $val.getInt()
        gLogger.debug("加载配置项", {"key": key, "value": result[key]}.toTable)
      of JFloat:
        result[key] = $val.getFloat()
        gLogger.debug("加载配置项", {"key": key, "value": result[key]}.toTable)
      of JBool:
        result[key] = $val.getBool()
        gLogger.debug("加载配置项", {"key": key, "value": result[key]}.toTable)
      else:
        gLogger.warn("配置项值类型不支持，已忽略", {"key": key}.toTable)
    gLogger.info("YAML 配置加载完成", {"file": filename, "vars_count": $result.len}.toTable)
  except YamlParserError as e:
    gLogger.error("YAML 解析失败", {"error": e.msg}.toTable)
  except YamlConstructionError as e:
    gLogger.error("YAML 构造失败", {"error": e.msg}.toTable)
  except CatchableError as e:
    gLogger.error("读取配置文件失败", {"error": e.msg}.toTable)

proc buildUrl*(base, params: string): string =
  if params.len == 0:
    gLogger.debug("URL 无查询参数", {"url": base}.toTable)
    return base
  result = if '?' in base: base & "&" & params else: base & "?" & params
  gLogger.debug("构建完整 URL", {"base": base, "params": params, "url": result}.toTable)

proc selectRequestBody(tc: TestCase): tuple[body: string, contentType: string] =
  if tc.json.len > 0:
    gLogger.debug("选择 JSON 请求体", {"content_type": "application/json", "body_len": $tc.json.len}.toTable)
    return (tc.json, "application/json")
  if tc.form.len > 0:
    gLogger.debug("选择表单请求体", {"content_type": "application/x-www-form-urlencoded", "body_len": $tc.form.len}.toTable)
    return (tc.form, "application/x-www-form-urlencoded")
  if tc.body.len > 0:
    gLogger.debug("选择自定义请求体", {"body_len": $tc.body.len}.toTable)
    return (tc.body, "")
  if tc.payload.len > 0:
    gLogger.debug("选择 payload 请求体", {"body_len": $tc.payload.len}.toTable)
    return (tc.payload, "")
  gLogger.debug("请求体为空")
  return ("", "")

proc collectSkipFields*(node: JsonNode, path: string = ""): seq[string] =
  if node.kind == JString and node.getStr() == "{{skip}}":
    result.add(if path.len == 0: "(root)" else: path)
    return
  case node.kind
  of JObject:
    for key, val in node:
      let childPath = if path.len == 0: key else: path & "." & key
      result.add collectSkipFields(val, childPath)
  of JArray:
    for i in 0 ..< node.len:
      let childPath = path & "[" & $i & "]"
      result.add collectSkipFields(node[i], childPath)
  else:
    discard

proc extractRegexMarker(s: string): string =
  ## 解析 {{regex:...}} 中的正则表达式模式
  result = s[8 ..< s.len - 2]

proc isRegexMarker(s: string): bool =
  s.startsWith("{{regex:") and s.endsWith("}}")

proc jsonDiff*(expect, actual: JsonNode, path: string = ""): seq[string] =
  gLogger.debug("JSON 对比", {"path": if path.len == 0: "(root)" else: path, "expect_kind": $expect.kind, "actual_kind": $actual.kind}.toTable)
  if expect.kind == JString and expect.getStr() == "{{skip}}":
    return @[]

  if expect.kind != actual.kind:
    result.add(path & ": 类型不符，期望 " & $expect.kind & "，实际 " & $actual.kind)
    return

  case expect.kind
  of JObject:
    for key, val in expect:
      let childPath = if path.len == 0: key else: path & "." & key
      if not actual.hasKey(key):
        result.add(childPath & ": 字段缺失")
      else:
        result.add jsonDiff(val, actual[key], childPath)

  of JArray:
    let eLen = expect.len
    let aLen = actual.len
    if eLen != aLen:
      result.add(path & ": 数组长度不符，期望 " & $eLen & "，实际 " & $aLen)
    else:
      for i in 0 ..< eLen:
        let childPath = path & "[" & $i & "]"
        result.add jsonDiff(expect[i], actual[i], childPath)

  of JString:
    let expectStr = expect.getStr()
    if isRegexMarker(expectStr):
      let pattern = extractRegexMarker(expectStr)
      gLogger.debug("正则断言", {"path": if path.len == 0: "(root)" else: path, "pattern": pattern}.toTable)
      try:
        let regex = re(pattern)
        if not match(actual.getStr(), regex):
          result.add(path & ": 正则匹配失败，模式 \"" & pattern & "\"，实际 \"" & actual.getStr() & "\"")
      except CatchableError as e:
        result.add(path & ": 正则表达式无效: " & pattern & "，错误: " & e.msg)
    elif expectStr != actual.getStr():
      result.add(path & ": 字符串不符，期望 \"" & expect.getStr() & "\"，实际 \"" & actual.getStr() & "\"")

  of JInt:
    if expect.getInt() != actual.getInt():
      result.add(path & ": 数值不符，期望 " & $expect.getInt() & "，实际 " & $actual.getInt())

  of JFloat:
    if expect.getFloat() != actual.getFloat():
      result.add(path & ": 浮点不符，期望 " & $expect.getFloat() & "，实际 " & $actual.getFloat())

  of JBool:
    if expect.getBool() != actual.getBool():
      result.add(path & ": 布尔不符，期望 " & $expect.getBool() & "，实际 " & $actual.getBool())

  of JNull:
    if actual.kind != JNull:
      result.add(path & ": 期望 null，实际 " & $actual.kind)

proc runTest*(tc: TestCase; pool: HttpClientPool; retryCount: int = 0; retryDelayMs: int = 0): TestResult =
  let start = epochTime()
  let expectBodyStr = $tc.expectBody
  let skipFields = collectSkipFields(tc.expectBody).join(",")
  let tags = tc.tags.join(",")
  let url = buildUrl(tc.url, tc.params)
  let (reqBody, contentType) = selectRequestBody(tc)

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
      for k, v in tc.headers:
        client.headers[k] = v
      if contentType.len > 0 and not tc.headers.hasKey("Content-Type"):
        client.headers["Content-Type"] = contentType

      resp = case tc.httpMethod
        of "GET":
          if reqBody.len > 0: client.request(url, HttpGet, body = reqBody)
          else: client.get(url)
        of "POST": client.post(url, body = reqBody)
        of "PUT": client.put(url, body = reqBody)
        of "PATCH": client.request(url, httpMethod = HttpPatch, body = reqBody)
        of "DELETE": client.request(url, httpMethod = HttpDelete, body = reqBody)
        else:
          gLogger.error("未知 HTTP 方法", {"method": tc.httpMethod}.toTable)
          pool.returnClient(client)
          return TestResult(
            id: tc.id, desc: tc.desc, status: "FAIL", durationSec: 0.0,
            expectStatus: tc.expectStatus, actualStatus: 0,
            diff: "未知 HTTP 方法: " & tc.httpMethod,
            actualBody: "",
            expectBody: expectBodyStr,
            skipFields: skipFields,
            tags: tags
          )
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
    return TestResult(
      id: tc.id, desc: tc.desc, status: "FAIL", durationSec: 0.0,
      expectStatus: tc.expectStatus, actualStatus: 0,
      diff: "请求异常: " & lastError,
      actualBody: "N/A",
      expectBody: expectBodyStr,
      skipFields: skipFields,
      tags: tags
    )

  let durationSec = epochTime() - start
  let actualStatus = resp.code.int
  let actualBody = resp.body

  gLogger.debug("收到 HTTP 响应", {
    "id": tc.id,
    "status": $actualStatus,
    "body_len": $actualBody.len,
    "duration_s": formatFloat(durationSec, ffDecimal, 3)
  }.toTable)

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
      skipFields: skipFields,
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
      skipFields: skipFields,
      tags: tags
    )

  let diffs = jsonDiff(tc.expectBody, actualBodyJson)
  if diffs.len > 0:
    gLogger.info("JSON 字段差异", {"id": tc.id, "diffs": diffs.join(" | ")}.toTable)
    return TestResult(
      id: tc.id, desc: tc.desc, status: "FAIL", durationSec: durationSec,
      expectStatus: tc.expectStatus, actualStatus: actualStatus,
      diff: diffs.join(" | "),
      actualBody: actualBody,
      expectBody: expectBodyStr,
      skipFields: skipFields,
      tags: tags
    )

  gLogger.debug("用例断言通过", {"id": tc.id}.toTable)
  TestResult(
    id: tc.id, desc: tc.desc, status: "PASS", durationSec: durationSec,
    expectStatus: tc.expectStatus, actualStatus: actualStatus,
    diff: "",
    actualBody: actualBody,
    expectBody: expectBodyStr,
    skipFields: skipFields,
    tags: tags
  )
