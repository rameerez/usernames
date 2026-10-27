#!/usr/bin/env ruby
# frozen_string_literal: true

# Builds data/offensive/{en,es}.json and data/offensive/allowlist/{en,es}.txt (PRD §10.1).
#
#   ruby script/build_offensive_data.rb
#
# Entry schema: {"term", "severity" 1–4, "variants" [], "tags" [], "exceptions" [], "segment_only"?}
#   severity 4 = severe (substring, PRD §10.2 a-1/a-2) · 3 = strong (whole segment) · 1–2 = mild.
#   segment_only: true — a severe term that must EQUAL a segment (rape, rapist; Scunthorpe-risk
#     slurs such as es `puto` ⊂ computo). Terms of ≤ 3 letters are segment-only by rule, not flag.
#   variants: compact ASCII spellings (spaces/hyphens/dots removed), including dsojevic's `*`
#     stretches (each starred letter repeated up to 3 extra times). Leet-folded spellings are NOT
#     stored: the matcher folds terms and input identically at load time.
#   exceptions: term-scoped exemption segments (dsojevic `exceptions` with `*` = the term, plus
#     the dictionary words this build found that a promoted severe term would otherwise reject).
#
# Hard rule (D-20): `negro` is blocked in no locale; the build aborts if it appears anywhere.

require "json"

ROOT = File.expand_path("..", __dir__)
SRC = File.join(ROOT, "docs/research/sources")
OUT = File.join(ROOT, "data/offensive")
STRETCH = 3

def compact(str) = str.downcase.unicode_normalize(:nfkd).gsub(/\p{Mn}/, "").gsub(/[\s\-.'’]/, "")
def ascii_term?(str) = str.match?(/\A[a-z0-9]+\z/)
def words(str) = str.split

# "fu*c*k" → fuck, fuuck, …, fuuuucccck (every starred letter 1 + 0..STRETCH times)
def expand(pattern)
  parts = pattern.scan(/.\*?/).map { |p| p.end_with?("*") ? (0..STRETCH).map { p[0] * (_1 + 1) } : [p] }
  parts.reduce([""]) { |acc, opts| acc.product(opts).map(&:join) }
end

# ================================================================================================
# en — dsojevic/profanity-list (MIT), re-tiered per PRD §10 / research 06
# ================================================================================================
SEGMENT_ONLY_EN = %w[rape].freeze
PROMOTED = words("kike faggot chink paki coon gook wetback tranny") # → severity 4 (spic stays 3)
NEVER = %w[negro] # D-20

# The maintainers' review of dsojevic's tiers (2026-10-27), by dsojevic id.
#   Not slurs at all: identity terms people use for themselves.
NOT_OFFENSIVE = %w[enby cishet].freeze
#   Re-tiered. Up: unambiguous racial abuse that sat in the disabled-by-default tiers — four letters
#   or more is severe (matched inside a name), three letters strong (only a whole segment, so `japan`
#   and `wogan` pass). Down to mild (off by default): words that are also real names or ordinary
#   words — Pansy and Cissy (given names), Hermie (a nickname), Santorum and Finocchio (surnames;
#   finocchio is also Italian for fennel), Shota (a common Japanese given name, Shōta).
RETIERED = {
  "ching-chong" => 4, "neonazi" => 4, "jap" => 3, "wog" => 3,
  "pansy" => 2, "cissy" => 2, "hermie" => 2, "santorum" => 2, "finocchio" => 2, "shota" => 2
}.freeze

# Dictionary words (web2 / propernames / Census surnames) that a promoted or severe substring
# term would reject; found by this build's own scan (see script/check_against_corpora.rb).
EXTRA_EXCEPTIONS = {
  "chink" => words("chinkara chinker chinkerinchee chinkle unchinked"),
  "coon" => words("cacoon carcoon cocoon cocoonery cocoons coonily cooniness coonroot") +
            words("coontail coony flocoon racoon scoon"),
  "cunt" => words("eduskunta placuntitis placuntoma pokunt"),
  "faggot" => words("contrafagotto fagoter fagoting fagottino fagottist fagoty unfagoted esophagotome esophagotomy"),
  "nigger" => words("snigger sniggered sniggerer sniggering sniggers"),
  "paki" => words("pakistan pakistani pakistanis rapakivi")
}.freeze

dsojevic = JSON.parse(File.read(File.join(SRC, "offensive/dsojevic_json")))
en = []
dropped = []
dsojevic.each do |row| # rubocop:disable Metrics/BlockLength
  id = row["id"]
  alts = row["match"].split("|")
  if NEVER.include?(id) || alts.any? { compact(_1.delete("*")).include?("negro") }
    dropped << "#{id} (D-20)"
    next
  end
  if NOT_OFFENSIVE.include?(id)
    dropped << "#{id} (not offensive)"
    next
  end
  spellings = alts.flat_map { expand(compact(_1)) }.select { ascii_term?(_1) }.uniq
  if spellings.empty?
    dropped << "#{id} (no ASCII spelling)"
    next
  end
  severity = PROMOTED.include?(id) ? 4 : RETIERED.fetch(id, row["severity"])
  exceptions = (row["exceptions"] || []).map { compact(_1.gsub("*", id)) }.select { ascii_term?(_1) }
  exceptions |= EXTRA_EXCEPTIONS.fetch(id, [])
  tags = row["tags"].sort

  # rape/rapist: whole-segment only (PRD §10.2 a-1). dsojevic files `rapist` under `raping`;
  # split it out so both carry the flag. `raping` also gets it: as a substring it rejects
  # scraping/skyscraping (research 06, second pass).
  if id == "raping"
    en << { "term" => "raping", "severity" => severity, "variants" => [], "tags" => tags, "exceptions" => [],
            "segment_only" => true }
    en << { "term" => "rapist", "severity" => severity, "variants" => [], "tags" => tags, "exceptions" => [],
            "segment_only" => true }
    next
  end

  term = spellings.include?(compact(id)) ? compact(id) : compact(alts.first.delete("*"))
  entry = { "term" => term, "severity" => severity, "variants" => (spellings - [term]).sort,
            "tags" => tags, "exceptions" => exceptions.uniq.sort }
  entry["segment_only"] = true if SEGMENT_ONLY_EN.include?(term)
  en << entry
end

# A spelling listed under two dsojevic ids (e.g. `strapon`) stays with the stricter entry only.
seen = Set.new
merged = []
en = en.sort_by { [-_1["severity"], _1["term"]] }.filter_map do |e|
  own = ([e["term"]] + e["variants"]).reject { seen.include?(_1) }
  merged << e["term"] if own.size < 1 + e["variants"].size
  next if own.empty?

  seen.merge(own)
  term = own.include?(e["term"]) ? e["term"] : own.first
  e.merge("term" => term, "variants" => own - [term])
end
puts "en: spellings shared between dsojevic ids, kept with the stricter one: #{merged.join(' ')}"

# An exception that is itself a blocked spelling would exempt the very thing a tier refuses:
# dsojevic lists `spicks` as both a variant and an exception of `spic`, and `blackcock` as an
# exception of `cock` while it is a strong term of its own. The tier wins; the exception goes.
spellings = en.flat_map { [_1["term"], *_1["variants"]] }.to_set
en.each do |e|
  blocked = e["exceptions"].select { spellings.include?(_1) }
  next if blocked.empty?

  puts "en: exceptions of #{e['term']} that are blocked spellings, dropped: #{blocked.join(' ')}"
  e["exceptions"] = e["exceptions"] - blocked
end

# ================================================================================================
# es — wooorm/cuss es (MIT) + AllProfanity spanish (MIT), tiered by hand from the research
# candidates (docs/research/sources/offensive2/lists/severe_candidates/es.tsv). Reviewed 2026-10-27
# by a Spanish-speaking reviewer (data/offensive/README.md).
# ================================================================================================
# [term, variants, tags, segment_only]
ES_SEVERE = [
  ["maricon", %w[maricones], %w[homophobic]],
  ["maricona", %w[mariconas], %w[homophobic]],
  ["marikon", %w[marikones], %w[homophobic]],
  ["mariconazo", %w[mariconazos], %w[homophobic]],
  ["marica", %w[maricas], %w[homophobic], true],       # ⊂ tamaricaceae (MED risk)
  ["puto", %w[putos], %w[homophobic], true],           # ⊂ computo, caputo, esputo, maputo (MED risk)
  ["joto", %w[jotos], %w[homophobic]],
  ["bujarron", %w[bujarrones bujarra], %w[homophobic]],
  ["machorra", %w[machorras], %w[homophobic]],
  ["marimacho", %w[marimachos], %w[homophobic]],
  ["tortillera", %w[tortilleras], %w[homophobic]],
  ["bollera", %w[bolleras], %w[homophobic]],
  ["travelo", %w[travelos], %w[transphobic], true],    # ⊂ travelogue (MED risk)
  ["sudaca", %w[sudacas], %w[racial]],
  ["negrata", %w[negratas], %w[racial]],
  ["mongolico", %w[mongolicos mongolica mongolicas], %w[ableist]],
  ["mongolo", %w[mongolos mongola mongolas], %w[ableist], true], # ⊂ mongoloid (MED risk)
  ["sidoso", %w[sidosos sidosa sidosas], %w[ableist]],
  ["chinorris", [], %w[racial]]
].freeze

ES_STRONG = [
  ["mierda", %w[mierdas mierdoso mierdosa], %w[general]],
  ["comemierda", %w[comemierdas], %w[insult]],
  ["joder", %w[jodido jodida jodete jodienda], %w[general]],
  ["puta", %w[putas putita putazo putero putona putamadre], %w[sexual insult]], # ⊂ computadora: never substring
  ["hijoputa", %w[hijodeputa hijadeputa hijueputa], %w[insult]],
  ["malparido", %w[malparida malnacido malnacida], %w[insult]],
  ["cono", [], %w[sexual]], # coño; ⊂ economia: never substring
  ["cojones", [], %w[sexual]],
  ["polla", %w[pollas], %w[sexual]],
  ["verga", %w[vergas vergazo], %w[sexual]],
  ["picha", [], %w[sexual]],
  # Not here (reviewer pass, 2026-10-27): "cipote" means "kid" in Central America; "pija" is just
  # "posh" in Spain (mild below).
  ["pinga", [], %w[sexual]],
  ["poronga", [], %w[sexual]],
  ["chocho", [], %w[sexual]],
  ["panocha", [], %w[sexual]],
  ["culo", %w[culos], %w[sexual]],                           # ⊂ ridiculo, articulo: never substring
  ["culero", [], %w[insult]],
  ["culear", %w[culeado], %w[sexual]],
  ["follar", %w[follador], %w[sexual]],
  ["gilipollas", %w[jilipollas], %w[insult]],
  ["cabron", %w[cabrona cabrones cabronazo cabronaza], %w[insult]],
  ["pendejo", %w[pendeja], %w[insult]],
  ["pelotudo", %w[pelotuda], %w[insult]],
  ["chingar", %w[chingado chingada chingadera], %w[general]],
  ["mamon", %w[mamona], %w[insult]],
  ["mamada", [], %w[sexual]],
  ["mamahuevo", %w[mamahuevos], %w[insult]],
  ["lameculos", [], %w[insult]],
  ["chupapollas", [], %w[insult]],
  ["soplapollas", [], %w[insult]],
  ["ojete", [], %w[sexual]],
  ["pajero", %w[pajearse], %w[sexual]],
  ["violador", [], %w[sexual]],
  ["subnormal", [], %w[ableist]],                            # ⊂ subnormality: never substring
  ["gabacho", %w[gabachos], %w[racial]]
].freeze

ES_MILD = [
  ["idiota", [], %w[insult]], ["imbecil", %w[imbeciles], %w[insult]], ["estupido", %w[estupida], %w[insult]],
  ["cretino", %w[cretina], %w[insult]], ["tarado", %w[tarada], %w[insult]], ["retrasado", %w[retrasada], %w[ableist]],
  ["boludo", %w[boluda], %w[insult]], ["huevon", %w[huevona], %w[insult]], ["capullo", [], %w[insult]],
  ["carajo", [], %w[general]], ["hostia", %w[ostia], %w[general]], ["cagar", %w[cagada cagado], %w[general]],
  ["cagon", %w[cagona], %w[insult]], ["zorra", [], %w[insult]], ["perra", [], %w[insult]],
  ["ramera", [], %w[insult]], ["prostituta", %w[prostituto], %w[sexual]],
  ["orto", [], %w[sexual]], ["teta", %w[tetas], %w[sexual]], ["pija", [], %w[sexual]],
  ["paja", [], %w[sexual]], ["pito", [], %w[sexual]], ["pedo", [], %w[general]],
  ["guarro", %w[guarra], %w[insult]], ["cornudo", [], %w[insult]], ["baboso", %w[babosa], %w[insult]],
  ["zopenco", %w[zopenca], %w[insult]], ["zoquete", [], %w[insult]], ["mentecato", [], %w[insult]],
  ["majadero", [], %w[insult]], ["mequetrefe", [], %w[insult]], ["papanatas", [], %w[insult]],
  ["pazguato", [], %w[insult]], ["cenutrio", [], %w[insult]], ["ceporro", [], %w[insult]],
  ["energumeno", [], %w[insult]], ["malandro", [], %w[insult]], ["mamarla", [], %w[sexual]],
  ["pajearse", [], %w[sexual]], ["sexo", [], %w[sexual]], ["vulva", [], %w[sexual]],
  ["violar", [], %w[sexual]], ["pinche", [], %w[general]],
  ["gilipuertas", [], %w[insult]]
  # Deliberately absent, even at mild (reviewer pass, 2026-10-27): "concha" is a common female name
  # (Concepción) and a seashell; "coger" is the everyday verb "to take" in Spain; "huevos" is
  # "eggs"; "semen" is a Ukrainian first name; "panchito" is a nickname for Francisco.
].freeze

# Every es term must be attested in a permissive source (or the research's severe candidates).
cuss_es = File.read(File.join(SRC, "offensive2/lists/raw/cuss/es.js")).scan(/^\s*["']?([^:"'\n]+?)["']?:\s*\d/).flatten
allprof_es = File.read(File.join(SRC, "offensive2/lists/raw/allprof/spanish.ts")).scan(/^\s*"([^"]+)"/).flatten
candidates_es = File.readlines(File.join(SRC, "offensive2/lists/severe_candidates/es.tsv"), chomp: true)
  .reject { _1.start_with?("#", "term\t") }.map { _1.split("\t").first }
ATTESTED = (cuss_es + allprof_es + candidates_es).to_set { compact(_1) }

def es_entries(rows, severity)
  rows.map do |term, variants, tags, seg|
    entry = { "term" => term, "severity" => severity, "variants" => variants.sort, "tags" => tags.sort,
              "exceptions" => [] }
    entry["segment_only"] = true if seg
    entry
  end
end
es = es_entries(ES_SEVERE, 4) + es_entries(ES_STRONG, 3) + es_entries(ES_MILD, 2)
# pajearse appears as a strong variant and a mild term: the strictest tier wins
strong_spellings = es.select { _1["severity"] >= 3 }.flat_map { [_1["term"]] + _1["variants"] }.to_set
es.reject! { _1["severity"] < 3 && strong_spellings.include?(_1["term"]) }
unattested = es.flat_map { [_1["term"]] + _1["variants"] }.reject { ATTESTED.include?(_1) }

# ================================================================================================
# Checks and output
# ================================================================================================
{ "en" => en, "es" => es }.each do |loc, list|
  spellings = list.flat_map { [_1["term"]] + _1["variants"] }
  abort "#{loc}: negro present (D-20)" if spellings.any? { _1.include?("negro") }
  dups = spellings.tally.select { |_, n| n > 1 }.keys
  abort "#{loc}: duplicate spellings #{dups.inspect}" if dups.any?
  list.sort_by! { [-_1["severity"], _1["term"]] }
  File.write(File.join(OUT, "#{loc}.json"), "#{JSON.pretty_generate(list)}\n")
  tiers = list.group_by { _1["severity"] }.sort.reverse.map { |s, l| "sev#{s}=#{l.size}" }.join(" ")
  puts "#{loc}.json: #{list.size} terms (#{tiers}), #{spellings.size} spellings"
end
puts "en dropped: #{dropped.join(', ')}"
puts "es spellings not attested verbatim in cuss/AllProfanity/candidates: #{unattested.join(' ')}"

# ================================================================================================
# Allowlists — real words/names ≥ 5 letters (PRD §10.1); fragments rejected at build time
# ================================================================================================
web2 = File.readlines("/usr/share/dict/web2", chomp: true).to_set(&:downcase)
names = %w[first_names surnames].flat_map { File.readlines(File.join(ROOT, "test/corpora/#{_1}.txt"), chomp: true) }
  .reject { _1.start_with?("#") }.to_set
REAL_EXTRA = words("montenegro negron turducken analog benedick dickety dickory kungfu shitake stoneground vandyke coonhound") # real, absent from web2

def blocked_spellings(list) = list.flat_map { [_1["term"]] + _1["variants"] }.to_set

allow_path = File.join(SRC, "offensive2/lists/allowlist/allowlist.tsv")
allow_rows = File.readlines(allow_path, chomp: true).drop(1).map { |row| row.split("\t") }
real_word = ->(word) { web2.include?(word) || names.include?(word) || REAL_EXTRA.include?(word) }
en_blocked = blocked_spellings(en)
en_allow = {}
rejected = Hash.new { |h, k| h[k] = [] }
allow_rows.each do |row|
  term, type, _hits, _web2, sources, notes = row
  word = compact(term.to_s)
  source = if sources.to_s.include?("obscenity") then "obscenity"
           elsif sources.to_s.include?("dsojevic") then "dsojevic-profanity-list"
           else "usernames"
           end
  reason =
    if notes.to_s.include?("unverified") then :unverified
    elsif term.to_s.match?(/\s/) && !web2.include?(word) && !REAL_EXTRA.include?(word)
      :multiword # joining would manufacture `scunthorpeunited`; kept only when the join is itself a word
    elsif !word.match?(/\A[a-z]+\z/) then :not_letters
    elsif word.length < 5 then :too_short
    elsif en_blocked.include?(word) then :is_a_blocked_term
    elsif source == "obscenity" && !real_word.call(word) then :fragment
    end
  if reason
    rejected[reason] << word
    next
  end
  label = source == "usernames" ? "usernames (Wikipedia-verified #{type}, research 17 §4)" : source
  en_allow[word] ||= label
end

en_header = <<~TXT
  # Offensive-word allowlist, en: real words and names (>= 5 letters) that contain a blocked
  # substring. An entry exempts a whole segment only (PRD §10.2). `<word> # <source>` per line.
  # Generated by script/build_offensive_data.rb from docs/research/sources/offensive2/lists/allowlist/.
  # source: obscenity (MIT) — whitelisted terms of the English preset
  # source: dsojevic-profanity-list (MIT) — the `exceptions` of en.json, expanded
  # source: usernames (MIT) — Wikipedia-verified names, places and words (names as facts)
TXT
File.write(File.join(OUT, "allowlist/en.txt"), "#{en_header}#{en_allow.sort.map { |w, s| "#{w} # #{s}" }.join("\n")}\n")
puts "allowlist/en.txt: #{en_allow.size}"
rejected.each { |why, list| puts "  rejected #{why} (#{list.size}): #{list.uniq.sort.join(' ')}" }

# es: Spanish words that embed an es term (from the research's FrequencyWords scan, facts only),
# plus Spanish-language names from the research's real-name set.
es_blocked = blocked_spellings(es)
es_words = words(<<~W)
  computadora computadoras computador reputacion disputa diputado amputar caputo esputo computo
  maputo ridiculo espectaculo articulo articulos vehiculo circulo desconocido reconocer reconocimiento
  economia gilipollez empollar ampolla ampollas recoger escoger repito papito capitolio chupito
  envergadura encabronado montenegro negron
W
es_allow = es_words.uniq.select { _1.length >= 5 && !es_blocked.include?(_1) }.sort
es_header = <<~TXT
  # Offensive-word allowlist, es: ordinary Spanish words and names (>= 5 letters) that embed an es
  # term (puta ⊂ computadora, culo ⊂ ridiculo, puto ⊂ caputo). Segment exemptions only (PRD §10.2).
  # Generated by script/build_offensive_data.rb. Reviewed with the es tiers (data/offensive/README.md).
  # source: usernames (MIT) — words from research 17's FrequencyWords scan and real-name set (facts)
TXT
File.write(File.join(OUT, "allowlist/es.txt"), "#{es_header}#{es_allow.map { "#{_1} # usernames" }.join("\n")}\n")
puts "allowlist/es.txt: #{es_allow.size}"
