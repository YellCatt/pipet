import std/[strutils, sequtils, json, tables]
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

proc printFailDetails*(results: seq[TestResult]) =
  let fails = results.filterIt(it.status == "FAIL")
  if fails.len == 0: return

  echo "\n" & repeat("=", 60)
  echo "失败用例详情（实际响应体）"
  echo repeat("=", 60)

  for r in fails:
    echo "\n[" & r.id & "] " & r.desc
    echo "  差异: " & r.diff
    echo "  实际响应体: " & r.actualBody
