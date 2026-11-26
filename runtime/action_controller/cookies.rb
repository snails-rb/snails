# Controller-level cookie access: the `cookies` jar. A read returns the
# request's inbound value; a write records one `Set-Cookie` line for the
# dispatcher to emit after the action. The jar is the app surface — the
# wire formatter stays in `Tep::Response#set_cookie`.
#
# The jar lives in this reopen rather than `api.rb` so the aggregator owns
# the load order and the controller body stays about its own state.
module ActionController
  # One pending cookie write: the name, the wire value, and canonical
  # `Set-Cookie` attributes (`Path`, `Expires`, `Max-Age`, `Domain`,
  # `Secure`, `HttpOnly`, `SameSite`). A flag attribute carries an empty
  # value because `Tep::Response#set_cookie` writes an empty value as a
  # bare attribute.
  #
  # Not app API: the jar creates these and the dispatcher reads them.
  #
  # @api internal
  class Cookie
    attr_reader :name, :value, :options

    def initialize(name, value, options)
      @name = name
      @value = value
      @options = options
    end
  end

  # The cookie jar a controller reads and writes through `cookies`.
  # Writes are pending until the dispatcher copies them onto the response,
  # so a filter and the action share one jar for the request.
  #
  # A missing cookie reads as `""` rather than `nil`. Rails returns nil;
  # this runtime keeps a non-null String because spinel's nullable-String
  # path rejects the common `cookies[:name].to_s.split(...)` shape. Callers
  # that need presence test `== ""` or read `request.cookies` and check
  # `key?`.
  #
  # The write forms are Rails-like:
  #
  #   cookies[:name] = "value"
  #   cookies[:name] = { value: "value", httponly: true, secure: true,
  #                      same_site: :strict, path: "/", max_age: 3600 }
  #   cookies.delete(:name, path: "/")
  #   cookies.permanent[:name] = "value"
  #
  # Unknown option keys raise, as do values that break the browser's
  # `__Host-`/`__Secure-`/`SameSite=None` rules — a silently dropped
  # `HttpOnly` or a browser-rejected cookie is worse than a loud error at
  # the call site.
  class CookieJar
    # @param inbound [Hash{String => String}] the request's parsed cookie
    #   hash (`ActionDispatch::Request#cookies`)
    # @return [void]
    def initialize(inbound = {})
      # The dispatcher copies the transport hash into `request.cookies`
      # first, so this store is already a plain String-to-String hash; a
      # second copy here would be dead weight.
      @inbound = inbound
      @writes = []
    end

    # the cookie value, or `""` when absent. A pending write wins over the
    # inbound value, including a cleared write, so a read after
    # `cookies.delete` does not see the deleted value.
    #
    # @param key [Object] the cookie name
    # @return [String] the value, `""` when absent
    # @example
    #   cookies[:session]
    def [](key)
      raw(key)
    end

    # record a cookie write. A bare value writes the cookie with defaults;
    # a Hash carries `value:` plus any transport attributes. A nil value
    # (bare or under `value:`) deletes the cookie.
    #
    # @param key [Object] the cookie name
    # @param value [Object] the value, or the options Hash
    # @return [String] the value stored on the wire
    # @raise [ArgumentError] the name is empty or invalid, the options
    #   carry an unknown key, or the attributes break a cookie prefix rule
    def []=(key, value)
      write_from(key, value, false)
    end

    # The shared write path for the plain jar and `cookies.permanent`: parse
    # the bare-value or options-Hash form, then record the write. `permanent`
    # only supplies the 20-year expiry the view promises.
    #
    # @api internal
    # @param key [Object] the cookie name
    # @param value [Object] the value, or the options Hash
    # @param permanent [Boolean] add a 20-year expiry when none is given
    # @return [String] the value stored on the wire
    def write_from(key, value, permanent)
      if value.nil?
        return delete(key)
      end
      if !value.is_a?(Hash)
        return raw_set(key, value, {}, permanent)
      end
      if !value.key?(:value)
        raise ArgumentError, "cookies[:#{key}] needs a value: key"
      end
      stored = value[:value]
      return delete(key) if stored.nil?
      raw_set(key, stored, value, permanent)
    end

    # a view whose writes expire in 20 years — Rails' `permanent` helper.
    # A read and a delete go through the same jar.
    #
    # @return [PermanentCookieJar] the permanent-write view
    def permanent
      PermanentCookieJar.new(self)
    end

    # the latest stored value for a key, without the option parsing of
    # `[]=` — the read side the signed view shares.
    #
    # @api internal
    # @param key [Object] the cookie name
    # @return [String] the value, `""` when absent
    def raw(key)
      name = key.to_s
      i = @writes.length - 1
      while i >= 0
        write = @writes[i]
        return write.value if write.name == name
        i -= 1
      end
      return @inbound[name] if @inbound.key?(name)
      ""
    end

    # record one write with canonical options — the write side the signed
    # view shares. Exposed to the sibling classes, not to apps.
    #
    # @api internal
    # @param key [Object] the cookie name
    # @param value [Object] the value coerced to a String
    # @param options [Hash{Symbol => Object}] the app's option Hash
    # @return [String] the value stored on the wire
    def raw_set(key, value, options = {}, permanent = false)
      name = cookie_name(key)
      text = value.to_s
      if text.include?("\r") || text.include?("\n")
        raise ArgumentError, "cookie value must not contain CR or LF"
      end
      canonical = canonical_options(name, options, permanent)
      @writes.push(Cookie.new(name, text, canonical))
      text
    end

    # remove a cookie: a cleared value with `Max-Age=0` and an epoch
    # `Expires`, plus the path and domain the browser matches on. Pass the
    # same path and domain the cookie was set with, or the browser keeps the
    # old cookie.
    #
    # @param key [Object] the cookie name
    # @param options [Hash{Symbol => Object}] `path:` and `domain:` used to
    #   match the cookie, plus optional `secure:`/`httponly:` flags
    # @return [String] `""`
    def delete(key, **options)
      options[:max_age] = 0
      options[:expires] = Time.at(0)
      raw_set(key, "", options)
      ""
    end

    # the writes this request records, for the dispatcher's Set-Cookie
    # serialization. Not the merged view (`to_h`) — a read of a cookie that
    # was not written this request must not emit a header.
    #
    # @api internal
    # @return [Array<Cookie>] the pending writes
    def pending
      @writes
    end

    # the whole jar: inbound values overlaid by this request's pending
    # writes. A cleared write appears as `""`.
    #
    # @return [Hash{String => String}] the merged cookie store
    def to_h
      merged = {}
      @inbound.each { |k, v| merged[k] = v }
      i = 0
      while i < @writes.length
        write = @writes[i]
        merged[write.name] = write.value
        i += 1
      end
      merged
    end

    # `to_h` under its Hash-style name, for code that rebuilds a jar from
    # stored values.
    #
    # @return [Hash{String => String}] the merged cookie store
    def to_hash
      to_h
    end

    # iterate the merged store. A write during the block is allowed: the
    # block walks the snapshot `to_h` builds, not the live stores.
    #
    # @yieldparam name [String] the cookie name
    # @yieldparam value [String] the cookie value
    # @return [CookieJar] self
    def each
      to_h.each { |k, v| yield k, v }
      self
    end

    # The name validation and the option canonicalization are one path for
    # every write (plain, signed, permanent, delete) so a prefix rule cannot
    # be skipped by one form. Empty values are flags on the wire.
    def canonical_options(name, options, permanent)
      path = "/"
      domain = ""
      secure = false
      httponly = false
      same_site = "Lax"
      expires = ""
      max_age = -1
      options.each do |key, value|
        if key == :value
          next
        elsif key == :path
          path = path_value(value)
        elsif key == :domain
          domain = domain_value(value)
        elsif key == :secure
          secure = boolean_value(value, :secure)
        elsif key == :httponly
          httponly = boolean_value(value, :httponly)
        elsif key == :same_site
          same_site = same_site_value(value)
        elsif key == :expires
          expires = expires_value(value)
        elsif key == :max_age
          max_age = max_age_value(value)
        else
          raise ArgumentError, "unknown cookie option #{key}"
        end
      end
      if permanent && expires.empty?
        expires = http_date(Time.now + 630720000)
      end
      if name.start_with?("__Host-")
        if !secure || path != "/" || !domain.empty?
          raise ArgumentError, "__Host- cookies need secure: true, path: \"/\", and no domain"
        end
      elsif name.start_with?("__Secure-")
        if !secure
          raise ArgumentError, "__Secure- cookies need secure: true"
        end
      end
      if same_site == "None" && !secure
        raise ArgumentError, "SameSite=None needs secure: true"
      end
      out = {}
      out["Path"] = path
      out["Expires"] = expires unless expires.empty?
      out["Max-Age"] = max_age.to_s if max_age >= 0
      out["Domain"] = domain unless domain.empty?
      out["Secure"] = "" if secure
      out["HttpOnly"] = "" if httponly
      out["SameSite"] = same_site unless same_site.empty?
      out
    end

    private :canonical_options

    def cookie_name(key)
      name = key.to_s
      if name.empty?
        raise ArgumentError, "cookie name must not be empty"
      end
      bad = [ ";", ",", "=", " ", "\t", "\r", "\n" ]
      i = 0
      while i < bad.length
        if name.include?(bad[i])
          raise ArgumentError, "cookie name contains #{bad[i]}"
        end
        i += 1
      end
      name
    end

    def path_value(value)
      if !value.is_a?(String) || value.empty? || !value.start_with?("/")
        raise ArgumentError, "cookie path must be a String starting with \"/\""
      end
      value
    end

    def domain_value(value)
      if !value.is_a?(String) || value.empty?
        raise ArgumentError, "cookie domain must be a non-empty String"
      end
      value
    end

    def boolean_value(value, name)
      return true if value == true
      return false if value == false
      raise ArgumentError, "cookie #{name} must be true or false"
    end

    def same_site_value(value)
      return "" if value.nil?
      text = value.to_s.downcase
      return "Lax" if text == "lax"
      return "Strict" if text == "strict"
      return "None" if text == "none"
      raise ArgumentError, "cookie same_site must be :lax, :strict, :none, or nil"
    end

    def expires_value(value)
      if !value.is_a?(Time)
        raise ArgumentError, "cookie expires must be a Time"
      end
      http_date(value)
    end

    def max_age_value(value)
      if !value.is_a?(Integer) || value < 0
        raise ArgumentError, "cookie max_age must be a non-negative Integer"
      end
      value
    end

    # RFC 6265's cookie-date shape, in UTC: `Wdy, DD Mon YYYY HH:MM:SS GMT`.
    # `Time#strftime` on the pinned toolchain does not carry `%a`/`%b`
    # through every call path, so the weekday and month tables are explicit.
    def http_date(value)
      utc = value.utc
      weekdays = [ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" ]
      months = [ "Jan", "Feb", "Mar", "Apr", "May", "Jun",
                 "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" ]
      weekdays[utc.wday] + ", " + pad_number(utc.mday) + " " +
        months[utc.mon - 1] + " " + utc.year.to_s + " " +
        pad_number(utc.hour) + ":" + pad_number(utc.min) + ":" +
        pad_number(utc.sec) + " GMT"
    end

    def pad_number(value)
      value < 10 ? "0" + value.to_s : value.to_s
    end

    private :cookie_name, :path_value, :domain_value, :boolean_value
    private :same_site_value, :expires_value, :max_age_value, :http_date, :pad_number
  end

  # The `cookies.permanent` view: every write gets a 20-year `expires`
  # unless the caller named one. Composed by delegation, not by a flag on
  # the jar — a flag would keep expiring later plain writes from the same
  # request.
  class PermanentCookieJar
    def initialize(jar)
      @jar = jar
    end

    def [](key)
      @jar[key]
    end

    def []=(key, value)
      @jar.write_from(key, value, true)
    end

    def delete(key, **options)
      @jar.delete(key, **options)
    end

    def to_h
      @jar.to_h
    end

    def each
      @jar.each { |k, v| yield k, v }
      self
    end
  end

  class API
    # the request's cookie jar. The dispatcher assigns it before the action;
    # a controller constructed in a test still gets an empty jar.
    #
    # @return [CookieJar] the request's cookie jar
    # @example
    #   cookies[:session] = { value: token, httponly: true }
    def cookies
      @cookies = ActionController::CookieJar.new if @cookies.nil?
      @cookies
    end

    # @param value [CookieJar] the jar the dispatcher assigns
    # @return [CookieJar] the assigned jar
    def cookies=(value)
      @cookies = value
      value
    end
  end
end

# Rails puts the jar at `ActionDispatch::Cookies::CookieJar` and reaches it
# from a controller as `cookies`. App code that rebuilds a jar from stored
# values calls `ActionDispatch::Cookies::CookieJar.build(request, hash)`;
# keeping that spelling as a constructor keeps the Rails call shape without
# a second jar. `request` is accepted and ignored — this runtime derives no
# host-scoped `domain: :all` behavior from it.
module ActionDispatch
  module Cookies
    class CookieJar
      def self.build(request, cookies)
        ActionController::CookieJar.new(cookies)
      end
    end
  end
end
