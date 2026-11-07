# App-owned boot profile — one literal require, chosen at build time.
#
# `all` is the full boot sequence. Other profiles are not available yet; the
# app edits this file when one is introduced.
require_relative "../snails-core/boot/all"
