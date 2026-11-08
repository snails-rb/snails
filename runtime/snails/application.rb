# frozen_string_literal: true

# the app-owned settings object. Values only: the app reopens `Application` in
# config/application.rb; environment-dependent wiring stays in
# config/environment.rb.
module Snails
  # the app's settings object, built once. The readers live on the app's
  # `Snails::Application` reopen (config/ application.rb); memoizing makes it
  # the one read channel rather than a per-call view.
  #
  # @return [Application] the process-wide settings object
  def self.app
    @application ||= Application.new
  end

  # App-owned settings read through `Snails.app.<name>`. Values only — no
  # adapters, no side effects; config/environment.rb owns
  # environment-dependent wiring. An app declares its settings by
  # reopening this class in config/application.rb; these defaults stand in
  # when it declares none.
  class Application
    # the app's own name; the server announces itself with it.
    #
    # The default is generic so a tree whose config/application.rb declares
    # none still starts with a usable name.
    #
    # @return [String] the app's name, `"app"` when the app declares none
    def app_name
      "app"
    end

    # the standard read channel for the app's signing key. The source is the
    # deployment's `SECRET_KEY_BASE`; a missing or empty value raises here,
    # because a token signed with a guessable key validates for anyone who
    # guesses it.
    #
    # The runtime neither generates nor stores a key. An app that sources
    # its key differently (a secret manager, for example) reopens
    # `Application` and overrides this reader.
    #
    # @return [String] the deployment-provided signing key
    # @raise [ArgumentError] when `SECRET_KEY_BASE` is unset or empty
    def secret_key_base
      key = ENV["SECRET_KEY_BASE"]
      if key.nil? || key.empty?
        raise ArgumentError, "SECRET_KEY_BASE is missing; provide the signing key in the environment"
      end
      key
    end

    # the process zone every local time is presented in, as an IANA identifier.
    # Read-only: config/environment.rb owns the slot with
    # `Snails.time_zone = "<zone>"`, which resolves and validates the name.
    #
    # @return [String] the IANA identifier
    def time_zone
      Snails.time_zone
    end

    # the app's own version, when it declares one.
    #
    # There is no default: the framework version and the app version are
    # different facts, so an app that wants one reopens this class in
    # config/application.rb and answers it here. `nil` means "not declared"
    # and a log record omits the field rather than inventing a value.
    #
    # @return [String, nil] the app version, nil when the app declares none
    def version
      nil
    end

    # the deployment identifier of the app code.
    #
    # `ENV["REVISION"]` wins, then a `REVISION` file at the app root. The
    # value is memoized because it describes this process's deployment, not a
    # request-derived value. There is no git fallback: a native binary may
    # run where the repository is absent, so a deploy sets the env or writes
    # the file.
    #
    # @return [String, nil] the revision, nil when neither source exists
    def revision
      unless @revision_initialized
        @revision = read_revision
        @revision_initialized = true
      end
      @revision
    end

    # Read the revision once: env first, then the app-root file. An
    # unreadable or empty source reads as nil rather than failing the
    # process over deployment metadata.
    def read_revision
      value = ENV["REVISION"]
      unless value.nil?
        value = value.strip
        return value unless value.empty?
      end

      path = Snails.root.join("REVISION")
      return nil unless File.exist?(path)
      text = File.read(path).strip
      text.empty? ? nil : text
    rescue SystemCallError
      nil
    end

    private :read_revision
  end
end
