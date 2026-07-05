import std/[json, os, parseopt, sequtils, strutils, sugar, tables, terminal, times]
import pipetpkg/[core, report, logger, executor, mailer]

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

proc collectPsvFiles(dir: string): seq[string] =
  result = @[]
  if not dirExists(dir): return
  for f in walkDirRec(dir):
    if f.endsWith(".psv") and fileExists(f):
      result.add(f)

proc resolveDataFiles(userPaths: seq[string]): seq[string] =
  if userPaths.len == 0:
    let candidates = @[
      getAppDir() / "tests",
      "tests"
    ]
    for c in candidates:
      result = collectPsvFiles(c)
      if result.len > 0:
        gLogger.debug("找到默认用例目录", {"dir": c, "files": $result.len}.toTable)
        return result
    gLogger.debug("未找到默认用例目录，使用默认 test_data.psv", initTable[string, string]())
    return @["test_data.psv"]
  result = @[]
  for p in userPaths:
    if dirExists(p):
      gLogger.debug("扫描目录用例文件", {"dir": p}.toTable)
      for f in collectPsvFiles(p):
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

proc parseOffsetMinutes(s: string): int =
  if s.len < 4:
    return 0
  var i = 0
  var sign = 1
  if s[0] == '+': i += 1
  elif s[0] == '-': i += 1; sign = -1
  if s.len - i < 4:
    return 0
  let hours = parseInt(s[i..i+1])
  let minutes = parseInt(s[i+2..i+3])
  return sign * (hours * 60 + minutes)

proc getReportTimestamp(zone: string): string =
  let t = getTime()
  case zone.toLowerAscii
  of "utc":
    return t.utc.format("yyyyMMdd'_'HHmmss")
  of "local":
    return t.local.format("yyyyMMdd'_'HHmmss")
  else:
    let offsetMinutes = parseOffsetMinutes(zone)
    if offsetMinutes == 0 and zone.toLowerAscii notin ["+0000", "-0000", "0000"]:
      gLogger.warn("无法解析时区配置，使用默认值 local", {"report_timezone": zone}.toTable)
      return t.local.format("yyyyMMdd'_'HHmmss")
    return (t.utc + initDuration(minutes = offsetMinutes)).format("yyyyMMdd'_'HHmmss")

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
    vars["base_url"] = "http://localhost:8080"
    gLogger.warn("未配置 base_url，使用默认值 http://localhost:8080", initTable[string, string]())
    gLogger.info("提示：当前编译未启用 OpenSSL，仅支持 HTTP 接口测试", initTable[string, string]())

  let timeout = getIntConfig(vars, "timeout", 30000, 0)
  let poolSize = getIntConfig(vars, "pool_size", 1, 1)
  let retryCount = getIntConfig(vars, "retry_count", 0, 0)
  let retryDelayMs = getIntConfig(vars, "retry_delay_ms", 0, 0)

  let pool = newHttpClientPool(poolSize, timeout)

  gLogger.level = parseLogLevel(vars.getOrDefault("log_level", "INFO"))
  gLogger.openLogFile("logs")
  gLogger.info("配置加载完成", {"config": configFile, "log_level": $gLogger.level, "vars_count": $vars.len}.toTable)

  let selectedTags = tagsFilter.split(',').mapIt(it.strip()).filterIt(it.len > 0)
  let startTime = epochTime()
  var allResults: seq[TestResult]

  echo "╔══════════════════════════════════════════════════════╗"
  echo "║              pipet 接口测试                          ║"
  echo "╚══════════════════════════════════════════════════════╝\n"

  let baseConditions = loadConditions("base_conditions.psv", vars)

  for f in dataFiles:
    var fileVars = vars
    var conditions = initTable[string, Condition]()
    for id, c in baseConditions:
      conditions[id] = c
    let localCondFile = parentDir(f) / "base_conditions.psv"
    if localCondFile != "base_conditions.psv" and fileExists(localCondFile):
      for id, c in loadConditions(localCondFile, fileVars):
        conditions[id] = c
    var fileCases = loadCases(f, fileVars)
    if fileCases.len == 0:
      continue

    if selectedTags.len > 0:
      gLogger.info("按标签过滤", {"tags": tagsFilter, "before": $fileCases.len}.toTable)
      fileCases = fileCases.filterIt(it.tags.any(tag => tag in selectedTags))
      gLogger.info("标签过滤完成", {"after": $fileCases.len}.toTable)
      if fileCases.len == 0:
        continue

    echo "\n  📁 " & f
    var fileResults: seq[TestResult]

    for tc in fileCases:
      let preList = tc.pre.join(";")
      let postList = tc.post.join(";")

      if tc.skip:
        gLogger.info("跳过用例", {"id": tc.id, "desc": tc.desc}.toTable)
        let (skipUrl, skipHeaders, skipBody) = formatRequestInfo(resolveTestCase(tc, fileVars))
        fileResults.add TestResult(
          id: tc.id, desc: tc.desc, httpMethod: tc.httpMethod, url: skipUrl,
          requestHeaders: skipHeaders, requestBody: skipBody, status: "SKIP", durationSec: 0.0,
          expectStatus: tc.expectStatus, actualStatus: 0, diff: "",
          actualBody: "",
          expectBody: $tc.expectBody,
          tags: tc.tags.join(","), preConditions: preList, postConditions: postList, extractedVars: ""
        )
        styledEcho styleDim, "    [", tc.id, "] ", tc.desc, " ... SKIP"
        continue

      var preDiffs: seq[string]
      for cid in tc.pre:
        if not conditions.hasKey(cid):
          gLogger.warn("前置条件不存在", {"id": tc.id, "condition": cid}.toTable)
          preDiffs.add("pre[" & cid & "]: 条件不存在")
          continue
        let resolvedCond = resolveCondition(conditions[cid], fileVars)
        gLogger.debug("执行前置条件", {"id": tc.id, "condition": cid}.toTable)
        stdout.write "    [" & tc.id & "] pre:" & cid & " ... "
        let rc = runCondition(resolvedCond, pool, fileVars)
        if rc.ok:
          styledEcho fgGreen, "OK", resetStyle
        else:
          styledEcho fgRed, "FAIL", resetStyle, " (" & rc.diff & ")"
          preDiffs.add("pre[" & cid & "]: " & rc.diff)
      if preDiffs.len > 0:
        let (reqUrl, reqHeaders, reqBody) = formatRequestInfo(resolveTestCase(tc, fileVars))
        fileResults.add TestResult(
          id: tc.id, desc: tc.desc, httpMethod: tc.httpMethod, url: reqUrl,
          requestHeaders: reqHeaders, requestBody: reqBody, status: "FAIL", durationSec: 0.0,
          expectStatus: tc.expectStatus, actualStatus: 0,
          diff: preDiffs.join(" | "), actualBody: "", expectBody: $tc.expectBody,
          tags: tc.tags.join(","), preConditions: preList, postConditions: postList, extractedVars: ""
        )
        continue

      let resolvedTc = resolveTestCase(tc, fileVars)
      gLogger.debug("开始执行用例", {"id": tc.id, "method": resolvedTc.httpMethod, "url": resolvedTc.url, "stream_mode": $resolvedTc.streamMode}.toTable)
      stdout.write "    [" & tc.id & "] " & tc.desc & " ... "
      let r = if resolvedTc.streamMode: runStreamTest(resolvedTc, pool) else: runTest(resolvedTc, pool, retryCount, retryDelayMs)

      var extractedVars: seq[string]
      if r.status == "PASS":
        let extracted = extractVars(r.actualBody, tc.extract)
        for k, v in extracted:
          fileVars[k] = v
          extractedVars.add(k & "=" & v)
          gLogger.info("提取上下文变量", {"key": k, "value": v}.toTable)

      var postDiffs: seq[string]
      for cid in tc.post:
        if not conditions.hasKey(cid):
          gLogger.warn("后置条件不存在", {"id": tc.id, "condition": cid}.toTable)
          postDiffs.add("post[" & cid & "]: 条件不存在")
          continue
        let resolvedCond = resolveCondition(conditions[cid], fileVars)
        gLogger.debug("执行后置条件", {"id": tc.id, "condition": cid}.toTable)
        stdout.write "    [" & tc.id & "] post:" & cid & " ... "
        let rc = runCondition(resolvedCond, pool, fileVars)
        if rc.ok:
          styledEcho fgGreen, "OK", resetStyle
        else:
          styledEcho fgRed, "FAIL", resetStyle, " (" & rc.diff & ")"
          postDiffs.add("post[" & cid & "]: " & rc.diff)

      var finalR = r
      finalR.preConditions = preList
      finalR.postConditions = postList
      finalR.extractedVars = extractedVars.join(";")
      if postDiffs.len > 0:
        finalR.status = "FAIL"
        finalR.diff = (if finalR.diff.len > 0: finalR.diff & " | " else: "") & postDiffs.join(" | ")
      fileResults.add(finalR)

      let durationStr = formatFloat(finalR.durationSec, ffDecimal, 3) & "s"
      gLogger.debug("用例执行完成", {"id": finalR.id, "status": finalR.status, "duration_s": durationStr}.toTable)
      case finalR.status
      of "PASS":
        styledEcho fgGreen, "PASS", resetStyle, " (" & durationStr & ")"
      of "FAIL":
        styledEcho fgRed, "FAIL", resetStyle, " (" & durationStr & ")"
        if finalR.diff.len > 80:
          echo "         " & finalR.diff[0..79] & "..."
        else:
          echo "         " & finalR.diff
      else:
        discard

    allResults.add(fileResults)

  let results = allResults
  gLogger.info("测试执行完成", {"total_cases": $results.len, "data_files": dataFiles.join(", ")}.toTable)
  if results.len == 0:
    echo "\n没有加载到测试用例"
    return

  let passed = results.countIt(it.status == "PASS")
  let failed = results.countIt(it.status == "FAIL")
  let skipped = results.countIt(it.status == "SKIP")

  gLogger.info("测试执行统计", {"pass": $passed, "fail": $failed, "skip": $skipped}.toTable)

  let durationSec = epochTime() - startTime
  let mailerConfig = initMailerConfig(vars)
  let mailer = newMailer(mailerConfig)
  mailer.sendTestReport(passed, failed, skipped, durationSec, results)

  echo "\n═══════════════════════════════════════════════════════"


  echo "\n╔══════════════════════════════════════════════════════╗"
  echo "║  通过: " & align($passed, 3) & "  失败: " & align($failed, 3) & "  跳过: " & align($skipped, 3) & "              ║"
  echo "╚══════════════════════════════════════════════════════╝"

  let timestamp = getReportTimestamp(vars.getOrDefault("report_timezone", "local"))
  let reportsDir = "reports"
  createDir(reportsDir)
  let reportPrefix = reportsDir / "report_" & timestamp

  gLogger.debug("生成测试报告", {"reports_dir": reportsDir, "prefix": reportPrefix}.toTable)
  writePsvReport(results, reportPrefix & ".psv")
  writeErrorPsvReport(results, reportPrefix & "_error.psv")
  printFailDetails(results)

  if failed > 0:
    gLogger.info("所有用例已执行完成，存在失败用例，以退出码 1 结束", {"failed": $failed, "total": $results.len}.toTable)
    quit(1)
  gLogger.info("所有用例执行完成")

when isMainModule:
  main()