#!/bin/bash
# Regression test for the schema-derived column generator
# (cli/gen-model-columns.sh; bin/snails gen-model-columns).
#
# Column metadata is generated automatically for every Sqlx::Base model under
# app/models. The cases pin the schema grammar it accepts, the type-to-rbs
# mapping, model discovery (subfolders; the declared class name is the
# authority), override exclusion, and every clear refusal — a silently
# dropped column would surface only as a missing API field.
#
# Usage: bash scripts/test-gen-model-columns.sh
# Exit: 0=all cases pass, 1=failure.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
G="$ROOT/cli/gen-model-columns.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK" || exit 1

# The model parser is the pinned spinel (`spinel --dump-ast`), not a regex
# over Ruby text: one pins file at the work root serves every case app, and
# the toolchain resolver materializes that rev from the cache or PATH once.
spinel_rev="$(awk -F'"' '/^SPINEL_REV=/ { print $2 }' "$ROOT/pins.toml")"
if [[ ! $spinel_rev =~ ^[0-9a-f]{4,40}$ ]]; then
  echo "cannot read SPINEL_REV from $ROOT/pins.toml" >&2
  exit 1
fi
printf 'SPINEL_REV="%s"\n' "$spinel_rev" >"$WORK/pins.toml"

pass=0
fail=0
chk() {
  if [[ $2 == "$3" ]]; then
    pass=$((pass + 1))
    echo "ok: $1"
  else
    fail=$((fail + 1))
    echo "FAIL: $1 (exit=$2 want $3)"
  fi
}

mk_app() {
  # mk_app <dir> — an app tree with the database configuration the shared resolver
  # marks an app root by, gen/, db/, and app/.
  rm -rf "$1"
  mkdir -p "$1/config" "$1/gen" "$1/db" "$1/app/models"
  printf 'require_relative "../snails-core/database/sqlite"\n' > "$1/config/database.rb"
}

# The canonical schema every case copies: tables plus an inline view —
# the single-file schema dump shape `migrate dump` writes. The view must
# never reach the generated column output.
cat > canonical.sql <<'SQL'
-- a comment outside quotes
DROP TABLE IF EXISTS "widgets" CASCADE;
CREATE TABLE "widgets" (
  "id" BIGSERIAL PRIMARY KEY,
  "label" TEXT NOT NULL,
  "amount_cents" INTEGER DEFAULT 0 NOT NULL,
  "active" BOOLEAN DEFAULT TRUE NOT NULL,
  "metadata" JSONB,
  "created_at" TIMESTAMP NOT NULL,
  "updated_at" TIMESTAMP NOT NULL,
  CONSTRAINT "widgets_label_key" UNIQUE ("label")
);
CREATE TABLE "other" ("id" INTEGER PRIMARY KEY, "note" TEXT);
CREATE VIEW active_widgets AS SELECT "id", "label" FROM "widgets" WHERE "active";
SQL

cat > widget.rb <<'RB'
class Widget < Sqlx::Base
  def self.table_name = "widgets"

  def label
    read_attribute(:label).strip
  end
end
RB

# 1. Generate a canonical app; the model is discovered without a marker,
#    the domain reader is excluded, and the type map reaches the rbs.
mk_app app
cp canonical.sql app/db/schema.sql
cp widget.rb app/app/models/widget.rb
bash "$G" app >/dev/null 2>&1
chk "the canonical app generates" $? 0
grep -q 'COLUMNS = %w\[id label amount_cents active metadata created_at updated_at\]' app/gen/model_columns.rb
chk "the schema column order reaches COLUMNS" $? 0
grep -q 'def order_id' app/gen/model_columns.rb 2>/dev/null
chk "a column outside the schema is not invented" $? 1
grep -q 'def label' app/gen/model_columns.rb 2>/dev/null
chk "the domain reader is excluded from the generated module" $? 1
grep -q 'def amount_cents = read_attribute(:amount_cents)' app/gen/model_columns.rb
chk "a plain column gets a literal reader" $? 0
grep -q 'def datetime_columns = %w\[created_at updated_at\]' app/gen/model_columns.rb
chk "timestamp columns are derived" $? 0
grep -q 'def date_columns = \[\]' app/gen/model_columns.rb
chk "a table without DATE yields an empty date_columns" $? 0
grep -q 'def date_columns: () -> Array\[String\]' app/gen/model_columns.rbs
chk "the date declaration reaches the rbs" $? 0
grep -q 'def boolean_columns = %w\[active\]' app/gen/model_columns.rb
chk "boolean columns are derived" $? 0
grep -q 'def json_columns = %w\[metadata\]' app/gen/model_columns.rb
chk "json columns are derived" $? 0
grep -q 'def json_columns: () -> Array\[String\]' app/gen/model_columns.rbs
chk "the json declaration reaches the rbs" $? 0
grep -q 'def integer_columns = %w\[id amount_cents\]' app/gen/model_columns.rb
chk "integer columns are derived" $? 0
grep -q 'def integer_columns: () -> Array\[String\]' app/gen/model_columns.rbs
chk "the integer declaration reaches the rbs" $? 0
grep -q 'attr_reader id: Integer' app/gen/model_columns.rbs
chk "a primary key is non-optional Integer" $? 0
grep -q 'attr_reader metadata: untyped' app/gen/model_columns.rbs
chk "jsonb is untyped" $? 0
grep -q 'attr_reader created_at: Time?' app/gen/model_columns.rbs
chk "a timestamp is Time?" $? 0
grep -q 'extend GeneratedModelColumns::Widget' app/gen/model_columns.rb
chk "the model is attached through extend" $? 0
grep -q 'include GeneratedModelReaders::Widget' app/gen/model_columns.rb
chk "the model is attached through include" $? 0

# 2. Freshness and content-gated write.
bash "$G" app --check >/dev/null 2>&1
chk "--check passes after generation" $? 0
before="$(stat -c %Y app/gen/model_columns.rb 2>/dev/null || stat -f %m app/gen/model_columns.rb)"
sleep 1
bash "$G" app >/dev/null 2>&1
after="$(stat -c %Y app/gen/model_columns.rb 2>/dev/null || stat -f %m app/gen/model_columns.rb)"
chk "an identical run leaves the file untouched" "$before" "$after"

# 3. A schema change makes --check stale; regeneration follows it.
cp canonical.sql app/db/schema.sql
awk '{ sub(/"metadata" JSONB,/, "\"metadata\" JSONB, \"extra\" TEXT,"); print }' \
  app/db/schema.sql > app/db/schema.sql.next
mv app/db/schema.sql.next app/db/schema.sql
bash "$G" app --check >/dev/null 2>&1
chk "a schema change makes --check stale" $? 1
out="$(bash "$G" app 2>&1)"
chk "regeneration succeeds" $? 0
if [[ $out == *"regenerated: gen/model_columns.rb"* ]]; then match=0; else match=1; fi
chk "regeneration reports its purpose" "$match" 0
grep -q 'extra' app/gen/model_columns.rb
chk "the new column reaches the readers" $? 0

# 4. Loud refusals: an unknown type, a missing table_name, and a table
#    outside the schema.
mk_app badtype
cat > badtype/db/schema.sql <<'SQL'
CREATE TABLE "widgets" ("id" BIGSERIAL PRIMARY KEY, "mystery" GEOMETRY);
SQL
cp widget.rb badtype/app/models/widget.rb
out="$(bash "$G" badtype 2>&1)"
chk "an unknown SQL type is refused" $? 2
if [[ $out == *"unsupported type GEOMETRY"* ]]; then match=0; else match=1; fi
chk "the refusal names the type" "$match" 0

mk_app notable
printf 'CREATE TABLE "widgets" ("id" BIGSERIAL PRIMARY KEY);\n' > notable/db/schema.sql
cat > notable/app/models/widget.rb <<'RB'
class Widget < Sqlx::Base
end
RB
out="$(bash "$G" notable 2>&1)"
chk "a model without table_name is refused" $? 2
if [[ $out == *"must declare"* ]]; then match=0; else match=1; fi
chk "the refusal names the missing declaration" "$match" 0

mk_app missing
printf 'CREATE TABLE "widgets" ("id" BIGSERIAL PRIMARY KEY);\n' > missing/db/schema.sql
cat > missing/app/models/widget.rb <<'RB'
class Widget < Sqlx::Base
  def self.table_name = "gadgets"
end
RB
out="$(bash "$G" missing 2>&1)"
chk "a table outside the schema is refused" $? 2
if [[ $out == *"not in db/schema.sql"* ]]; then match=0; else match=1; fi
chk "the refusal names the table contract" "$match" 0

# 5. No Sqlx model leaves header-only output (minimal scaffold state).
mk_app none
cp canonical.sql none/db/schema.sql
bash "$G" none >/dev/null 2>&1
chk "no model still generates" $? 0
grep -q '^module GeneratedModelColumns$' none/gen/model_columns.rb 2>/dev/null
chk "no model emits no model body" $? 1

# 5a. A model outside app/models is reported, not generated — the path
#     under app/models is what names the attach target. A model directly
#     under app/models with a `def self.table_name` declaration still is.
mk_app service
cp canonical.sql service/db/schema.sql
cp widget.rb service/app/models/widget.rb
mkdir -p service/app/services
cat > service/app/services/queue_row.rb <<'RB'
class QueueRow < Sqlx::Base
  def self.table_name = "other"
end
RB
out="$(bash "$G" service 2>&1 >/dev/null)"
chk "a tree with an out-of-scope model still generates" $? 0
if [[ $out == *"ignored 1 Sqlx::Base model(s) outside app/models"* ]]; then match=0; else match=1; fi
chk "the out-of-scope model is reported" "$match" 0
if [[ $out == *"app/services/queue_row.rb"* ]]; then match=0; else match=1; fi
chk "the report names the file" "$match" 0
grep -q 'class Widget' service/gen/model_columns.rb
chk "a model directly under app/models generates" $? 0
grep -q 'class QueueRow' service/gen/model_columns.rb 2>/dev/null
chk "the out-of-scope model is not attached" $? 1

mk_app hidden
cp canonical.sql hidden/db/schema.sql
cat > hidden/app/models/hidden.rb <<'RB'
class Hidden < Sqlx::Base
  class << self
    def table_name = "other"
  end
end
RB
bash "$G" hidden >/dev/null 2>&1
chk "a class << self table_name generates" $? 0
grep -q 'class Hidden' hidden/gen/model_columns.rb
chk "the class << self model is attached" $? 0

# 5b. DATETIME (the sqlite scaffold adapter) is a time column.
mk_app sqlite
cat > sqlite/db/schema.sql <<'SQL'
CREATE TABLE "widgets" ("id" INTEGER PRIMARY KEY, "seen_at" DATETIME NOT NULL);
SQL
cat > sqlite/app/models/widget.rb <<'RB'
class Widget < Sqlx::Base
  def self.table_name = "widgets"
end
RB
bash "$G" sqlite >/dev/null 2>&1
chk "DATETIME generates" $? 0
grep -q 'attr_reader seen_at: Time?' sqlite/gen/model_columns.rbs
chk "DATETIME maps to Time?" $? 0
grep -q 'def integer_columns = %w\[id\]' sqlite/gen/model_columns.rb
chk "sqlite INTEGER columns are derived" $? 0

# 5c. A project without a schema or a model is a no-op (the boot chain's
#     seed placeholder stays intact); a model without a schema is refused.
mk_app noschema
bash "$G" noschema >/dev/null 2>&1
chk "a project without a schema is a no-op" $? 0
[[ -f noschema/gen/model_columns.rb ]]
chk "the no-schema path does not create a generated file" $? 1

mk_app modelschema
cat > modelschema/app/models/widget.rb <<'RB'
class Widget < Sqlx::Base
  def self.table_name = "widgets"
end
RB
out="$(bash "$G" modelschema 2>&1)"
chk "a model without a schema is refused" $? 2
if [[ $out == *"no schema file"* ]]; then match=0; else match=1; fi
chk "the refusal names the missing schema" "$match" 0
if [[ $out == *"snails migrate dump"* ]]; then repair=0; else repair=1; fi
chk "the refusal names the dump repair" "$repair" 0

# 5d. A model that owns datetime_columns keeps its reader types; the
#     generated rbs must not seed a conflicting Time? declaration.
mk_app rawtime
cd rawtime
cat > db/schema.sql <<'SQL'
CREATE TABLE "widgets" ("id" BIGSERIAL PRIMARY KEY, "created_at" TIMESTAMP NOT NULL);
SQL
cat > app/models/widget.rb <<'RB'
class Widget < Sqlx::Base
  def self.table_name = "widgets"
  def self.datetime_columns = []
end
RB
cd "$WORK" || exit 1
bash "$G" rawtime >/dev/null 2>&1
chk "a datetime_columns override generates" $? 0
grep -q 'def created_at = read_attribute(:created_at)' rawtime/gen/model_columns.rb
chk "the reader is still generated" $? 0
grep -q 'attr_reader created_at' rawtime/gen/model_columns.rbs 2>/dev/null
chk "the rbs leaves the type to the model" $? 1

# 5e. A writer-only column still gets its reader (the writer must not be
#     mistaken for a reader override).
mk_app writer
cat > writer/db/schema.sql <<'SQL'
CREATE TABLE "widgets" ("id" BIGSERIAL PRIMARY KEY, "note" TEXT);
SQL
cat > writer/app/models/widget.rb <<'RB'
class Widget < Sqlx::Base
  def self.table_name = "widgets"

  def note=(value)
    @attrs[:note] = value
  end
end
RB
bash "$G" writer >/dev/null 2>&1
chk "a writer-only column generates" $? 0
grep -q 'def note = read_attribute(:note)' writer/gen/model_columns.rb
chk "the writer does not suppress the reader" $? 0

# 5f. A namespaced model is attached where the app declared it: the
#     directories between app/models and the file are the modules the class
#     sits in, and the generated file reopens them.
mk_app nested
cat > nested/db/schema.sql <<'SQL'
CREATE TABLE "widgets" ("id" BIGSERIAL PRIMARY KEY, "note" TEXT NOT NULL, "seen_at" TIMESTAMP);
SQL
mkdir -p nested/app/models/snails/admin
cat > nested/app/models/snails/admin/queue_row.rb <<'RB'
module Snails
  module Admin
    class QueueRow < Sqlx::Base
      def self.table_name = "widgets"
    end
  end
end
RB
bash "$G" nested >/dev/null 2>&1
chk "a namespaced model generates" $? 0
grep -q '^module GeneratedModelColumns$' nested/gen/model_columns.rb
chk "the generated module keeps its root" $? 0
grep -q '^    module Admin$' nested/gen/model_columns.rb
chk "the namespace nests inside the generated module" $? 0
grep -q '^module Snails$' nested/gen/model_columns.rb
chk "the attach reopens the outer namespace" $? 0
grep -q '^    class QueueRow$' nested/gen/model_columns.rb
chk "the attach reopens the model class inside it" $? 0
grep -q '^      COLUMNS = GeneratedModelColumns::Snails::Admin::QueueRow::COLUMNS$' nested/gen/model_columns.rb
chk "the constant reference carries the full name" $? 0
grep -q 'extend GeneratedModelColumns::Snails::Admin::QueueRow' nested/gen/model_columns.rb
chk "the namespaced model is extended" $? 0
grep -q '^        attr_reader seen_at: Time?$' nested/gen/model_columns.rbs
chk "the rbs seeds the namespaced readers" $? 0
bash "$G" nested --check >/dev/null 2>&1
chk "--check passes after a namespaced generation" $? 0

# 5g. A compact `Namespace::Model` declaration resolves the same way.
mk_app compact
cat > compact/db/schema.sql <<'SQL'
CREATE TABLE "widgets" ("id" INTEGER PRIMARY KEY, "note" TEXT);
SQL
mkdir -p compact/app/models/snails
cat > compact/app/models/snails/queue_row.rb <<'RB'
class Snails::QueueRow < Sqlx::Base
  def self.table_name = "widgets"
end
RB
bash "$G" compact >/dev/null 2>&1
chk "a compact namespaced declaration generates" $? 0
grep -q '^  class QueueRow$' compact/gen/model_columns.rb
chk "the compact declaration attaches inside its namespace" $? 0
grep -q 'extend GeneratedModelColumns::Snails::QueueRow' compact/gen/model_columns.rb
chk "the compact declaration gets the full name" $? 0

# 5h. The declared class name is the authority — the folder is a layout
#     choice, not part of the name (the AST reads the declaration, so the
#     folder no longer has to encode it).
mk_app mismatch
cat > mismatch/db/schema.sql <<'SQL'
CREATE TABLE "widgets" ("id" INTEGER PRIMARY KEY, "note" TEXT);
SQL
mkdir -p mismatch/app/models/snails
cat > mismatch/app/models/snails/queue_row.rb <<'RB'
module Wrong
  class QueueRow < Sqlx::Base
    def self.table_name = "widgets"
  end
end
RB
bash "$G" mismatch >/dev/null 2>&1
chk "a declared namespace wins over the folder" $? 0
grep -q '^module Wrong$' mismatch/gen/model_columns.rb
chk "the declared namespace is reopened" $? 0
grep -q 'extend GeneratedModelColumns::Wrong::QueueRow' mismatch/gen/model_columns.rb
chk "the attach uses the declared name" $? 0

mk_app unnamespaced
cat > unnamespaced/db/schema.sql <<'SQL'
CREATE TABLE "widgets" ("id" INTEGER PRIMARY KEY, "note" TEXT);
SQL
mkdir -p unnamespaced/app/models/snails
cat > unnamespaced/app/models/snails/queue_row.rb <<'RB'
class QueueRow < Sqlx::Base
  def self.table_name = "widgets"
end
RB
bash "$G" unnamespaced >/dev/null 2>&1
chk "a top-level model inside a namespace folder generates" $? 0
grep -q 'extend GeneratedModelColumns::QueueRow' unnamespaced/gen/model_columns.rb
chk "the attach stays at the top level" $? 0

# 5i. Two files declaring one class would emit the same attach modules
#     twice, and a model inside a class cannot be reopened as a module.
mk_app duplicate
cat > duplicate/db/schema.sql <<'SQL'
CREATE TABLE "widgets" ("id" INTEGER PRIMARY KEY);
CREATE TABLE "other" ("id" INTEGER PRIMARY KEY);
SQL
mkdir -p duplicate/app/models/a duplicate/app/models/b
cat > duplicate/app/models/a/widget.rb <<'RB'
class Widget < Sqlx::Base
  def self.table_name = "widgets"
end
RB
cat > duplicate/app/models/b/widget.rb <<'RB'
class Widget < Sqlx::Base
  def self.table_name = "other"
end
RB
out="$(bash "$G" duplicate 2>&1)"
chk "two files declaring one model are refused" $? 2
if [[ $out == *"already declared in"* ]]; then match=0; else match=1; fi
chk "the refusal names the earlier file" "$match" 0

mk_app classscope
cat > classscope/db/schema.sql <<'SQL'
CREATE TABLE "widgets" ("id" INTEGER PRIMARY KEY);
SQL
mkdir -p classscope/app/models/outer
cat > classscope/app/models/outer/widget.rb <<'RB'
class Outer
  class Widget < Sqlx::Base
    def self.table_name = "widgets"
  end
end
RB
out="$(bash "$G" classscope 2>&1)"
chk "a model declared inside a class is refused" $? 2
if [[ $out == *"inside class Outer"* ]]; then match=0; else match=1; fi
chk "the refusal names the class scope" "$match" 0

# 5i. A module that closes above the model does not leak into its name.
mk_app closed
cat > closed/db/schema.sql <<'SQL'
CREATE TABLE "widgets" ("id" INTEGER PRIMARY KEY, "note" TEXT);
SQL
cat > closed/app/models/widget.rb <<'RB'
module Snails
end

class Widget < Sqlx::Base
  def self.table_name = "widgets"
end
RB
bash "$G" closed >/dev/null 2>&1
chk "a model under a closed module generates" $? 0
grep -q '^class Widget$' closed/gen/model_columns.rb
chk "the closed module is not part of the model name" $? 0

# 5j. A model that declares json columns the DDL type does not carry
#     (an existing TEXT column stores JSON) owns the reader type — the
#     seed must not claim the storage String, and a declaration the
#     generator cannot read is refused instead of misparsed.
mk_app jsondecl
cat > jsondecl/db/schema.sql <<'SQL'
CREATE TABLE "widgets" ("id" INTEGER PRIMARY KEY, "note" TEXT, "extra" TEXT);
SQL
cat > jsondecl/app/models/widget.rb <<'RB'
class Widget < Sqlx::Base
  def self.table_name = "widgets"
  def self.json_columns = %w[note]
end
RB
bash "$G" jsondecl >/dev/null 2>&1
chk "a model json_columns declaration generates" $? 0
grep -q 'def json_columns = \[\]' jsondecl/gen/model_columns.rb
chk "the DDL-derived list stays the schema's answer" $? 0
grep -q 'attr_reader note: untyped' jsondecl/gen/model_columns.rbs
chk "the declared json reader seeds untyped" $? 0
grep -q 'attr_reader note: String' jsondecl/gen/model_columns.rbs 2>/dev/null
chk "the storage String type is not claimed" $? 1
grep -q 'attr_reader extra: String?' jsondecl/gen/model_columns.rbs
chk "an undeclared neighbor keeps its type" $? 0

cat > jsondecl/app/models/widget.rb <<'RB'
class Widget < Sqlx::Base
  def self.table_name = "widgets"
  def self.json_columns = JSON_COLS
end
RB
out="$(bash "$G" jsondecl 2>&1)"
chk "an unreadable json_columns declaration is refused" $? 2
if [[ $out == *"literal string array"* ]]; then match=0; else match=1; fi
chk "the refusal names the readable form" "$match" 0

# 5k. Ruby is read by the pinned spinel's parser, not by line regexes: a
#     heredoc or a block comment that looks like a model is not one, and a
#     declaration spelled across lines still is.
mk_app heredoc
cat > heredoc/db/schema.sql <<'SQL'
CREATE TABLE "widgets" ("id" INTEGER PRIMARY KEY);
CREATE TABLE "ghost" ("id" INTEGER PRIMARY KEY);
SQL
cat > heredoc/app/models/widget.rb <<'RB'
class Widget < Sqlx::Base
  def self.table_name = "widgets"

  SQL_DOC = <<~DOC
    class Ghost < Sqlx::Base
      def self.table_name = "ghost"
    end
  DOC
end
RB
bash "$G" heredoc >/dev/null 2>&1
chk "a heredoc that spells a model still generates" $? 0
grep -q 'class Ghost' heredoc/gen/model_columns.rb 2>/dev/null
chk "the heredoc body is not a model" $? 1

mk_app doccomment
cat > doccomment/db/schema.sql <<'SQL'
CREATE TABLE "widgets" ("id" INTEGER PRIMARY KEY);
CREATE TABLE "ghost" ("id" INTEGER PRIMARY KEY);
SQL
cat > doccomment/app/models/widget.rb <<'RB'
class Widget < Sqlx::Base
  def self.table_name = "widgets"
end

=begin
class Ghost < Sqlx::Base
  def self.table_name = "ghost"
end
=end
RB
bash "$G" doccomment >/dev/null 2>&1
chk "a block comment that spells a model still generates" $? 0
grep -q 'class Ghost' doccomment/gen/model_columns.rb 2>/dev/null
chk "the block comment body is not a model" $? 1

mk_app spelled
cat > spelled/db/schema.sql <<'SQL'
CREATE TABLE "widgets" ("id" INTEGER PRIMARY KEY, "note" TEXT);
SQL
cat > spelled/app/models/widget.rb <<'RB'
class Widget < Sqlx::Base
  def self.table_name
    "widgets"
  end

  def self.json_columns = %w(note)
end
RB
bash "$G" spelled >/dev/null 2>&1
chk "a multi-line table_name and a %w() list generate" $? 0
grep -q '^class Widget$' spelled/gen/model_columns.rb
chk "the multi-line declaration reaches the attach" $? 0
grep -q 'attr_reader note: untyped' spelled/gen/model_columns.rbs
chk "the %w() json declaration seeds untyped" $? 0

# 5l. Shapes the AST cannot represent fail instead of disappearing: a model
#     created with Class.new has no class line to attach columns to, and a
#     model file that does not parse is a structural error.
mk_app dynamic
printf 'CREATE TABLE "widgets" ("id" INTEGER PRIMARY KEY);\n' > dynamic/db/schema.sql
cat > dynamic/app/models/widget.rb <<'RB'
Widget = Class.new(Sqlx::Base)
Widget.table_name = "widgets"
RB
out="$(bash "$G" dynamic 2>&1)"
chk "a Class.new model is refused" $? 2
if [[ $out == *"Class.new"* ]]; then match=0; else match=1; fi
chk "the refusal names the dynamic declaration" "$match" 0

mk_app broken
printf 'CREATE TABLE "widgets" ("id" INTEGER PRIMARY KEY);\n' > broken/db/schema.sql
cat > broken/app/models/widget.rb <<'RB'
class Widget < Sqlx::Base
  def self.table_name = "widgets"
RB
out="$(bash "$G" broken 2>&1)"
chk "an unparseable model file is refused" $? 2
if [[ $out == *"could not parse"* ]]; then match=0; else match=1; fi
chk "the refusal names the broken parse" "$match" 0

# 5m. The parser is the pinned toolchain: without a pins file above the app
#     the generator cannot know which spinel reads the models.
nopin_root="$(mktemp -d)"
mkdir -p "$nopin_root/config" "$nopin_root/gen" "$nopin_root/db" "$nopin_root/app/models"
printf 'require_relative "../snails-core/database/sqlite"\n' >"$nopin_root/config/database.rb"
printf 'CREATE TABLE "widgets" ("id" INTEGER PRIMARY KEY);\n' >"$nopin_root/db/schema.sql"
printf 'class Widget < Sqlx::Base\n  def self.table_name = "widgets"\nend\n' >"$nopin_root/app/models/widget.rb"
out="$(bash "$G" "$nopin_root" 2>&1)"
chk "a tree without a pins file is refused" $? 2
if [[ $out == *"no pins file"* ]]; then match=0; else match=1; fi
chk "the refusal names the missing pin" "$match" 0
rm -rf "$nopin_root"

# 5n. A DATE column is a civil date, not a time: the stored text is 10
#     characters, so the reader is Date? and the column joins date_columns
#     (never datetime_columns). The generator also loads the opt-in date
#     codec — only a tree with a DATE column pays for it.
mk_app datecol
cat > datecol/db/schema.sql <<'SQL'
CREATE TABLE "events" ("id" INTEGER PRIMARY KEY, "happens_on" DATE NOT NULL, "issued_on" DATE, "seen_at" DATETIME);
SQL
cat > datecol/app/models/event.rb <<'RB'
class Event < Sqlx::Base
  def self.table_name = "events"
end
RB
bash "$G" datecol >/dev/null 2>&1
chk "DATE generates" $? 0
grep -q 'COLUMNS = %w\[id happens_on issued_on seen_at\]' datecol/gen/model_columns.rb
chk "DATE columns stay projected" $? 0
grep -q 'attr_reader happens_on: Date$' datecol/gen/model_columns.rbs
chk "a NOT NULL DATE maps to Date" $? 0
grep -q 'attr_reader issued_on: Date?$' datecol/gen/model_columns.rbs
chk "a nullable DATE maps to Date?" $? 0
grep -q 'def date_columns = %w\[happens_on issued_on\]' datecol/gen/model_columns.rb
chk "DATE columns land in date_columns" $? 0
grep -q 'def datetime_columns = %w\[seen_at\]' datecol/gen/model_columns.rb
chk "DATE stays out of datetime_columns" $? 0
grep -q 'require_relative "../snails-core/ext/date"' datecol/gen/model_columns.rb
chk "a DATE tree loads the date codec" $? 0
grep -q 'snails-core/ext/date' app/gen/model_columns.rb 2>/dev/null
chk "a tree without DATE does not load the date codec" $? 1

# 5o. A model that owns date_columns keeps its reader types; the generated
#     rbs must not seed a conflicting Date? declaration.
mk_app rawdate
cat > rawdate/db/schema.sql <<'SQL'
CREATE TABLE "events" ("id" INTEGER PRIMARY KEY, "happens_on" DATE NOT NULL);
SQL
cat > rawdate/app/models/event.rb <<'RB'
class Event < Sqlx::Base
  def self.table_name = "events"
  def self.date_columns = []
end
RB
bash "$G" rawdate >/dev/null 2>&1
chk "a date_columns override generates" $? 0
grep -q 'def happens_on = read_attribute(:happens_on)' rawdate/gen/model_columns.rb
chk "the DATE reader is still generated" $? 0
grep -q 'attr_reader happens_on' rawdate/gen/model_columns.rbs 2>/dev/null
chk "the rbs leaves the DATE type to the model" $? 1

# 6. A non-Sqlx class is not a model, even if it declares a table name.
mk_app nonmodel
cp canonical.sql nonmodel/db/schema.sql
cat > nonmodel/app/models/widget.rb <<'RB'
class Widget < ActionController::API
  def self.table_name = "widgets"
end
RB
bash "$G" nonmodel >/dev/null 2>&1
chk "a non-Sqlx class is ignored" $? 0
grep -q 'class Widget' nonmodel/gen/model_columns.rb 2>/dev/null
chk "the non-Sqlx class is not attached" $? 1

# 7. The engine does not need ruby. A failing ruby shim on PATH must not
#    change the result.
mkdir -p shim
cat > shim/ruby <<'SH'
#!/bin/bash
echo "ruby must not be called" >&2
exit 99
SH
chmod +x shim/ruby
mk_app norb
cp canonical.sql norb/db/schema.sql
cp widget.rb norb/app/models/widget.rb
PATH="$WORK/shim:$PATH" bash "$G" norb >/dev/null 2>&1
chk "the generator does not call ruby" $? 0

printf '%s passed, %s failed\n' "$pass" "$fail"
[[ $fail == 0 ]]
