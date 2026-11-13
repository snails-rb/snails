# Querying

`Sqlx` models are class-level table objects: every read and write is a class method, conditions are plain hashes, and a missing row is an exception rather than a `nil` you discover three calls later. There is no relation object and no query builder — the method names below are the whole surface.

## Conditions

A conditions hash has one form per kind of question. The same rules apply to every read and write that takes conditions.

```ruby
Post.find_by({ title: "hello" })                  # equality
Post.find_by({ deleted_at: nil })                 # IS NULL
Post.find_by({ status: ["draft", "published"] })  # IN (...)
Post.find_by({ created_at: { lt: cutoff } })      # <
Post.find_by({ created_at: { gte: from, lt: to } })  # a range is two keys
Post.find_by({ deleted_at: { is_not: nil } })     # IS NOT NULL
```

The comparison operators are `lt`, `lte`, `gt`, and `gte`. The only null operator is `is_not: nil`; there is no general negation and no `eq`. A comparison bound cannot be nil, an operator hash cannot be empty, and an `IN` list cannot be empty or carry nil. Those conditions raise `ArgumentError` instead of producing SQL that quietly matches nothing. Values are escaped; keys are code, so a typo in a column name fails at the database instead of reading as a miss.

A String value on a column declared in `integer_columns` is cast to an Integer before it binds. A decimal value such as `"42"` becomes `42`; `"1-welcome"` and `"abc"` raise `Sqlx::CastError` instead of binding as text. A TEXT or UUID primary key is not in the list, so it stays an exact string lookup.

An empty hash is a broken condition, not "all rows". `find_by({})` refuses, and the bulk entries accept `nil` when you mean the whole table. `count` and `exists?` are the exception: their empty form is a well-defined "any row?" question.

## Reads

```ruby
Post.find(42)                        # by id; RecordNotFound when absent
Post.find_by({ title: "hello" })     # one row, or nil
Post.find_by!({ title: "hello" })    # one row, or RecordNotFound
Post.count                           # whole table
Post.count({ status: "draft" })      # matching rows
Post.exists?                         # any row?
Post.exists?({ status: "draft" })    # conditions
Post.exists?(42)                     # id shorthand
```

`find_by` takes `order:` to decide which of several matches it returns: `:desc` picks the highest `id`, `:asc` the lowest. An empty condition hash is allowed with `order:` — `find_by({}, order: :desc)` is the table's last row.

`fetch_many` is the multi-row read. Pass `nil` for the whole table.

```ruby
Post.fetch_many({ status: "draft" }, order: :desc)
Post.fetch_many(nil, order: :desc, limit: 20)
Post.fetch_many({ status: "draft" }, order: :desc, limit: 20, offset: 40)
```

`order:` sorts by `id`, not by an arbitrary column; a read that needs another order writes its own SQL. `limit:` says "at most N rows". `offset:` is for a numbered page and requires both `limit:` and `order:` — an offset without a sort can repeat or skip rows while writes land.

## Walk a large table

A full-table walk uses keyset pagination, not an offset page. Each batch asks for the rows after the last id it saw, so a static table is visited exactly once.

```ruby
Post.find_each(nil, batch_size: 500) { |post| ... }
Post.find_in_batches({ status: "draft" }, batch_size: 500) do |posts|
  Post.update_all!({ id: posts.map { |post| post.id } }, { status: "published" })
end
```

`find_each` yields one record at a time; `find_in_batches` yields the batch so one bulk statement covers it. A `break` in the block stops the walk. The `id` column is the cursor, so a model whose `only_columns` omits `id` cannot use either entry. The walk is not a snapshot: a row inserted with a higher id during the walk may be seen.

## Writes

```ruby
post = Post.create!({ title: "hello", body: "world" })
Post.update!(post.id, { title: "revised" })
Post.update_all!({ status: "draft" }, { status: "published" })
Post.delete!(post.id)
Post.delete_all!({ post_id: post.id })
Post.upsert_all!([{ slug: "a", title: "A" }, { slug: "b", title: "B" }], unique_by: [ :slug ])
```

`create!` returns the stored row and fills a declared `created_at`/`updated_at` the caller left out. `update!` returns the re-read row, fills `updated_at`, and raises `RecordNotFound` when the id does not exist — an unknown id can never become a silent insert. `delete!` returns the deleted-row count; an unknown id is `0`, because the caller's lookup already decides whether that is a 404.

`update_all!` and `delete_all!` take `nil` conditions to mean the whole table. They return the number of rows changed. They do not stamp `updated_at`; pass it when the batch should move it. `upsert_all!` inserts rows and rewrites the row a conflict collides with; `unique_by:` names the columns of the conflict target, every row must carry the same keys, and every `unique_by` column must be one of them. At least one column outside `unique_by` must remain to update, or the entry raises instead of turning into a skip-duplicates insert. The return is the number of rows inserted or rewritten.

`create!` and the bulk writes accept `nil` values (SQL NULL) and `Time` values (stored as UTC). A declared JSON column accepts the logical value and encodes it for you.

## Transactions

Wrap a unit that must commit or disappear together:

```ruby
Sqlx::Base.transaction do
  post = Post.create!({ title: "parent", body: "..." })
  Comment.create!({ post_id: post.id, body: "..." })
end
```

The block runs between `BEGIN` and `COMMIT`; any exception rolls back and re-raises. Transactions are flat — a nested `BEGIN` fails rather than joining the outer unit. `Sqlx::Busy` and `ConnectionFailed` mean the unit did not commit, so retry the whole unit, never one statement inside it.

## Raw SQL

The model methods cover the common queries; a join, a view, or an aggregate writes its own statement. Values enter by binding, never by string interpolation:

```ruby
Post.find_by_sql("SELECT " + Post.projection + " FROM posts WHERE author_id = ?", [ author_id ])
Post.rows_by_sql("SELECT status, COUNT(*) AS total FROM posts GROUP BY status")
Post.row_by_sql("SELECT id, title FROM posts WHERE id = ?", [ 42 ])
Post.write("UPDATE posts SET title = ? WHERE id = ? RETURNING id", [ "revised", 42 ])
```

`find_by_sql` hydrates each row through the model's `from_row`. `rows_by_sql` and `row_by_sql` return name-keyed hashes with the adapter's native values. `write` returns the rows the statement returned — empty when it returned none; read `Sqlx::Database.exec_write(...)["count"]` when the row count is the answer.

`Post.projection` is the model's quoted column list, so a raw SELECT and the inherited reads share one spelling. Use `Sqlx.quote(value)` only for code-built SQL, and never for a value that arrived from a request.

## Dialect differences

`Sqlx.adapter_name` answers `"SQLite"` or `"PostgreSQL"`. Branch when the SQL genuinely differs; do not branch to compensate for a value, because the adapter renders values by their Ruby type already. A boolean condition, for example, is `1` on SQLite and `'1'` on PostgreSQL without the app spelling either.

[Columns and Types](11-columns-and-types.md) covers what the generated model readers convert on the way in and out.
