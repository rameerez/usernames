#!/usr/bin/env ruby
# frozen_string_literal: true

# Diagnostic report: how the bundled data collides with the measurement corpora, through the
# gem's own matcher (lib/), so what it prints is what Usernames.check does.
#
#   bundle exec ruby script/check_against_corpora.rb            # summary
#   bundle exec ruby script/check_against_corpora.rb --verbose  # every colliding word
#
# Sections:
#   1. reserved/*.txt  vs first names, surnames (must be empty but for ALLOWLIST_EXCEPTIONS) and
#      the 50k dictionary sample (diagnostic: exact matches block that exact username only).
#   2. offensive/<loc>.json — strong/severe spellings equal to a first name or surname; names and
#      dictionary words each language's matcher refuses at :strong.
#   3. words/*.txt — words that equal or contain a severity >= 3 term; adjective_animal pairs
#      Usernames.check refuses at :strong (the generator's guarantee, also in words_test.rb).
#   4. The PRD §10.6 gates through Usernames.check at :strong: legitimate.txt and the name corpora
#      (gate: 0 refused by the offensive matcher) and offensive.txt (gate: all refused).

require "json"

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "usernames"

ROOT = File.expand_path("..", __dir__)
VERBOSE = ARGV.include?("--verbose")

def lines(path)
  File.readlines(File.join(ROOT, path), chomp: true).map { _1.sub(/\s+#.*\z/, "").strip }
    .reject { _1.empty? || _1.start_with?("#") }
end

def show(label, list)
  sample = VERBOSE ? list : list.first(25)
  more = list.size > sample.size ? " … (+#{list.size - sample.size})" : ""
  puts "  #{label.ljust(46)} #{list.size.to_s.rjust(5)}  #{sample.join(' ')}#{more}"
end

FIRST = lines("test/corpora/first_names.txt").to_set
SUR = lines("test/corpora/surnames.txt").to_set
DICT = lines("test/corpora/words_en_50k.txt").to_set
LEGIT = lines("test/corpora/legitimate.txt")
EVASIONS = lines("test/corpora/offensive.txt")
NAMES = FIRST | SUR

# --- 1. reserved ---------------------------------------------------------------------------------
puts "1. Reserved words"
exceptions = lines("data/reserved/ALLOWLIST_EXCEPTIONS.txt").to_set
%w[impersonation system mailboxes web].each do |cat|
  words = lines("data/reserved/#{cat}.txt")
  puts " #{cat}.txt (#{words.size})"
  show("first names (excl. exceptions)", words.select { FIRST.include?(_1) && !exceptions.include?(_1) })
  show("surnames (excl. exceptions)", words.select { SUR.include?(_1) && !exceptions.include?(_1) })
  show("kept by ALLOWLIST_EXCEPTIONS", words.select { NAMES.include?(_1) && exceptions.include?(_1) })
  show("dictionary words (diagnostic)", words.select { DICT.include?(_1) })
end

# --- 2. offensive vs names / dictionary ----------------------------------------------------------
LANGUAGES = %i[en es].freeze
ALL_SEPARATORS = %w[_ . -].freeze

# The offensive matcher alone, on the comparison key, as PRD §10.6 runs the corpora.
def refusal(name, **offensive)
  rules = Usernames.configuration.rules_for(separators: ALL_SEPARATORS, offensive: { severity: :strong, **offensive })
  Usernames::Offensive.verdict(rules.comparison_key(rules.normalize(name)), rules)
end

puts "\n2. Offensive terms"
LANGUAGES.each do |language|
  data = JSON.parse(File.read(File.join(ROOT, "data/offensive/#{language}.json")))
  spellings = data.select { _1["severity"] >= 3 }.flat_map { [_1["term"]] + _1["variants"] }
    .map { Usernames::Offensive.fold(_1) }.uniq
  puts " #{language}.json (#{spellings.size} strong/severe folded spellings)"
  show("strong/severe spelling = first name/surname", spellings.select { NAMES.include?(_1) }.sort)
  show("names refused (#{language} only)", NAMES.select { refusal(_1, languages: [language]) }.sort)
  show("dictionary words refused (#{language} only)", DICT.select { refusal(_1, languages: [language]) }.sort)
end

# --- 3. generator vocabulary ---------------------------------------------------------------------
puts "\n3. Generator words"
en = JSON.parse(File.read(File.join(ROOT, "data/offensive/en.json")))
bad = en.select { _1["severity"] >= 3 }.flat_map { [_1["term"]] + _1["variants"] }.uniq
adjectives = Usernames::Words::ADJECTIVES
animals = Usernames::Words::ANIMALS
{ "adjectives.txt" => adjectives, "animals.txt" => animals }.each do |file, words|
  show("#{file} (#{words.size}) containing a sev>=3 term", words.select { |w| bad.any? { w.include?(_1) } })
end
strong = Usernames.configuration.rules_for(offensive: { severity: :strong })
pairs = adjectives.product(animals).filter_map do |adjective, animal|
  name = "#{adjective}_#{animal}"
  failure = strong.failure_for(name)
  "#{name}(#{failure.rule || failure.reason})" if failure
end
show("adjective_animal pairs Usernames.check refuses", pairs)

# --- 4. the gates, through Usernames.check -------------------------------------------------------
puts "\n4. PRD §10.6 gates at :strong (Usernames.check and the offensive matcher)"
offensive_refusal = lambda do |name|
  result = Usernames.check(name, separators: ALL_SEPARATORS, offensive: { severity: :strong })
  verdict = refusal(name)
  "#{name}(#{verdict || result.rule})" if verdict || result.reason == :username_not_allowed
end
show("legitimate.txt refused (gate: 0)", LEGIT.filter_map(&offensive_refusal))
show("first names + surnames refused (gate: 0)", NAMES.sort.filter_map(&offensive_refusal))
passed = EVASIONS.select { |name| Usernames.check(name, separators: ALL_SEPARATORS).ok? || !refusal(name) }
show("offensive.txt NOT refused (gate: 0)", passed)
show("dictionary sample refused (diagnostic)", DICT.select { refusal(_1) }.sort)
