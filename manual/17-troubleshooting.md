# Troubleshooting

When something is off, start with the symptom — each one below is a real error and the fix that unblocks it.

### `could not create schema_migrations` when applying migrations

`snails migrate apply` fails on a brand-new project because the database folder does not exist yet:

```text
Error: unable to open database ".../storage/development.sqlite3": unable to open database file
[snails] could not create schema_migrations
```

Start `bin/dev` once (it creates `storage/` and the database) or create the folder, then run the migration again. `snails doctor` calls this out as a warning before you hit it.

### A route row will not parse

`spinel could not parse it — Parse errors in 'config/routes.rb'` with `expected a ',' separator` means the rows in the route list have no commas — a newline is not a separator:

```ruby
[
  get("/up", Snails::HealthController, :show),
  get("/posts", Api::PostsController, :index),   # commas between rows
]
```

### `:name is derived from more than one pattern`

Two hand-written rows want the same helper name (`/posts` and `/posts/:id` both derive `posts`). Give one row its own name with a `# as:` marker:

```ruby
get("/posts", Api::PostsController, :index),
get("/posts/:id", Api::PostsController, :show), # as: post
```

### A model's class methods are refused at build time

If the compiler refuses `create!` or `find_by` on your model with `unsupported call`, the model file is not being loaded. Keep the model under `app/models/` and check that `gen/models.rb` carries the `# scan: models/**/*` spec — an empty region there never loads a model, so add the line and run `bin/test` once so the list regenerates with your file in it.

### A parameter comes back nil

`params` is a hash keyed by strings — `params[:id]` is always nil, so the value never reaches your JSON. Use `params["id"]`.

### The test runner disagrees with your memory of a file

`bin/test` diffs every case file against its `.expected` sibling. If you changed what a test prints, update the `.expected` file in the same change — see [Testing](14-testing.md).

When the symptom is not here, run `snails doctor` first — it checks the pin, the toolchain, and the database before you go looking further.
