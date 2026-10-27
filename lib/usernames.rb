# frozen_string_literal: true

require "active_support"
require "active_model"
require "i18n"

require_relative "usernames/errors"
require_relative "usernames/version"
require_relative "usernames/data"

# Every bundled list, read now: a broken install fails here, naming the file.
Usernames::Data.load!

require_relative "usernames/normalizer"
require_relative "usernames/phrase"
require_relative "usernames/result"
require_relative "usernames/reserved"
require_relative "usernames/offensive"
require_relative "usernames/words"
require_relative "usernames/generator"
require_relative "usernames/candidates"
require_relative "usernames/rules"
require_relative "usernames/configuration"
require_relative "usernames/validator"
require_relative "usernames/comparison"
require_relative "usernames/unique_violation"
require_relative "usernames/model"
require_relative "usernames/engine" if defined?(Rails::Engine)

module Usernames
  # Deliberately permissive (PRD §6.3): what may ROUTE is not what may be
  # REGISTERED. A name grandfathered in under older rules still has a page,
  # the validator decides what can be registered, and the database decides
  # what exists. No anchors: Rails refuses them in route constraints.
  ROUTE = /[A-Za-z0-9._-]+/

  LOCALES = File.expand_path("../config/locales/*.yml", __dir__)

  # Under Rails the engine loads config/locales (before the app's, so the
  # app's keys win). Without Rails nothing would, and every message would
  # read "Translation missing".
  I18n.load_path |= Dir[LOCALES] unless defined?(Rails::Engine)

  class << self
    attr_writer :configuration

    # Lazily initialized, so every function works without an initializer.
    def configuration
      @configuration ||= Configuration.new
    end

    # Validates at the end of the block, so a bad value fails on the line
    # that boots the app, naming itself.
    def configure
      yield configuration
      configuration.validate!
    end

    # Usernames.check("Ad_min")
    #   # => #<data Usernames::Result ok?=false, reason=:username_reserved, rule=:impersonation, canonical="ad_min", …>
    #
    # Normalises, then applies every rule in order; the first failure wins.
    # Options override the configuration for this call (`length: 2..15`).
    def check(value, **)
      rules = configuration.rules_for(**)
      canonical = rules.normalize(value)
      Result.for(canonical, rules.failure_for(canonical))
    end

    # Eligibility only: whether the name may be registered at all. Says
    # nothing about whether somebody already has it.
    def allowed?(value, **)
      check(value, **).ok?
    end

    # Usernames.normalize(" @Javi_R ") # => "javi_r"
    def normalize(value, **)
      configuration.rules_for(**).normalize(value)
    end

    # What two names are compared by: Usernames.comparison_key("Javi") # => "javi".
    # Normalises first, which changes nothing in a name that already is
    # canonical (normalisation is idempotent).
    # NOTE(p1a): PRD §7.3 defines it on a canonical name; the public function
    # accepts any input, since normalising a canonical name is a no-op.
    def comparison_key(value, **)
      rules = configuration.rules_for(**)
      rules.comparison_key(rules.normalize(value))
    end

    # normalizes :username, with: Usernames.normalizer
    #
    # A blank result is stored as nil, so "  " never becomes an empty
    # username that a unique index would let only one person have. The
    # options are checked now, when the model is defined; the configuration
    # is read on every call, so it may still change after that.
    def normalizer(**options)
      configuration.rules_for(**options)

      lambda do |value|
        normalized = normalize(value, **options)
        normalized unless normalized.empty?
      end
    end

    # get "@:username", to: "profiles#show", format: false, constraints: { username: Usernames.route }
    def route
      ROUTE
    end

    # [{ rule:, pattern:, message: }] for live hints in a form (PRD §8.2).
    def rules_for_browser(**)
      configuration.rules_for(**).for_browser
    end

    # Usernames.generate                          # => "quiet_otter_42"
    # Usernames.generate(from: "José García")     # => "jose_garcia"
    #
    # A name the rules allow (PRD §12). Eligibility only, like check: whether
    # somebody already has it is for the database to say — has_username's
    # generate_username takes the whole batch there in one query.
    # NOTE(p2): raises NoFreeNameError when the rules leave nothing to draw
    # (a word list emptied, a minimum length no shape reaches) rather than
    # returning nil, which a model would store as a missing username.
    def generate(from: nil, **)
      name = Generator.candidates(from: from, rules: configuration.rules_for(**)).first
      return name if name

      raise NoFreeNameError, "no name these rules allow could be generated; check length, separators and the generator's word lists"
    end

    # Usernames.candidates_for("Javi R", count: 5)  # => ["javi_r", "javir", "javi_r_42", …]
    #
    # Up to 3 × count allowed names, ordered, deduplicated (PRD §13). May be
    # fewer, never raises for running out.
    def candidates_for(seed, count:, **)
      Candidates.for(seed, count: count, rules: configuration.rules_for(**))
    end
  end
end
