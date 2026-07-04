import std/[json, strutils, tables]
import regex

import logger

proc getJsonPath*(node: JsonNode; path: seq[string]): JsonNode =
  result = node
  for segment in path:
    if result == nil: return nil
    case result.kind
    of JObject:
      if result.hasKey(segment):
        result = result[segment]
      else:
        return nil
    else:
      return nil

proc extractVars*(body: string; rules: Table[string, string]): Table[string, string] =
  result = initTable[string, string]()
  if rules.len == 0: return
  var bodyJson: JsonNode
  try:
    bodyJson = parseJson(body)
  except JsonParsingError:
    return result

  for varName, jsonPath in rules:
    let path = jsonPath.split('.')
    let node = getJsonPath(bodyJson, path)
    if node != nil:
      case node.kind
      of JString: result[varName] = node.getStr()
      of JInt: result[varName] = $node.getInt()
      of JFloat: result[varName] = $node.getFloat()
      of JBool: result[varName] = $node.getBool()
      else: discard

proc extractRegexMarker(s: string): string =
  ## 解析 {{regex:...}} 中的正则表达式模式
  result = s[8 ..< s.len - 2]

proc isRegexMarker(s: string): bool =
  s.startsWith("{{regex:") and s.endsWith("}}")

proc isSkipMarker(s: string): bool = s == "{{skip}}"
proc isNotExistsMarker(s: string): bool = s == "{{not_exists}}"

proc jsonDiff*(expect, actual: JsonNode, path: string = "", mode: string = "exact"): seq[string] =
  gLogger.debug("JSON 对比", {"path": if path.len == 0: "(root)" else: path, "expect_kind": $expect.kind, "actual_kind": $actual.kind, "mode": mode}.toTable)
  let mode = mode.toLowerAscii()

  if expect.kind == JString and isSkipMarker(expect.getStr()):
    return @[]

  if expect.kind == JString and isNotExistsMarker(expect.getStr()):
    return @[]

  if expect.kind != actual.kind:
    result.add(path & ": 类型不符，期望 " & $expect.kind & "，实际 " & $actual.kind)
    return

  case expect.kind
  of JObject:
    for key, val in expect:
      let childPath = if path.len == 0: key else: path & "." & key
      if val.kind == JString and isNotExistsMarker(val.getStr()):
        if actual.hasKey(key):
          result.add(childPath & ": 字段不应存在")
        continue
      if not actual.hasKey(key):
        result.add(childPath & ": 字段缺失")
      else:
        result.add jsonDiff(val, actual[key], childPath, mode)

    if mode == "exact":
      for key in actual.keys:
        if not expect.hasKey(key):
          result.add(if path.len == 0: key else: path & "." & key & ": 存在多余字段")

  of JArray:
    let eLen = expect.len
    let aLen = actual.len
    if eLen != aLen:
      result.add(path & ": 数组长度不符，期望 " & $eLen & "，实际 " & $aLen)
    else:
      for i in 0 ..< eLen:
        let childPath = path & "[" & $i & "]"
        result.add jsonDiff(expect[i], actual[i], childPath, mode)

  of JString:
    let expectStr = expect.getStr()
    if isRegexMarker(expectStr):
      let pattern = extractRegexMarker(expectStr)
      gLogger.debug("正则断言", {"path": if path.len == 0: "(root)" else: path, "pattern": pattern}.toTable)
      try:
        let regex = re(pattern)
        if regex.find(actual.getStr()).isNone:
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