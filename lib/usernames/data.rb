# frozen_string_literal: true

require "json"
require "yaml"

module Usernames
  # The word lists that ship in data/, read once per process and frozen.
  #
  # Every list is a plain text file, one entry per line; blank lines and
  # `#` comments (which carry each block's source and reason, see
  # data/NOTICE) are skipped. A file that is not there reads as an empty
  # list, so the gem still loads from a checkout whose data has not been
  # built yet — the configuration then simply starts from nothing.
  #
  # Note the name: inside `module Usernames`, `Data` is this module. Ruby's
  # own value-object class is `::Data`, and the gem always spells it so.
  module Data
    ROOT = File.expand_path("../../data", __dir__)

    # Matched exactly (PRD §9.1): system words, mailboxes, web paths.
    EXACT_FILES = %w[reserved/system.txt reserved/mailboxes.txt reserved/web.txt].freeze

    # Matched the way impersonators type them (PRD §9.2).
    IMPERSONATION_FILES = %w[reserved/impersonation.txt].freeze

    # `# source: gitlab (MIT) — GitLab top-level and project wildcard routes`
    SOURCE_LINE = /\A#\s*source:\s*(?<name>\S+)\s+\((?<licence>[^)]+)\)\s*(?:—\s*(?<reason>.*))?\z/

    # Where one bundled reserved word comes from: its file (:impersonation,
    # :system, :mailboxes, :web) and the `# source:` comment of its block.
    Provenance = ::Data.define(:category, :source, :licence, :reason)

    class << self
      # What `config.reserved` starts from.
      def reserved
        @reserved ||= EXACT_FILES.flat_map { |file| list(file) }.uniq.freeze
      end

      # What `config.forbidden` starts from.
      def impersonation
        @impersonation ||= IMPERSONATION_FILES.flat_map { |file| list(file) }.uniq.freeze
      end

      # { word => Provenance } over every bundled reserved file. The
      # impersonation file is read first: a word in it and in a mailbox list
      # (`postmaster`) is matched the stricter way, so that is its source.
      def reserved_provenance
        @reserved_provenance ||= (IMPERSONATION_FILES + EXACT_FILES).each_with_object({}) do |file, words|
          category = File.basename(file, ".txt").to_sym
          sourced(file).each { |word, source| words[word] ||= Provenance.new(category: category, **source) }
        end.freeze
      end

      # The generator's vocabulary (PRD §12.1).
      def adjectives
        @adjectives ||= list("words/adjectives.txt")
      end

      # data/words/animals.txt, published as Usernames::Words::ANIMALS.
      def nouns
        @nouns ||= list("words/animals.txt")
      end

      # The languages whose offensive words ship (data/offensive/<locale>.json),
      # as symbols: what config.offensive.languages may name.
      def available_locales
        @available_locales ||= Dir[File.join(ROOT, "offensive", "*.json")]
          .map { |path| File.basename(path, ".json").to_sym }.sort.freeze
      end

      # The parsed entries of data/offensive/<locale>.json, or [] for a
      # language that ships no data.
      def offensive(locale)
        (@offensive ||= {})[locale.to_sym] ||= begin
          path = File.expand_path("offensive/#{locale}.json", ROOT)
          File.file?(path) ? deep_freeze(JSON.parse(File.read(path))) : [].freeze
        end
      end

      # data/offensive/allowlist/<locale>.txt (each line `word # source`).
      def allowlist(locale)
        (@allowlist ||= {})[locale.to_sym] ||= list("offensive/allowlist/#{locale}.txt")
      end

      # data/offensive/hate.yml (PRD §10.3).
      def hate
        @hate ||= yaml("offensive/hate.yml")
      end

      # data/offensive/leet.yml: the digit folds both matchers use, and the
      # rewrites only the offensive matcher uses.
      def leet
        @leet ||= yaml("offensive/leet.yml")
      end

      # The entries of one data file, relative to data/ (or an absolute path).
      def list(path)
        path = File.expand_path(path, ROOT)
        return [].freeze unless File.file?(path)

        File.foreach(path, chomp: true).filter_map do |line|
          entry = line.sub(/#.*/, "").strip
          entry.freeze unless entry.empty?
        end.freeze
      end

      # [[entry, { source:, licence:, reason: }], …] for one data file: each
      # entry with the `# source:` comment of the block it sits in (nils for
      # an entry before any).
      def sourced(path)
        path = File.expand_path(path, ROOT)
        return [] unless File.file?(path)

        source = { source: nil, licence: nil, reason: nil }
        File.foreach(path, chomp: true).filter_map do |line|
          if (match = SOURCE_LINE.match(line.strip))
            source = { source: match[:name], licence: match[:licence], reason: match[:reason] }
            next
          end
          entry = line.sub(/#.*/, "").strip
          [entry, source] unless entry.empty?
        end
      end

      private

      def yaml(relative)
        path = File.expand_path(relative, ROOT)
        deep_freeze(File.file?(path) ? YAML.safe_load_file(path) || {} : {})
      end

      def deep_freeze(value)
        case value
        when Hash then value.each_value { |item| deep_freeze(item) }
        when Array then value.each { |item| deep_freeze(item) }
        end
        value.freeze
      end
    end
  end
end
