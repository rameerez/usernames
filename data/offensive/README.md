# Offensive-word data

Built by `script/build_offensive_data.rb` (en, es, allowlists); `hate.yml` and `leet.yml` are
hand-written. Sources, revisions and licences: `data/NOTICE` and `data/LICENSES/`. Matching
rules: PRD §10.

Review status: `en` tiers follow the research (dsojevic severity 4 plus the promoted slurs).
`es` tiers were built from permissive sources and reviewed by a Spanish-speaking reviewer on
2026-10-27 (removed at every tier: `concha`, `coger`, `huevos`, `semen`, `cipote`, `panchito`;
`pija` demoted to mild). A second review by the maintainer is welcome; `negro` is never blocked
in any locale by decision.

## `<locale>.json`

```json
{"term": "cunt", "severity": 4, "variants": ["cunnt", "cunts", "kunt", "..."],
 "tags": ["general"], "exceptions": ["scunthorpe", "eduskunta", "..."]}
```

| severity | tier | matched as (PRD §10.2) |
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
- No term or variant is ever `negro`, in any locale (D-20); the build aborts if one appears.

## en — dsojevic/profanity-list, re-tiered

- Severity 4 = dsojevic's 31 severity-4 entries plus the promoted slurs `kike faggot/fagot chink
  paki coon gook wetback tranny`. `spic` stays at 3 (it is inside allspice/aspic/suspicious).
- `rape`, `rapist` (split out of dsojevic's `raping`), `raping` and `shota` are `segment_only`:
  as substrings they reject grape/therapist/scraping, and Shōta is a common Japanese given name.
  **`raping` and `shota` are this build's call — please confirm.**
- `negro` (dsojevic severity 2) is removed (D-20).
- Dictionary words a promoted slur would otherwise reject were added as exceptions of that term
  (cocoon, snigger, pakistani, chinkapin, eduskunta, esophagotomy, …); see `EXTRA_EXCEPTIONS`.
- Strong/mild are dsojevic's tiers unchanged. Its README says most entries carry an unreviewed
  default of 3; real names at 3 worth a look: `santorum`, `finocchio`, `pansy`, `cissy`,
  `hermie`, and the non-slurs `enby`, `cishet`.

## es — awaiting the author's review

**The es tiers are a first pass by the build, not a native-speaker review. They await the
author's review before 0.1.0.** Every term is attested in wooorm/cuss (es), AllProfanity
(spanish) or the research's severe candidates
(`docs/research/sources/offensive2/lists/severe_candidates/es.tsv`); plural and gender forms of
an attested word are added as variants.

- **Severe (19, slurs only):** maricon, maricona, marikon, mariconazo, marica*, puto*, joto,
  bujarron, machorra, marimacho, tortillera, bollera, travelo*, sudaca, negrata, mongolico,
  mongolo*, sidoso, chinorris. `*` = `segment_only` because the research measured a Scunthorpe
  risk (puto ⊂ computo/caputo, marica ⊂ tamaricaceae, travelo ⊂ travelogue, mongolo ⊂ mongoloid).
- **Strong (37):** vulgar and insulting words that are rarely anything else (mierda, joder, puta,
  cono, culo, polla, verga, gilipollas, cabron, pendejo, chingar, …). The research's
  Scunthorpe-risk words (`puta` ⊂ computadora, `culo` ⊂ ridiculo, `cono` ⊂ economia, `pito`) are
  strong or mild — never severe, never substrings.
- **Mild (47):** everyday insults and words with an innocent primary meaning (idiota, imbecil,
  capullo, concha, paja, pito, coger, zorra, retrasado, panchito, …).
- Left out on purpose: `moronegro` (unattested, and contains `negro`), `moro` (a surname),
  `gringo`, and the hundreds of cuss entries whose ordinary meaning dominates (alcornoque, leche,
  palo, pistola, cuchara, filiberto, tonga, …).
- Decisions to check: `subnormal` (strong; also an English word), `retrasado` (mild — "delayed"),
  `gabacho` (strong), `panchito` (mild — also the diminutive of Francisco), `pinche` (mild).

## Allowlists

`allowlist/en.txt` (obscenity's whitelist, dsojevic's exceptions, the research's
Wikipedia-verified names) and `allowlist/es.txt` keep only real words and names of 5+ letters.
Rejected at build time: fragments (`an al`, `s hit`, `assem`, `nigg`), multi-word entries whose
join is not a word (`scunthorpe united` would otherwise exempt `scunthorpeunited`), unverified
rows, and any entry that is itself a term of the locale (`faggot`, `penis`, `whore`).
