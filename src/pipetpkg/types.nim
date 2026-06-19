import std/[httpclient, json, tables]

type
  StreamAssert* = object
    kind*: string
    pattern*: string
    maxWaitMs*: int
    minChunks*: int

  TestCase* = object
    id*: string
    desc*: string
    httpMethod*: string
    url*: string
    headers*: Table[string, string]
    payload*: string
    params*: string
    form*: string
    json*: string
    body*: string
    expectStatus*: int
    expectBody*: JsonNode
    skip*: bool
    tags*: seq[string]
    extract*: Table[string, string]
    streamMode*: bool
    streamAsserts*: seq[StreamAssert]
    matchMode*: string

  TestResult* = object
    id*: string
    desc*: string
    status*: string
    durationSec*: float
    expectStatus*: int
    actualStatus*: int
    diff*: string
    actualBody*: string
    expectBody*: string
    tags*: string

  HttpClientPool* = ref object
    maxSize*: int
    timeoutMs*: int
    available*: seq[HttpClient]
