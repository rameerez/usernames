# frozen_string_literal: true

require "test_helper"
require "open3"
require "rubygems/package"

# The bundled data and its licences ship in the gem; the research
# record, the tests and the maintainer scripts do not. Built for real with
# `gem build`, so what is checked is what `gem push` would upload.
class PackagingTest < UsernamesTestCase
  ROOT = File.expand_path("../..", __dir__)
  OUTPUT = File.join(ROOT, "tmp", "packaging")

  def self.contents
    @contents ||= begin
      FileUtils.mkdir_p(OUTPUT)
      path = File.join(OUTPUT, "usernames.gem")
      _output, error, status = Open3.capture3(Gem.ruby, "-S", "gem", "build", "usernames.gemspec", "--output", path,
                                              chdir: ROOT)
      raise "gem build failed: #{error}" unless status.success?

      Gem::Package.new(path).contents
    end
  end

  # What git tracks: the gemspec packages `git ls-files`, so a file is only
  # in the gem once it is committed.
  def tracked(*paths)
    output, status = Open3.capture2("git", "ls-files", "-z", "--", *paths, chdir: ROOT)
    skip "not a git checkout" unless status.success?
    output.split("\x0")
  end

  def contents
    self.class.contents
  end

  def test_ships_the_data_its_notice_and_its_licences
    assert_includes contents, "data/NOTICE"
    refute_empty contents.grep(%r{\Adata/LICENSES/.+\.txt\z})
    assert_empty tracked("data") - contents, "every tracked data file ships"
  end

  # The engine's endpoint, its JavaScript and its importmap pins.
  def test_ships_the_app_directory_and_the_importmap
    assert_includes contents, "app/controllers/usernames/availability_controller.rb"
    assert_includes contents, "app/assets/javascripts/usernames/index.js"
    assert_includes contents, "app/assets/javascripts/usernames/username_check_controller.js"
    assert_includes contents, "config/importmap.rb"
    assert_empty tracked("app") - contents, "every tracked file under app/ ships"
  end

  def test_ships_the_locales_and_the_library
    assert_includes contents, "config/locales/usernames.en.yml"
    assert_includes contents, "lib/usernames.rb"
    assert_empty tracked("config/locales") - contents
    assert_empty tracked("lib") - contents, "every tracked file under lib/ (generators and rake tasks included) ships"
    assert_includes contents, "README.md"
    assert_includes contents, "LICENSE.txt"
  end

  # The shipped code explains itself: no pointer into the unpublished
  # design documents (section numbers, decision ids, phase notes), which a
  # reader of the gem — or of a file a generator copied into their app —
  # could never follow.
  def test_shipped_code_never_points_into_unpublished_documents
    pointers = /PRD|§|\bD-\d+\b|\bR\d-\d+\b|NOTE\(p|research \d+/
    found = contents.grep(%r{\A(app|lib|config|sig)/}).flat_map do |file|
      File.readlines(File.join(ROOT, file)).each_with_index.filter_map do |line, index|
        "#{file}:#{index + 1}" if line.match?(pointers)
      end
    end

    assert_empty found
  end

  # A copy without git — `git archive`d into an app's vendor/ and loaded
  # with `path:` inside an image that has no git binary — must still load
  # the gemspec, and its file list must still cover everything the built
  # gem ships under the code and data directories.
  def test_gemspec_loads_where_git_is_missing
    no_git = File.join(OUTPUT, "empty-path")
    FileUtils.mkdir_p(no_git)
    script = 'puts Gem::Specification.load("usernames.gemspec").files'
    output, error, status = Open3.capture3({ "PATH" => no_git }, Gem.ruby, "-e", script, chdir: ROOT)

    assert_predicate status, :success?, "the gemspec failed to load without git: #{error}"
    files = output.split("\n")

    assert_includes files, "lib/usernames.rb"
    assert_includes files, "data/NOTICE"
    assert_includes files, "README.md"
    assert_includes files, "app/assets/javascripts/usernames/index.js"
    assert_empty contents.grep(%r{\A(app|lib|config|data|sig)/}) - files, "the fallback list misses shipped files"
    assert_empty files.grep(%r{\A(test|docs|script)/})
    refute_includes files, "usernames.gemspec"
  end

  def test_leaves_development_files_out
    %w[docs/ test/ script/ bin/ gemfiles/ .github/].each do |prefix|
      assert_empty contents.grep(/\A#{Regexp.escape(prefix)}/), "#{prefix} is not packaged"
    end
    %w[.ruby-version .rubocop.yml .simplecov Gemfile Rakefile Appraisals AGENTS.md CLAUDE.md
       context7.json].each do |file|
      refute_includes contents, file
    end
  end
end
