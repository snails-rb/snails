# Read one `spinel --dump-ast` output for config/routes.rb and print the items
# the path-helper generator needs, one tab-separated line:
#
#   helper    <name> <verb> <default action>
#   call      <helper> <pattern> <controller> <action> <line>
#   route     <verb> <pattern> <controller> <action> <line>
#   resources <pattern> <controller> <only> <line>
#
# "-" marks an empty field. A row the reader cannot represent fails with exit 2
# — the generator never guesses a path.
#
# Rows are the literal array elements of `def self.table`: a verb-helper call,
# a Route.new call, or a resources call (bare or splatted). Anything else —
# a computed path, a method call, a loop — is not statically resolvable and is
# refused. Local helper definitions are learned from their parameters and the
# Route.new call in their body, so an `if` inside one no longer hides it.
#
# Invoked by cli/gen-route-helpers.sh; POSIX awk only.

function fail(message) {
  printf "[gen-route-helpers] config/routes.rb: %s\n", message > "/dev/stderr"
  failed = 1
  exit 2
}

function first_statement(statements,    n, parts) {
  if (!(statements in type)) return ""
  n = split(array[statements, "body"], parts, ",")
  return n >= 1 ? parts[1] : ""
}

function first_argument(arguments,    n, parts) {
  if (!(arguments in type)) return ""
  n = split(array[arguments, "arguments"], parts, ",")
  return n >= 1 ? parts[1] : ""
}

function argument_count(arguments,    n, parts) {
  if (!(arguments in type)) return 0
  n = split(array[arguments, "arguments"], parts, ",")
  if (n == 1 && parts[1] == "") return 0
  return n
}

function argument_at(arguments, position,    n, parts) {
  if (!(arguments in type)) return ""
  n = split(array[arguments, "arguments"], parts, ",")
  return position <= n ? parts[position] : ""
}

function resolve_const(id,    parent) {
  if (!(id in type)) return ""
  if (type[id] == "ConstantReadNode") return string[id, "name"]
  if (type[id] == "ConstantPathNode") {
    parent = reference[id, "parent"]
    if (parent == "" || parent < 0) return string[id, "name"]
    return resolve_const(parent) "::" string[id, "name"]
  }
  return ""
}

function last_segment(path,    n, parts) {
  n = split(path, parts, "::")
  return parts[n]
}

function literal_string(id) {
  return type[id] == "StringNode" ? string[id, "content"] : ""
}

function symbol_value(id) {
  return type[id] == "SymbolNode" ? string[id, "value"] : ""
}

function node_line(id) {
  return integer[id, "node_line"] + 0
}

# The receiver of a call: "" (none), "self", or a resolved constant path.
function receiver_text(id,    receiver) {
  receiver = reference[id, "receiver"]
  if (receiver == "" || receiver < 0) return ""
  if (type[receiver] == "SelfNode") return "self"
  return resolve_const(receiver)
}

function require_string(id, what) {
  if (type[id] != "StringNode") fail(what " must be a literal string")
  return string[id, "content"]
}

function require_const(id, what,    name) {
  name = resolve_const(id)
  if (name == "") fail(what " must be a literal constant (a controller class)")
  return name
}

# The verb of the Route.new a helper body builds. A helper only constructs a
# row, so its body is scanned for that call rather than read line by line.
function route_verb_in(id,    i, verb) {
  if (type[id] == "CallNode" && string[id, "name"] == "new" &&
      last_segment(receiver_text(id)) == "Route") {
    return literal_string(first_argument(reference[id, "arguments"]))
  }
  for (i = 1; i <= kid_count[id]; i++) {
    verb = route_verb_in(kid[id, i])
    if (verb != "") return verb
  }
  return ""
}

# The action default of `def self.x(path, controller, action = :create)`.
function default_action(parameters,    n, parts, i, node) {
  if (!(parameters in type)) return ""
  n = split(array[parameters, "optionals"], parts, ",")
  for (i = 1; i <= n; i++) {
    node = parts[i]
    if (node == "") continue
    if (string[node, "name"] == "action") return symbol_value(reference[node, "value"])
  }
  return ""
}

function learn_helpers(def_id) {
  printf "helper\t%s\t%s\t%s\n", string[def_id, "name"], route_verb_in(reference[def_id, "body"]),
         default_action(reference[def_id, "parameters"])
}

function emit_call(id,    local_args, count) {
  local_args = reference[id, "arguments"]
  count = argument_count(local_args)
  if (count < 2 || count > 3)
    fail("line " node_line(id) ": " string[id, "name"] " takes path, controller, and an optional action")
  if (count == 3 && type[argument_at(local_args, 3)] != "SymbolNode")
    fail("line " node_line(id) ": " string[id, "name"] " action must be a literal symbol")
  printf "call\t%s\t%s\t%s\t%s\t%d\n", string[id, "name"],
         require_string(argument_at(local_args, 1), string[id, "name"] " path"),
         require_const(argument_at(local_args, 2), string[id, "name"] " controller"),
         (count == 3 ? symbol_value(argument_at(local_args, 3)) : "-"),
         node_line(id)
}

function emit_route(id,    local_args) {
  local_args = reference[id, "arguments"]
  if (argument_count(local_args) != 4)
    fail("line " node_line(id) ": Route.new takes verb, path, controller, and action")
  if (type[argument_at(local_args, 4)] != "SymbolNode")
    fail("line " node_line(id) ": Route.new action must be a literal symbol")
  printf "route\t%s\t%s\t%s\t%s\t%d\n",
         require_string(argument_at(local_args, 1), "Route.new verb"),
         require_string(argument_at(local_args, 2), "Route.new path"),
         require_const(argument_at(local_args, 3), "Route.new controller"),
         symbol_value(argument_at(local_args, 4)),
         node_line(id)
}

function emit_resources(id,    local_args, count, only, i, n, parts) {
  local_args = reference[id, "arguments"]
  count = argument_count(local_args)
  if (count < 2 || count > 4)
    fail("line " node_line(id) ": resources takes path, controller, format, and only — a further argument cannot run")
  only = "-"
  if (count == 4) {
    local_only = argument_at(local_args, 4)
    if (type[local_only] == "ArrayNode") {
      n = split(array[local_only, "elements"], parts, ",")
      only = ""
      for (i = 1; i <= n; i++) {
        if (parts[i] == "") continue
        if (type[parts[i]] != "SymbolNode")
          fail("line " node_line(id) ": resources only: must be a literal symbol array")
        only = only (only == "" ? "" : " ") string[parts[i], "value"]
      }
      if (only == "") only = "-"
    } else if (type[local_only] != "NilNode") {
      fail("line " node_line(id) ": resources only: must be a list of symbols or nil")
    }
  }
  printf "resources\t%s\t%s\t%s\t%d\n",
         require_string(argument_at(local_args, 1), "resources path"),
         require_const(argument_at(local_args, 2), "resources controller"),
         only, node_line(id)
}

function table_element(id,    name, receiver, inner) {
  if (type[id] == "SplatNode") {
    inner = reference[id, "expression"]
    if (type[inner] != "CallNode" || string[inner, "name"] != "resources" || receiver_text(inner) != "")
      fail("line " node_line(id) ": a splat in the table must wrap a resources(...) call")
    emit_resources(inner)
    return
  }
  if (type[id] != "CallNode")
    fail("line " node_line(id) ": unsupported table row (" type[id] ") — rows are literal get/post/put/delete, Route.new, or resources calls")
  name = string[id, "name"]
  receiver = receiver_text(id)
  if (name == "resources" && receiver == "") { emit_resources(id); return }
  if (name == "new" && last_segment(receiver) == "Route") { emit_route(id); return }
  if (receiver == "" || receiver == "self") { emit_call(id); return }
  fail("line " node_line(id) ": unsupported table row " receiver "." name " — a row is a literal declaration, not a method call")
}

/^N / { type[$2] = $3; next }
/^I / { integer[$2, $3] = $4; next }
/^R / {
  if ($4 != "" && $4 + 0 > 0) {
    parent[$4] = $2
    kid[$2, ++kid_count[$2]] = $4
  }
  reference[$2, $3] = $4
  next
}
/^A / {
  n = split($4, parts, ",")
  for (k = 1; k <= n; k++) {
    if (parts[k] == "") continue
    parent[parts[k]] = $2
    kid[$2, ++kid_count[$2]] = parts[k]
  }
  array[$2, $3] = $4
  next
}
/^S / {
  value = $0
  sub(/^S [^ ]+ [^ ]+ /, "", value)
  string[$2, $3] = value
  next
}

END {
  if (failed) exit 2

  tables = 0
  for (id in type) {
    if (type[id] != "DefNode") continue
    if (string[id, "name"] != "table") {
      if (receiver_text(id) == "self") learn_helpers(id)
      continue
    }
    if (receiver_text(id) != "self") continue
    tables++
    table_id = id
  }
  if (tables == 0) fail("no `def self.table` — the generator reads the table method's literal array")
  if (tables > 1) fail("more than one `def self.table` — the table has one declaration")

  body = reference[table_id, "body"]
  elements = first_statement(body)
  if (type[elements] != "ArrayNode")
    fail("`def self.table` must return a literal array — a computed table is not supported")
  n = split(array[elements, "elements"], parts, ",")
  for (i = 1; i <= n; i++) {
    if (parts[i] == "") continue
    table_element(parts[i])
  }
}
