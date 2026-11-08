# frozen_string_literal: true

# the process mode and its predicates. The vocabulary is SNAILS_ENV's:
# development | test | staging | production. `Snails.logger`'s debug gate and
# app-side dev-only branches read these predicates.
module Snails
  # the process mode, read once from SNAILS_ENV and memoized. Development is the
  # default when unset (a deployment sets SNAILS_ENV=production, a harness
  # test.env sets SNAILS_ENV=test).
  #
  # @return [Env] the mode predicates
  def self.env
    @env ||= build_env
  end

  # replace the process mode in-process (a test, a console-style override). A
  # deployment sets SNAILS_ENV before the process starts; there is no separate
  # env-name slot.
  #
  # @param name [String, nil] a vocabulary name, or nil for development
  # @return [Env] the new mode
  def self.env=(name)
    @env = Env.new(name.nil? || name.empty? ? "development" : name)
  end

  def self.build_env
    name = ENV["SNAILS_ENV"]
    Env.new(name.nil? || name.empty? ? "development" : name)
  end
  private_class_method :build_env

  # a plain object answering the known environment predicates (no
  # `method_missing`, no `String` subclass). A name outside the vocabulary
  # answers every predicate false rather than raising — mode is read on the
  # request path (the logger's gate), where a raise would turn a typo into a
  # 500.
  class Env
    def initialize(name)
      @name = name
    end

    # the mode name as declared: development, test, staging, production, or the
    # raw out-of-vocabulary value. Log records use it for the deployment
    # environment field.
    #
    # @return [String] the mode name
    def name
      @name
    end

    def development?
      @name == "development"
    end

    def test?
      @name == "test"
    end

    def staging?
      @name == "staging"
    end

    def production?
      @name == "production"
    end
  end
end
