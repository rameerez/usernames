#!/usr/bin/env ruby
# frozen_string_literal: true

# Diagnostic report: how the bundled data collides with the measurement corpora.
# Standalone — needs no gem code (the matcher lives in lib/ and is not loaded here).
#
#   ruby script/check_against_corpora.rb            # summary
#   ruby script/check_against_corpora.rb --verbose  # every colliding word
#
# Sections:
#   1. reserved/*.txt  vs first names, surnames (must be empty but for ALLOWLIST_EXCEPTIONS) and
#      the 50k dictionary sample (diagnostic: exact matches block that exact username only).
#   2. offensive/<loc>.json — strong/severe terms equal to a first name or surname; severe
#      substrings inside names and dictionary words (after allowlist and term exceptions).
#   3. words/*.txt — words that equal or contain a severity >= 3 term; adjective+animal pairs
#      that spell a severe term across the separator.
#   4. A REFERENCE APPROXIMATION of the PRD §10.2 matcher at :strong over legitimate.txt (gate: 0
#      rejected) and offensive.txt (gate: all rejected). It exists to sanity-check the data
#      before lib/ lands; the gem's own matcher and its tests are authoritative.

require "json"
require "yaml"

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

# --- offensive data ------------------------------------------------------------------------------
LEET = YAML.load_file(File.join(ROOT, "data/offensive/leet.yml"))
HATE = YAML.load_file(File.join(ROOT, "data/offensive/hate.yml"))

def fold(str)
  out = str.gsub(/[013457]/) { LEET["digits"].fetch(_1) }
  LEET["offensive_only"].each { |from, to| out = out.gsub(from, to) }
  out
end

Locale = Struct.new(:name, :severe, :strong, :exceptions, :allow) # severe/strong: folded spelling → term
LOCALES = %w[en es].map do |loc|
  data = JSON.parse(File.read(File.join(ROOT, "data/offensive/#{loc}.json")))
  severe = {}
  strong = {}
  exc = Hash.new { |h, k| h[k] = Set.new }
  data.each do |e|
    ([e["term"]] + e["variants"]).each do |s|
      f = fold(s)
      if e["severity"] == 4 then severe[f] = e
      elsif e["severity"] == 3 then strong[f] = e
      end
    end
    exc[e["term"]].merge(e["exceptions"].map { fold(_1) })
  end
  Locale.new(loc, severe, strong, exc, lines("data/offensive/allowlist/#{loc}.txt").to_set { fold(_1) })
end

# --- 2. offensive vs names / dictionary ----------------------------------------------------------
puts "\n2. Offensive terms"
LOCALES.each do |loc|
  puts " #{loc.name}.json (severe #{loc.severe.size} / strong #{loc.strong.size} folded spellings)"
  colliding = (loc.severe.keys + loc.strong.keys).select { |spelling| NAMES.include?(spelling) }.sort
  show("strong/severe spelling = first name/surname", colliding)
  sub = lambda do |word|
    next nil if loc.allow.include?(word)

    loc.severe.find do |s, e|
      next false if s.length <= 3 || e["segment_only"]

      word.include?(s) && !loc.exceptions[e["term"]].include?(word)
    end
  end
  show("names containing a severe substring", NAMES.select { sub.call(_1) }.sort)
  dict_hits = DICT.select { sub.call(_1) }.sort
  show("dictionary words containing a severe substring", dict_hits)
end

# --- 3. generator vocabulary ---------------------------------------------------------------------
puts "\n3. Generator words"
en = JSON.parse(File.read(File.join(ROOT, "data/offensive/en.json")))
bad = en.select { _1["severity"] >= 3 }.flat_map { [_1["term"]] + _1["variants"] }.uniq
adj = lines("data/words/adjectives.txt")
ani = lines("data/words/animals.txt")
{ "adjectives.txt" => adj, "animals.txt" => ani }.each do |file, words|
  show("#{file} (#{words.size}) containing a sev>=3 term", words.select { |w| bad.any? { w.include?(_1) } })
end
severe_all = LOCALES.flat_map { |l| l.severe.reject { |s, _| s.length <= 3 }.keys }
pairs = adj.product(ani).filter_map do |a, n|
  joined = fold(a + n)
  hit = severe_all.find { joined.include?(_1) && !fold(a).include?(_1) && !fold(n).include?(_1) }
  "#{a}_#{n}(#{hit})" if hit
end
show("adjective_animal pairs spelling a severe term", pairs)

# --- 4. reference matcher (approximation of PRD §10.2 at :strong) --------------------------------
SEP = /[_.-]+|\d+/

def segments_with_offsets(_compact_source, raw)
  # map each character of the compact (separator-free) string to its segment index
  idx = []
  seg = 0
  prev_sep = false
  raw.each_char do |c|
    if "_.-".include?(c)
      prev_sep = true
      next
    end
    seg += 1 if prev_sep
    prev_sep = false
    if c.match?(/\d/)
      idx << :digit
      seg += 1
    else
      idx << seg
    end
  end
  idx
end

def hate?(key, compact) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity
  return true if HATE["always"].any? { compact.include?(_1) }

  digit_runs = key.scan(/\d+/)
  return true if digit_runs.any? { HATE["digit_runs"].include?(_1) }
  return true if HATE["digit_runs"].any? { |n| key.match?(/(?<!\d)#{n[0, 2]}[_.-]#{n[2, 2]}(?!\d)/) }

  HATE["adjacent"].any? do |num, tokens|
    tokens.any? { |t| key.match?(/(?<!\d)#{num}(?!\d)[_.-]?#{Regexp.escape(t)}|#{Regexp.escape(t)}[_.-]?(?<!\d)#{num}(?!\d)/) }
  end || HATE["whole_token"].fetch("en", []).any? { |t| key.split(SEP).include?(t) }
end

# rubocop:disable-next Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity, Metrics/MethodLength
def rejection(raw)
  key = raw.downcase
  reps = [key, fold(key)]
  segs = reps.flat_map { _1.split(SEP) }.reject(&:empty?).uniq
  LOCALES.each do |loc|
    exempt = ->(seg, e) { loc.allow.include?(seg) || loc.exceptions[e["term"]].include?(seg) }
    segs.each do |seg|
      loc.severe.each do |s, e|
        short = s.length <= 3 || e["segment_only"]
        hit = short ? seg == s : seg.include?(s)
        return "#{loc.name}:severe:#{e['term']}" if hit && !exempt.call(seg, e)
      end
      e = loc.strong[seg]
      return "#{loc.name}:strong:#{e['term']}" if e && !exempt.call(seg, e)
    end
    reps.each do |rep|
      w = rep.delete("_.-")
      map = segments_with_offsets(w, rep)
      loc.severe.each_key do |s|
        next if s.length <= 3

        start = 0
        while (i = w.index(s, start))
          span = map[i, s.length].reject { _1 == :digit }.uniq
          return "#{loc.name}:severe-across:#{s}" if span.size >= 2

          start = i + 1
        end
      end
    end
  end
  "hate" if hate?(key, fold(key).delete("_.-"))
end

puts "\n4. Reference matcher at :strong (approximation; lib/ is authoritative)"
legit_rejected = LEGIT.filter_map { |w| (r = rejection(w)) && "#{w}(#{r})" }
show("legitimate.txt rejected (gate: 0)", legit_rejected)
first_rejected = (FIRST | SUR).sort.filter_map { |w| (r = rejection(w)) && "#{w}(#{r})" }
show("first names + surnames rejected (gate: 0)", first_rejected)
evasion_passed = EVASIONS.reject { rejection(_1) }
show("offensive.txt NOT rejected (gate: 0)", evasion_passed)
show("dictionary sample rejected (diagnostic)", DICT.select { rejection(_1) }.sort)
