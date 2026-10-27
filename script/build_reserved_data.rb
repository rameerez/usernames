#!/usr/bin/env ruby
# frozen_string_literal: true

# Builds data/reserved/{impersonation,system,mailboxes,web}.txt and
# data/reserved/ALLOWLIST_EXCEPTIONS.txt from the vendorable lists downloaded during research
# (docs/research/sources/reserved/lists/) plus the hand-typed facts of research 12.
#
#   ruby script/build_reserved_data.rb          # rewrites the five files, prints what it dropped
#
# File format (read by Usernames::Data):
#   - `#` starts a comment line; blank lines are ignored.
#   - Every block of words is preceded by `# source: <name> (<licence>) — <reason>`; <name> is a
#     row of data/NOTICE and a file in data/LICENSES/<name>.txt.
#   - One lowercase ASCII entry per line, sorted inside its block; an entry appears once per
#     file (first block wins); impersonation, system and mailboxes may share a word, web.txt never
#     repeats one of theirs.
#
# Exclusions (PRD §9.4, research 05): company/product names, all-digit entries (HTTP codes),
# entries of 1–2 characters except `me is it go my up`, entries with `/`, typos, and every first
# name / surname in test/corpora/ unless listed in ALLOWLIST_EXCEPTIONS.txt with a reason.

ROOT = File.expand_path("..", __dir__)
LISTS = File.join(ROOT, "docs/research/sources/reserved/lists")
OUT = File.join(ROOT, "data/reserved")

def read_list(name)
  File.readlines(File.join(LISTS, "#{name}.txt"), chomp: true).map { _1.strip.downcase }.reject(&:empty?)
end

def read_corpus(name)
  File.readlines(File.join(ROOT, "test/corpora", name), chomp: true)
    .map(&:strip).reject { _1.empty? || _1.start_with?("#") }.to_set
end

def words(str) = str.split

# --- Licences of the sources (the names match data/NOTICE and data/LICENSES/<name>.txt) --------
LICENCE = {
  "big-username-blocklist" => "MIT",
  "shouldbee" => "MIT",
  "mottie-github-reserved-names" => "MIT",
  "gitlab" => "MIT",
  "gitea" => "MIT",
  "django-registration" => "BSD-3-Clause",
  "forwardemail" => "MIT",
  "rfc2142" => "IETF standards facts",
  "iana-well-known-uris" => "CC0-1.0",
  "usernames" => "MIT"
}.freeze

# --- Short entries the PRD keeps (§9.1); `up` is the Rails 8 health-check route ------------------
SHORT_KEEP = words("me is it go my up").to_set

# --- Exclusions -----------------------------------------------------------------------------------
# Company, product and trademark names (PRD §17: "never vendored: … trademarks").
BRANDS = words(<<~W).to_set
  facebook github instagram twitter msn ipad iphone android paypal linux java javascript python ruby
  perl php mysql phpmyadmin phppgadmin phpredisadmin cpanel owa tux windows mac
  copilot github-copilot codespaces why-github git-guides gist gists gitea-actions
  ashrae gs1resolver terraform.json amphtml knx
W
# GitHub-only pages in Mottie's list that mean nothing outside github.com (research 05).
GITHUB_ONLY = words(<<~W).to_set
  hovercards save-net-neutrality dashboard-feed invalid-email-address user-attachments
  customer-stories works-with site-policy social-impact garage cla ten
W
TYPOS = words("iamges").to_set
# Words a source reserves as a path that read first as somebody's handle: refusing them costs real
# people more than the route collision it prevents (an app with such a page reserves it through its
# routes anyway).
PLAUSIBLE_USERNAMES = words("analysis").to_set

# --- Hand-typed facts (research 12): words retyped from public facts, no file copied -------------
IMPERSONATION = [
  ["usernames", "staff and authority roles (Mastodon, Discourse and Misskey defaults; facts only)",
   words(<<~W)],
     admin administrator administration superadmin superuser sysadmin sysop root staff moderator
     moderation mod owner operator maintainer founder cofounder ceo employee official
   W
  ["usernames", "support, trust and safety desks a scammer would pose as (research 05 §gaps)",
   words(<<~W)],
     support helpdesk help helpcenter helpline customerservice customersupport customercare appeals
     security verified verification trust trustandsafety safety compliance billing payments
   W
  ["usernames", "platform voices: the system itself, its bots and its announcements",
   words(<<~W)],
     system bot team announcement announcements notification notifications noreply donotreply
     mailerdaemon webmaster hostmaster postmaster abuse
   W
  ["usernames", "joined compounds that segment matching cannot see (admin_team is caught, adminteam is not)",
   words(<<~W)]
     adminteam supportteam staffteam modteam securityteam safetyteam officialaccount
   W
].freeze

SYSTEM = [
  ["usernames", "code sentinels and JavaScript prototype keys (research 12 §6)",
   words(<<~W)],
     null nil none undefined undef nan infinity true false void constructor hasownproperty prototype
     __proto__ then
   W
  ["usernames", "mention words: @everyone/@here/@channel/@all (Slack, Mattermost, Discourse, Misskey; facts only)",
   words(<<~W)],
     everyone here channel all mention mentions
   W
  ["usernames", "placeholders for deleted or absent users (GitHub's ghost, verified; the rest convention)",
   words(<<~W)],
     ghost deleted deleteduser deleted_user unknown anonymous anon removed suspended nobody
   W
  ["usernames", "pronoun and name placeholders (Discourse and Misskey defaults; facts only)",
   words(<<~W)],
     me you username user name nickname random-username host instance server
   W
  ["usernames", "Windows reserved device names (Microsoft Learn, file naming; facts only)",
   words(<<~W)],
     con prn aux nul com1 com2 com3 com4 com5 com6 com7 com8 com9 lpt1 lpt2 lpt3 lpt4 lpt5 lpt6 lpt7 lpt8 lpt9
   W
  ["usernames", "Windows built-in accounts (Microsoft Learn; facts only)",
   words(<<~W)],
     guest krbtgt helpassistant defaultaccount wdagutilityaccount
   W
  ["usernames", "Debian base-passwd users and groups, systemd service users (facts only)",
   words(<<~W)],
     daemon bin sys sync games man mail news uucp proxy www-data backup irc _apt nobody
     adm tty disk sudo users nogroup
     systemd-network systemd-resolve systemd-timesync systemd-coredump systemd-oom systemd-journal-remote
   W
  ["django-registration", "special hostnames: a username turned subdomain must not hijack client auto-configuration",
   words("autoconfig autodiscover broadcasthost isatap localdomain localhost wpad")],
  ["usernames", "RFC 2606 / RFC 6761 special-use names (facts only)",
   words("example test invalid localhost")]
].freeze

MAILBOXES = [
  ["rfc2142", "RFC 2142 role mailboxes", read_list("rfc2142")],
  ["django-registration", "mailboxes Certificate Authorities accept for domain validation",
   words("admin administrator hostmaster info is it mis postmaster root ssladmin ssladministrator") +
     words("sslwebmaster sysadmin webmaster")],
  ["django-registration", "protocol hostnames and no-reply addresses",
   words("ftp imap mail news pop pop3 smtp usenet uucp webmail www mailer-daemon nobody noreply no-reply")],
  ["forwardemail", "role and no-reply mailbox names (ASCII base names; leet/homoglyph variants are the matcher's job)",
   words(<<~W)]
     abuse administracion billing boletins bounce bounces conserje contabilidad contact contacto contato
     do-not-reply do-not-respond donotreply donotrespond email help hostmaster hr imap info mail
     mailer-daemon mailer.daemon mailerdaemon naoresponda no-reply no-replys no_reply noc noreply
     noreplys pop pop3 postmaster sales security smtp soporte ssl ssladministrator suporte support
     sys.administrator sysadmin sysadministrator system-administrator system.administrator
     systemadministrator tls vendas webmaster
   W
].freeze

RAILS_ROUTES = [
  ["usernames", "Rails core, Hotwire and Rails 8 generator routes (verified from Rails source, research 12 §4)",
   words(<<~W)],
     rails cable up assets active_storage action_mailbox conductor recede_historical_location
     resume_historical_location refresh_historical_location manifest service-worker offline
     passwords session healthz packs turbo
   W
  ["usernames", "authentication routes (Devise, Rails 8 auth generator, Doorkeeper, OmniAuth)",
   words("users admins sign_in sign_out sign_up password sessions login logout signin signup oauth auth")],
  ["usernames", "default mount paths of common engines (Sidekiq, Mission Control, admin frameworks, dev tools)",
   words("sidekiq jobs letter_opener pghero blazer lookbook admin avo madmin mini-profiler-resources __web_console")],
  ["usernames", "root-level files and scanner probes (meaningful when dots are an allowed separator)",
   words(<<~W)]
     robots.txt favicon.ico sitemap.xml manifest.json sw.js service-worker.js humans.txt security.txt
     ads.txt app-ads.txt browserconfig.xml opensearch.xml crossdomain.xml clientaccesspolicy.xml
     apple-touch-icon .env wp-admin wp-login.php wp-content xmlrpc.php
   W
].freeze

WEB_LISTS = [
  ["django-registration", "sensitive filenames and account/commerce paths (rationale per entry upstream)",
   "django_registration"],
  ["gitlab", "GitLab top-level and project wildcard routes", "gitlab"],
  ["gitea", "Gitea reserved usernames (real routes and files)", "gitea"],
  ["mottie-github-reserved-names", "GitHub's reserved top-level paths, minus GitHub-only pages", "mottie"],
  ["big-username-blocklist", "generic privileges, code, terms, financial, sections and actions", "bigblock"],
  ["shouldbee", "route-collision words", "shouldbee"],
  ["forwardemail", "generic account and environment words from the mailbox list (digit-free)", "forwardemail"],
  ["iana-well-known-uris", "IANA well-known URI suffixes (permanent and provisional)", "iana_wellknown"]
].freeze

EXCEPTIONS = {
  "root" => "Unix superuser and a CA validation mailbox; the impersonation risk outweighs the rare given name"
}.freeze

# --- Build ----------------------------------------------------------------------------------------
FIRST = read_corpus("first_names.txt")
SUR = read_corpus("surnames.txt")
DROPPED = Hash.new { |h, k| h[k] = Set.new }

def keep?(word) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
  reason =
    if word.include?("/") || word !~ /\A[a-z0-9._-]+\z/ then :charset
    elsif !/[a-z]/.match?(word) then :all_digits_or_no_letter
    elsif word.length <= 2 && !SHORT_KEEP.include?(word) then :too_short
    elsif BRANDS.include?(word) then :brand
    elsif GITHUB_ONLY.include?(word) then :github_only
    elsif TYPOS.include?(word) then :typo
    elsif PLAUSIBLE_USERNAMES.include?(word) then :plausible_username
    elsif (FIRST.include?(word) || SUR.include?(word)) && !EXCEPTIONS.key?(word) then :name
    end
  DROPPED[reason] << word if reason
  reason.nil?
end

render = lambda do |title, blocks, claimed|
  out = "# #{title}\n# Generated by script/build_reserved_data.rb — edit the script, not this file.\n"
  blocks.each do |source, reason, list|
    fresh = list.map(&:downcase).uniq.select { keep?(_1) }.reject { claimed.include?(_1) }.sort
    next if fresh.empty?

    claimed.merge(fresh)
    out << "\n# source: #{source} (#{LICENCE.fetch(source)}) — #{reason}\n" << fresh.join("\n") << "\n"
  end
  out
end

files = {
  "impersonation.txt" => [
    "Impersonation words: matched on the whole name, every segment, leet-folded, plural (PRD §9.2)", IMPERSONATION
  ],
  "system.txt" => ["System words: matched exactly", SYSTEM],
  "mailboxes.txt" => ["Mailbox and role names: matched exactly", MAILBOXES],
  "web.txt" => ["Web paths and generic reserved words: matched exactly",
                WEB_LISTS.map do |src, why, file|
                  [src, why, file == "forwardemail" ? read_list(file).grep_v(/\d/) : read_list(file)]
                end + RAILS_ROUTES]
}

small = Set.new
files.each do |name, (title, blocks)|
  # The three small categories may overlap (admin is impersonation AND a CA mailbox); web.txt is
  # the catch-all and never repeats a word another file already holds.
  claimed = name == "web.txt" ? small.dup : Set.new
  body = render.call(title, blocks, claimed)
  small.merge(claimed) unless name == "web.txt"
  File.write(File.join(OUT, name), body)
  puts "#{name.ljust(20)} #{body.lines.count { _1 !~ /\A(#|\s*\z)/ }.to_s.rjust(5)} entries"
end

exceptions_header = <<~TXT
  # Reserved words that are also a first name or surname in test/corpora/ and are kept on purpose.
  # One entry per line: `<word> # <reason>`. Generated by script/build_reserved_data.rb.
  # Every other name collision is dropped at build time (nick mac page price win old list ping).

  # source: usernames (MIT) — deliberate exceptions to the no-real-names rule
TXT
File.write(File.join(OUT, "ALLOWLIST_EXCEPTIONS.txt"),
           "#{exceptions_header}#{EXCEPTIONS.sort.map { |w, why| "#{w} # #{why}" }.join("\n")}\n")

puts "\nDropped:"
DROPPED.sort_by { |k, _| k.to_s }.each { |reason, set| puts "  #{reason} (#{set.size}): #{set.sort.join(' ')}" }
