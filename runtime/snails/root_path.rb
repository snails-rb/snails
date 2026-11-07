# `Snails.root` — the app root as a plain path value (`AppPath`). The server
# runs with the app root as its working directory, so the value is "." and
# interpolation stays byte-identical to plain relative paths.
module Snails
  # `Snails.root()` — the app root.
  #
  # This is app-facing surface: the runtime itself does not read it, but app
  # code uses it for paths under the root.
  #
  # @return [AppPath] the app root, relative to the process working directory
  # @example
  #   "#{Snails.root}/tmp"                    # => "./tmp"
  #   Snails.root.join("tmp", "storage").to_s # => "./tmp/storage"
  def self.root
    AppPath.new(".")
  end

  # A path value returned by `Snails.root`.
  #
  # It is not a `String` subclass, so the runtime stays statically resolvable.
  # The surface is what app code needs from a path: interpolation, `join`,
  # `+`, and the implicit conversion `File` methods use.
  class AppPath
    def initialize(base)
      @base = base
    end

    # `join(*parts)` — appends path parts with one separator between each.
    #
    # With no parts it answers this path unchanged, so `Snails.root.join` is
    # `Snails.root`.
    #
    # @param parts [Array<String>] the parts to append
    # @return [AppPath] the joined path
    # @example
    #   Snails.root.join("tmp", "storage").to_s # => "./tmp/storage"
    def join(*parts)
      if parts.empty?
        self
      else
        AppPath.new(@base + "/" + parts.join("/"))
      end
    end

    # `+(part)` — a path join, not string concatenation.
    #
    # @param part [String] the part to append
    # @return [AppPath] the joined path
    def +(part)
      join(part)
    end

    # `to_s()` — the accumulated path, which is what interpolation prints.
    #
    # @return [String] the path text
    def to_s
      @base
    end

    # `to_path()` — the implicit conversion `File` methods look for.
    #
    # It is `to_path`, not `to_str`: a path value does not pose as a String.
    #
    # @return [String] the path text
    def to_path
      @base
    end
  end
end
