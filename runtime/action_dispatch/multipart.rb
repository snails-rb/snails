# The `multipart/form-data` parser and the `UploadedFile` a file part becomes.
#
# The body drains (`Tep::Request#consume_body_via_io` and
# `#consume_body_via_scheduler`) call `Multipart.parse` and put each file part
# into the params tree under the same nested key a text field would take. The
# synthesized `<Resource>Params.from_raw` narrows it back through
# `UploadedFile.from_params`; the tree carries `String`, `Hash`, `Array`, and
# `UploadedFile` values (plus `nil` for a key without a value), so this class
# is a fourth arm in the untyped Hash.
#
# The body is BYTES: every offset is a byte offset (`byteindex`, `byteslice`,
# `bytesize`), because a JPEG is not valid UTF-8 and a character index would be
# wrong.
#
# Read: `Content-Disposition: form-data; name="…"; filename="…"` and the part's
# `Content-Type`. A part with a filename is a file, without one a text field; an
# empty filename (a file input nobody picked) is dropped, so the field is not
# provided. Nested `multipart/mixed`, `Content-Transfer-Encoding`, and RFC 2231
# filenames are not modeled.
module ActionDispatch
  module Http
    # A multipart part, and what `fixture_file_upload` hands a test: the name
    # it was uploaded under, its declared type, and its bytes. Data-backed
    # rather than file-backed so a part never touches the disk before the
    # storage service decides where it lives.
    class UploadedFile
      attr_reader :original_filename, :content_type

      def initialize(data, original_filename, content_type)
        @data = data
        @original_filename = original_filename
        @content_type = content_type
      end

      def read
        @data
      end

      def size
        @data.bytesize
      end

      # the uploaded name, which is what a params hash carrying this file
      # stringifies to.
      #
      # @return [String] the uploaded file name
      def to_s
        @original_filename
      end

      # the file under `key` in a params sub-hash, or nil when the request
      # carried no file there (absent, or a text field — the bare filename a
      # urlencoded form posts for a file input is a String, not a file).
      #
      # @param sub [Hash{String => Object}] the params sub-hash to look in
      # @param key [String] the field name to read
      # @return [UploadedFile, nil] the file, or nil when none was uploaded
      def self.from_params(sub, key)
        value = sub[key]
        if value.is_a?(ActionDispatch::Http::UploadedFile)
          value
        else
          nil
        end
      end

      # did the request carry a file under `key`? The file counterpart of
      # `ActionController::Params.provided`.
      #
      # @param sub [Hash{String => Object}] the params sub-hash to look in
      # @param key [String] the field name to read
      # @return [Boolean] true when a file part was uploaded under `key`
      def self.provided(sub, key)
        !from_params(sub, key).nil?
      end

      # the uploaded name for a params record's `to_h`, or "" for none.
      #
      # @param file [UploadedFile, nil] the file to read, or nil
      # @return [String] the uploaded name, "" when there is no file
      def self.name_of(file)
        file.nil? ? "" : file.original_filename
      end
    end

    module Multipart
      # The parsed body: text fields by full name (`message[body]`),
      # files by full name. Two typed hashes rather than one mixed one,
      # so each serving path can nest them into its own params shape.
      class Form
        attr_reader :fields, :files

        def initialize
          @fields = {}
          @files = {}
        end

        def add_field(name, value)
          @fields[name] = value
        end

        def add_file(name, file)
          @files[name] = file
        end
      end

      # the boundary parameter of a `multipart/form-data; boundary=…` header,
      # unquoted.
      #
      # @param content_type [String] the request's Content-Type header value
      # @return [String] the boundary, or "" when the header has none
      def self.boundary(content_type)
        at = content_type.index("boundary=")
        return "" if at.nil?
        rest = content_type[at + 9, content_type.length - at - 9].to_s
        semi = rest.index(";")
        rest = rest[0, semi].to_s unless semi.nil?
        rest = rest.strip
        if rest.length >= 2 && rest[0, 1] == "\"" && rest[rest.length - 1, 1] == "\""
          rest = rest[1, rest.length - 2].to_s
        end
        rest
      end

      # the value of `<attr>="…"` inside a Content-Disposition header.
      #
      # @param header [String] the Content-Disposition header value
      # @param attr [String] the parameter name to read
      # @return [String] the value, or "" when it is absent
      def self.disposition_param(header, attr)
        needle = attr + "=\""
        at = header.index(needle)
        return "" if at.nil?
        from = at + needle.length
        close = header.index("\"", from)
        return "" if close.nil?
        header[from, close - from].to_s
      end

      # the parts of one multipart body, split into `Form#fields` (text) and
      # `Form#files`. A body that does not parse answers nil instead of the
      # parts found before it stopped: a missing boundary, a lost delimiter, or
      # a truncated part means the payload never arrived whole, and the fields
      # before the break are not the request the client meant. The caller turns
      # nil into a request failure rather than serving half a form.
      #
      # @param body [String] the raw request body
      # @param content_type [String] the Content-Type header, boundary included
      # @return [Form, nil] the parsed parts; nil when the body does not parse
      def self.parse(body, content_type)
        form = Form.new
        b = boundary(content_type)
        return nil if b.length == 0
        delimiter = "--" + b
        n = body.bytesize
        pos = body.byteindex(delimiter)
        return nil if pos.nil?
        pos += delimiter.bytesize
        while pos < n
          # The delimiter is followed by CRLF for a part, or by "--"
          # for the closing delimiter.
          return form if body.byteslice(pos, 2) == "--"
          pos += 2 if body.byteslice(pos, 2) == "\r\n"
          header_end = body.byteindex("\r\n\r\n", pos)
          return nil if header_end.nil?
          headers = body.byteslice(pos, header_end - pos).to_s
          content_start = header_end + 4
          next_delim = body.byteindex("\r\n" + delimiter, content_start)
          return nil if next_delim.nil?
          content = body.byteslice(content_start, next_delim - content_start).to_s
          add_part(form, headers, content)
          pos = next_delim + 2 + delimiter.bytesize
        end
        # The walk ran off the end without meeting the closing delimiter:
        # the body stops inside a part.
        nil
      end

      # register one part: its name, whether it is a file, and its bytes. The
      # header block is small and ASCII, so character ops are byte ops there.
      #
      # @param form [Form] the parsed form to add the part to
      # @param headers [String] the part's header block, CRLF-separated
      # @param content [String] the part's bytes
      # @return [void]
      def self.add_part(form, headers, content)
        disposition = +""
        part_type = "application/octet-stream"
        headers.split("\r\n").each do |line|
          colon = line.index(":")
          next if colon.nil?
          hname = line[0, colon].to_s.strip.downcase
          hvalue = line[colon + 1, line.length - colon - 1].to_s.strip
          if hname == "content-disposition"
            disposition = hvalue
          elsif hname == "content-type"
            part_type = hvalue
          end
        end
        name = disposition_param(disposition, "name")
        return nil if name.length == 0
        if disposition.include?("filename=")
          filename = disposition_param(disposition, "filename")
          return nil if filename.length == 0
          # A browser sends the basename; a client that sends a path keeps
          # only its tail.
          slash = filename.rindex("/")
          filename = filename[slash + 1, filename.length - slash - 1].to_s unless slash.nil?
          bslash = filename.rindex("\\")
          filename = filename[bslash + 1, filename.length - bslash - 1].to_s unless bslash.nil?
          form.add_file(name, UploadedFile.new(content, filename, part_type))
        else
          form.add_field(name, content)
        end
      end
    end
  end
end
