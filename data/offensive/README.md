# Offensive-word data

Built by `script/build_offensive_data.rb` (en, es, allowlists); `hate.yml` and `leet.yml` are
hand-written. Sources, revisions and licences: `data/NOTICE` and `data/LICENSES/`.

## Review status

Both languages ship reviewed, as of 2026-10-27:

- **en** — dsojevic/profanity-list's tiers, reviewed by the maintainers: slurs promoted to severe,
  racial abuse moved out of the disabled-by-default tiers, identity words removed and real names
  demoted to mild (see "en" below). Every decision is a line of `script/build_offensive_data.rb`.
- **es** — built from permissive sources and reviewed by a Spanish-speaking reviewer: `concha`,
  `coger`, `huevos`, `semen`, `cipote` and `panchito` removed at every tier, `pija` demoted to mild.

`negro` is never blocked, in any locale, by decision: it is the Spanish word for black and a common
surname. Corrections and new languages are welcome; please include a source.

## `<locale>.json`

```json
{"term": "cunt", "severity": 4, "variants": ["cunnt", "cunts", "kunt", "..."],
 "tags": ["general"], "exceptions": ["scunthorpe", "eduskunta", "..."]}
```

| severity | tier | matched as |
|---|---|---|
| 4 | severe | substring of a segment (terms of 4+ letters), and across separators; `"segment_only": true` → the segment must equal the term |
| 3 | strong | the segment equals the term (default mode `:strong` and stricter) |
| 1–2 | mild | the segment equals the term, only in `:mild` mode |

- `variants` are compact ASCII spellings (spaces, hyphens and dots removed) including stretched
  letters (dsojevic's `*`, up to 3 extra repeats). **Leet-folded spellings are not stored**: the
  matcher folds terms, variants, exceptions and allowlist entries with `leet.yml` at load time,
  exactly as it folds the input.
- `exceptions` are term-scoped segment exemptions; `allowlist/<locale>.txt` exempts a segment
  from every term of that locale. Neither applies to a match that spans a separator.
- No term or variant is ever `negro`, in any locale; the build aborts if one appears.

## en — dsojevic/profanity-list, reviewed

430 terms: 41 severe, 316 strong, 73 mild.

- **Severe** = dsojevic's severity-4 entries, plus the promoted slurs `kike faggot/fagot chink paki
  coon gook wetback tranny`, plus `chingchong` and `neonazi` (dsojevic: 2). `spic` stays strong:
  it is inside allspice, aspic and suspicious.
- **Strong** = dsojevic's severity 3, plus `jap` and `wog` (dsojevic: 1). Three letters, so they
  are matched only as a whole segment: `japan`, `japanese` and `wogan` pass.
- **Mild** (off by default) = dsojevic's severity 1–2, plus words that are also real names or
  ordinary words: `pansy` and `cissy` (given names), `hermie` (a nickname), `santorum` and
  `finocchio` (surnames; finocchio is also Italian for fennel), and `shota` (Shōta, a common
  Japanese given name).
- **Removed**: `enby` and `cishet`, identity terms people use for themselves, not slurs; and
  `negro` (see above).
- `rape`, `rapist` (split out of dsojevic's `raping`) and `raping` are `segment_only`: as
  substrings they would reject grape, therapist and scraping.
- Dictionary words a promoted slur would otherwise reject were added as exceptions of that term
  (cocoon, snigger, pakistani, chinkapin, eduskunta, esophagotomy, …); see `EXTRA_EXCEPTIONS`.

## es — wooorm/cuss and AllProfanity, tiered by hand, reviewed

97 terms: 19 severe, 35 strong, 43 mild. Every term is attested in wooorm/cuss (es), AllProfanity
(spanish) or the research's severe-candidate list; plural and gender forms of an attested word are
added as variants.

- **Severe (slurs only):** maricon, maricona, marikon, mariconazo, marica\*, puto\*, joto,
  bujarron, machorra, marimacho, tortillera, bollera, travelo\*, sudaca, negrata, mongolico,
  mongolo\*, sidoso, chinorris. `*` = `segment_only`, because each is inside an innocent word
  (puto ⊂ computo/caputo, marica ⊂ tamaricaceae, travelo ⊂ travelogue, mongolo ⊂ mongoloid).
- **Strong:** vulgar and insulting words that are rarely anything else (mierda, joder, puta,
  cono, culo, polla, verga, gilipollas, cabron, pendejo, chingar, …). The words inside innocent
  ones (`puta` ⊂ computadora, `culo` ⊂ ridiculo, `cono` ⊂ economia) are never severe, never
  substrings.
- **Mild:** everyday insults and words with an innocent primary meaning (idiota, imbecil,
  capullo, paja, pito, zorra, retrasado, pinche, …).
- `subnormal` is strong although it is also an English word; `retrasado` is mild because it also
  means "delayed"; `gabacho` is strong and `pinche` mild.
- **Left out on purpose:** `concha` (a common female name, Concepción, and a seashell), `coger`
  (the everyday verb "to take" in Spain), `huevos` ("eggs"), `semen` (a Ukrainian first name),
  `cipote` ("kid" in Central America), `panchito` (a nickname for Francisco), `moronegro`
  (unattested, and contains `negro`), `moro` (a surname), `gringo`, and the hundreds of cuss
  entries whose ordinary meaning dominates (alcornoque, leche, palo, pistola, cuchara, …).

## Allowlists

`allowlist/en.txt` (obscenity's whitelist, dsojevic's exceptions, the research's
Wikipedia-verified names) and `allowlist/es.txt` keep only real words and names of 5+ letters.
Rejected at build time: fragments (`an al`, `s hit`, `assem`, `nigg`), multi-word entries whose
join is not a word (`scunthorpe united` would otherwise exempt `scunthorpeunited`), unverified
rows, and any entry that is itself a term of the locale (`faggot`, `penis`, `whore`).
