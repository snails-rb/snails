# Entry index for the OTLP transport helpers shared by logs and traces.
#
# The HTTP layer owns endpoint/token validation, the session, retry, and the
# signal path; the resource attributes are the process-wide values both signals
# send once per batch.
require_relative "otlp/http"
require_relative "otlp/resource"
