#! /opt/homebrew/bin/nu

# Swagman
def main [
  --unix-socket(-s) #Set if using a unix socket
  command_name: string #Name of command in you cli, once the output file is sourced, it will be placed into the cli namespace
  api_url: string #URL that will be hit
  api_file: string #Path to open-api spec
  output_file: string #Where file will be stored, default is the script directory. Source this file to use the command
] {
  let connection_info = {
    api_url: $api_url
    api_file: $api_file
    unix_socket: $unix_socket
  }

  mut api_ref_path = $api_file
  if ($api_ref_path | is-empty) {
    $api_ref_path = $env.FILE_PWD + "/v1.47.yaml"
  }

  mut command = $command_name
  if ($command | is-empty) {
    $command = "swagman"
  }

  mut output_path = $output_file
  if ($output_path | is-empty) {
    $output_path = $env.FILE_PWD + $"/($command).nu"
  }

  let spec = (cd $env.FILE_PWD | open $api_ref_path)
  let paths = $spec | get -i paths
  let definitions = $spec | get -i definitions
  process_paths $paths $command $connection_info | save -f $output_path
  $output_path
}

def process_paths [
  paths: record
  command: string
  connection_info: record
] {
  let path_names = $paths | columns
  $path_names |
    filter { |path_name| ($paths | get -i $path_name | is-not-empty) } |
    each { |path_name| process_operators $path_name $paths $command $connection_info } |
    flatten
}

def process_operators [
  path: string
  paths: record
  command: string
  connection_info: record
] {
  let path_info = $paths | get -i $path
  $path_info |
    columns |
    filter { |operator| 'application/json' in ($path_info | get -i $'($operator)' | get -i produces | default []) } |
    each { |operator| generation_defs $operator $path $path_info $command $connection_info } |
    flatten
}

def generation_defs [
  operator: string
  path: string
  path_info: record
  command: string
  connection_info: record
] {
  let operator_info = $path_info | get $operator

  let summary = $operator_info | get -i summary
  let defName = $operator_info | get -i operationId
  let description = $operator_info | get -i description
  let params = $operator_info | get -i parameters | default []
  let unix_socket = if $connection_info.unix_socket {
      ' --unix-socket ' + $connection_info.api_url
    } else {
      ''
    }
  let api_url = if $connection_info.unix_socket {
      'http://lo'
    } else {
      $connection_info.api_url
    }

  let path_params = $params | where in == "path" | get name
  let path_with_vars = $path_params | reduce --fold $path { |param,acc| $acc | str replace $"{($param)}" $"($param | str replace '-' '_')} )" }
  let interpolate_url_path = $path | str replace -a "{" "($" | str replace -a "}" ")"

  let has_body = ($params | where in == "body" | length) > 0
  let body = if $has_body {
    $" -d $'\($body | to json\)' -H \"Content-Type: application/json\""
  } else {
    ''
  }

  let query_params = $params | where in == "query" | get name | each { |param| $"      ($param): $\"\($($param | str replace -a '-' '_')\)\""} | str join "\n"
  let http_query_string = $"{\n($query_params)\n    } | transpose | filter { |row| $row.column1 | is-not-empty } | transpose -r -d | url build-query"

  [
    (comment_out $summary)
    '#'
    (comment_out ($description | default ''))
    $'export def "($command) ($defName | str title-case | str downcase)" ['
    (process_params $params)
    '] {'
    $"  let url_path = $\"($interpolate_url_path)\""
    $"  let url_query_string = ($http_query_string)"
    '  let url_params = if ($url_query_string | is-not-empty) { $"?($url_query_string)" } else { "" }'
    $"  curl --silent -X($operator | str upcase)($unix_socket)($body) $\"($api_url)\($url_path\)\($url_params\)\" | from json"
    '}'
    ''
  ] | flatten
}

def process_params [
  params: list
] {
  let path_params = $params | where in == "path" | update name { |row| $row.name | str replace '-' '_' }
  let body_params = $params | where in == "body" | update name { |row| $row.name | str replace '-' '_' }
  let query_params = $params | where in == "query"

  $query_params |
    append $path_params |
    append $body_params |
    filter { |param| ($param | is-not-empty) } |
    each { |param| process_param $param}
}

def process_param [
  param: record
] {
  let is_body = (($param | get -i in | default '') == 'body')
  let is_path = (($param | get -i in | default '') == 'path')

  let param_type = type_converter ($param | get -i type | default '')
  let param_desc = comment_out ($param | get -i description | default '')
  # TODO: fix if example empty
  let param_example = comment_out ($param | get -i schema | get -i example | to json | default '')
  let param_name = $param | get -i name

  if $is_body {
    $"  body: record ($param_desc)\n#Example:\n($param_example)"
  } else if $is_path {
    $'  ($param.name)($param_type) ($param_desc)'
  } else {
    $'  --($param.name)($param_type) ($param_desc)'
  }
}

def comment_out [
  comment: string
] {
  if ($comment | is-empty) {
    return ''
  }
  $comment | str trim | split row "\n" | each { |line| '#' + $line } | str join "\n" 
}

def type_converter [
  type_name: string
] {
  match $type_name {
    object => ': record'
    integer => ': int'
    number => ': float'
    string => ': string'
    array => ': list'
    _ => ''
  }
}
