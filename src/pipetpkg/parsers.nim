import std/[json, os, parsecsv, streams, strutils, tables]

import logger, types

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

proc parseExtractRules*(jsonStr: string): Table[string, string] =
  result = initTable[string, string]()
  let s = jsonStr.strip()
  if s.len == 0 or s == "{}": return
  try:
    let node = parseJson(s)
    if node.kind == JObject:
      for key, val in node:
        if val.kind == JString:
          result[key] = val.getStr()
  except:
    discard

proc parseStreamAsserts*(jsonStr: string): seq[StreamAssert] =
  result = @[]
  let s = jsonStr.strip()
  if s.len == 0 or s == "[]": return
  try:
    let node = parseJson(s)
    if node.kind != JArray:
      return
    for item in node:
      if item.kind != JObject:
        continue
      var sa = StreamAssert(kind: "contains", pattern: "", maxWaitMs: 0, minChunks: 0)
      if item.hasKey("kind") and item["kind"].kind == JString:
        sa.kind = item["kind"].getStr()
      if item.hasKey("pattern") and item["pattern"].kind == JString:
        sa.pattern = item["pattern"].getStr()
      if item.hasKey("max_wait_ms") and item["max_wait_ms"].kind == JInt:
        sa.maxWaitMs = item["max_wait_ms"].getInt()
      elif item.hasKey("maxWaitMs") and item["maxWaitMs"].kind == JInt:
        sa.maxWaitMs = item["maxWaitMs"].getInt()
      if item.hasKey("min_chunks") and item["min_chunks"].kind == JInt:
        sa.minChunks = item["min_chunks"].getInt()
      elif item.hasKey("minChunks") and item["minChunks"].kind == JInt:
        sa.minChunks = item["minChunks"].getInt()
      result.add(sa)
  except:
    discard

proc hasColumn*(parser: var CsvParser; name: string): bool =
  result = name in parser.headers

proc rowEntryOr*(parser: var CsvParser; name: string; default = ""): string =
  if parser.hasColumn(name):
    let idx = parser.headers.find(name)
    if idx >= 0 and idx < parser.row.len:
      return parser.row[idx]
  default

proc resolveTestCase*(tc: TestCase; vars: Table[string, string]): TestCase =
  result = tc
  result.url = replaceVars(tc.url, vars)
  result.params = replaceVars(tc.params, vars)
  result.form = replaceVars(tc.form, vars)
  result.json = replaceVars(tc.json, vars)
  result.body = replaceVars(tc.body, vars)
  result.payload = replaceVars(tc.payload, vars)
  var resolvedHeaders = initTable[string, string]()
  for k, v in tc.headers:
    resolvedHeaders[replaceVars(k, vars)] = replaceVars(v, vars)
  result.headers = resolvedHeaders
  result.streamAsserts = @[]
  for sa in tc.streamAsserts:
    result.streamAsserts.add(StreamAssert(
      kind: sa.kind,
      pattern: replaceVars(sa.pattern, vars),
      maxWaitMs: sa.maxWaitMs,
      minChunks: sa.minChunks
    ))

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
    if parser.row.len > 0 and parser.row[0].strip().startsWith("#"):
      continue
    rowCount += 1
    let skip = rowEntryOr(parser, "skip") == "1"
    let bodyStr = replaceVars(rowEntryOr(parser, "expected_body", "{}"), vars)
    let tagsStr = rowEntryOr(parser, "tags")
    let tags = parseTags(tagsStr)
    let extractStr = rowEntryOr(parser, "extract", "{}")
    let extract = parseExtractRules(extractStr)
    let streamMode = rowEntryOr(parser, "stream_mode") == "1"
    let streamAssertStr = rowEntryOr(parser, "stream_assert", "[]")
    let streamAsserts = parseStreamAsserts(streamAssertStr)
    let matchMode = rowEntryOr(parser, "match_mode", "exact").toLowerAscii()
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
      tags: tags,
      extract: extract,
      streamMode: streamMode,
      streamAsserts: streamAsserts,
      matchMode: matchMode
    )
    gLogger.debug("解析用例行", {
      "row": $rowCount,
      "id": tc.id,
      "method": tc.httpMethod,
      "url": tc.url,
      "skip": $tc.skip,
      "tags": tagsStr,
      "extract": extractStr,
      "stream_mode": $tc.streamMode,
      "stream_asserts": $tc.streamAsserts.len
    }.toTable)
    result.add(tc)

  parser.close()
  gLogger.info("用例文件加载完成", {"file": filename, "rows": $rowCount, "loaded": $result.len}.toTable)
