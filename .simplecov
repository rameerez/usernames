# frozen_string_literal: true

# SimpleCov configuration file (auto-loaded by `require "simplecov"`).
# Configuration only: test/test_helper.rb calls SimpleCov.start, as SimpleCov
# 1.x asks (calling start from this file is deprecated there).

SimpleCov.configure do
  # Use SimpleFormatter for terminal-only output (no HTML generation)
  formatter SimpleCov::Formatter::SimpleFormatter

  # Report the gem's source (lib/), unloaded files included. skip/cover are
  # the SimpleCov 1.x names; 0.22 (the last release for Ruby 3.2) knows
  # add_filter/track_files.
  if respond_to?(:cover)
    skip "/test/"
    cover "lib/**/*.rb"
  else
    add_filter "/test/"
    track_files "lib/**/*.rb"
  end

  # Enable branch coverage for more detailed metrics
  enable_coverage :branch

  # Set minimum coverage threshold to prevent coverage regression
  minimum_coverage line: 90, branch: 90

  # Disambiguate parallel test runs
  command_name "Job #{ENV.fetch('TEST_ENV_NUMBER')}" if ENV["TEST_ENV_NUMBER"]
end

# Print coverage summary to terminal after tests complete
SimpleCov.at_exit do
  SimpleCov.result.format!
  puts "\n#{'=' * 60}"
  puts "COVERAGE SUMMARY"
  puts "=" * 60
  puts "Line Coverage:   #{SimpleCov.result.covered_percent.round(2)}%"
  puts "Branch Coverage: #{SimpleCov.result.coverage_statistics[:branch]&.percent&.round(2) || 'N/A'}%"
  puts "=" * 60
end
