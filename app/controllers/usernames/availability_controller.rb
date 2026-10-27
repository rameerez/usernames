# frozen_string_literal: true

module Usernames
  # GET /usernames/availability?username=javi&target=user
  #   => { "state": "free" | "taken" | "invalid", "message": "…" }
  #
  # The endpoint behind `f.username_field`. The engine draws its route
  # (config.availability.path); `target` is an alias from
  # config.availability.targets, and any other value is a 404.
  #
  # An availability endpoint tells anyone which names exist — that is its
  # job — so it comes with guard rails:
  #
  # * Rails' own rate_limit (config.availability.rate_limit), counted in
  #   config.availability.rate_limit_store (Rails.cache by default), read
  #   once when this class loads. A store that cannot count — the NullStore,
  #   Rails' default in development and test, or a backend that is down —
  #   makes the limiter count nothing, so outside development and test the
  #   endpoint answers 503, with a log line, until it can. A MemoryStore
  #   works, but per process: each worker counts on its own, so it logs a
  #   warning once.
  # * Taken, reserved and not-allowed names all answer "taken", with one
  #   message: no list, matched word or reason is ever sent to the browser.
  # * Never cached (no-store), whatever the answer, and advisory only: the
  #   model's validations and the unique index decide at save time.
  #
  # It inherits config.availability.parent_controller (your
  # ApplicationController by default), so that controller's locale and
  # authentication callbacks apply. Copy it into your app to change it:
  # `rails generate usernames:availability --copy`.
  class AvailabilityController < Usernames.configuration.availability.parent_class
    # Raised by the counter when the rate limit store cannot count.
    class CounterUnavailable < StandardError; end

    # The store Rails' rate_limit writes to, wrapped so that a count that
    # did not happen is noticed: Rails' limiter lets a request through when
    # increment returns nil, which is exactly what a NullStore, or a cache
    # whose backend is down, returns.
    class Counter
      attr_reader :store

      def initialize(store)
        @store = store
        @warned = Concurrent::AtomicBoolean.new(false)
      end

      def increment(name, amount = 1, **)
        count = begin
          store.increment(name, amount, **)
        rescue StandardError => e
          failure = e
          nil
        end
        return count if count.is_a?(Integer)

        unavailable!(failure)
      end

      def null?
        store.is_a?(ActiveSupport::Cache::NullStore)
      end

      def memory?
        store.is_a?(ActiveSupport::Cache::MemoryStore)
      end

      # Why nothing was counted, for the log.
      def problem(failure = nil)
        if null? then "the rate limit store is the NullStore, where Rails' rate_limit counts nothing"
        elsif failure then "the rate limit store failed to count (#{failure.class}: #{failure.message})"
        else "the rate limit store's increment returned nothing, so Rails' rate_limit counts nothing"
        end
      end

      private

      # In development and test an unlimited check is the useful one: log
      # once and let it through. Anywhere else, refuse.
      def unavailable!(failure)
        raise CounterUnavailable, problem(failure) unless Rails.env.local?

        if @warned.make_true
          Rails.logger.warn "[usernames] The availability check isn't rate limited here: #{problem(failure)}. " \
                            "Outside development and test it answers 503 until the store can count."
        end
        0
      end
    end

    # Captured once: the very object the limiter writes to.
    RATE_LIMIT = Counter.new(Usernames.configuration.availability.rate_limit_store || Rails.cache)

    MEMORY_STORE_WARNED = Concurrent::AtomicBoolean.new(false)

    # Format failures are shown as they are (the browser hints them anyway);
    # reserved and not-allowed names are reported as taken (see above).
    FORMAT_FAILURES = %i[
      username_spaces username_characters username_unicode too_short too_long username_edges
      username_consecutive username_first_character username_digits_only username_extension
    ].freeze

    # Far beyond any username: what is longer is cut here, before the
    # normaliser sees it, and still breaks the length rule.
    LONGEST = 1024

    # Before everything else, the limiter included: an answer about who
    # exists is never cached, and neither is a 404, a 429 or a 503.
    prepend_before_action :no_store

    rate_limit(**Usernames.configuration.availability.rate_limit, store: RATE_LIMIT,
                                                                  with: -> { head :too_many_requests })

    before_action :warn_about_a_memory_store
    # After the limiter, so guessing aliases is rate limited too.
    before_action :find_the_target

    rescue_from CounterUnavailable do |error|
      Rails.logger.error "[usernames] The availability check is off (503): #{error.message}. " \
                         "Use a shared store that counts: Solid Cache, Redis or Memcached."
      head :service_unavailable
    end

    def show
      render json: answer_for(typed)
    end

    private

    def find_the_target
      @model, @column = Targets.find(params[:target])
      head :not_found unless @model
    end

    def typed
      value = params[:username]
      value.is_a?(String) ? value[0, LONGEST] : ""
    end

    # Every message in the model's own words: a translation under
    # activerecord.errors.models.<model>.attributes.<column> wins here as on
    # the form.
    def answer_for(value)
      result = @model.public_send(:"check_#{@column}", value)

      if result.canonical.empty?
        { state: "invalid", message: message(:blank) }
      elsif FORMAT_FAILURES.include?(result.reason)
        { state: "invalid", message: result.message }
      elsif result.ok? && @model.public_send(:"#{@column}_available?", result.canonical)
        { state: "free", message: I18n.t(:available, scope: :usernames) }
      else
        { state: "taken", message: message(:taken) }
      end
    end

    def message(type)
      @model.new.errors.generate_message(@column, type)
    end

    def warn_about_a_memory_store
      return unless RATE_LIMIT.memory? && MEMORY_STORE_WARNED.make_true

      Rails.logger.warn "[usernames] The availability check's rate limit uses a MemoryStore, which each " \
                        "process counts on its own. Use a shared store (Solid Cache, Redis, Memcached) for one " \
                        "limit per client."
    end
  end
end
