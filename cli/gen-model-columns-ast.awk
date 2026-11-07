# Reads one `spinel --dump-ast` output and prints the model facts the
# emitter needs, one tab-separated line:
#
#   <path> <declared class> <table> <datetime override> <date override> <json columns> <defined readers>
#
# Empty lists print as "-". A file without a Sqlx::Base model prints nothing
# and exits 0; anything the reader cannot represent fails with exit 2.
#
# Every lookup goes through node ids, never dump order: spinel revs order the
# dump differently (one prints attributes before children, the next after),
# while the id graph is the same.
#
# Invoked by cli/gen-model-columns.sh; POSIX awk only.

function fail(message) {
  if (probe) exit 0
  printf "[gen-model-columns] %s: %s\n", path, message > "/dev/stderr"
  failed = 1
  exit 2
}

# The first child of a statements node is the value of an endless def body.
function first_statement(statements,    n, parts) {
  if (!(statements in type)) return ""
  n = split(array[statements, "body"], parts, ",")
  return n >= 1 ? parts[1] : ""
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

function join_name(prefix, name) {
  return prefix == "" ? name : prefix "::" name
}

# The model's enclosing module scopes, outermost first. A model declared
# inside a class is refused: the generated file reopens each scope as a
# module, and a class cannot be reopened that way.
function enclosing_namespace(id,    out, up, scope) {
  out = ""
  up = parent[id]
  while (up != "") {
    if (type[up] == "ClassNode") {
      scope = resolve_const(reference[up, "constant_path"])
      fail("a model declared inside class " (scope == "" ? "?" : scope) \
           " is not supported — declare the model inside modules")
    }
    if (type[up] == "ModuleNode") {
      scope = resolve_const(reference[up, "constant_path"])
      if (scope == "") fail("unreadable module constant path")
      out = out == "" ? scope : scope "::" out
    }
    up = parent[up]
  }
  return out
}

function model_name(id,    path, parts, n, i, namespace) {
  path = resolve_const(reference[id, "constant_path"])
  if (path == "") fail("unreadable class constant path")
  n = split(path, parts, "::")
  namespace = enclosing_namespace(id)
  for (i = 1; i < n; i++) namespace = join_name(namespace, parts[i])
  return join_name(namespace, parts[n])
}

function literal_string(id) {
  return type[id] == "StringNode" ? string[id, "content"] : ""
}

function literal_string_list(id,    n, parts, i, out) {
  if (!(id in type) || type[id] != "ArrayNode") return ""
  n = split(array[id, "elements"], parts, ",")
  out = ""
  for (i = 1; i <= n; i++) {
    if (parts[i] == "") continue
    if (type[parts[i]] != "StringNode") return ""
    out = out (out == "" ? "" : " ") string[parts[i], "content"]
  }
  return out
}

# Collect the declarations the generator reads. A model keeps them in its own
# body or inside `class << self`; no other shape is accepted, so a stray
# declaration cannot look like a fact it is not.
function scan_body(body,    n, parts, i, node, name, value) {
  if (body == "" || !(body in type)) return
  n = split(array[body, "body"], parts, ",")
  for (i = 1; i <= n; i++) {
    node = parts[i]
    if (node == "") continue
    if (type[node] == "DefNode") {
      name = string[node, "name"]
      readers = readers == "" ? name : readers " " name
      if (name == "table_name") {
        value = literal_string(first_statement(reference[node, "body"]))
        if (value == "") fail("table_name must be a literal string on the def")
        if (table != "" && table != value) fail("conflicting table_name declarations")
        table = value
      } else if (name == "datetime_columns") {
        datetime_override = 1
      } else if (name == "date_columns") {
        date_override = 1
      } else if (name == "json_columns") {
        value = literal_string_list(first_statement(reference[node, "body"]))
        if (value == "" && !has_empty_array(reference[node, "body"]))
          fail("json_columns must be a literal string array (%w[...] or [])")
        if (json != "" && json != value) fail("conflicting json_columns declarations")
        json = value
      }
    } else if (type[node] == "SingletonClassNode") {
      scan_body(reference[node, "body"])
    }
  }
}

# `def self.json_columns = []` — an empty literal array, and nothing else.
function has_empty_array(statements,    value) {
  value = first_statement(statements)
  return type[value] == "ArrayNode" && array[value, "elements"] == ""
}

# A model class created at runtime carries no `class` line, so the schema walk
# would never see it — a silent miss today. It fails here instead.
function dynamic_model(id,    receiver, arguments, node) {
  if (type[id] != "CallNode") return 0
  if (string[id, "name"] != "new") return 0
  receiver = resolve_const(reference[id, "receiver"])
  if (receiver != "Class") return 0
  node = first_argument(reference[id, "arguments"])
  return resolve_const(node) == "Sqlx::Base"
}

function first_argument(arguments,    n, parts) {
  if (!(arguments in type) || type[arguments] != "ArgumentsNode") return ""
  n = split(array[arguments, "arguments"], parts, ",")
  return n >= 1 ? parts[1] : ""
}

/^SOURCE_FILE / { path = substr($0, 13); next }
/^N / { type[$2] = $3; next }
/^R / {
  if ($4 != "" && $4 + 0 > 0) parent[$4] = $2
  reference[$2, $3] = $4
  next
}
/^A / {
  n = split($4, parts, ",")
  for (k = 1; k <= n; k++) if (parts[k] != "") parent[parts[k]] = $2
  array[$2, $3] = $4
  next
}
/^S / {
  value = $0
  sub(/^S [^ ]+ [^ ]+ /, "", value)
  string[$2, $3] = value
  next
}
/^I / { next }

END {
  if (failed) exit 2
  models = 0
  for (id in type) {
    if (dynamic_model(id)) fail("a Sqlx::Base model created with Class.new cannot carry generated columns — declare a class")
    if (type[id] != "ClassNode") continue
    if (resolve_const(reference[id, "superclass"]) != "Sqlx::Base") continue
    models++
    name = model_name(id)
    table = ""; datetime_override = 0; date_override = 0; json = ""; readers = ""
    scan_body(reference[id, "body"])
    if (table == "") fail("model " name " must declare a literal table_name")
    if (readers == "") readers = "-"
    if (json == "") json = "-"
    printf "%s\t%s\t%s\t%d\t%d\t%s\t%s\n", path, name, table, datetime_override, date_override, json, readers
  }
  if (models > 1) fail("more than one Sqlx::Base model in one file — one model per file")
  if (models == 0) exit 0
  if (probe && models > 0) exit 0
}
