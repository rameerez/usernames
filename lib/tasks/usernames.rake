# frozen_string_literal: true

namespace :usernames do
  desc "Read-only report on an existing username column: values to normalise, collisions, index and " \
       "collation (rails usernames:audit or usernames:audit[Member,handle])"
  task :audit, %i[model column] => :environment do |_task, args|
    require "usernames/audit"

    args.with_defaults(model: "User", column: "username")
    model = args[:model].safe_constantize
    abort "[usernames] No model named #{args[:model]}. Usage: rails usernames:audit[User,username]" unless model

    # Always exits 0: this is a report, not a gate. Read it, then fix what
    # it lists in a migration you own.
    Usernames::Audit.new(model, args[:column]).report($stdout)
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
