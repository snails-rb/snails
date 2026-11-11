# Time, Dates, and JSON

Times are stored as UTC and read back in the app's zone. Durations are plain values with their own arithmetic, and `render json:` has one fixed spelling for Time. This chapter covers the three together because they meet at the same boundary: a stored instant becomes a JSON string.

## Durations

An integer answers the time units. Every unit returns a `Snails::Duration`, which carries the arithmetic:

```ruby
3.minutes.to_i        # 180
2.hours.from_now      # Time, two hours ahead
7.days.ago            # Time, seven days back
1.month.to_i          # 2629746 — an average month, not a calendar month
1.year.to_i           # 31556952
```

`ago` and `until` are the same instant in the past; `from_now` and `since` are the same instant in the future. A Duration compares with another Duration or with a raw seconds count:

```ruby
1.hour == 3600        # true
1.day > 1.hour        # true
```

Months and years use average lengths. For a calendar step — "one month after January 31" — use a `Time` calculation instead.

## Time arithmetic

`Time` answers boundaries and calendar shifts:

```ruby
now = Time.now
now.beginning_of_day       # midnight in the app zone
now.end_of_day             # 23:59:59.999999999
now.beginning_of_month     # the 1st at midnight
now.end_of_month           # the last day's inclusive end
now.yesterday              # one civil day back, same clock time
now.tomorrow
now.days_ago(30)
now.months_since(1)        # Jan 31 becomes Feb 29 in a leap year
now.years_since(1)
now.beginning_of_week      # Monday
now.next_week              # next Monday
```

The predicates read the civil calendar, not elapsed seconds:

```ruby
now.today?
now.yesterday?
now.past?
now.future?
now.on_weekend?
now.on_weekday?
```

A day shift rebuilds the civil date, so a daylight-saving transition cannot move the clock. A month step clamps to the target month's last day.

## Stored time and the app zone

A declared `datetime` column is stored as UTC text in a fixed-width form. Reading it back parses that form and renders it in the process zone:

```ruby
post.created_at                      # Time in the app zone
post.created_at.to_fs(:db)           # "2026-11-12 08:00:00.000000" (UTC)
post.created_at.to_fs(:iso8601)      # "2026-11-12T08:00:00.000+00:00"
```

`Snails.time_zone` is the process zone. Set it once in `config/environment.rb`; `Snails.app.time_zone` reads it back. `in_time_zone` renders the same instant elsewhere without changing the process slot, so concurrent requests can present different zones:

```ruby
time.in_time_zone("Seoul")           # fixed-offset Time, +09:00
time.in_time_zone("UTC")
```

Both a zone name from the runtime's vocabulary (`"Seoul"`, `"Eastern Time (US & Canada)"`) and an IANA identifier (`"Asia/Seoul"`) are accepted. The name must have a zone file; a typo raises at the call, not at the first request.

`Time.now.utc` is the same instant in UTC. `Duration#ago` and `from_now` return UTC, because they were built from `Time.now.utc`; call `in_time_zone` when the result is for a human in the app zone.

`String#to_time` parses the stored datetime form, not arbitrary date text. `String#to_date` parses the stored date form; it is loaded only for an app with `DATE` columns.

## Render JSON

`render json:` takes a Ruby value and encodes it. The encoder runs `as_json` first, then walks the result:

| Value | JSON |
|---|---|
| `Hash` | object; keys become strings |
| `Array` | array, element by element |
| `String`, `Integer`, `Float`, `true`, `false`, `nil` | the obvious primitive |
| `Symbol` | a string |
| `Time` | ISO 8601 with milliseconds and the zone offset |
| any other object | `to_s` |

```ruby
render(json: { "post" => post_json(post), "count" => Post.count })
render(json: nil)                 # "null"
render(json: "hello")             # "\"hello\""
```

A model does not serialize for JSON by default. A bare `render(json: post)` falls to the last row and prints the object's `to_s`. Give the model an `as_json` when the record itself is the payload:

```ruby
class Post < Sqlx::Base
  def self.table_name = "posts"

  def as_json(options = {})
    {
      "id" => id,
      "title" => title,
      "body" => body,
      "created_at" => created_at
    }
  end
end

render(json: post)
```

`as_json` runs for a model even inside a Hash value, so a nested record uses the same shape. A `Time` inside that Hash still becomes an ISO 8601 string. A `Date` is not a Time: it falls to `to_s` and renders as `"2026-11-12"`.

`render json:` sets `Content-Type: application/json; charset=utf-8` unless the call names another type. `render("text", content_type: ...)` is the pre-encoded body form; `render(json: value, content_type: ...)` overrides the header but still encodes the value.

JSON columns use the same codec on the database side: a declared `json_columns` entry encodes on write and decodes on read, so app code never calls the codec itself. See [Columns and Types](11-columns-and-types.md).

The process zone applies to every read, including a job that runs without a request. If a job formats a time for a user, render it in that user's zone with `in_time_zone` rather than changing the process slot.
