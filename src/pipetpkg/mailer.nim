import std/[smtp, strutils, sequtils, times, tables]
import types, logger

type
  MailerConfig* = object
    enabled*: bool
    smtpHost*: string
    smtpPort*: int
    fromAddr*: string
    toAddrs*: seq[string]
    authUser*: string
    authPass*: string
    useSsl*: bool
    subjectPrefix*: string

  Mailer* = object
    config*: MailerConfig

proc initMailerConfig*(vars: Table[string, string]): MailerConfig =
  result.enabled = vars.getOrDefault("mail_enabled", "false").toLowerAscii == "true"
  result.smtpHost = vars.getOrDefault("mail_smtp_host", "smtp.qq.com")
  result.smtpPort = parseInt(vars.getOrDefault("mail_smtp_port", "465"))
  result.fromAddr = vars.getOrDefault("mail_from", "")
  result.toAddrs = vars.getOrDefault("mail_to", "")
    .split(',')
    .mapIt(it.strip())
    .filterIt(it.len > 0)
  result.authUser = vars.getOrDefault("mail_auth_user", result.fromAddr)
  result.authPass = vars.getOrDefault("mail_auth_pass", "")
  result.useSsl = vars.getOrDefault("mail_use_ssl", "true").toLowerAscii == "true"
  result.subjectPrefix = vars.getOrDefault("mail_subject_prefix", "pipet 测试结果")

proc newMailer*(config: MailerConfig): Mailer =
  result.config = config

proc formatMailBody(mailer: Mailer,
                    passed, failed, skipped: int;
                    durationSec: float;
                    results: seq[TestResult]): string =
  let timeStr = now().format("yyyy-MM-dd HH:mm")
  let total = passed + failed + skipped
  result.add mailer.config.subjectPrefix & " - " & timeStr & "\n\n"
  result.add "通过: " & $passed & "  失败: " & $failed & "  跳过: " & $skipped &
             "  耗时: " & formatFloat(durationSec, ffDecimal, 1) & "s\n"
  result.add "总计: " & $total & " 个用例\n\n"
  if failed > 0:
    result.add "失败用例:\n"
    var idx = 1
    for r in results:
      if r.status == "FAIL":
        result.add $idx & ". [" & r.desc & "] " & r.diff & "\n"
        idx += 1
  else:
    result.add "全部通过，无失败用例。\n"

proc sendTestReport*(mailer: Mailer;
                     passed, failed, skipped: int;
                     durationSec: float;
                     results: seq[TestResult]) =
  if not mailer.config.enabled:
    gLogger.info("邮件通知未启用")
    return
  if mailer.config.fromAddr.len == 0 or mailer.config.toAddrs.len == 0 or
     mailer.config.authPass.len == 0:
    gLogger.warn("邮件配置不完整，跳过发送")
    return

  let subject = mailer.config.subjectPrefix & " - " & now().format("yyyy-MM-dd HH:mm")
  let body = mailer.formatMailBody(passed, failed, skipped, durationSec, results)
  let msg = createMessage(subject, body, mailer.config.fromAddr, mailer.config.toAddrs)

  gLogger.info("正在发送测试结果邮件",
    {"to": mailer.config.toAddrs.join(", "), "subject": subject}.toTable)

  var client = newSmtp(useSsl = mailer.config.useSsl)
  client.connect(mailer.config.smtpHost, Port(mailer.config.smtpPort))
  client.auth(mailer.config.authUser, mailer.config.authPass)
  client.sendMail(mailer.config.fromAddr, mailer.config.toAddrs, $msg)
  client.close()

  gLogger.info("测试结果邮件已发送")
