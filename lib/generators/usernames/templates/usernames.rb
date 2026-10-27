# frozen_string_literal: true

# Every line below shows the default: uncomment one to change it.
# The README documents the less common options (first_character,
# reserve_routes, app_name, offensive.adapters, on_adapter_failure, generator,
# unique_index). Every option is also accepted per model:
#   has_username :handle, length: 2..24, case: :preserve
Usernames.configure do |config|
  # How long a username may be, in characters.
  # config.length          = 3..30

  # Which separators a name may contain.
  # %w[_ .] is Instagram-style (and adds the rule that a name can't end like a
  # file: .json, .png…) · %w[-] is GitHub- and subdomain-style.
  # config.separators      = %w[_]

  # true allows _javi_ (a dot is never allowed at an edge).
  # config.edge_separators = false

  # :preserve keeps the case people type (CoolCat) and still compares without
  # it (nobody else can be coolcat). Decide before you migrate: the unique
  # index is built for one mode.
  # config.case            = :lowercase

  # Reserved names. `+=` adds to the bundled lists; `=` replaces them.
  # config.reserved  += %w[]               # exact: nobody can be exactly this
  # config.forbidden += %w[]               # impersonation matching, like admin (ad.min, adm1n, admins)
  # config.allowed   += %w[]               # exceptions to the reserved checks

  # Offensive words, in severity tiers per language.
  # config.offensive.severity  = :strong   # :severe · :strong · :mild · :off
  # config.offensive.languages = %i[en es]
  # config.offensive.allowed  += %w[]      # exceptions to the offensive-word checks (a whole name or segment)
end
