# Background Jobs

Move slow work off the request: run a job in the background, schedule one for a later moment, or repeat it on an interval.

## Declare a job

A job is a class with one class-side `perform` — the name it is filed under comes from the class name:

```ruby
class CommentDigestJob < ActiveJob::Base
  def self.perform(data)
    CommentDigestSink::COUNTS << Comment.count
  end
end
```

The payload arrives as the one argument — a hash or nothing at all. Put the file under `app/jobs/` and it loads through `gen/jobs.rb`, like everything else in `app/`.

## Enqueue it

```ruby
ActiveJob.enqueue(CommentDigestJob, { "since" => 0 })
```

Where it runs depends on where you enqueued it. On the server the job waits for the worker loop and runs off the request; in tests there is no loop, so it runs right where you enqueue it — which is why a test can assert on the result immediately:

```text
ok an enqueued job runs with its payload
```

For work that should happen again and again, `ActiveJob.recurring(CommentDigestJob, 300)` registers it once and the loop takes care of the rest — one run per interval, starting with the interval you are in.
