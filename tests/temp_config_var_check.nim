import std/tables
import ../src/pipetpkg/config
import ../src/pipetpkg/parsers

let vars = loadConfig("tests/fixtures/config_var_sample.yaml")
let resolved = replaceVars("{{base_url}}/api/users?token={{token}}", vars)
echo resolved
