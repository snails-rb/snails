# Columns and Types

A model declares its table and nothing else. The columns, their readers, and the lists that drive type conversion are generated from `db/schema.sql` into `gen/model_columns.rb`. Treat that file as build output: edit the schema or the model, never the generated file.

## What the generator writes

For a `posts` table with an id, text columns, timestamps, a boolean flag, a date, and a JSON column, the generated file carries one module per model:

```ruby
module GeneratedModelColumns
  module Post
    COLUMNS = %w[id title body published_on published detail created_at updated_at]
    def only_columns = COLUMNS.map { |c| c.to_sym }
    def datetime_columns = %w[created_at updated_at]
    def date_columns = %w[published_on]
    def boolean_columns = %w[published]
    def json_columns = %w[detail]
  end
end

module GeneratedModelReaders
  module Post
    def id = read_attribute(:id)
    def title = read_attribute(:title)
    def body = read_attribute(:body)
    def published_on = read_attribute(:published_on)
    def published = read_attribute(:published)
    def detail = read_attribute(:detail)
    def created_at = read_attribute(:created_at)
    def updated_at = read_attribute(:updated_at)
  end
end

class Post
  COLUMNS = GeneratedModelColumns::Post::COLUMNS
  extend GeneratedModelColumns::Post
  include GeneratedModelReaders::Post
end
```

`bin/dev` and `bin/test` run the generator before the build, so a schema change or a new model reaches the readers on the next run. `snails gen-model-columns --check` reports a stale pair without writing. A model outside `app/models/` is reported and skipped — move it under `app/models/`.

## What each list converts

The generated lists are the type contract between the database and Ruby:

| Declaration | Column types | Read as | Write input |
|---|---|---|---|
| `only_columns` | every column | raw adapter value for columns in no other list | raw Ruby value |
| `datetime_columns` | `TIMESTAMP`, `DATETIME` | `Time` | `Time` |
| `date_columns` | `DATE` | `Date` | `Date` |
| `boolean_columns` | `BOOL*` | `true` / `false` | `true` / `false` |
| `json_columns` | `JSON`, `JSONB` | decoded Hash/Array/scalar | any JSON value |

A `datetime` column read from SQLite text goes through the stored-time parser and comes back in the app's time zone. A `date` column reads through `String#to_date`; the generator loads the optional date codec only when some model projects a `DATE` column. A boolean is stored as `1`/`0` on SQLite and read back as `true`/`false`. A JSON column is encoded on every write and decoded on every read, so app code hands over a Hash and reads a Hash. A value JSON cannot represent — a `Time`, for example — raises at the write instead of being stringified into the column.

The built-in timestamp pair is special in one way: `create!` and `update!` fill a declared `created_at`/`updated_at` the caller left out. A table without those columns is legal and gets no stamp.

## Readers and overrides

The generated reader is a plain method over `read_attribute`. A model that defines the same method itself wins, and the generator leaves that reader out of both the generated Ruby and the `.rbs`. That is the seam for a derived value:

```ruby
class Post < Sqlx::Base
  def self.table_name = "posts"

  def summary = title.to_s[0, 40]
end
```

A model can replace a declaration when the default is wrong for its table. The list replaces the default wholesale, so spell the whole default again if you keep part of it:

```ruby
class Event < Sqlx::Base
  def self.table_name = "events"
  def self.datetime_columns = %w[created_at updated_at started_at ended_at]
end
```

`from_row` copies every `only_columns` entry and then applies the declared conversions. A conversion naming a column outside `only_columns` raises — only the built-in timestamp pair may be absent. If you hand-write a narrower SELECT, declare the narrowed columns or override `from_row`; leaving the generated lists in place while the SELECT omits a declared date, boolean, JSON, or extra datetime column is the common source of a `ArgumentError` at hydration.

A model that needs more than the five declarations overrides `from_row` outright. It receives one name-keyed row and answers one record:

```ruby
def self.from_row(row)
  new(id: row["id"], title: row["title"], body: row["body"])
end
```

## Enums

An integer column with a fixed set of labels can carry a validated enum declaration. It stores the mapping once and gives the model the read, predicate, and write pieces; it does not generate methods, so the model writes the small members it wants:

```ruby
class Post < Sqlx::Base
  STATUS = enum(draft: 0, published: 1, archived: 2)

  def self.table_name = "posts"

  def status = STATUS.label(read_attribute(:status))
  def published? = STATUS.label?(read_attribute(:status), :published)
  def published! = STATUS.writer(table: "posts", column: "status").write!(id, :published)
end
```

`enum` rejects an empty declaration, a non-Symbol label, a non-Integer value, and a repeated value at load. `label` answers `nil` for an unknown stored value; `value` and the predicate raise for a label the declaration no longer carries. `writer(...).write!` updates the column and `updated_at` in one statement, matching the row by id; the table must carry `updated_at`.

## The `.rbs` sidecar

`gen/model_columns.rbs` is written beside the Ruby file. It gives each generated reader its column type, so the compiler can check a caller against the schema. A model method that overrides a generated reader owns its own type declaration; add it to the model's `.rbs` when the value differs from the column type.

[Querying](10-querying.md) covers the reads and writes these columns feed.
