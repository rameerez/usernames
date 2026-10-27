# frozen_string_literal: true

module Usernames
  module Reserved
    # `rails usernames:reserved`: every reserved word in force and where it
    # comes from, for the day somebody asks why `x` is taken by nobody.
    #
    #   admin        impersonation · big-username-blocklist (MIT) — …
    #   recipe       config.reserved
    #   pricing      route /pricing
    #
    # A word on several lists is shown with the one that decides how it is
    # matched: impersonation first (it is matched in every spelling), then
    # your own lists, the bundled exact words and your routes.
    module Listing
      class << self
        # [[word, source], …], sorted by word, without the words
        # config.allowed lifts (see .allowed).
        def entries(rules = Usernames.configuration.rules_for)
          sources = {}
          impersonation(rules).each { |word, source| sources[word] ||= source }
          exact(rules).each { |word, source| sources[word] ||= source }
          routes(rules).each { |word| sources[word] ||= "route /#{word}" }
          lifted = allowed(rules)
          sources.except(*lifted).sort
        end

        # The words config.allowed lifts, sorted.
        def allowed(rules = Usernames.configuration.rules_for)
          keys(rules.allowed).sort
        end

        def report(io = $stdout, rules = Usernames.configuration.rules_for)
          words = entries(rules)
          width = words.map { |word, _source| word.length }.max.to_i
          io.puts "#{words.size} reserved names (impersonation words also refuse their spellings: adm1n, ad.min, admins)"
          words.each { |word, source| io.puts "  #{word.ljust(width)}  #{source}" }
          lifted = allowed(rules)
          io.puts "Lifted by config.allowed: #{lifted.join(' ')}" if lifted.any?
          io.puts "And whatever config.reserved_if reserves, asked after these lists." if rules.reserved_if
          words.size
        end

        private

        def impersonation(rules)
          bundled = Data.impersonation.to_set
          keys(rules.forbidden).map do |word|
            [word, bundled.include?(word) ? bundled_source(word) : "config.forbidden"]
          end +
            Reserved.app_names(rules).map { |word| [word, "impersonation · your app's name"] }
        end

        def exact(rules)
          bundled = Data.reserved.to_set
          custom, shipped = keys(rules.reserved).partition { |word| !bundled.include?(word) }
          custom.map { |word| [word, "config.reserved"] } + shipped.map { |word| [word, bundled_source(word)] }
        end

        def routes(rules)
          rules.reserve_routes ? Reserved.routes.to_a : []
        end

        # "web · gitlab (MIT) — GitLab top-level and project wildcard routes"
        def bundled_source(word)
          provenance = Reserved.source_of(word)
          return "bundled" unless provenance

          origin = [provenance.source, ("(#{provenance.licence})" if provenance.licence)].compact.join(" ")
          text = [provenance.category, (origin unless origin.empty?)].compact.join(" · ")
          provenance.reason ? "#{text} — #{provenance.reason}" : text
        end

        def keys(words)
          words.map { |word| word.strip.downcase(:ascii) }.uniq
        end
      end
    end
  end
end
