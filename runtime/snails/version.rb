# frozen_string_literal: true

# Framework version metadata — the version and revision of the core that is
# actually running. `publish-dist.sh` rewrites the two constants when it
# packages a release; `sync` copies the vendored file, so the values name the
# code in the binary rather than the app's pin declaration. A checkout sync
# stamps the resolved revision into the app's vendored copy.
module Snails
  # The core version: a release tag (`v0.20.0`) or a full commit revision for
  # an edge pin. `"unknown"` in a checkout that was never stamped.
  VERSION = "unknown"

  # The exact core revision, full 40-hex when known.
  REV = "unknown"

  # `version()` — the framework version the running core was packaged from.
  #
  # @return [String] the release tag or revision, `"unknown"` when unstamped
  def self.version
    VERSION
  end

  # `rev()` — the exact framework revision the running core was packaged from.
  #
  # @return [String] the full commit revision, `"unknown"` when unstamped
  def self.rev
    REV
  end
end
