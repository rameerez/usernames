# frozen_string_literal: true

require_relative "lib/usernames/version"

Gem::Specification.new do |spec|
  spec.name = "usernames"
  spec.version = Usernames::VERSION
  spec.authors = ["rameerez"]
  spec.email = ["rubygems@rameerez.com"]

  spec.summary = "Add usernames with validations to your Rails app: block reserved names, screen profanity, " \
                 "enforce case-insensitive uniqueness, suggest alternatives and generate default names"

  spec.description = "Add correct, secure usernames to any Rails model with one line (`has_username`). " \
                     "Format rules that read like English (no symbols at the edges, no two in a row, not all digits), " \
                     "a bundled list of reserved names (admin, root, login, your own routes) matched the way impersonators " \
                     "actually type them (ad.min, adm1n, admin2), offensive-word screening in severity tiers per language, " \
                     "case-insensitive uniqueness that actually uses your index, a free generated name for every account, " \
                     "suggestions when a name is taken, and a live availability check. No table, no network, no API key."

  spec.homepage = "https://github.com/rameerez/usernames"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/rameerez/usernames"
  spec.metadata["changelog_uri"] = "https://github.com/rameerez/usernames/blob/main/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"] = "https://github.com/rameerez/usernames/issues"
  spec.metadata["documentation_uri"] = "https://github.com/rameerez/usernames#readme"
  spec.metadata["rubygems_mfa_required"] = "true"

  # Specify which files should be added to the gem when it is released.
  # In a checkout `git ls-files -z` lists them. A copy without git — `git archive`d into
  # an app's vendor/ and loaded with `path:`, typically inside a production image that
  # has no git binary — falls back to the shipped directories, so loading the gemspec
  # never fails there. Bundled data (data/**, NOTICE, LICENSES/**) ships; the research
  # record (docs/) and maintainer scripts (script/) do not.
  gemspec = File.basename(__FILE__)
  development_files = %w[.ruby-version .simplecov .rubocop.yml AGENTS.md Appraisals CLAUDE.md Rakefile context7.json]
  tracked = begin
    IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) { |ls| ls.readlines("\x0", chomp: true) }
  rescue SystemCallError
    []
  end
  if tracked.empty?
    tracked = Dir.glob("{app,lib,config,data,sig}/**/*", base: __dir__) + %w[LICENSE.txt README.md CHANGELOG.md SECURITY.md]
  end
  spec.files = tracked.select { |f| File.file?(File.join(__dir__, f)) }.reject do |f|
    (f == gemspec) || development_files.include?(f) ||
      f.start_with?(*%w[bin/ gemfiles/ test/ spec/ features/ docs/ script/ .git .github appveyor Gemfile])
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  # Runtime dependencies: only what a host app needs. `normalizes` (Active Record) and the
  # controller `rate_limit` behind the availability endpoint arrived in Rails 7.1 / 7.2.
  spec.add_dependency "activemodel", ">= 7.2.0", "< 9.0"
  spec.add_dependency "activerecord", ">= 7.2.0", "< 9.0"
  spec.add_dependency "activesupport", ">= 7.2.0", "< 9.0"
  spec.add_dependency "railties", ">= 7.2.0", "< 9.0"

  # Optional, detected at runtime and never required here:
  #   any_ascii  — transliterates non-Latin names when generating from a real name
  #   moderate   — its word list is also consulted when the gem is loaded

  # Development dependencies live in the Gemfile, not here.
  # See: https://guides.rubygems.org/patterns/
end
