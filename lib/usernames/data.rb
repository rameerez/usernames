# frozen_string_literal: true

require "json"
require "yaml"

module Usernames
  # The word lists that ship in data/, read once per process and frozen.
  #
  # Every list is a plain text file, one entry per line; blank lines and
  # `#` comments (which carry each block's source and reason, see
  # data/NOTICE) are skipped. Every file is mandatory: one that is missing,
  # empty or malformed raises Usernames::DataError when the gem loads, since
  # the alternative — rules that silently check nothing — fails open.
  #
  # Note the name: inside `module Usernames`, `Data` is this module. Ruby's
  # own value-object class is `::Data`, and the gem always spells it so.
  module Data
    ROOT = File.expand_path("../../data", __dir__)

    # The lists every offensive entry carries, besides its term and severity.
    TERM_LISTS = %w[variants tags exceptions].freeze

    # Matched exactly: system words, mailboxes, web paths.
    EXACT_FILES = %w[reserved/system.txt reserved/mailboxes.txt reserved/web.txt].freeze

    # Matched the way impersonators type them.
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

      # The generator's vocabulary.
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
        @available_locales ||= begin
          locales = Dir[File.join(ROOT, "offensive", "*.json")].map { |path| File.basename(path, ".json").to_sym }
          broken!(File.join(ROOT, "offensive"), "holds no <locale>.json word list") if locales.empty?
          locales.sort.freeze
        end
      end

      # The parsed entries of data/offensive/<locale>.json: each a Hash with
      # a "term", a "severity" from 1 to 4, and lists of "variants", "tags"
      # and "exceptions". An empty list is as broken as a missing file: it
      # would screen nothing in that language.
      def offensive(locale)
        (@offensive ||= {})[locale.to_sym] ||= read("offensive/#{locale}.json") do |path|
          entries = JSON.parse(File.read(path))
          broken!(path, "has no entries") if entries == []
          unless entries.is_a?(Array) && entries.all? { |entry| term?(entry) }
            broken!(path, "is not a list of {term, severity 1–4, variants, tags, exceptions} entries")
          end

          deep_freeze(entries)
        end
      end

      # data/offensive/allowlist/<locale>.txt (each line `word # source`).
      def allowlist(locale)
        (@allowlist ||= {})[locale.to_sym] ||= list("offensive/allowlist/#{locale}.txt")
      end

      # data/offensive/hate.yml: the hate tokens and number rules.
      def hate
        @hate ||= yaml("offensive/hate.yml", "always" => Array, "digit_runs" => Array, "adjacent" => Hash,
                                             "whole_token" => Hash)
      end

      # data/offensive/leet.yml: the digit folds both matchers use, and the
      # rewrites only the offensive matcher uses.
      def leet
        @leet ||= yaml("offensive/leet.yml", "digits" => Hash, "offensive_only" => Hash)
      end

      # The entries of one data file, relative to data/ (or an absolute path).
      def list(path)
        read(path) do |file|
          entries = File.foreach(file, chomp: true).filter_map do |line|
            entry = line.sub(/#.*/, "").strip
            entry.freeze unless entry.empty?
          end
          broken!(file, "has no entries") if entries.empty?
          entries.freeze
        end
      end

      # [[entry, { source:, licence:, reason: }], …] for one data file: each
      # entry with the `# source:` comment of the block it sits in (nils for
      # an entry before any).
      def sourced(path)
        read(path) do |file|
          source = { source: nil, licence: nil, reason: nil }
          File.foreach(file, chomp: true).filter_map do |line|
            if (match = SOURCE_LINE.match(line.strip))
              source = { source: match[:name], licence: match[:licence], reason: match[:reason] }
              next
            end
            entry = line.sub(/#.*/, "").strip
            [entry, source] unless entry.empty?
          end
        end
      end

      # Reads every bundled file once, so a broken install fails when the gem
      # loads rather than on the first sign-up that needs the missing list.
      def load!
        reserved
        impersonation
        reserved_provenance
        adjectives
        nouns
        available_locales.each do |locale|
          offensive(locale)
          allowlist(locale)
        end
        hate
        leet
        self
      end

      private

      def read(relative)
        path = File.expand_path(relative, ROOT)
        broken!(path, "is missing") unless File.file?(path)

        yield path
      rescue JSON::ParserError, Psych::Exception => e
        broken!(path, "can't be parsed (#{e.message.lines.first.strip})")
      end

      # A YAML mapping with at least `shape`'s keys, each of its type.
      def yaml(relative, shape)
        read(relative) do |path|
          data = YAML.safe_load_file(path)
          wrong = shape.find { |key, type| !(data.is_a?(Hash) && data[key].is_a?(type)) }
          broken!(path, "needs #{wrong[0].inspect} (a #{wrong[1].name})") if wrong

          deep_freeze(data)
        end
      end

      def term?(entry)
        entry.is_a?(Hash) && entry["term"].is_a?(String) && !entry["term"].empty? &&
          entry["severity"].is_a?(Integer) && (1..4).cover?(entry["severity"]) &&
          term_lists?(entry) && [nil, true, false].include?(entry["segment_only"])
      end

      def term_lists?(entry)
        TERM_LISTS.all? { |key| entry[key].is_a?(Array) && entry[key].all?(String) }
      end

      def broken!(path, problem)
        raise DataError, "usernames' bundled data is broken: #{path} #{problem}. " \
                         "Reinstall the gem, or rebuild data/ with script/build_*.rb in a checkout."
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
