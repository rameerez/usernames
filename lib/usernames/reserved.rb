# frozen_string_literal: true

require "active_support/core_ext/string/inflections"

module Usernames
  # Reserved names: the exact list (config.reserved, your routes,
  # the bundled system, mailbox and web words) and the impersonation list
  # (config.forbidden, the bundled impersonation words, your app's name),
  # with config.allowed lifting individual words.
  #
  # The two lists are matched differently because they fail differently.
  # Somebody posing as staff types `adm1n`, `ad.min`, `admin_bob` or
  # `admins`, so impersonation words are looked for in every form the name
  # can be read as. The thousand-odd exact words are paths and mailboxes
  # that only collide when spelled exactly: folding trailing digits over
  # them is what refused `game969` in production, and matching them as
  # prefixes is what refused `badminton_fan`.
  module Reserved
    SEPARATORS = "_.-"

    # A segment is what sits between separators and digit runs:
    # `adm1n_bob` reads as adm, n, bob.
    SEGMENT_BOUNDARY = /[_.-]+|\d+/

    # Names that read as a well-known URI or as an IDNA/punycode label
    # whatever follows: `/.well-known/…` is served by the web server, and
    # `xn--…` is how a Unicode lookalike travels as ASCII.
    PREFIXES = %w[.well-known xn--].freeze

    # The compiled sets for one Usernames::Rules. Every word is an ASCII
    # comparison key, so a lookup is one Set#include?. :nodoc:
    Sets = ::Data.define(:exact, :custom, :impersonation, :allowed)

    class << self
      # The kind of reservation that matched — :impersonation, :exact, :route,
      # :custom or :reserved_if — or nil when the name is free to use. `key` is
      # Usernames.comparison_key of a name that already passed every format
      # rule; `rules` is the Usernames::Rules in force.
      #
      # config.allowed lifts any of them, but only for exactly that name:
      # allowing `help` frees `help`, not `help_desk`.
      #
      # A word in config.forbidden is matched as an impersonation
      # word and reported as :impersonation; :custom names a config.reserved
      # word that is not bundled. A reserved prefix (`.well-known`, `xn--`)
      # is reported as :exact.
      #
      # Last, after every list, config.reserved_if is asked about `name` —
      # the name as normalised, case kept in preserve mode — and a truthy
      # answer is :reserved_if. It runs on the checks the lists let
      # through, and whatever it raises is the app's.
      def verdict(key, rules, name = key)
        sets = sets_for(rules)
        return if sets.allowed.include?(key)

        listed(key, sets, rules) || (:reserved_if if rules.reserved_if&.call(name))
      end

      # Whether any spelling of the name is an impersonation entry: the name
      # exactly as typed (so a custom entry that is itself digits or
      # separators, `web3`, still forbids itself), and — as typed and
      # leet-folded — whole and without trailing digits (separators removed),
      # and every segment. The first spelling that is an entry answers, so
      # most names are refused or passed in a few lookups.
      def impersonation?(key, entries)
        return true if entries.include?(key)

        [key, leet(key)].uniq.any? do |form|
          entries.include?(form.delete(SEPARATORS)) ||
            entries.include?(form.sub(/\d+\z/, "").delete(SEPARATORS)) ||
            form.split(SEGMENT_BOUNDARY).any? { |segment| entries.include?(segment) }
        end
      end

      def prefix?(key)
        key.start_with?(*PREFIXES)
      end

      # The digit folds of data/offensive/leet.yml: 0→o 1→i 3→e 4→a 5→s 7→t.
      def leet(string)
        from, to = digit_folds
        string.tr(from, to)
      end

      # Where a bundled reserved word comes from, for `usernames:reserved`:
      # a Usernames::Data::Provenance (category, source, licence, reason),
      # or nil for a word the gem does not ship.
      def source_of(word)
        Data.reserved_provenance[word.to_s.downcase(:ascii)]
      end

      # The first path segment of every static route the app draws, collected
      # once and kept until reset_routes! (the engine calls it when routes
      # reload). Empty outside a Rails application.
      def routes
        @routes ||= rails_routes
      end

      def reset_routes!
        @routes = nil
      end

      # The app's own name as it would be typed: `config.app_name`
      # when it is a String, else the module of the Rails application —
      # `RecipeBox::Application` reserves `recipe_box` and
      # `recipebox`. None when opted out (`false`) or when there is no
      # named application.
      def app_names(rules)
        name = rules.app_name
        name = detected_app_name if name.nil?
        return [] unless name.is_a?(String)

        underscored = name.underscore.downcase(:ascii).gsub(/[^a-z0-9]+/, "_").gsub(/\A_+|_+\z/, "")
        [underscored, underscored.delete("_")].reject(&:empty?).uniq
      end

      private

      # The list that reserves `key`, in the order they are asked.
      def listed(key, sets, rules)
        if impersonation?(key, sets.impersonation) then :impersonation
        elsif sets.custom.include?(key) then :custom
        elsif sets.exact.include?(key) || prefix?(key) then :exact
        elsif rules.reserve_routes && routes.include?(key) then :route
        end
      end

      def sets_for(rules)
        rules.compiled(:reserved) do
          bundled = Data.reserved.to_set
          reserved = keys(rules.reserved)
          Sets.new(
            exact: (reserved & bundled).freeze,
            custom: (reserved - bundled).freeze,
            impersonation: impersonation_entries(keys(rules.forbidden) | app_names(rules)).freeze,
            allowed: keys(rules.allowed)
          )
        end
      end

      # Each word as the matcher stores it: itself, leet-folded, and the plural
      # of both; and, for an entry written with separators (`my_app`), the
      # same again without them — the name side is read without separators
      # too, and an entry with one could otherwise only ever match literally.
      def impersonation_entries(words)
        words.each_with_object(Set.new) do |word, entries|
          [word, word.delete(SEPARATORS)].uniq.each do |form|
            [form, leet(form)].each { |spelling| entries << spelling << "#{spelling}s" }
          end
        end
      end

      def keys(words)
        words.to_set { |word| word.strip.downcase(:ascii) }.freeze
      end

      def digit_folds
        @digit_folds ||= begin
          digits = Data.leet.fetch("digits")
          [digits.keys.join, digits.values.join].map(&:freeze).freeze
        end
      end

      def rails_routes
        return Set.new.freeze unless defined?(::Rails) && ::Rails.respond_to?(:application) && ::Rails.application

        Routes.collect(::Rails.application.routes)
      end

      # Rails::Application subclasses are named `<App>::Application`; one
      # defined at the top level (a script, a test) has no app name.
      def detected_app_name
        return unless defined?(::Rails) && ::Rails.respond_to?(:application) && ::Rails.application

        parent = ::Rails.application.class.module_parent
        parent.name unless parent == Object
      end
    end

    # The first path segment of an app's static routes, so a user
    # called `login` cannot take /login from under the app's feet.
    module Routes
      # What a route's first segment may be: anything a username could be.
      # Others (`@`, `~`) can never collide, so they are left out.
      SEGMENT = /\A[a-z0-9._-]+\z/

      class << self
        # The frozen Set of first segments from an ActionDispatch::Routing::RouteSet.
        #
        # Reads each route's Journey AST: a path of the form `/literal`, then
        # nothing, another `/`, or an optional group that starts with `/` or
        # `.` (`/login(.:format)`, `/bar(/:x)`). A literal followed directly by a
        # dot or a parameter (`/foo.:kind`, `/@:username`) is only part of a
        # dynamic segment, and `/:username`, `/*path` have no literal at all.
        # A mounted engine contributes its mount path, like any other route.
        def collect(route_set)
          route_set.routes.each_with_object(Set.new) do |route, segments|
            segment = first_segment(route.path.spec)
            segments << segment if segment
          end.freeze
        end

        private

        def first_segment(spec)
          slash, literal, following = flatten(spec)
          return unless slash&.type == :SLASH && literal&.type == :LITERAL && complete?(following)

          segment = literal.left.to_s.downcase(:ascii)
          segment if SEGMENT.match?(segment)
        end

        def complete?(node)
          case node&.type
          when nil, :SLASH then true
          when :GROUP then %i[SLASH DOT].include?(flatten(node.left).first&.type)
          else false
          end
        end

        # A Journey path is a right-leaning tree of Cat nodes; this reads it
        # as the list of nodes it spells, groups left whole.
        def flatten(node)
          node.type == :CAT ? flatten(node.left) + flatten(node.right) : [node]
        end
      end
    end
  end
end
