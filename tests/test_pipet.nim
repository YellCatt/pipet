import std/[json, strutils, tables]
import pipetpkg/core

# parseHeaders
block:
  let h = parseHeaders("""{"Content-Type":"application/json"}""")
  assert h["Content-Type"] == "application/json"

# replaceVars
block:
  let vars = {"base_url": "https://example.com"}.toTable()
  assert replaceVars("{{base_url}}/api", vars) == "https://example.com/api"

# loadConfig 读取 YAML 配置
block:
  let vars = loadConfig("tests/test_config.yaml")
  assert vars["base_url"] == "http://localhost:8080"
  assert vars["token"] == "dev-token"

# jsonDiff 成功：跳过字段 + 允许额外字段
block:
  let expect = parseJson("""{"a":1,"b":{"c":"{{skip}}"}}""")
  let actual = parseJson("""{"a":1,"b":{"c":"ignored","d":"extra"}}""")
  assert jsonDiff(expect, actual).len == 0

# jsonDiff 成功：正则表达式断言
block:
  let expect = parseJson("""{"ip":"{{regex:^[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}$}}"}""")
  let actual = parseJson("""{"ip":"192.168.1.1"}""")
  assert jsonDiff(expect, actual).len == 0

# jsonDiff 失败：正则表达式不匹配
block:
  let expect = parseJson("""{"name":"{{regex:^\\d+$}}"}""")
  let actual = parseJson("""{"name":"abc"}""")
  let diffs = jsonDiff(expect, actual)
  assert diffs.len == 1
  assert diffs[0].contains("正则匹配失败")

# jsonDiff 失败
block:
  let expect = parseJson("""{"a":1}""")
  let actual = parseJson("""{"a":2}""")
  let diffs = jsonDiff(expect, actual)
  assert diffs.len == 1
  assert diffs[0].contains("数值不符")

echo "所有测试通过"
