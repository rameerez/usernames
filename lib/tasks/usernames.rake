# frozen_string_literal: true

namespace :usernames do
  desc "Read-only report on an existing username column: values to normalise, collisions, index and " \
       "collation (rails usernames:audit, usernames:audit[Member,handle] or usernames:audit[Member,handle,preserve])"
  task :audit, %i[model column case] => :environment do |_task, args|
    require "usernames/audit"

    args.with_defaults(model: "User", column: "username")
    model = args[:model].safe_constantize
    abort "[usernames] No model named #{args[:model]}. Usage: rails usernames:audit[User,username]" unless model
    if args[:case] && !%w[lowercase preserve].include?(args[:case])
      abort "[usernames] The case mode is lowercase or preserve (got #{args[:case]})."
    end

    # Always exits 0: this is a report, not a gate. Read it, then fix what
    # it lists in a migration you own. The case mode matters before
    # has_username is declared (the README runs the audit first): without
    # it, the configured mode is assumed.
    Usernames::Audit.new(model, args[:column], mode: args[:case]).report($stdout)
  end

  desc "Every reserved name in force and where it comes from (or usernames:reserved[Player,handle] " \
       "for one model's rules)"
  task :reserved, %i[model column] => :environment do |_task, args|
    require "usernames/reserved/listing"

    rules = Usernames.configuration.rules_for
    if args[:model]
      model = args[:model].safe_constantize
      abort "[usernames] No model named #{args[:model]}." unless model

      column = model.try(:_usernames)&.[]((args[:column] || "username").to_sym)
      rules = column.rules if column
    end
    Usernames::Reserved::Listing.report($stdout, rules)
  end
end
