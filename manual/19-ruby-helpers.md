# Ruby Helpers

The runtime reopens a few core classes with the helpers app code reaches for most: string formatting, key transforms, collection predicates, and value presence. They are available everywhere — controllers, models, jobs, and tests — with no require.

## Strings

```ruby
"  hello   world  ".squish        # "hello world"
"FooBar".underscore               # "foo_bar"
"host_info".camelize              # "HostInfo"
"host_info".camelize(:lower)      # "hostInfo"
"foo_bar".humanize                # "Foo bar"
"foo_bar".titleize                # "Foo Bar"
"post".pluralize(2)               # "posts"
"category".pluralize(3)           # "categories"
"Hello World".parameterize         # "hello-world"
```

`camelize` reads `/` as a namespace separator (`"a/b"` becomes `"A::B"`). `humanize` drops a trailing `" id"`, which is the label shape a form field name usually needs. `pluralize(1)` returns the word unchanged; the suffix rules are the regular English ones, not an irregular-word table. `parameterize` keeps only ASCII letters, digits, and `_`, so a non-Latin word parameterizes to an empty string.

`String#to_time` and `String#to_date` parse the stored database forms, not arbitrary date input. `to_time` reads the fixed-width datetime text and returns the instant in the app zone; `to_date` reads the first ten characters and answers nil for shorter text.

## Presence

```ruby
nil.blank?          # true
"  ".blank?         # true
[].blank?           # true
0.blank?            # false
"x".present?        # true
"x".presence        # "x"
"".presence         # nil
"admin".presence_in(["member", "admin"])   # "admin"
"other".presence_in(["member", "admin"])   # nil
```

`blank?` treats `nil`, `false`, an empty Array or Hash, and a whitespace-only String as empty. `0` and `:sym` are values. `presence` is the `value.presence || fallback` shape. `presence_in` takes an Array and compares the receiver's text, so a Symbol matches its String spelling.

## Hashes and arrays

```ruby
{ "a" => 1 }.symbolize_keys           # { a: 1 }
{ a: 1 }.stringify_keys               # { "a" => 1 }
{ "a" => { "b" => 1 } }.deep_transform_keys { |k| k.to_s.upcase }
# => { "A" => { "B" => 1 } }
[ { "a" => 1 } ].deep_transform_keys { |k| k.to_s.upcase }
# => [ { "A" => 1 } ]

{ name: "Sue", page: 2 }.to_query     # "name=Sue&page=2"
[ "a", "b", "c" ].to_sentence         # "a, b, and c"
```

`deep_transform_keys` returns a new Hash; the receiver keeps its old keys. The bang spelling returns a new Hash too, despite the name — use the return value. On an Array, the bang spelling mutates the receiver's Hash elements.

`to_query` percent-encodes ASCII punctuation, renders a space as `+`, repeats `key[]` for a scalar Array, and nests a Hash as `outer[inner]`. A non-ASCII value passes through unencoded, so encode it before the call if the consumer requires it.

## Collections

```ruby
[ a, b, c ].index_by { |item| item.id }   # { id => item, ... }
[ a, b ].many?                            # true
[ a ].sole                                # a; raises when empty or more than one
```

`index_by` keeps the last item for a duplicate key. `many?` answers whether the collection holds more than one element. `sole` asserts that the collection holds exactly one and raises `"no item found"` or `"multiple items found"` otherwise.

These helpers are ordinary Ruby reopenings, so a method your app defines on the same class wins. They exist to save a repeated local helper, not to replace a domain method with a vaguer name.

[Forms and Validation](13-forms.md) uses `humanize` in error messages; [Time, Dates, and JSON](17-time-dates-and-json.md) covers the time units and `to_fs`.
