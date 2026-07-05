import std/[strutils, sequtils, json, tables, math]
import core, logger

proc normalizeBody(s: string): string =
  if s == "N/A" or s.len == 0:
    return s
  try:
    let node = parseJson(s)
    return $node
  except JsonParsingError:
    return s.replace("\r\n", " ").replace("\n", " ").replace("\r", " ")

proc writeRows(f: File, results: seq[TestResult]) =
  f.writeLine "id|desc|method|url|request_headers|request_body|tags|status|duration_s|expect_status|actual_status|diff|actual_body|expect_body|pre_conditions|post_conditions|extracted_vars"

  gLogger.debug("写入报告行", {"count": $results.len}.toTable)
  for r in results:
    let safeDiff = r.diff.replace("|", ";").replace("\r\n", " ").replace("\n", " ").replace("\r", " ")
    let safeDesc = r.desc.replace("|", ";").replace("\r\n", " ").replace("\n", " ").replace("\r", " ")
    let safeTags = r.tags.replace("|", ";").replace("\r\n", " ").replace("\n", " ").replace("\r", " ")
    let safeUrl = r.url.replace("|", ";")
    let safeReqHeaders = r.requestHeaders.replace("|", ";").replace("\r\n", " ").replace("\n", " ").replace("\r", " ")
    let safeReqBody = normalizeBody(r.requestBody).replace("|", ";")
    let safeBody = normalizeBody(r.actualBody).replace("|", ";")
    let safeExpect =
      if r.expectBody == "null":
        ""
      else:
        normalizeBody(r.expectBody).replace("|", ";")
    let safePre = r.preConditions.replace("|", ";")
    let safePost = r.postConditions.replace("|", ";")
    let safeExtracted = r.extractedVars.replace("|", ";")
    let durationStr = formatFloat(r.durationSec, ffDecimal, 3)

    f.writeLine r.id & "|" & safeDesc & "|" & r.httpMethod & "|" & safeUrl & "|" & safeReqHeaders & "|" & safeReqBody &
                "|" & safeTags & "|" & r.status & "|" & durationStr &
                "|" & $r.expectStatus & "|" & $r.actualStatus & "|" & safeDiff & "|" & safeBody &
                "|" & safeExpect & "|" & safePre & "|" & safePost & "|" & safeExtracted

proc writePsvReport*(results: seq[TestResult], filename: string) =
  let f = open(filename, fmWrite)
  defer: f.close()

  writeRows(f, results)

  gLogger.info("全量报告已生成", {"file": filename, "rows": $results.len}.toTable)
  echo "\nPSV 报告已保存: " & filename

proc writeErrorPsvReport*(results: seq[TestResult], filename: string) =
  let fails = results.filterIt(it.status == "FAIL")
  if fails.len == 0:
    gLogger.debug("无失败用例，不生成异常报告")
    return

  let f = open(filename, fmWrite)
  defer: f.close()

  writeRows(f, fails)

  gLogger.info("异常报告已生成", {"file": filename, "rows": $fails.len}.toTable)
  echo "异常用例 PSV 报告已保存: " & filename

proc summarizeFail(fails: seq[TestResult]): seq[tuple[key: string, reasons: seq[string]]] =
  ## 按 URL 汇总失败原因，相同 URL 的多条差异合并成一条记录。
  result = @[]
  var order = newSeq[string]()
  var grouped = initTable[string, seq[string]]()
  for r in fails:
    let key = r.url
    if key notin grouped:
      grouped[key] = @[]
      order.add(key)
    let reason = if r.diff.len > 0: r.diff else: "未记录具体差异"
    grouped[key].add(reason)
  for key in order:
    result.add((key: key, reasons: grouped[key]))

proc printFailDetails*(results: seq[TestResult]) =
  let failed = results.countIt(it.status == "FAIL")
  let passed = results.countIt(it.status == "PASS")
  let executed = passed + failed

  echo ""
  echo "通过 " & $passed & " 个 / ❌ 失败 " & $failed & " 个"
  if executed > 0:
    let rate = (float(passed) * 100.0) / float(executed)
    echo "通过率：" & formatFloat(rate, ffDecimal, 0) & "%"
  else:
    echo "通过率：0%"

  let fails = results.filterIt(it.status == "FAIL")
  if fails.len == 0: return

  echo "\n问题："
  let summary = summarizeFail(fails)
  for item in summary:
    echo "- " & item.key & "：" & item.reasons.join("；")

proc logSummary*(results: seq[TestResult]) =
  ## 将统计信息汇总成一条日志输出。
  let failed = results.countIt(it.status == "FAIL")
  let passed = results.countIt(it.status == "PASS")
  let executed = passed + failed

  var summaryTable = initTable[string, string]()
  summaryTable["total"] = $results.len
  summaryTable["passed"] = $passed
  summaryTable["failed"] = $failed
  summaryTable["skipped"] = $(results.countIt(it.status == "SKIP"))

  if executed > 0:
    let rate = (float(passed) * 100.0) / float(executed)
    summaryTable["pass_rate"] = formatFloat(rate, ffDecimal, 0) & "%"
  else:
    summaryTable["pass_rate"] = "0%"

  let fails = results.filterIt(it.status == "FAIL")
  if fails.len > 0:
    let summary = summarizeFail(fails)
    var items = newSeq[string]()
    for item in summary:
      items.add(item.key & "：" & item.reasons.join("；"))
    summaryTable["problems"] = items.join(" | ")

  let msg = if failed > 0:
    "通过 " & $passed & " 个 / ❌ 失败 " & $failed & " 个，通过率 " & summaryTable["pass_rate"] & "，存在失败用例"
  else:
    "通过 " & $passed & " 个 / ❌ 失败 " & $failed & " 个，通过率 " & summaryTable["pass_rate"] & "，全部通过"

  gLogger.info(msg, summaryTable)