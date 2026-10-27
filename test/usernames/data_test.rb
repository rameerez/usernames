# frozen_string_literal: true

require "test_helper"
require "json"
require "yaml"

# Hygiene of the bundled data (PRD §9.4, §10.1, §12.1, §17, §20). Reads the files directly, not
# through the library, so a loader bug cannot hide a data bug.
module Usernames
  module DataFiles
    ROOT = File.expand_path("../..", __dir__)
    DATA = File.join(ROOT, "data")
    RESERVED = %w[impersonation system mailboxes web].freeze
    SOURCE = /\A# source: (\S+) \(([^)]+)\) — \S/

    module_function

    def path(relative) = File.join(DATA, relative)
    def plain(relative) = File.readlines(path(relative), chomp: true)

    # => [[source_name, [entries...]], ...]; an entry before any `# source:` line gets source nil
    def blocks(relative)
      plain(relative).each_with_object([]) do |line, out|
        next if line.strip.empty?

        if line.start_with?("# source:")
          out << [line[SOURCE, 1], [], line]
        elsif !line.start_with?("#")
          out << [nil, [], nil] if out.empty?
          out.last[1] << line.sub(/\s+#.*\z/, "")
        end
      end
    end

    def entries(relative) = blocks(relative).flat_map { |block| block[1] }
    def reserved(name) = entries("reserved/#{name}.txt")

    def corpus(name)
      File.readlines(File.join(ROOT, "test/corpora", name), chomp: true)
        .reject { |line| line.start_with?("#") || line.strip.empty? }.to_set
    end

    def offensive(locale) = JSON.parse(File.read(path("offensive/#{locale}.json")))
    def spellings(list) = list.flat_map { |entry| [entry["term"]] + entry["variants"] }
    def by_term(locale) = offensive(locale).to_h { |entry| [entry["term"], entry] }
    def severe_or_strong(locale) = spellings(offensive(locale).select { |entry| entry["severity"] >= 3 })

    def range(target) = (target * 0.75).floor..(target * 1.25).ceil
  end

  class ReservedDataTest < Minitest::Test
    include DataFiles

    TARGETS = { "impersonation" => 60, "system" => 90, "mailboxes" => 70, "web" => 1100 }.freeze
    FILES = (DataFiles::RESERVED + ["ALLOWLIST_EXCEPTIONS"]).freeze

    def test_every_entry_is_lowercase_ascii_with_a_letter
      FILES.each do |name|
        refute_empty reserved(name), name
        reserved(name).each do |word|
          assert_match(/\A[a-z0-9._-]+\z/, word, "#{name}: #{word.inspect}")
          assert_match(/[a-z]/, word, "#{name}: #{word} is all digits or has no letter")
        end
      end
    end

    def test_files_are_deduplicated_and_every_block_is_sorted_and_sourced
      FILES.each do |name|
        list = reserved(name)

        assert_equal list.uniq, list, "#{name}: duplicates #{list.tally.select { |_, n| n > 1 }.keys}"
        blocks("reserved/#{name}.txt").each do |source, words, header|
          refute_nil source, "#{name}: entries before any well-formed `# source:` comment (#{header})"
          assert_equal words.sort, words, "#{name}: block #{source} is not sorted"
        end
      end
    end

    def test_short_entries_are_only_the_meaningful_ones
      DataFiles::RESERVED.each do |name|
        short = reserved(name).select { |word| word.length <= 2 }

        assert_empty short - %w[me is it go my up], "#{name}: unexpected short entries"
      end
    end

    def test_web_never_repeats_a_word_of_another_category
      small = %w[impersonation system mailboxes].flat_map { |name| reserved(name) }.to_set

      assert_empty(reserved("web").select { |word| small.include?(word) })
    end

    def test_counts_are_near_the_prd_targets
      TARGETS.each { |name, target| assert_includes range(target), reserved(name).size, name }
    end

    def test_no_reserved_word_is_a_first_name_or_surname_unless_excepted
      names = corpus("first_names.txt") | corpus("surnames.txt")
      exceptions = reserved("ALLOWLIST_EXCEPTIONS").to_set
      DataFiles::RESERVED.each do |name|
        hits = reserved(name).select { |word| names.include?(word) && !exceptions.include?(word) }

        assert_empty hits, "#{name}: real names must not be reserved (give a reason in ALLOWLIST_EXCEPTIONS.txt or drop)"
      end
    end

    def test_the_known_name_collisions_stay_out_and_root_stays_in
      all = DataFiles::RESERVED.flat_map { |name| reserved(name) }

      assert_empty all & %w[nick mac page price win old list ping]
      assert_includes reserved("impersonation"), "root"
    end

    def test_allowlist_exceptions_carry_a_reason
      lines = plain("reserved/ALLOWLIST_EXCEPTIONS.txt").reject { |line| line.start_with?("#") || line.strip.empty? }

      refute_empty lines
      lines.each { |line| assert_match(/\A[a-z0-9._-]+ # \S.{10,}\z/, line) }
    end
  end

  class ProvenanceDataTest < Minitest::Test
    include DataFiles

    JSON_SOURCES = %w[dsojevic-profanity-list cuss allprofanity friendly-words petname imsky-wordlists corpora
                      usernames].freeze

    def notice_rows = File.read(path("NOTICE")).lines.grep(/\A[a-z0-9-]+ \| /)

    def comment_sources
      files = Dir[path("reserved/*.txt")] + Dir[path("offensive/allowlist/*.txt")]
      files.flat_map { |file| File.readlines(file, chomp: true).filter_map { |line| line[SOURCE, 1] } }.to_set
    end

    def test_every_source_is_in_notice_and_has_a_licence_file
      rows = notice_rows.to_set { |row| row[/\A([a-z0-9-]+) \| /, 1] }
      (comment_sources | JSON_SOURCES).each do |source|
        assert_includes rows, source, "#{source} has no row in data/NOTICE"
        assert_path_exists path("LICENSES/#{source}.txt")
      end
      rows.each { |row| assert_path_exists path("LICENSES/#{row}.txt") }
    end

    def test_notice_rows_have_all_six_fields
      refute_empty notice_rows
      notice_rows.each { |row| assert_equal 6, row.split(" | ").size, "name|URL|revision|licence|taken|how: #{row[0, 50]}" }
    end
  end

  class OffensiveDataTest < Minitest::Test
    include DataFiles

    KEYS = %w[exceptions severity tags term variants].freeze

    def test_entries_have_the_schema
      %w[en es].each do |locale|
        refute_empty offensive(locale)
        offensive(locale).each do |entry|
          assert_equal KEYS, (entry.keys - ["segment_only"]).sort, "#{locale}: #{entry['term']}"
          assert_includes 1..4, entry["severity"], "#{locale}: #{entry['term']}"
          assert_includes [true, nil], entry["segment_only"]
          assert_kind_of Array, entry["tags"] + entry["exceptions"]
        end
      end
    end

    def test_spellings_are_compact_ascii_and_never_repeated
      %w[en es].each do |locale|
        all = spellings(offensive(locale))

        all.each { |spelling| assert_match(/\A[a-z0-9]+\z/, spelling, "#{locale}: #{spelling.inspect}") }

        assert_equal all.uniq, all, "#{locale}: repeated spellings #{all.tally.select { |_, n| n > 1 }.keys}"
      end
    end

    def test_negro_is_blocked_in_no_locale
      %w[en es].each { |locale| assert_empty spellings(offensive(locale)).grep(/negro/), "D-20: #{locale}" }
      assert_includes corpus("legitimate.txt"), "negro"
    end

    def test_rape_and_rapist_are_segment_only
      %w[rape rapist].each { |term| assert_equal true, by_term("en").fetch(term)["segment_only"], term }
    end

    def test_promoted_slurs_are_severe_and_spic_is_not
      en = by_term("en")

      %w[kike faggot chink paki coon gook wetback tranny nigger cunt].each do |term|
        assert_equal 4, en.fetch(term)["severity"], term
      end
      assert_includes en.fetch("faggot")["variants"], "fagot"
      assert_equal 3, en.fetch("spic")["severity"]
    end

    def test_es_severe_is_slurs_only_and_never_a_scunthorpe_risk_substring
      severe = offensive("es").select { |entry| entry["severity"] == 4 }
      substring = spellings(severe.reject { |entry| entry["segment_only"] })

      assert_empty substring & %w[puta culo cu con cono pito puto marica]
      slur_tags = %w[homophobic transphobic racial ableist]

      assert_empty(severe.reject { |entry| entry["tags"].intersect?(slur_tags) }.map { |entry| entry["term"] })
    end

    def test_allowlists_hold_real_words_of_five_letters_or_more
      %w[en es].each do |locale|
        list = entries("offensive/allowlist/#{locale}.txt")

        refute_empty list
        assert_equal list.uniq, list
        list.each { |word| assert_match(/\A[a-z]{5,}\z/, word, "#{locale}: #{word.inspect}") }
        assert_empty list & spellings(offensive(locale)), "#{locale}: an allowlist entry must not be a term itself"
      end
    end

    def test_the_english_allowlist_keeps_the_documented_places_but_never_a_join
      en = entries("offensive/allowlist/en.txt")

      assert_empty %w[scunthorpe penistone clitheroe sussex cockburn] - en
      refute_includes en, "scunthorpeunited"
    end
  end

  class RulesDataTest < Minitest::Test
    include DataFiles

    def hate = YAML.load_file(path("offensive/hate.yml"))
    def leet = YAML.load_file(path("offensive/leet.yml"))

    def test_hate_rules_have_the_required_keys
      assert_equal %w[adjacent always digit_runs never whole_token], hate.keys.sort
      assert_equal %w[goyimdefense goyimknow heilhitler rahowa siegheil sonnenrad waffenss whitepower wpww],
                   hate["always"].sort
      assert_equal %w[1488 8814], hate["digit_runs"].sort
    end

    def test_hate_adjacency_and_tokens
      assert_equal %w[14 18 88], hate["adjacent"].keys.sort
      assert_includes hate["adjacent"]["88"], "hh"
      assert_equal %w[kkk zog], hate["whole_token"]["en"].sort
      assert_kind_of Array, hate["whole_token"]["es"]
    end

    def test_hate_never_list
      assert_equal %w[100 1312 14 18 311 420 69 88], hate["never"].sort
      assert_empty hate["never"] & hate["digit_runs"]
    end

    def test_leet_table_is_the_curated_subset
      assert_equal({ "0" => "o", "1" => "i", "3" => "e", "4" => "a", "5" => "s", "7" => "t" }, leet["digits"])
      assert_equal({ "vv" => "w", "ph" => "f", "x" => "ks" }, leet["offensive_only"])
    end
  end

  class WordsDataTest < Minitest::Test
    include DataFiles

    TARGETS = { "adjectives" => 400, "animals" => 250 }.freeze

    def words(name) = plain("words/#{name}.txt")

    def test_words_are_short_lowercase_letters_sorted_and_near_target
      TARGETS.each do |name, target|
        words(name).each { |word| assert_match(/\A[a-z]{3,10}\z/, word, "#{name}: #{word.inspect}") }

        assert_equal words(name).uniq.sort, words(name), "#{name}: not sorted/deduplicated"
        assert_includes range(target), words(name).size, name
      end
    end

    def test_no_word_contains_a_severity_three_or_four_term
      bad = severe_or_strong("en")

      TARGETS.each_key do |name|
        assert_empty words(name).select { |word| bad.any? { |term| word.include?(term) } }, name
      end
    end

    def test_reviewed_words_stay_out
      %w[booby beaver cock tit ass coon].each { |frag| assert_empty words("animals").grep(/#{frag}/), frag }
      assert_empty words("adjectives") & %w[holy hip whip angry bitter broken slimy grave skinny yellow apple chrome]
    end
  end
end
