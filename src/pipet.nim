import std/[json, os, parseopt, sequtils, strutils, sugar, tables, terminal, times]
import pipetpkg/[core, report, logger]

proc resolveConfigFile(userPath: string): string =
  if userPath.len > 0:
    gLogger.debug("使用显式配置文件", {"path": userPath}.toTable)
    return userPath
  let candidates = @[
    getAppDir() / "config.yaml",
    getAppDir() / "config.yml",
    "config.yaml",
    "config.yml"
  ]
  for c in candidates:
    if fileExists(c):
      gLogger.debug("找到默认配置文件", {"path": c}.toTable)
      return c
  return "config.yaml"

proc resolveDataFiles(userPaths: seq[string]): seq[string] =
  if userPaths.len == 0:
    let candidates = @[
      getAppDir() / "test_data.psv",
      "test_data.psv",
      getAppDir() / "tests" / "test_data.psv",
      "tests" / "test_data.psv"
    ]
    for c in candidates:
      if fileExists(c):
        gLogger.debug("找到默认用例文件", {"path": c}.toTable)
        return @[c]
    gLogger.debug("未找到默认用例文件", {"candidates": candidates.join(", ")}.toTable)
    return @[candidates[0]]
  result = @[]
  for p in userPaths:
    if dirExists(p):
      gLogger.debug("扫描目录用例文件", {"dir": p}.toTable)
      for f in walkFiles(p / "*.psv"):
        result.add(f)
        gLogger.debug("发现用例文件", {"file": f}.toTable)
    elif fileExists(p):
      result.add(p)
      gLogger.debug("使用指定用例文件", {"file": p}.toTable)
    else:
      gLogger.warn("文件或目录不存在", {"path": p}.toTable)

proc getIntConfig(vars: Table[string, string], key: string, defaultValue: int, minValue = low(int)): int =
  result = defaultValue
  if vars.hasKey(key):
    try:
      result = parseInt(vars[key])
      if result < minValue:
        result = defaultValue
        gLogger.warn("配置项超出允许范围，已使用默认值", {"key": key, "value": vars[key], "min": $minValue, "default": $defaultValue}.toTable)
    except ValueError:
      gLogger.warn("配置项不是有效整数，已使用默认值", {"key": key, "value": vars[key], "default": $defaultValue}.toTable)

proc main() =
  var configFile = ""
  var dataFileArgs: seq[string] = @[]
  var tagsFilter = ""
  var configExplicit = false

  var opt = initOptParser(commandLineParams())
  for kind, key, val in opt.getopt():
    case kind
    of cmdLongOption, cmdShortOption:
      case key
      of "config", "c":
        configFile = val
        configExplicit = true
      of "tags", "t":
        tagsFilter = val
      else: discard
    of cmdArgument:
      dataFileArgs.add(key)
    of cmdEnd: break

  configFile = resolveConfigFile(configFile)
  let dataFiles = resolveDataFiles(dataFileArgs)

  gLogger.info("启动参数解析完成", {
    "config": configFile,
    "data_files": dataFiles.join(", "),
    "tags_filter": tagsFilter,
    "config_explicit": $configExplicit
  }.toTable)

  var vars: Table[string, string]
  if fileExists(configFile):
    vars = loadConfig(configFile)
  elif configExplicit:
    gLogger.error("配置文件不存在", {"config": configFile}.toTable)
    quit(1)
  else:
    vars = initTable[string, string]()

  if not vars.hasKey("base_url"):
    vars["base_url"] = "https://httpbin.org"

  let timeout = getIntConfig(vars, "timeout", 30000, 0)
  let poolSize = getIntConfig(vars, "pool_size", 1, 1)
  let retryCount = getIntConfig(vars, "retry_count", 0, 0)
  let retryDelayMs = getIntConfig(vars, "retry_delay_ms", 0, 0)

  let pool = newHttpClientPool(poolSize, timeout)

  gLogger.level = parseLogLevel(vars.getOrDefault("log_level", "INFO"))
  gLogger.openLogFile("logs")
  gLogger.info("配置加载完成", {"config": configFile, "log_level": $gLogger.level, "vars_count": $vars.len}.toTable)

  var cases: seq[TestCase] = @[]
  for f in dataFiles:
    cases.add(loadCases(f, vars))
  gLogger.info("用例加载完成", {"total_cases": $cases.len, "data_files": dataFiles.join(", ")}.toTable)
  if cases.len == 0:
    echo "没有加载到测试用例"
    return

  let selectedTags = tagsFilter.split(',').mapIt(it.strip()).filterIt(it.len > 0)
  if selectedTags.len > 0:
    gLogger.info("按标签过滤", {"tags": tagsFilter, "before": $cases.len}.toTable)
    cases = cases.filterIt(it.tags.any(tag => tag in selectedTags))
    gLogger.info("标签过滤完成", {"after": $cases.len}.toTable)
    if cases.len == 0:
      echo "没有符合标签的测试用例: " & tagsFilter
      return

  var results: seq[TestResult]

  echo "╔══════════════════════════════════════════════════════╗"
  echo "║              pipet 接口测试                          ║"
  echo "╚══════════════════════════════════════════════════════╝\n"

  for tc in cases:
    if tc.skip:
      gLogger.info("跳过用例", {"id": tc.id, "desc": tc.desc}.toTable)
      results.add TestResult(
        id: tc.id, desc: tc.desc, status: "SKIP", durationSec: 0.0,
        expectStatus: tc.expectStatus, actualStatus: 0, diff: "",
        actualBody: "",
        expectBody: $tc.expectBody,
        skipFields: collectSkipFields(tc.expectBody).join(","),
        tags: tc.tags.join(",")
      )
      styledEcho styleDim, "  [", tc.id, "] ", tc.desc, " ... SKIP"
      continue

    gLogger.debug("开始执行用例", {"id": tc.id, "method": tc.httpMethod, "url": tc.url}.toTable)
    stdout.write "  [" & tc.id & "] " & tc.desc & " ... "
    let r = runTest(tc, pool, retryCount, retryDelayMs)
    results.add(r)

    let durationStr = formatFloat(r.durationSec, ffDecimal, 3) & "s"
    gLogger.debug("用例执行完成", {"id": r.id, "status": r.status, "duration_s": durationStr}.toTable)
    case r.status
    of "PASS":
      styledEcho fgGreen, "PASS", resetStyle, " (" & durationStr & ")"
    of "FAIL":
      styledEcho fgRed, "FAIL", resetStyle, " (" & durationStr & ")"
      if r.diff.len > 80:
        echo "       " & r.diff[0..79] & "..."
      else:
        echo "       " & r.diff
    else:
      discard

  let passed = results.countIt(it.status == "PASS")
  let failed = results.countIt(it.status == "FAIL")
  let skipped = results.countIt(it.status == "SKIP")

  gLogger.info("测试执行统计", {"pass": $passed, "fail": $failed, "skip": $skipped}.toTable)

  echo "\n╔══════════════════════════════════════════════════════╗"
  echo "║  通过: " & align($passed, 3) & "  失败: " & align($failed, 3) & "  跳过: " & align($skipped, 3) & "              ║"
  echo "╚══════════════════════════════════════════════════════╝"

  let timestamp = now().format("yyyyMMdd'_'HHmmss")
  let reportsDir = "reports"
  createDir(reportsDir)
  let reportPrefix = reportsDir / "report_" & timestamp

  gLogger.debug("生成测试报告", {"reports_dir": reportsDir, "prefix": reportPrefix}.toTable)
  writePsvReport(results, reportPrefix & ".psv")
  writeErrorPsvReport(results, reportPrefix & "_error.psv")
  printFailDetails(results)

  if failed > 0:
    gLogger.info("存在失败用例，退出码 1", {"failed": $failed}.toTable)
    quit(1)
  gLogger.info("所有用例执行完成")

when isMainModule:
  main()
