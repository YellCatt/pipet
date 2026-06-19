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
├── config.nims              # 默认启用 SSL 的项目配置
├── config.yaml              # 变量配置
├── src/
│   ├── pipet.nim            # 主入口
│   └── pipetpkg/
    │       ├── core.nim         # 用例加载、执行、JSON 对比
    │       ├── logger.nim       # JSON Lines 日志
    │       └── report.nim       # PSV 报告输出
└── tests/
    ├── test_config.yaml     # 测试用 YAML 配置
    ├── test_data.psv        # 示例测试数据
    ├── test_data2.psv       # 多文件示例
    └── test_pipet.nim       # 单元测试
```

## 编译运行

`config.nims` 已默认启用 SSL，构建时无需再传 `-d:ssl`。程序会优先在 `pipet.exe` 所在目录查找 `config.yaml` 和 `test_data.psv`，方便打包分发。

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
```

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
id|skip|desc|method|url|headers|params|form|json|body|expected_status|expected_body|tags
```

- `skip` 为 `1` 时跳过该用例
- `expected_body` 为期望的完整 JSON 响应体
- 字段值写成 `{{skip}}` 表示跳过该字段对比
- 字段值写成 `{{regex:...}}` 表示用正则表达式断言该字段，例如 `{"origin":"{{regex:^[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}$}}"}}`
- 所有列支持 `{{var}}` 变量替换
- `tags` 为标签列表，多个标签用逗号分隔，用于 `--tags` 过滤
- 列按需加载：每个 PSV 文件可以只包含自己需要的列，不存在的列留空或省略表头即可
- 入参类型按优先级 `json` > `form` > `body` > `payload` 自动选择：
  - `params`：URL 查询参数，如 `foo=bar&baz=1`，自动拼接到 URL
  - `form`：自动以 `application/x-www-form-urlencoded` 发送
  - `json`：自动以 `application/json` 发送
  - `body`：原始请求体，配合 `headers` 中的 `Content-Type` 使用
  - `payload`：兼容旧列，作为无类型原始 body

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
