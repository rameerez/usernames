# frozen_string_literal: true

require "test_helper"
require "json"
require "open3"

# JavaScript-compatible hints for rules 1–7, advisory only.
class BrowserRulesTest < UsernamesTestCase
  # Configurations whose browser rules must all lint and agree.
  CONFIGURATIONS = [
    {},
    { separators: %w[_ . -] },
    { separators: %w[-] },
    { separators: [] },
    { separators: %w[_ .], edge_separators: true },
    { case: :preserve, first_character: :letter },
    { length: 1..1 },
    { length: 2..15 }
  ].freeze

  # Ruby (Onigmo) syntax with no JavaScript meaning, or a different one.
  RUBY_ONLY = {
    "\\A" => /\\A/, "\\z" => /\\z/, "\\Z" => /\\Z/, "lookbehind" => /\(\?<[=!]/, "named group" => /\(\?<\w/,
    "\\h" => /\\h/, "\\p{...}" => /\\[pP]\{/, "atomic group" => /\(\?>/, "inline flags" => /\(\?[imx-]+[:)]/,
    "\\G" => /\\G/, "\\K" => /\\K/, "\\R" => /\\R/, "\\X" => /\\X/, "POSIX class" => /\[\[:/,
    "possessive quantifier" => /[*+?}]\+/, "comment group" => /\(\?#/, "\\u{...}" => /\\u\{/
  }.freeze

  def hints(**)
    Usernames.rules_for_browser(**)
  end

  # ---- Shape -------------------------------------------------------------------

  def test_the_default_hints
    expected = [
      [:username_spaces, Usernames::Rules::WHITESPACE_SOURCE],
      [:username_characters, "[^a-z0-9_]"],
      [:too_short, "^[\\s\\S]{0,2}$"],
      [:too_long, "[\\s\\S]{31}"],
      [:username_edges, "^[_]|[_]$"],
      [:username_consecutive, "[_]{2}"],
      [:username_digits_only, "^[^A-Za-z]+$"]
    ]

    assert_equal(expected, hints.map { |hint| [hint[:rule], hint[:pattern]] })
  end

  def test_every_hint_has_a_rule_a_pattern_and_a_message
    CONFIGURATIONS.each do |options|
      hints(**options).each do |hint|
        assert_equal %i[rule pattern message], hint.keys
        assert_kind_of Symbol, hint[:rule]
        assert_kind_of String, hint[:pattern]
        assert_kind_of String, hint[:message]
        refute_match(/translation missing/i, hint[:message])
      end
    end
  end

  def test_only_rules_one_to_seven_are_hinted
    rules = hints(separators: %w[_ .], first_character: :letter).map { |hint| hint[:rule] }

    assert_equal %i[username_spaces username_characters too_short too_long username_edges username_consecutive
                    username_first_character username_digits_only], rules
    refute_includes rules, :username_extension, "the extension list is the server's business"
    refute_includes rules, :username_unicode, "a refinement of username_characters' message, not a separate rule"
  end

  def test_rules_without_anything_to_check_are_left_out
    assert_empty(hints(separators: []).map { |hint| hint[:rule] } & %i[username_edges username_consecutive])
    refute_includes hints(edge_separators: true).map { |hint| hint[:rule] }, :username_edges
    refute_includes hints.map { |hint| hint[:rule] }, :username_first_character
  end

  def test_messages_are_in_the_current_locale
    I18n.with_locale(:es) do
      assert_equal "no puede contener espacios", hints.first[:message]
      assert_equal "es demasiado corto (3 caracteres mínimo)", hints.find { |hint| hint[:rule] == :too_short }[:message]
    end
  end

  def test_messages_follow_the_options
    characters = hints(separators: %w[_ .]).find { |hint| hint[:rule] == :username_characters }

    assert_equal "can only contain lowercase letters, numbers, underscores and periods", characters[:message]
  end

  # ---- Lint: a conservative subset both engines read the same way ---------------

  def test_no_source_uses_ruby_only_syntax
    CONFIGURATIONS.each do |options|
      hints(**options).each do |hint|
        RUBY_ONLY.each do |name, token|
          refute_match token, hint[:pattern], "#{hint[:rule]} #{options}: #{name} in #{hint[:pattern].inspect}"
        end
      end
    end
  end

  def test_every_source_compiles_as_a_ruby_regexp
    CONFIGURATIONS.each do |options|
      hints(**options).each { |hint| assert_kind_of Regexp, Regexp.new(hint[:pattern]) }
    end
  end

  def test_every_source_is_ascii
    CONFIGURATIONS.each do |options|
      hints(**options).each { |hint| assert_predicate hint[:pattern], :ascii_only?, hint[:pattern] }
    end
  end

  # ---- Agreement with the server, over the shared table --------------------------

  # Each source run the way JavaScript runs it: ^ and $ anchor the whole
  # string (no multiline flag), which in Ruby is \A and \z.
  def test_the_hints_agree_with_the_server_rules_on_every_row
    username_table.each do |input, expected, options|
      canonical = Usernames.normalize(input, **options)

      assert_equal browser_reason(expected) || :none, first_hint(canonical, **options) || :none,
                   "#{input.dump} → #{canonical.dump} #{options}"
    end
  end

  def test_the_whitespace_hint_matches_exactly_what_ruby_calls_space
    source = javascript(hints.first[:pattern])

    (0..0x3000).each do |code_point|
      next if code_point.between?(0xD800, 0xDFFF)

      character = [code_point].pack("U")

      assert_equal character.match?(/\p{Space}/), source.match?(character), format("U+%04X", code_point)
    end
  end

  # The real engine, when there is one: GitHub's runners ship Node.
  def test_the_hints_agree_with_the_server_rules_in_node
    node = ENV.fetch("NODE", "node")
    skip "node is not installed" unless system(node, "--version", out: File::NULL, err: File::NULL)

    rows = username_table
    configurations = rows.map(&:last).uniq
    payload = {
      hints: configurations.map { |options| hints(**options).map { |hint| [hint[:rule], hint[:pattern]] } },
      cases: rows.map do |input, _expected, options|
        [configurations.index(options), Usernames.normalize(input, **options)]
      end
    }
    output, error, status = Open3.capture3(node, "-e", NODE_SCRIPT, stdin_data: JSON.generate(payload))

    assert_predicate status, :success?, error
    JSON.parse(output).zip(rows).each do |answer, (input, expected, options)|
      assert_equal (browser_reason(expected) || :none).to_s, answer || "none", "#{input.dump} #{options}"
    end
  end

  # Compiles every source with and without the u flag, then reports the first
  # hint each case breaks.
  NODE_SCRIPT = <<~JS
    let input = "";
    process.stdin.on("data", (chunk) => { input += chunk; });
    process.stdin.on("end", () => {
      const { hints, cases } = JSON.parse(input);
      const compiled = hints.map((list) => list.map(([rule, source]) => {
        new RegExp(source, "u");
        return [rule, new RegExp(source)];
      }));
      const answers = cases.map(([configuration, value]) => {
        const hit = compiled[configuration].find(([, regexp]) => regexp.test(value));
        return hit ? hit[0] : null;
      });
      process.stdout.write(JSON.stringify(answers));
    });
  JS

  private

  # What the browser can say about a server verdict: the unicode message is
  # the characters rule in other words, and the extension rule (like every
  # content rule) is not hinted at all.
  def browser_reason(expected)
    case expected
    when :ok, :username_extension then nil
    when :username_unicode then :username_characters
    else expected
    end
  end

  def first_hint(value, **options)
    hints(**options).find { |hint| javascript(hint[:pattern]).match?(value) }&.fetch(:rule)
  end

  # A JavaScript source as Ruby would run it in JavaScript's place: ^ and $
  # at a branch's edge become \A and \z. Our sources have no other ^ or $
  # outside a character class.
  def javascript(source)
    Regexp.new(source.gsub(/(\A|[|(])\^/) { "#{Regexp.last_match(1)}\\A" }.gsub(/\$(?=\z|[|)])/, "\\z"))
  end
end
