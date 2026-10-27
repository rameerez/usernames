# Security Policy

`usernames` decides which usernames an application accepts and how it compares them for uniqueness. Mistakes here become account impersonation, enumeration or duplicate identities, so please report suspected vulnerabilities privately and keep real user data out of any report.

## Supported versions

Security fixes are released for the latest published version. The maintained test matrix covers Ruby 3.3, 3.4 and 4.0 with patched Rails 7.2, 8.0 and 8.1 releases, on SQLite and PostgreSQL. MySQL support is experimental and not security-supported. Older Ruby and Rails versions may remain installable, but runtimes that no longer receive upstream security fixes are not security-supported.

## Reporting a vulnerability

Use GitHub's **Report a vulnerability** button on the [`usernames` security advisories page](https://github.com/rameerez/usernames/security/advisories) so the report and any proposed fix remain private. If GitHub's private reporting flow is unavailable, email `rubygems@rameerez.com` with the subject `usernames security report`.

Include:

- the affected version, Rails version and database adapter;
- a minimal reproduction (the input string, the configuration, the observed result);
- the impact you believe is possible; and
- any suggested mitigation or patch.

Do not open a public issue for an undisclosed vulnerability. We will acknowledge the report, investigate it, and coordinate disclosure and credit with you.

## What is in scope

- A username that passes validation but should not (a reserved name, an impersonation form such as `adm1n`, an evasion of the offensive-word tiers, an invisible or bidi character surviving normalisation).
- Two stored usernames that the gem's comparison treats as different but a reader, a URL or a database would treat as the same (normalisation that is not idempotent; a collation mismatch; a case or punctuation form that defeats the unique index).
- Anything that lets the generated availability endpoint be used to enumerate accounts faster than its rate limit intends.
- A generated or suggested name that is offensive, reserved or predictable.

## Operational security

Applications remain responsible for:

- running `rails usernames:audit` before adopting the gem on an existing column and resolving what it reports (noncanonical rows, collisions, incompatible indexes or collations);
- keeping the username column's collation as the generator sets it (`"C"` on PostgreSQL, `utf8mb4_bin` on MySQL) — a different collation changes what "equal" means;
- a working, shared cache store behind the generated availability controller's `rate_limit` (a `NullStore` disables rate limiting; a per-process `MemoryStore` cannot limit across workers), and deciding whether that endpoint should require sign-in;
- the words they add to `config.allowed` and `config.offensive.allowed`, which lift the gem's verdicts;
- their own `before_*` callbacks being safe to run more than once on a username model (a generated-name redraw repeats them);
- moderation of what people do with a username once they have one — this gem screens the string, not the person.

## Data provenance

Every bundled word list is derived from a permissively licensed source pinned to a revision in `data/NOTICE`, with the licence text in `data/LICENSES/`. If you believe a bundled entry is wrong — a real name the gem refuses, or a term it should refuse — open an ordinary issue with a source; that is not a security report.
