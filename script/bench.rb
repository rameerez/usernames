#!/usr/bin/env ruby
# frozen_string_literal: true

# How long one Usernames.check takes (targets: p50 < 30 µs, p99 < 200 µs).
# A benchmark, not a test: numbers depend on the machine, so CI never asserts them.
#
#   bundle exec ruby script/bench.rb           # 10,000 checks
#   bundle exec ruby script/bench.rb 50000     # more
#
# The names are a mix of what a sign-up form sees: ordinary handles, generated
# names, reserved words, evasions and names that fail a format rule early.

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "usernames"

COUNT = Integer(ARGV.first || 10_000)

ordinary = %w[javi javi_r maria_garcia pedro2001 quiet_otter_42 scunthorpe_united therapist mike88 dominic_cummings
              hong_kong gcastro staffordshire teamwork adminbob game969 the_real_slim_shady abcdefghijabcdefghij]
refused = %w[admin adm1n_bob official_javi null everyone shithead1 xxfuckxx fu_ck scunt_horpe hh88 heil_hitler kkk]
odd = ["_javi", "ja vi", "josé", "a", "x" * 40, "12345", "  @Javi_R  "]
words = File.readlines(File.expand_path("../test/corpora/words_en_50k.txt", __dir__), chomp: true)
  .reject { |line| line.start_with?("#") }
names = Array.new(COUNT) do |index|
  case index % 10
  when 0..5 then words.sample
  when 6, 7 then ordinary.sample
  when 8 then refused.sample
  else odd.sample
  end
end

# Compile the rules and every lexicon before timing: that is a once-per-process cost.
Usernames.check("warm_up")
names.first(500).each { |name| Usernames.check(name) }

clock = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC, :float_microsecond) }
timings = names.map do |name|
  started = clock.call
  Usernames.check(name)
  clock.call - started
end.sort

percentile = ->(fraction) { timings[((timings.size - 1) * fraction).round] }
puts format("Usernames.check × %<count>d  (Ruby %<ruby>s)", count: COUNT, ruby: RUBY_VERSION)
puts format("  p50 %<p50>8.1f µs   (target < 30)", p50: percentile.call(0.50))
puts format("  p90 %<p90>8.1f µs", p90: percentile.call(0.90))
puts format("  p99 %<p99>8.1f µs   (target < 200)", p99: percentile.call(0.99))
puts format("  max %<max>8.1f µs", max: timings.last)
puts format("  total %<total>.1f ms", total: timings.sum / 1000.0)
