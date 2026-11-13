# Emit model column readers and constants from db/schema.sql and the model
# facts the shell collected from the pinned spinel's AST dump.
#
# spinel AOT unrolls `define_method` only for a literal array in a class
# body, so a generic Sqlx::Base cannot create per-model readers from a
# constant. This generator is the compile-time layer: it reads the schema,
# emits literal reader methods and the COLUMNS constant, and attaches them to
# every Sqlx::Base model under app/models/.
#
# This file never reads Ruby text — gen-model-columns-ast.awk turns the
# spinel AST into one fact line per model, and the shell passes that file
# here. The declared class name is the authority: the file's folder is a
# layout choice, so `class Snails::QueueJob` in app/models/queue_job.rb is
# attached as Snails::QueueJob. What the generator insists on is uniqueness
# (one class, one table) and module scopes only — the attach reopens each
# enclosing scope as a module.
#
# Invoked by cli/gen-model-columns.sh; POSIX awk only.

function die(message) {
  printf "[gen-model-columns] %s\n", message > "/dev/stderr"
  exit 2
}

function trim(value) {
  sub(/^[ \t\r\n]+/, "", value)
  sub(/[ \t\r\n]+$/, "", value)
  return value
}

# ---------------------------------------------------------------- schema ---

function read_schema(path,    line) {
  schema_line_count = 0
  while ((getline line < path) > 0) {
    schema_line[++schema_line_count] = line
  }
  close(path)
}

# Join the file, dropping `--` comments outside single-quoted strings.
function join_schema(    i, j, line, out, in_single, ch) {
  schema_sql = ""
  in_single = 0
  for (i = 1; i <= schema_line_count; i++) {
    line = schema_line[i]
    out = ""
    for (j = 1; j <= length(line); j++) {
      ch = substr(line, j, 1)
      if (ch == "'") {
        if (in_single && substr(line, j + 1, 1) == "'") {
          out = out "''"
          j++
          continue
        }
        in_single = !in_single
        out = out ch
        continue
      }
      if (!in_single && ch == "-" && substr(line, j + 1, 1) == "-") break
      out = out ch
    }
    schema_sql = schema_sql out "\n"
  }
}

function split_schema(    i, ch, in_single, statement) {
  statement = ""
  in_single = 0
  for (i = 1; i <= length(schema_sql); i++) {
    ch = substr(schema_sql, i, 1)
    if (ch == "'") {
      if (in_single && substr(schema_sql, i + 1, 1) == "'") {
        statement = statement "''"
        i++
        continue
      }
      in_single = !in_single
    }
    if (ch == ";" && !in_single) {
      parse_statement(statement)
      statement = ""
      continue
    }
    statement = statement ch
  }
  if (trim(statement) != "") {
    die("db/schema.sql: statement without a terminating semicolon: " substr(trim(statement), 1, 60))
  }
}

function parse_statement(statement,    s, rest, table, quoted_rest) {
  s = trim(statement)
  if (s !~ /^[Cc][Rr][Ee][Aa][Tt][Ee][ \t]+[Tt][Aa][Bb][Ll][Ee]([ \t]|$)/) return

  match(s, /^[ \t]*[Cc][Rr][Ee][Aa][Tt][Ee][ \t]+[Tt][Aa][Bb][Ll][Ee][ \t]+/)
  rest = substr(s, RSTART + RLENGTH)
  sub(/^[ \t]*[Ii][Ff][ \t]+[Nn][Oo][Tt][ \t]+[Ee][Xx][Ii][Ss][Tt][Ss][ \t]+/, "", rest)

  if (substr(rest, 1, 1) == "\"") {
    quoted_rest = substr(rest, 2)
    table = substr(quoted_rest, 1, index(quoted_rest, "\"") - 1)
    if (table == "") die("db/schema.sql: empty table name")
    rest = substr(quoted_rest, length(table) + 2)
  } else {
    if (!match(rest, /^[A-Za-z_][A-Za-z0-9_]*/)) {
      die("db/schema.sql: unreadable table name near: " substr(rest, 1, 60))
    }
    table = substr(rest, RSTART, RLENGTH)
    rest = substr(rest, RLENGTH + 1)
  }
  sub(/^[ \t\r\n]+/, "", rest)
  if (substr(rest, 1, 1) != "(") {
    die("db/schema.sql: CREATE TABLE " table " has no column list")
  }
  if (!split_parenthesized(rest)) {
    die("db/schema.sql: unbalanced column list for table " table)
  }
  if (trim(split_trailing) != "") {
    die("db/schema.sql: unsupported CREATE TABLE clause for " table ": " substr(trim(split_trailing), 1, 40))
  }
  if (table in schema_table) die("db/schema.sql: duplicate CREATE TABLE " table)
  schema_table[table] = 1
  parse_table_body(table, split_body)
}

# Read the leading `(...)` into split_body / split_trailing.
function split_parenthesized(text,    i, ch, depth, in_single, in_double) {
  split_body = ""
  split_trailing = ""
  depth = 0
  in_single = 0
  in_double = 0
  for (i = 1; i <= length(text); i++) {
    ch = substr(text, i, 1)
    if (in_single) {
      if (ch == "'") {
        if (substr(text, i + 1, 1) == "'") { i++; continue }
        in_single = 0
      }
      if (depth >= 1) split_body = split_body ch
      continue
    }
    if (in_double) {
      if (ch == "\"") in_double = 0
      if (depth >= 1) split_body = split_body ch
      continue
    }
    if (ch == "'") { in_single = 1; if (depth >= 1) split_body = split_body ch; continue }
    if (ch == "\"") { in_double = 1; if (depth >= 1) split_body = split_body ch; continue }
    if (ch == "(") {
      depth++
      if (depth == 1) continue
    } else if (ch == ")") {
      depth--
      if (depth == 0) {
        split_trailing = substr(text, i + 1)
        return 1
      }
      if (depth < 0) return 0
    }
    if (depth >= 1) split_body = split_body ch
  }
  return 0
}

function parse_table_body(table, body,    i, ch, item, depth, in_single, in_double) {
  item = ""
  depth = 0
  in_single = 0
  in_double = 0
  for (i = 1; i <= length(body); i++) {
    ch = substr(body, i, 1)
    if (in_single) {
      item = item ch
      if (ch == "'") {
        if (substr(body, i + 1, 1) == "'") { item = item "'"; i++; continue }
        in_single = 0
      }
      continue
    }
    if (in_double) {
      item = item ch
      if (ch == "\"") in_double = 0
      continue
    }
    if (ch == "'") { in_single = 1; item = item ch; continue }
    if (ch == "\"") { in_double = 1; item = item ch; continue }
    if (ch == "(") { depth++; item = item ch; continue }
    if (ch == ")") { depth--; item = item ch; continue }
    if (ch == "," && depth == 0) {
      parse_column_item(table, item)
      item = ""
      continue
    }
    item = item ch
  }
  parse_column_item(table, item)
}

function parse_column_item(table, item,    s, name, rest, up, cut, candidates, count, i, type, notnull, key, pos) {
  s = trim(item)
  if (s == "") return

  if (substr(s, 1, 1) == "\"") {
    if (index(substr(s, 2), "\"") == 0) die("db/schema.sql: unreadable column in " table ": " s)
    name = substr(s, 2, index(substr(s, 2), "\"") - 1)
    rest = substr(s, length(name) + 3)
  } else {
    if (!match(s, /^[A-Za-z_][A-Za-z0-9_]*/)) {
      die("db/schema.sql: unreadable column in " table ": " s)
    }
    name = substr(s, RSTART, RLENGTH)
    rest = substr(s, RLENGTH + 1)
  }
  rest = trim(rest)
  up = toupper(rest)

  key = toupper(name)
  if (key == "PRIMARY" || key == "UNIQUE" || key == "CONSTRAINT" ||
      key == "FOREIGN" || key == "CHECK" || key == "EXCLUDE") return

  candidates = " NOT NULL| DEFAULT| PRIMARY| REFERENCES| UNIQUE| CHECK| COLLATE| GENERATED| CONSTRAINT| DEFERRABLE| INITIALLY"
  count = split(candidates, candidate, "|")
  cut = 0
  for (i = 1; i <= count; i++) {
    if (candidate[i] == "") continue
    pos = index(up, candidate[i])
    if (pos > 0 && (cut == 0 || pos < cut)) cut = pos
  }
  if (cut > 0) type = substr(rest, 1, cut - 1)
  else type = rest
  type = toupper(trim(type))
  gsub(/[ \t\r\n]+/, " ", type)
  if (type == "") die("db/schema.sql: column " table "." name " has no type")

  notnull = (up ~ /(^|[ \t])NOT[ \t]+NULL([ \t]|$)/)
  if (up ~ /(^|[ \t])PRIMARY[ \t]+KEY([ \t]|$)/) notnull = 1
  if (type ~ /^BIGSERIAL$/ || type ~ /^SERIAL$/) notnull = 1

  if ((table, name) in column_index) {
    die("db/schema.sql: duplicate column " table "." name)
  }
  column_count[table]++
  column_index[table, name] = column_count[table]
  column_name[table, column_count[table]] = name
  column_type[table, column_count[table]] = type
  column_notnull[table, column_count[table]] = notnull
}

# ---------------------------------------------------------------- models ---

# One line per model, tab separated, from gen-model-columns-ast.awk:
#   <path> <declared class> <table> <datetime override> <date override> <json columns> <readers>
# "-" marks an empty list. The declared name is the authority — the file's
# folder is a layout choice, not part of the name. What must stay unique is
# the class (two files attaching to one class would emit the same modules
# twice) and the table (two models cannot share one schema entry).
function read_model_facts(facts,    line, count, field, i, class_name,
                          reader_count, reader, col_count, col) {
  while ((getline line < facts) > 0) {
    if (line == "") continue
    count = split(line, field, "\t")
    if (count != 7) die("internal: unreadable model fact: " line)
    class_name = field[2]
    if (class_name in model_file) {
      die(field[1] ": model " class_name " is already declared in " model_file[class_name])
    }
    if (!(field[3] in column_count)) die(field[1] ": table " field[3] " is not in db/schema.sql")
    if (field[3] in model_for_table) {
      die(field[1] ": table " field[3] " is already generated for " model_for_table[field[3]])
    }

    model_file[class_name] = field[1]
    model_for_table[field[3]] = class_name
    model_table[class_name] = field[3]
    model_datetime_override[class_name] = (field[4] == 1)
    model_date_override[class_name] = (field[5] == 1)
    if (field[6] != "-") {
      col_count = split(field[6], col, " ")
      for (i = 1; i <= col_count; i++)
        if (col[i] != "") model_json_declared[class_name SUBSEP col[i]] = 1
    }
    # A method the model defines itself wins over the generated reader, so
    # the generated module and rbs leave that name to the model.
    reader_count = split(field[7], reader, " ")
    for (i = 1; i <= reader_count; i++)
      if (reader[i] != "" && reader[i] != "-") override[class_name, reader[i]] = 1

    model_count++
    model_order[model_count] = class_name
  }
  close(facts)
}

# -------------------------------------------------------------- emission ---

function indent_of(depth,    out) {
  out = ""
  while (length(out) < depth * 2) out = out " "
  return out
}

# `root` is the shared namespace the generated modules live under; every
# segment of the model name opens one more level inside it.
function emit_wrapper(out, root, full_name,    count, part, i) {
  print indent_of(0) "module " root > out
  count = split(full_name, part, "::")
  for (i = 1; i <= count; i++) print indent_of(i) "module " part[i] > out
}

function emit_wrapper_end(out, full_name,    count, part, i) {
  count = split(full_name, part, "::")
  for (i = count; i >= 1; i--) print indent_of(i) "end" > out
  print indent_of(0) "end" > out
  # the blank line that separates this block from the next
  print "" > out
}

function column_is_datetime(table, i,    type) {
  type = column_type[table, i]
  # DATE stays out: the stored text is 10 characters, which String#to_time
  # reads as nil — a DATE column is converted through the date codec
  # (`String#to_date`) instead.
  return type ~ /TIMESTAMP/ || type ~ /^DATETIME$/
}

function column_is_date(table, i,    type) {
  type = column_type[table, i]
  return type ~ /^DATE$/
}

function column_is_boolean(table, i,    type) {
  type = column_type[table, i]
  return type ~ /^BOOL/
}

function column_is_json(table, i,    type) {
  type = column_type[table, i]
  return type ~ /JSON/
}

function column_is_integer(table, i,    type) {
  type = column_type[table, i]
  return type ~ /BIGSERIAL|SERIAL|BIGINT|INTEGER|SMALLINT/
}

function rbs_type(table, i,    type, base) {
  type = column_type[table, i]
  if (type ~ /JSON/) return "untyped"
  if (column_is_datetime(table, i)) return "Time?"
  if (column_is_boolean(table, i)) base = "bool"
  else if (column_is_date(table, i)) base = "Date"
  else if (type ~ /BIGSERIAL|SERIAL|BIGINT|INTEGER|SMALLINT/) base = "Integer"
  else if (type ~ /TEXT|VARCHAR|CHARACTER|^CHAR$/) base = "String"
  else if (type ~ /DOUBLE|REAL|NUMERIC|DECIMAL/) base = "Float"
  else if (type ~ /^UUID$/) base = "String"
  else die("db/schema.sql: unsupported type " type " for " table "." column_name[table, i])
  if (column_notnull[table, i]) return base
  return base "?"
}

function list_literal(table, predicate,    out, i, first, value) {
  out = ""
  first = 1
  for (i = 1; i <= column_count[table]; i++) {
    if (predicate == "datetime" && !column_is_datetime(table, i)) continue
    if (predicate == "date" && !column_is_date(table, i)) continue
    if (predicate == "boolean" && !column_is_boolean(table, i)) continue
    if (predicate == "json" && !column_is_json(table, i)) continue
    if (predicate == "integer" && !column_is_integer(table, i)) continue
    value = column_name[table, i]
    if (first) { out = value; first = 0 }
    else out = out " " value
  }
  return out
}

function list_word(table, predicate,    list) {
  list = list_literal(table, predicate)
  if (list == "") return "[]"
  return "%w[" list "]"
}

# Whether any generated model projects a DATE column. The date package is
# opt-in: an app with no DATE column must not pay its build and binary cost,
# so the generated file requires the date codec only when this answers 1.
function any_model_has_date(    m, table, i) {
  for (m = 1; m <= model_count; m++) {
    table = model_table[model_order[m]]
    for (i = 1; i <= column_count[table]; i++)
      if (column_is_date(table, i)) return 1
  }
  return 0
}

function emit_rb(class_name,    table, i, col, count, part, module_body, attach_body) {
  table = model_table[class_name]
  count = split(class_name, part, "::")
  module_body = indent_of(count + 1)
  attach_body = indent_of(count)

  emit_wrapper(out_rb, "GeneratedModelColumns", class_name)
  print module_body "COLUMNS = " list_word(table, "all") > out_rb
  print module_body "def only_columns = COLUMNS.map { |c| c.to_sym }" > out_rb
  print module_body "def datetime_columns = " list_word(table, "datetime") > out_rb
  print module_body "def date_columns = " list_word(table, "date") > out_rb
  print module_body "def boolean_columns = " list_word(table, "boolean") > out_rb
  print module_body "def json_columns = " list_word(table, "json") > out_rb
  print module_body "def integer_columns = " list_word(table, "integer") > out_rb
  emit_wrapper_end(out_rb, class_name)

  emit_wrapper(out_rb, "GeneratedModelReaders", class_name)
  for (i = 1; i <= column_count[table]; i++) {
    col = column_name[table, i]
    if ((class_name, col) in override) continue
    print module_body "def " col " = read_attribute(:" col ")" > out_rb
  }
  emit_wrapper_end(out_rb, class_name)

  # Reopen the model where the app declared it: the enclosing namespaces as
  # modules, then the model class itself.
  for (i = 1; i < count; i++) print indent_of(i - 1) "module " part[i] > out_rb
  print indent_of(count - 1) "class " part[count] > out_rb
  print attach_body "COLUMNS = GeneratedModelColumns::" class_name "::COLUMNS" > out_rb
  print attach_body "extend GeneratedModelColumns::" class_name > out_rb
  print attach_body "include GeneratedModelReaders::" class_name > out_rb
  for (i = count - 1; i >= 0; i--) print indent_of(i) "end" > out_rb
  print "" > out_rb
}

function emit_rbs(class_name,    table, i, col, count, part, module_body, attach_body) {
  table = model_table[class_name]
  count = split(class_name, part, "::")
  module_body = indent_of(count + 1)
  attach_body = indent_of(count)

  emit_wrapper(out_rbs, "GeneratedModelColumns", class_name)
  print module_body "COLUMNS: Array[String]" > out_rbs
  print module_body "def only_columns: () -> Array[Symbol]" > out_rbs
  print module_body "def datetime_columns: () -> Array[String]" > out_rbs
  print module_body "def date_columns: () -> Array[String]" > out_rbs
  print module_body "def boolean_columns: () -> Array[String]" > out_rbs
  print module_body "def json_columns: () -> Array[String]" > out_rbs
  print module_body "def integer_columns: () -> Array[String]" > out_rbs
  emit_wrapper_end(out_rbs, class_name)

  emit_wrapper(out_rbs, "GeneratedModelReaders", class_name)
  for (i = 1; i <= column_count[table]; i++) {
    col = column_name[table, i]
    if ((class_name, col) in override) continue
    # A model that declares the column json owns its reader type: the
    # value arrives decoded (a Hash), so the DDL-derived seed (String
    # for a TEXT column) would lie. JSON-typed columns already seed
    # untyped through rbs_type.
    if ((class_name, col) in model_json_declared) {
      print module_body "attr_reader " col ": untyped" > out_rbs
      continue
    }
    # A model that overrides datetime_columns owns those reader types
    # (the scaffold keeps timestamps as stored TEXT); do not seed a
    # conflicting Time? declaration here. date_columns follows the same
    # rule (a model that keeps DATE as stored text owns the reader type).
    if (model_datetime_override[class_name] && column_is_datetime(table, i)) continue
    if (model_date_override[class_name] && column_is_date(table, i)) continue
    print module_body "attr_reader " col ": " rbs_type(table, i) > out_rbs
  }
  emit_wrapper_end(out_rbs, class_name)

  for (i = 1; i < count; i++) print indent_of(i - 1) "module " part[i] > out_rbs
  print indent_of(count - 1) "class " part[count] > out_rbs
  print attach_body "COLUMNS: Array[String]" > out_rbs
  print attach_body "extend GeneratedModelColumns::" class_name > out_rbs
  print attach_body "include GeneratedModelReaders::" class_name > out_rbs
  for (i = count - 1; i >= 0; i--) print indent_of(i) "end" > out_rbs
  print "" > out_rbs
}

BEGIN {
  if (schema == "" || facts == "" || out_rb == "" || out_rbs == "" || vendor_dir == "") {
    die("internal: schema, model facts, output paths, and vendor_dir are required")
  }
  read_schema(schema)
  join_schema()
  split_schema()
  read_model_facts(facts)

  print "# Generated by `snails gen-model-columns` from db/schema.sql — do not edit." > out_rb
  print "# Column readers and COLUMNS for every Sqlx::Base model under app/models/." > out_rb
  if (any_model_has_date()) {
    print "# DATE columns read as Date — load the optional date codec." > out_rb
    print "require_relative \"../" vendor_dir "/ext/date\"" > out_rb
  }
  print "" > out_rb
  print "# Generated by `snails gen-model-columns` from db/schema.sql — do not edit." > out_rbs
  print "# Column readers and COLUMNS for every Sqlx::Base model under app/models/." > out_rbs
  print "" > out_rbs

  for (m = 1; m <= model_count; m++) {
    emit_rb(model_order[m])
    emit_rbs(model_order[m])
  }

  close(out_rb)
  close(out_rbs)
}
