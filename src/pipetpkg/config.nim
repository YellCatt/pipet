import std/[json, os, streams, tables]

import yaml/tojson
import logger

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
      of JInt:
        result[key] = $val.getInt()
      of JFloat:
        result[key] = $val.getFloat()
      of JBool:
        result[key] = $val.getBool()
      else:
        gLogger.warn("配置项值类型不支持，已忽略", {"key": key}.toTable)
        continue
      gLogger.debug("加载配置项", {"key": key, "value": result[key]}.toTable)
    gLogger.info("YAML 配置加载完成", {"file": filename, "vars_count": $result.len}.toTable)
  except YamlParserError as e:
    gLogger.error("YAML 解析失败", {"error": e.msg}.toTable)
  except YamlConstructionError as e:
    gLogger.error("YAML 构造失败", {"error": e.msg}.toTable)
  except CatchableError as e:
    gLogger.error("读取配置文件失败", {"error": e.msg}.toTable)
