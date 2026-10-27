# 👤 `usernames` - Usernames for your Rails app, done right in one line

[![Gem Version](https://badge.fury.io/rb/usernames.svg)](https://badge.fury.io/rb/usernames) [![Build Status](https://github.com/rameerez/usernames/workflows/Tests/badge.svg)](https://github.com/rameerez/usernames/actions)

> [!TIP]
> **🚀 Ship your next Rails app 10x faster!** I've built **[RailsFast](https://railsfast.com/?ref=usernames)**, a production-ready Rails boilerplate template that comes with everything you need to launch a software business in days, not weeks. Go [check it out](https://railsfast.com/?ref=usernames)!

`usernames` gives any Rails model a username that is **valid, unique, not reserved, not offensive, and there from day one** — with one line:

```ruby
class User < ApplicationRecord
  has_username
end
```

That's it. Now:

```ruby
user.username = "javi_r"          # ✅
user.username = "admin"           # ❌ is reserved
user.username = "Ad_min2"         # ❌ is reserved        (that's still "admin" to a reader)
user.username = "_javi"           # ❌ can't start or end with an underscore
user.username = "oliver___hjj"    # ❌ can't have two symbols in a row
user.username = "12345"           # ❌ can't be only numbers
user.username = "xXf_u_c_kXx"     # ❌ isn't allowed        (it never says which word)
user.username = "  @Javi_R "      # ✅ stored as "javi_r"  (pasted @, spaces and case are normalised)
```

Every new account gets a free, pronounceable name from the moment it exists (`quiet_otter_42`), and when someone picks a name that's taken you can offer free alternatives in one query:

```ruby
User.create!(email: "ana@example.com").username   # => "quiet_otter_42"
User.suggest_usernames("Javi R")                  # => ["javi_r", "javir", "javi_r_42", "javi_r_817", "javi_r_23"]
User.username_available?("javi")                  # => false  (taken — or reserved, or not allowed)
```

(The names and digits in these examples are illustrative: the digits are random, and a taken name is skipped.)

No table, no migration beyond one unique index, no network calls, no API key. Everything runs in-process in microseconds.

Check out my other 💎 Ruby gems: [`nondisposable`](https://github.com/rameerez/nondisposable) · [`moderate`](https://github.com/rameerez/moderate) · [`api_keys`](https://github.com/rameerez/api_keys) · [`usage_credits`](https://github.com/rameerez/usage_credits)

## Why this gem exists

Every Rails app with profiles writes username handling by hand, and gets it subtly wrong. The username regex everyone copies from Stack Overflow (197k views) accepts `12345678`, `Administrator`, `robots.txt` and `"validuser\n"`. The regex on Devise's own wiki accepts the empty string. Rails' `validates :username, uniqueness: true` is case-sensitive, so `Javi` and `javi` are two people — and the fix, `case_sensitive: false`, makes Rails emit `LOWER(username) = LOWER(?)`, which your unique index can't serve, and on MySQL and `citext` columns it doesn't even do that.

Then someone registers `admin`, or `login`, or `ad.min`, or `/robots.txt`, or a name that looks like yours with a `1` for an `l`, or something you'd rather not see on your homepage. Spotify once lost accounts to a username normaliser that wasn't idempotent (`ᴮᴵᴳᴮᴵᴿᴰ` became `bigbird` on the second pass).

`usernames` is that whole subsystem, written once, tested against 60 platforms' rules, 25 public reserved-name lists, 13 profanity datasets and 234,000 dictionary words, and reviewed adversarially before the first line of code. It is opinionated so you don't have to be.

## Installation

```ruby
gem "usernames"
```

```bash
bundle install
rails generate usernames:install
rails db:migrate
```

The generator writes `config/initializers/usernames.rb` (ten options, all commented), adds a `username` column to `users` if there isn't one, and adds **the one unique index the gem needs** — with the right collation, so the database agrees with Ruby about what "the same name" means (see [Uniqueness, case and collation](#uniqueness-case-and-collation)).

Then, in your model:

```ruby
class User < ApplicationRecord
  has_username
end
```

If your column has another name, or your rules differ for one model:

```ruby
class Player < ApplicationRecord
  has_username :handle, length: 2..24, case: :preserve, separators: %w[_ . -]
end
```

> [!IMPORTANT]
> **Already have users?** `has_username` only checks a username **when it changes**, so adding the gem never stops an existing account from saving its other attributes. But Rails' `normalizes` doesn't rewrite rows already in the database, and a stored `JAVI` next to a new `javi` would be two identities. Run `rails usernames:audit` first and read [Adopting an existing column](#adopting-an-existing-column) — it's a five-minute, read-only check.

## What it checks, in order

The first failing rule names the error. Messages never contain what the user typed, so they can never echo abuse back or trip I18n on a `%{` someone pasted.

| # | Rule | Error (English) |
|---|---|---|
| 1 | no whitespace | can't contain spaces |
| 2 | letters `a–z`, digits and `_` only (everything else — accents, emoji, invisible characters — fails here) | can only contain lowercase letters, numbers and underscores |
| 3 | 3 to 30 characters | is too short / is too long (minimum is 3 characters) |
| 4 | no `_` first or last | can't start or end with an underscore |
| 5 | no two symbols in a row | can't have two symbols in a row |
| 6 | not all digits (`231640921` reads as an id, and collides with `/users/:id`) | can't be only numbers |
| 7 | not a reserved name | is reserved |
| 8 | not an offensive word | isn't allowed |
| 9 | not taken (your unique index decides) | has already been taken |

Before any rule runs, the value is **normalised**: invalid bytes dropped, Unicode NFKC (so `Ｊａｖｉ` typed on a Japanese keyboard becomes `Javi`, and `ᴮᴵᴳ` becomes `BIG`), trimmed, lowercased, and one pasted leading `@` removed. The normaliser is idempotent — running it twice gives the same answer — which is exactly the property Spotify's wasn't. It never strips invisible characters (zero-width spaces, right-to-left overrides): those fail rule 2, loudly.

Usernames are **ASCII** in this version. Unicode usernames are a lookalike-impersonation problem (Cyrillic `а` is not Latin `a`) that deserves its own design; GitHub, X, Discord, Mastodon and Bluesky made the same call and put Unicode in the display name. We recommend you do too — give people a free-form `display_name` column for who they are, and keep the username as the stable identifier.

## Reserved names

Nobody can register these, out of the box:

- **Impersonation** (~60): `admin`, `administrator`, `root`, `staff`, `support`, `official`, `moderator`, `mod`, `security`, `verified`, `trust`, `safety`, `team`, `bot`, `system`, `help`, `owner`, `webmaster`, `abuse` — **and your app's own name**, read from your application class. These are matched the way impersonators type them: separators and trailing digits removed, digits folded (`ad.min`, `adm1n`, `admin2`, `admin_bob`, `bob.support`, `admins` are all refused). They are *not* matched as prefixes: `supportive`, `staffordshire`, `teamwork` and `adminbob` are fine — the naive "contains `admin`" check most apps write would have refused `badminton_fan`.
- **System words** (~90): `null`, `nil`, `undefined`, `true`, `false`, `deleted`, `ghost` (GitHub's placeholder for deleted users), `anonymous`, `everyone`, `here`, `channel`, `me`, `you`, `constructor`, `__proto__`, Windows device names (`con`, `nul`, `com1`…), Unix accounts (`root`, `daemon`, `www-data`…).
- **Mailboxes** (~70): the RFC 2142 role addresses (`postmaster`, `hostmaster`, `abuse`, `noc`, `security`…), the addresses certificate authorities accept for domain validation (`ssladmin`, `webmaster`…), `noreply`, `mailer-daemon`, and hostnames that hijack autoconfiguration if a username ever becomes a subdomain (`autoconfig`, `autodiscover`, `wpad`, `isatap`, `localhost`).
- **Web paths** (~1,100): `login`, `logout`, `signup`, `settings`, `account`, `api`, `dashboard`, `assets`, `cable`, `up`, `rails`, `sidekiq`, `admin`, `search`, `about`, `help`, `terms`, `privacy`, `pricing`, `blog`, `sitemap`, `robots`, `favicon`… — the union of the Big Username Blocklist, shouldbee, GitHub's, GitLab's and Gitea's own reserved paths, django-registration and the IANA `.well-known` registry, minus company names, minus common first names (so Nick, Page and Mac can sign up), minus words people go by (`alpha`, `beta`, `flash`, `free`, `master`, `recent`) — if your app has such a page, your routes reserve it.
- **Your routes**: every static top-level path in `config/routes.rb` (`/pricing`, `/recipes`, `/play`…) is reserved automatically, and refreshed when routes reload in development. So a GitHub-style `/:username` can never be shadowed by a page you add next month.

Add your own:

```ruby
Usernames.configure do |config|
  config.reserved  += %w[recipe recipes]       # exact: nobody can be exactly this
  config.forbidden += %w[yourapp yourap]       # impersonation matching, like admin — add your misspellings
  config.allowed   += %w[nick page]            # lift a bundled word you disagree with
end
```

`+=` adds to the bundled lists; `=` replaces them. Who wins when lists disagree (top wins):

| # | List | Effect |
|---|---|---|
| 1 | `config.allowed` | allowed |
| 2 | `config.reserved`, `config.forbidden` | reserved |
| 3 | your routes | reserved |
| 4 | the bundled lists | reserved |

Your own official account, under a name the gem reserves? Lift exactly that name — `config.allowed += %w[yourapp]` — and register it yourself before launch (a seed, or the console). It frees that exact name only: `yourapp2` and `your.app` stay reserved. `has_username` deliberately has no per-record skip: whether a name may be held is a fact about the name, and a skip that hangs off the record is one `update` away from letting someone else keep `admin`. `rails usernames:reserved` prints the effective list with the source of every word, for when you wonder why `x` is reserved.

## Offensive words

A username has no spaces, so `xxfuckxx`, `f_u_c_k` and `sh1thead` have to be caught — but `assassin`, `scunthorpe`, `therapist`, `cockburn` and `grape` must not be. The gem uses **severity tiers**, per language:

- **Severe** terms (slurs, the worst sexual and violent terms) are matched anywhere inside a name, after folding leetspeak digits and separators — but only terms of four letters or more (`gc` and `mj` are on some lists; matching them anywhere would refuse `gcastro` and `mjordan`).
- **Strong** terms are matched only as a whole name or a whole segment between separators and digits: `shithead_bob` is refused, `scunthorpe` is not, and a real surname like `Chujew` stays legal. With `case: :preserve`, a capital after a lowercase letter separates words too: `ShitheadBob` is refused, `ScunthorpeUnited` is fine. Words glued in lowercase (`shitheadbob`) have nothing to split them by, so at `:strong` they pass — a known limit.
- **Mild** words (`hell`, `damn`) are off by default.
- **Hate numbers** are rules, not list entries: `1488` is refused as a whole number or `14_88`; bare `88` never is (birth years, NASCAR, a lucky number in Chinese); `kkk` is refused in English — and, when a Portuguese word list ships, it will not be there, where `kkkk` is laughter (Portuguese messages ship today; Portuguese screening does not).
- An **allowlist** of ~800 real words and names that happen to contain a bad substring (`scunthorpe`, `sussex`, `cockburn`, `fukuda`, `dikshit`…) exempts a whole name or a whole segment: `scunthorpe_united` is fine. Joining segments never manufactures an exemption, so `scunt_horpe` and `f.u.c.k` are still refused.

```ruby
Usernames.configure do |config|
  config.offensive.severity  = :strong      # :severe (substring only) · :strong (default) · :mild · :off
  config.offensive.languages = %i[en es]    # English and Spanish ship reviewed; more as they're tiered
  config.offensive.allowed  += %w[sussex]   # your own exemptions
end
```

If you already use [`moderate`](https://github.com/rameerez/moderate), its word list is consulted too — automatically, no configuration, and never required. Any `->(name) { … }` can be an adapter; it receives the name as stored (typed case and all, in preserve mode).

One deliberate choice worth stating: `negro` is the Spanish word for black and a common surname, and it is not blocked in any language. The slur is a different word.

The gem can't read context and never will; it clears the bar of "obvious slurs don't sail through" at zero latency and zero cost, and says so. Every word it ships has a source and a licence (see [Data and licences](#data-and-licences)), and its test suite runs the whole vocabulary against lists of real first names and surnames so a person is never refused for being called Dick or Gay.

## Uniqueness, case and collation

By default usernames are stored **lowercase**. That is the one configuration where Ruby, the validator and the database agree on what "equal" means: the stored value is already canonical, so uniqueness is a plain `username = ?` on an ordinary unique index — no `LOWER()`, no full-table scan.

In lowercase mode the generator sets the column's collation to `"C"` on PostgreSQL and `utf8mb4_bin` on MySQL. Why: PostgreSQL's `lower()` and `=` follow the column's collation, and under a Turkish collation `I` lowercases to `ı`, not `i`; MySQL's default `_ai_ci` collations make `jose` equal `josé`; PostgreSQL's nondeterministic collations can ignore punctuation entirely. Pinning the collation makes the database compare bytes, exactly as Ruby does. `citext` is never used — its own docs say it isn't truly case-insensitive.

Want to keep the case people type (`CoolCat` shows as `CoolCat`, but nobody else can be `coolcat`)?

```ruby
has_username case: :preserve
```

Declare it on the model first (or pass `--case=preserve` to the install generator) and the generator writes a functional unique index on `lower(username COLLATE "C")` instead; every query the gem makes — uniqueness, lookup, availability, suggestions — uses that same expression. Because the expression carries its own `COLLATE "C"`, on PostgreSQL the generator leaves the column's collation alone, so `ORDER BY username` keeps sorting `Alice, bob, Carol` rather than every capitalised name first (MySQL, whose `lower()` follows the column, still gets `utf8mb4_bin`).

Two names that differ only in punctuation are **different** names: `john.doe` and `johndoe` are two people. (npm and PyPI decided otherwise for package names; for people, literal is less surprising.)

When two sign-ups race for the same generated name, the unique index refuses the second and the gem silently draws another, inside a savepoint so your surrounding transaction survives. When two people race for the same *typed* name, the loser gets the ordinary `has already been taken` error — `save` returns `false`, `save!` raises `ActiveRecord::RecordInvalid` — never a `RecordNotUnique` 500. (What the gem handles is the unique index refusing a name. Two writers waiting on each other is the database's concern: on SQLite, give the database a `timeout` in `config/database.yml` so concurrent writers wait for the lock instead of failing with `SQLite3::BusyException`.)

A redraw tries the insert again, so your `before_create` and `around_create` callbacks may run once per attempt (at most four times); validations and `before_save` run once, and `after_create` and `after_commit` run once, for the attempt that succeeded. Keep side effects — emails, API calls — out of `before_create`: `after_commit` is the place for them.

## Adopting an existing column

```bash
rails usernames:audit            # or: rails usernames:audit[Member,handle] · usernames:audit[Member,handle,preserve]
```

Read-only. It prints: stored values that differ from their normalised form (`JAVI`, ` javi`, `@javi`); groups of rows that would collide once normalised (`Javi` and `javi`); whether your existing index and column collation match the chosen case mode; and values that fail today's rules (those keep working — only a *change* is validated). Run before `has_username` is declared, it checks the configured rules and case mode; the third argument names the mode you're adopting. It always exits 0 — it is a report, not a gate — and its last line is `Nothing to fix: …` or `N things to fix. …`, for a script to grep.

If the audit finds anything, fix it with a migration you own, under a short freeze of the username form: rewrite the noncanonical values with your own callbacks and policy, resolve collisions by contacting the people or appending a suffix, set the collation, add the index, reopen the form. The gem deliberately ships **no automatic rewriting task** — renaming people silently is not a thing a gem should do for you.

Alternatively, `case: :preserve` leaves stored case alone; the audit will tell you if anything else needs attention.

## Generated names and suggestions

Every new account has a name from day one. A profile with no name is a row that renders as plain text everywhere and has no page — so `has_username` assigns one on create when the field is blank. (Only on create: an existing account may still clear its username, unless you pass `required: true`.)

```ruby
User.create!(email: "ana@example.com").username   # => "quiet_otter_42"
```

Adjective + animal + two random digits, from a vocabulary curated for this purpose (no brands, no body parts, nothing a slur list could trip on — and the test suite proves it, pair by pair). Digits come from `SecureRandom`, never a counter, so names don't reveal sign-up order. On collision the digits grow (`quiet_otter_417`), then fall back to hex. If every name a batch draws is taken or not allowed (a tiny custom vocabulary, a very short length), the save fails with `username_unavailable` ("couldn't be assigned automatically, please choose one") rather than raising; `generate_username` itself raises `Usernames::NoFreeNameError`. Pass `required: true` instead if you'd rather make people choose, or `generate: false` to leave it blank.

Both also take a method name or a proc, evaluated on the record like Rails' `if:` — for an app where some sign-up flows ask for a name and others don't:

```ruby
has_username required: :handle_required            # typed where the flow asks for one, generated everywhere else
has_username required: -> { invited? }, generate: false
```

By default a name is generated exactly where none is required, record by record. An explicit `generate:` is honoured as given: `required: true, generate: true` fills a blank on create and refuses clearing it later.

From a real name:

```ruby
User.generate_username(from: "Pedro Gonzales Armillon")   # => "pedro_gonzales_armillon", or "pedro_gonzales_armillon_73" if taken
User.generate_username(from: "José García")               # => "jose_garcia"
User.generate_username(from: "Иван Петров")               # => "ivan_petrov"  with the any_ascii gem; "quiet_otter_42" without
```

Names are cut at word boundaries, never mid-word. The gem never derives a username from an **email** unless you pass one explicitly — the local part of someone's address is not something they agreed to publish. If you do pass one, generic local parts (`info@`, `admin@`, `me@`) use the domain instead.

When a chosen name is taken:

```ruby
User.suggest_usernames("javi", count: 5)   # => ["javi_42", "javi_817", "javi_23", "javi_561", "javi_90"]  (illustrative: random digits)
```

Candidates are built in memory, filtered through every rule, checked for availability in **one** query, and returned in order. You may get fewer than you asked for; you never get a loop or an exception for running out.

Bring your own vocabulary or shape:

```ruby
Usernames.configure do |config|
  config.generator.adjectives = %w[swift silent iron lunar …]
  config.generator.nouns      = %w[comet pulsar nebula …]
  # or anything at all:
  config.generator = ->(attempt) { "player#{SecureRandom.random_number(10_000)}" }
end
```

Whatever you return still goes through the validator and the redraw logic.

## Live availability check

```bash
rails generate usernames:availability
```

Copies into **your** app — nothing is mounted behind your back — a small controller, a route (`GET /usernames/availability?username=…`), a Stimulus controller and a form partial. As people type, the browser shows the format rules instantly (same rules, same words as the server, no round trip) and asks the server whether the name is free, debounced, with stale answers discarded. Browser hints never block submission; the server is the only authority.

An availability endpoint reveals which names exist by design, so the generated controller comes with guard rails: it rate-limits with Rails' built-in `rate_limit`, it refuses to run (503, with a log line) if your cache store is the `NullStore` — Rails' limiter silently does nothing there — and it answers "taken" for taken, reserved and disallowed names alike. The word lists never reach the browser.

## Recipes

**Profile URLs with `/@username`** — dots and dashes in a dynamic segment need a constraint, or Rails reads `/@john.doe` as `username=john, format=doe`:

```ruby
# config/routes.rb
get "@:username", to: "profiles#show", as: :profile, format: false,
    constraints: { username: Usernames.route }
```

In the controller, `User.find_by_username!(params[:username])` finds `@Javi` as `javi` and raises `ActiveRecord::RecordNotFound` — a 404 — when nobody has the name, as `find_by!` does.

`Usernames.route` is deliberately permissive (`/[A-Za-z0-9._-]+/`): it decides what *routes*, your database decides what *exists*, and your validator decides what can be *registered*. That way an account grandfathered in with a name today's rules would refuse still has a page.

**GitHub-style `/username`** — declare it **last**, after every other route; the gem already reserves your static paths so a new page can't shadow a person.

**Dots like Instagram** — `config.separators = %w[_ .]`. Enabling dots switches on one more rule: a name may not end like a file (`.json`, `.png`, `.php`, `.git`, `.atom` and every extension Rails knows), because `/@john.json` confuses routers, CDNs and crawlers. `john.doe` is fine.

**Subdomain-safe (`javi.yourapp.com`)** — only `-` is legal in a DNS label: `config.separators = %w[-]; config.length = 3..63`.

**Allow `_javi_`** — `config.edge_separators = true`. Gamers like it; dots are never allowed at an edge (a trailing dot is punctuation in a mention).

**Log in with username or email (Devise)** — set `config.authentication_keys = [:login]` and in your model `def self.find_for_database_authentication(conditions)` look up `find_by_username(login) || find_by(email: login)`; `find_by_username` normalises for you, so `@Javi` finds `javi`. Because `@` is never legal in a username, the two can't be confused.

**Just the validation, I'll handle the rest** —

```ruby
normalizes :username, with: Usernames.normalizer
validates  :username, username: true
```

The validator checks the value as stored — pair it with the `normalizes` line, or typed `Javi` fails the lowercase rule, which is the point. You keep your own uniqueness validation and index.

**Pure functions, no model** —

```ruby
Usernames.allowed?("admin")        # => false  (eligibility only; says nothing about availability)
Usernames.check("Ad_min")          # => #<Usernames::Result ok?=false reason=:username_reserved canonical="ad_min" message="is reserved">
Usernames.normalize(" @Javi_R ")   # => "javi_r"
Usernames.generate                 # => "quiet_otter_42"
```

## What it deliberately doesn't do

- **Display names.** Add a `display_name` column; let it be anything. The username is the identifier.
- **Hold a released name.** When someone renames themselves, their old name is free immediately. Twitch holds names for 180 days and PlayStation never releases them, but that needs a table, and this gem has none. Put stable ids in URLs if that matters to you.
- **Unicode usernames**, in this version — see above.
- **Read context.** A word list is a word list. For real moderation of what people post, use [`moderate`](https://github.com/rameerez/moderate).
- **Authentication.** That's Devise's job; the gem just gives you `find_by_username`.

## Translating messages

Every message is a standard Active Model error (`errors.messages.username_reserved`, `username_edges`, `username_consecutive`, `username_digits_only`, `username_characters`, `username_not_allowed`, `username_unavailable`…, plus Rails' own `too_short`, `too_long`, `blank`, `taken`). English, Spanish and Portuguese ship with the gem; Rails loads an engine's locale files before your app's, so a key in your `config/locales/*.yml` always wins, and the usual per-model override works too:

```yaml
es:
  activerecord:
    errors:
      models:
        user:
          attributes:
            username:
              username_reserved: "está reservado"
```

A per-model override reaches every place the gem speaks for that model: `User.check_username(value)` (`Usernames.check` with the model's rules and words) and `User.username_rules_for_browser` (the hints) look messages up the way the model's own errors do, and the generated availability check uses both, so the form, the hints and the endpoint say the same thing.

`rails generate usernames:locale --locale=fr` copies the English file for you to translate.

## Configuration reference

The initializer the generator writes (every line commented out — these are the defaults):

```ruby
Usernames.configure do |config|
  config.length          = 3..30
  config.separators      = %w[_]         # %w[_ .] Instagram-style (adds the file-extension rule) · %w[-] GitHub/subdomain style
  config.edge_separators = false         # true allows _javi_ (never a dot at an edge)
  config.case            = :lowercase    # :preserve keeps typed case, compares case-insensitively

  config.reserved  += %w[]               # exact
  config.forbidden += %w[]               # impersonation matching, like admin
  config.allowed   += %w[]               # exceptions to the reserved checks

  config.offensive.severity  = :strong   # :severe · :strong · :mild · :off
  config.offensive.languages = %i[en es]
  config.offensive.allowed  += %w[]      # exceptions to the offensive-word checks
end
```

Less common, documented here rather than in the initializer: `first_character` (`:alphanumeric`, or `:letter` for the Snapchat/Telegram rule), `reserve_routes` (`true`), `app_name` (auto-detected; `false` to opt out), `offensive.adapters` (`[:moderate]`), `on_adapter_failure` (`:allow` logs and skips a raising adapter; `:reject` fails the save), `generator.adjectives` / `generator.nouns` / `generator` (a callable), `unique_index` (only if the generator didn't create yours). Every option is also accepted per model — `has_username :handle, length: 2..24` — and per validator call. `has_username` itself takes `required:` (`false`; `true`, a method name such as `required: :handle_required`, or a proc) and `generate:` (by default: wherever a name isn't required). An invalid value raises `Usernames::ConfigurationError` at boot, naming it.

## Data and licences

The bundled lists come from permissively licensed sources, each pinned to a revision and listed in `data/NOTICE` with its licence text in `data/LICENSES/`: The Big Username Blocklist and shouldbee (MIT), GitHub's reserved names via Mottie (MIT), GitLab's and Gitea's route lists (MIT), django-registration (BSD-3), forwardemail's mailbox names (MIT), RFC 2142 and the IANA well-known URI registry, dsojevic/profanity-list (MIT), jo3-l/obscenity's allowlist (MIT), wooorm/cuss (MIT), Glitch's friendly-words, petname and corpora for the generator vocabulary (MIT / Apache-2.0 / CC0). Nothing GPL, nothing CC-BY, nothing without a licence, no real people's surnames, no trademarks. Hate-symbol meanings follow the ADL and the Simon Wiesenthal Center; nothing of theirs is copied.

## Development

```bash
bin/setup
bundle exec rake test                        # Minitest 6; SQLite in memory
bundle exec appraisal rails-8.1 rake test    # Rails 7.2 / 8.0 / 8.1 via Appraisals
DATABASE_URL=postgres://localhost/usernames_test bundle exec rake test   # the PostgreSQL suite (races, collations)
```

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/rameerez/usernames. A word you think should be reserved, an innocent word the filter refuses, a language you can review — those are the most useful contributions of all. Please include a source.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
