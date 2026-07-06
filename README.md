# pipet

一个基于 PSV（Pipe-Separated Values）的轻量级 HTTP 接口测试工具。

## 特性

- 用 PSV 文件定义测试用例，可读、易扩展
- 支持 `GET`、`POST`、`PUT`、`PATCH`、`DELETE`
- 支持 `{{var}}` 变量替换
- 递归 JSON 全响应体断言
- 失败用例输出 PSV 格式报告
- 使用 YAML 单一环境配置变量
- 支持按 `tags` 列过滤执行用例

## 目录结构

```text
pipet/
├── pipet.nimble
├── README.md
├── .gitignore
├── config.nims              # 项目配置（使用 Puppy HTTP 客户端）
├── config.yaml              # 变量配置
├── data/                    # 测试数据文件，如上传文件
├── src/
│   ├── pipet.nim            # 主入口
│   └── pipetpkg/
│       ├── core.nim         # 用例加载、执行、JSON 对比
│       ├── logger.nim       # JSON Lines 日志
│       └── report.nim       # PSV 报告输出
└── tests/
    ├── smoke/
    ├── chain/
    ├── negative/
    ├── stream/            # 流式断言示例
    ├── test_data.psv        # 示例测试数据
    └── test_data2.psv       # 多文件示例
```

## 编译运行

程序使用 Puppy HTTP 客户端，原生支持 HTTPS，无需额外 SSL 配置。程序会优先在 `pipet.exe` 所在目录查找 `config.yaml` 和 `test_data.psv`，方便打包分发。

```bash
# 用 nimble 构建 release 版（输出到 dist/pipet/）
nimble release

# 直接编译
nim c src/pipet.nim

# 运行示例（默认 + tests/test_data.psv）
./pipet.exe

# 指定用例文件
./pipet.exe tests/test_data.psv

# 指定自定义 YAML 配置文件
./pipet.exe --config=prod.yaml tests/test_data.psv

# 按标签过滤执行（多个标签用逗号分隔，满足任一即可）
./pipet.exe --tags=smoke tests/test_data.psv
./pipet.exe --tags=smoke,api tests/test_data.psv
./pipet.exe -t json tests/test_data.psv

# 一次指定多个 PSV 文件
./pipet.exe tests/test_data.psv tests/test_data2.psv

# 指定目录，自动扫描该目录下所有 .psv 文件
./pipet.exe tests
```

## 打包分发

使用 `nimble package` 一键打包，它会自动构建 release 版 `pipet.exe`，并把运行所需的文件集中复制到 `dist/pipet/`：

```bash
nimble package
```

生成的可分发目录结构：

```text
dist/pipet/
├── pipet.exe
├── config.yaml
├── README.md
├── data/
└── tests/
    ├── test_data.psv
    └── test_data2.psv
```

直接复制 `dist/pipet/` 到其他电脑即可运行：

```bash
# 默认执行 tests/test_data.psv
./pipet.exe

# 扫描整个 tests 目录
./pipet.exe tests
```

程序会优先在 `pipet.exe` 所在目录查找 `config.yaml` 和 `test_data.psv`。

## YAML 配置

配置文件只支持 YAML，根节点为变量键值对，不再有多个环境层级。

`config.yaml` 示例：

```yaml
base_url: https://httpbin.org
token: my-token
log_level: info
timeout: 30000
pool_size: 1
retry_count: 0
retry_delay_ms: 0
report_timezone: local
```

- `timeout`：HTTP 请求超时时间（毫秒，默认 30000）
- `pool_size`：HTTP 客户端连接池大小（默认 1）
- `retry_count`：请求失败后的重试次数（默认 0）
- `retry_delay_ms`：每次重试前的等待时间（毫秒，默认 0）
- `report_timezone`：报告文件名时间戳时区，支持 `local`（本地时间，默认）、`utc` 或固定偏移（如 `+0800`、`-0500`）

`log_level` 支持 `debug`、`info`、`warn`、`error`，不区分大小写。程序运行时的诊断日志会以 JSON Lines 格式同时输出到 **stderr** 和 **`logs/`** 目录下的 `pipet_YYYYMMDD_HHMMSS.log` 文件。

运行时指定配置文件：

```bash
# 默认查找当前目录 / exe 同级目录的 config.yaml
./pipet.exe tests/test_data.psv

# 指定配置文件
./pipet.exe --config=prod.yaml tests/test_data.psv
```

## 测试用例格式

```psv
id|skip|desc|method|url|headers|params|form|json|body|expected_status|expected_body|tags|extract|stream_mode|stream_assert
```

- `stream_mode` 为 `1` 时启用 SSE 流式断言分支（默认不启用）
- `stream_assert` 为流式断言规则 JSON 数组，每个元素包含 `kind`、`pattern`、`max_wait_ms`、`min_chunks`
  - `kind` 可选 `contains`（聚合内容包含子串）、`regex`（聚合内容匹配正则）、`json_path`（当前 SSE 节点存在指定 JSON 路径）
  - `pattern` 为断言内容，支持 `{{var}}` 变量替换
  - `max_wait_ms` 为最大等待时间（毫秒，目前作为保留字段，后续支持实时流可据此提前结束）
  - `min_chunks` 为断言通过所需的最少 SSE chunk 数
- `match_mode` 控制响应体匹配方式，可选 `exact`（默认，严格全量匹配）或 `subset`（子集匹配）
- `expected_body` 中字段值写成 `{{not_exists}}` 表示该字段必须不存在；写成 `{{skip}}` 表示跳过该字段对比
- 流式用例的 `expected_body` 不再断言原始响应 JSON，而是断言最终聚合对象：`{"aggregated_content": "...", "chunk_count": N}`
- `expected_body` 为期望的完整 JSON 响应体
- 字段值写成 `{{regex:...}}` 表示用正则表达式断言该字段，例如 `{"origin":"{{regex:^[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}$}}"}`
- 所有列支持 `{{var}}` 变量替换
- `tags` 为标签列表，多个标签用逗号分隔，用于 `--tags` 过滤
- 列按需加载：每个 PSV 文件可以只包含自己需要的列，不存在的列留空或省略表头即可；`json`、`form`、`body` 等空列表示不发送该类型请求体
- 入参类型按优先级自动选择：
  - `params`：URL 查询参数，如 `foo=bar&baz=1`，自动拼接到 URL
  - `form`：自动以 `multipart/form-data` 发送；字段值以 `@` 或 `file://` 开头时作为文件字段上传，例如 `name=demo&upload=@data/sample.txt`
  - `json`：自动以 `application/json` 发送
  - `body`：原始请求体，配合 `headers` 中的 `Content-Type` 使用
  - `payload`：兼容旧列，作为无类型原始 body
  - 优先级：`form`（含文件字段）> `json` > `form`（纯文本）> `body` > `payload`

## 严格全量匹配

默认使用 `exact`（严格全量匹配）：响应 JSON 必须与 `expected_body` 字段一一对应、不允许额外字段。如果只想检查响应包含 `expected_body` 中的字段且值一致，将 `match_mode` 设为 `subset`。

```psv
id|skip|desc|method|url|headers|params|form|json|body|expected_status|expected_body|tags|match_mode
strict_01|0|严格匹配 IP|GET|{{base_url}}/ip|{}||||||200|{"origin":"{{regex:^[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}$}}"}|strict|
```

在 `expected_body` 中使用 `{{not_exists}}` 可以断言某个字段必须不存在（在 `subset` 和 `exact` 模式下均生效）：

```psv
id|skip|desc|method|url|headers|params|form|json|body|expected_status|expected_body|tags|match_mode
strict_02|0|不允许返回敏感字段|GET|{{base_url}}/get|{}||||||200|{"args":{},"password":"{{not_exists}}"}|strict|exact
```

## 流式断言

当后端返回 SSE（Server-Sent Events）流时，可在 PSV 中开启 `stream_mode` 并定义 `stream_assert` 规则。程序会按行解析 `data: {...}`，提取 OpenAI 风格的 `choices[0].delta.content`，实时检查断言。

```psv
id|skip|desc|method|url|headers|params|form|json|body|expected_status|expected_body|tags|extract|stream_mode|stream_assert
stream_01|0|SSE 流式断言示例|POST|{{base_url}}/chat/completions|{"Content-Type":"application/json"}|||{"model":"gpt-4","messages":[{"role":"user","content":"hi"}],"stream":true}||200|{"aggregated_content":"{{regex:.*hi.*}}","chunk_count":"{{skip}}"}|stream||1|[{"kind":"contains","pattern":"hi","min_chunks":1}]
```

- 命中任意 `stream_assert` 规则时立即返回 PASS
- 若未命中，则在流结束后用 `expected_body` 断言 `{"aggregated_content": "...", "chunk_count": N}`

## 标签过滤

用例文件中的 `tags` 列可以填写一个或多个标签。运行时使用 `--tags`（或 `-t`）指定要执行哪些标签，程序会执行包含任一指定标签的用例。

```bash
# 只执行标签为 smoke 的用例
./pipet.exe --tags=smoke tests/test_data.psv

# 执行标签为 smoke 或 api 的用例
./pipet.exe --tags=smoke,api tests/test_data.psv

# 不指定 --tags 时执行所有用例
./pipet.exe tests/test_data.psv
```
## 多 PSV 文件

命令行支持传入多个 PSV 文件路径，也可以传入一个目录，程序会自动扫描该目录下所有 `.psv` 文件。所有用例会合并到一次执行并生成一份报告。

```bash
# 一次执行多个 PSV 文件
./pipet.exe tests/test_data.psv tests/test_data2.psv

# 扫描整个目录
./pipet.exe tests

# 多文件 + 标签过滤
./pipet.exe tests --tags=smoke
```

## 示例输出

```text
╔══════════════════════════════════════════════════════╗
║              pipet 接口测试                          ║
╚══════════════════════════════════════════════════════╝

  [1] 获取IP ... PASS (1.022s)
  ...

PSV 报告已保存: reports/report_20260619_081222.psv
异常用例 PSV 报告已保存: reports/report_20260619_081222_error.psv
```

每次运行后会在当前目录创建 `reports/` 文件夹，里面同时生成全量报告和异常用例报告（仅当存在失败用例时）。

## 运行测试

```bash
nimble test
```