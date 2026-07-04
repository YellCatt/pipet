import std/[json, os, strutils, tables, times]

type
  LogLevel* {.pure.} = enum
    llDebug = 0
    llInfo = 1
    llWarn = 2
    llError = 3

  Logger* = ref object
    level*: LogLevel
    outStream*: File
    fileStream*: File

proc parseLogLevel*(s: string): LogLevel =
  case s.normalize
  of "debug": llDebug
  of "info": llInfo
  of "warn", "warning": llWarn
  of "error": llError
  else: llInfo

proc `$`*(level: LogLevel): string =
  case level
  of llDebug: "DEBUG"
  of llInfo: "INFO"
  of llWarn: "WARN"
  of llError: "ERROR"

proc newLogger*(level: LogLevel = llInfo; outStream: File = stderr): Logger =
  Logger(level: level, outStream: outStream, fileStream: nil)

var gLogger* = newLogger()

proc chinaNow(): DateTime =
  ## 返回东八区（UTC+8）当前时间。
  now().utc + initTimeInterval(hours = 8)

proc formatChinaTime*(dt: DateTime): string =
  ## 将时间格式化为东八区 ISO 8601 字符串。
  dt.format("yyyy-MM-dd'T'HH:mm:ss'.'fff") & "+08:00"

proc openLogFile*(logger: Logger; dir: string = "logs"; filename: string = "") =
  ## 打开日志文件，日志会同时输出到 stderr 和该文件。
  ## 如果已打开旧文件，会先关闭。
  if logger.fileStream != nil:
    try:
      logger.fileStream.close()
    except CatchableError:
      discard
  createDir(dir)
  let name = if filename.len > 0: filename else: "pipet_" & chinaNow().format("yyyyMMdd'_'HHmmss") & ".log"
  let path = dir / name
  logger.fileStream = open(path, fmWrite)

proc closeLogFile*(logger: Logger) =
  if logger.fileStream != nil:
    logger.fileStream.close()
    logger.fileStream = nil

proc log*(logger: Logger; level: LogLevel; message: string;
           fields: Table[string, string]) =
  if level.ord < logger.level.ord:
    return

  var entry = newJObject()
  entry["timestamp"] = % formatChinaTime(chinaNow())
  entry["level"] = % $level
  entry["message"] = % message

  var f = newJObject()
  for k, v in fields:
    f[k] = % v
  entry["fields"] = f

  let line = $entry
  if logger.outStream != nil:
    logger.outStream.writeLine(line)
    logger.outStream.flushFile()
  if logger.fileStream != nil:
    logger.fileStream.writeLine(line)
    logger.fileStream.flushFile()

proc debug*(logger: Logger; message: string;
            fields: Table[string, string]) =
  logger.log(llDebug, message, fields)

proc info*(logger: Logger; message: string;
           fields: Table[string, string]) =
  logger.log(llInfo, message, fields)

proc warn*(logger: Logger; message: string;
            fields: Table[string, string]) =
  logger.log(llWarn, message, fields)

proc error*(logger: Logger; message: string;
            fields: Table[string, string]) =
  logger.log(llError, message, fields)

proc debug*(logger: Logger; message: string) =
  logger.debug(message, initTable[string, string]())

proc info*(logger: Logger; message: string) =
  logger.info(message, initTable[string, string]())

proc warn*(logger: Logger; message: string) =
  logger.warn(message, initTable[string, string]())

proc error*(logger: Logger; message: string) =
  logger.error(message, initTable[string, string]())
