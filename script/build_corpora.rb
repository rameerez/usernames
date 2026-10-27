#!/usr/bin/env ruby
# frozen_string_literal: true

# Builds the measurement corpora under test/corpora/ (never shipped in the gem):
#
#   first_names.txt   /usr/share/dict/propernames, lowercased
#   surnames.txt      US Census Bureau 2010 surnames, top 1,000 by rank (public domain)
#   words_en_50k.txt  every Nth word of /usr/share/dict/web2 (a–z, ≥ 3 letters), exactly 50,000
#   legitimate.txt    names and words the offensive matcher must accept (PRD §10.6)
#   offensive.txt     evasions the offensive matcher must reject (PRD §10.6)
#
#   ruby script/build_corpora.rb [path/to/Names_2010Census.csv]
#
# Without the CSV argument the script downloads the Census zip into a temporary directory.
# legitimate.txt reads data/offensive/en.json and es.json (if present) to leave out the few real
# names that are deliberately blocked terms (e.g. the surname Coon); run it after
# script/build_offensive_data.rb, and run build_offensive_data.rb after the first corpora build.

require "csv"
require "json"
require "tmpdir"

ROOT = File.expand_path("..", __dir__)
DIR = File.join(ROOT, "test/corpora")
CENSUS_URL = "https://www2.census.gov/topics/genealogy/2010surnames/names.zip"

def write(name, header, entries)
  File.write(File.join(DIR, name), "#{header.map { |line| "# #{line}" }.join("\n")}\n#{entries.join("\n")}\n")
  puts "#{name.ljust(18)} #{entries.size.to_s.rjust(6)}"
end

# --- first names ---------------------------------------------------------------------------------
first = File.readlines("/usr/share/dict/propernames", chomp: true).map { _1.strip.downcase }
  .grep(/\A[a-z]+\z/).uniq.sort
write("first_names.txt",
      ["source: /usr/share/dict/propernames (4.4BSD/FreeBSD word list; names are facts), lowercased",
       "Used by data_test.rb: no bundled reserved word may be a first name (PRD §9.4)."],
      first)

# --- surnames ------------------------------------------------------------------------------------
csv_path = ARGV[0]
tmp = nil
unless csv_path && File.exist?(csv_path)
  tmp = Dir.mktmpdir
  system("curl", "-sSfL", "-o", File.join(tmp, "names.zip"), CENSUS_URL, exception: true)
  system("unzip", "-q", "-o", File.join(tmp, "names.zip"), "Names_2010Census.csv", "-d", tmp, exception: true)
  csv_path = File.join(tmp, "Names_2010Census.csv")
end
surnames = CSV.foreach(csv_path, headers: true).first(1000).map { _1["name"].downcase }.grep(/\A[a-z]+\z/).uniq.sort
FileUtils.remove_entry(tmp) if tmp
write("surnames.txt",
      ["source: US Census Bureau, 2010 surnames, top 1,000 by rank (public domain, US Government work)",
       "URL: #{CENSUS_URL} (Names_2010Census.csv)",
       "Used by data_test.rb and the offensive legitimate gate; never shipped in the gem."],
      surnames)

# --- dictionary sample ---------------------------------------------------------------------------
web2 = File.readlines("/usr/share/dict/web2", chomp: true).map { _1.strip.downcase }
  .grep(/\A[a-z]{3,}\z/).uniq.sort
step = web2.size.fdiv(50_000)
sample = Array.new(50_000) { |i| web2[(i * step).floor] }
write("words_en_50k.txt",
      ["source: /usr/share/dict/web2 (Webster's Second International, 1934; copyright lapsed)",
       "Lowercase a-z, length >= 3, deduplicated, sorted; word i = list[floor(i * #{web2.size} / 50000)].",
       "Diagnostic only: dictionary-collision counts, never a gate."],
      sample)

# --- legitimate ----------------------------------------------------------------------------------
# Research 17 §4: the Wikipedia-verified names, places and words that contain a profanity
# substring (allowlist.tsv rows that are not from obscenity or dsojevic), transliterated to ASCII
# with spaces as `_`, plus the Scunthorpe probes and the handle-style probes of PRD §10.6.
tsv = File.join(ROOT, "docs/research/sources/offensive2/lists/allowlist/allowlist.tsv")
real = CSV.read(tsv, col_sep: "\t", headers: true, quote_char: "\u0000")
  .reject { _1["sources"].to_s.match?(/obscenity|dsojevic/) || _1["notes"].to_s.include?("unverified") }
  .map { _1["term"].unicode_normalize(:nfkd).gsub(/\p{Mn}/, "").downcase.strip.gsub(/\s+/, "_") }
  .grep(/\A[a-z0-9_]+\z/)
probes = %w[scunthorpe penistone clitheroe sussex cockburn assassin therapist grape shiitake classic
            analysis bass hello mike88 josh1979 gcastro mjordan chujew montenegro computadora negro
            scunthorpe_united]

# Real names that ARE a blocked term (severity >= 3) in a launch locale cannot pass by design;
# they are listed here, not silently dropped (the policy decision is recorded in data/offensive/README.md).
blocked = Set.new
%w[en es].each do |loc|
  path = File.join(ROOT, "data/offensive/#{loc}.json")
  next unless File.exist?(path)

  JSON.parse(File.read(path)).each do |e|
    next if e["severity"] < 3

    ([e["term"]] + e["variants"]).each { blocked << _1 }
  end
end
conflicts = real.select { |w| w.split("_").any? { blocked.include?(_1) } }
legit = (real - conflicts + probes).uniq.sort
write("legitimate.txt",
      ["Names, places and words the offensive matcher must ACCEPT at :strong (PRD §10.6 gate: 0 rejections).",
       "Sources: research 17 §4 Wikipedia-verified names/places (facts; non-ASCII transliterated, spaces as _),",
       "the Scunthorpe probes and handle-style probes (mike88, gcastro). Run on ASCII comparison keys.",
       "Left out because the name IS a blocked term (deliberate): #{conflicts.sort.join(' ')}"],
      legit)

# --- offensive / evasion -------------------------------------------------------------------------
offensive = %w[xxfuckxx f.u.c.k fu_ck sh1thead shithead1 shithead2 shithead_bob sh1thead_bob BigCunt
               n1gger 1488 14_88 hh88 heil_hitler scunt_horpe scunthorpe_fuck scunthorpeunited sus.sex
               cunt s.cunt.horpe gr_ape ther_apist kkk]
write("offensive.txt",
      ["Evasions the offensive matcher must REJECT at :strong (PRD §10.6 gate: 100 % rejected).",
       "Case is kept on purpose (BigCunt): the corpus is run through normalisation first."],
      offensive)
