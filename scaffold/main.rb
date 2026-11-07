# App entry — the server binary's main.rb.
#
# The boot chain (snails-core/boot.rb) and the shared entry behavior
# (`Snails::Main`: dispatch, server start) are core-owned and vendored with
# snails-core/, so a fix reaches every app through SNALS_REV. App-specific
# `Snails::Main` overrides go in config/environment.rb, which boot requires
# last (the last definition wins).
#
# Canonical copy: scaffold/main.rb. Sync compares this file byte-for-byte.
require_relative "snails-core/boot"

Snails::Main.start
