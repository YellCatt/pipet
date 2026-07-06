import std/[strutils, tables, uri]

import logger, types

proc buildUrl*(base, params: string): string =
  if params.len == 0:
    gLogger.debug("URL 无查询参数", {"url": base}.toTable)
    return base
  result = if '?' in base: base & "&" & params else: base & "?" & params
  gLogger.debug("构建完整 URL", {"base": base, "params": params, "url": result}.toTable)

proc splitFormFields*(form: string): tuple[textFields: Table[string, string], fileFields: Table[string, string]] =
  result.textFields = initTable[string, string]()
  result.fileFields = initTable[string, string]()
  let s = form.strip()
  if s.len == 0: return
  for pair in s.split('&'):
    let kv = pair.split('=', 1)
    if kv.len != 2: continue
    let key = kv[0].strip()
    if key.len == 0: continue
    let rawVal = kv[1]
    let val = decodeUrl(rawVal)
    if val.startsWith("file://"):
      result.fileFields[key] = val[7 ..< val.len]
    elif val.startsWith("@"):
      result.fileFields[key] = val[1 ..< val.len]
    else:
      result.textFields[key] = val

proc selectRequestBody*(tc: TestCase): tuple[body: string, contentType: string, multipartFields: tuple[text: Table[string, string], files: Table[string, string]]] =
  let (textFields, fileFields) = splitFormFields(tc.form)
  if fileFields.len > 0:
    gLogger.debug("选择 multipart 文件请求体", {"files_count": $fileFields.len, "text_fields_count": $textFields.len}.toTable)
    return ("", "", (textFields, fileFields))
  if tc.json.len > 0:
    gLogger.debug("选择 JSON 请求体", {"content_type": "application/json", "body_len": $tc.json.len}.toTable)
    return (tc.json, "application/json", (initTable[string, string](), initTable[string, string]()))
  if tc.form.len > 0:
    gLogger.debug("选择表单请求体", {"content_type": "application/x-www-form-urlencoded", "body_len": $tc.form.len}.toTable)
    return (tc.form, "application/x-www-form-urlencoded", (initTable[string, string](), initTable[string, string]()))
  if tc.body.len > 0:
    gLogger.debug("选择自定义请求体", {"body_len": $tc.body.len}.toTable)
    return (tc.body, "", (initTable[string, string](), initTable[string, string]()))
  if tc.payload.len > 0:
    gLogger.debug("选择 payload 请求体", {"body_len": $tc.payload.len}.toTable)
    return (tc.payload, "", (initTable[string, string](), initTable[string, string]()))
  gLogger.debug("请求体为空")
  return ("", "", (initTable[string, string](), initTable[string, string]()))

proc selectConditionBody*(c: Condition): tuple[body: string, contentType: string, multipartFields: tuple[text: Table[string, string], files: Table[string, string]]] =
  let (textFields, fileFields) = splitFormFields(c.form)
  if fileFields.len > 0:
    gLogger.debug("选择条件 multipart 文件请求体", {"files_count": $fileFields.len, "text_fields_count": $textFields.len}.toTable)
    return ("", "", (textFields, fileFields))
  if c.json.len > 0:
    gLogger.debug("选择条件 JSON 请求体", {"content_type": "application/json", "body_len": $c.json.len}.toTable)
    return (c.json, "application/json", (initTable[string, string](), initTable[string, string]()))
  if c.form.len > 0:
    gLogger.debug("选择条件表单请求体", {"content_type": "application/x-www-form-urlencoded", "body_len": $c.form.len}.toTable)
    return (c.form, "application/x-www-form-urlencoded", (initTable[string, string](), initTable[string, string]()))
  if c.body.len > 0:
    gLogger.debug("选择条件自定义请求体", {"body_len": $c.body.len}.toTable)
    return (c.body, "", (initTable[string, string](), initTable[string, string]()))
  if c.payload.len > 0:
    gLogger.debug("选择条件 payload 请求体", {"body_len": $c.payload.len}.toTable)
    return (c.payload, "", (initTable[string, string](), initTable[string, string]()))
  gLogger.debug("条件请求体为空")
  return ("", "", (initTable[string, string](), initTable[string, string]()))