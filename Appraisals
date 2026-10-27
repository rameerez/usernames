# frozen_string_literal: true

# NOTE: Rails < 7.2 is not compatible with Ruby 3.4
# (Logger became a bundled gem in Ruby 3.4, and only Rails 7.2+ handles this)
# See: https://stdgems.org/logger/

# Test against Rails 7.2 (the minimum this gem supports)
appraise "rails-7.2" do
  gem "rails", "~> 7.2.0"
end

# Test against Rails 8.0
appraise "rails-8.0" do
  gem "rails", "~> 8.0.0"
end

# Test against Rails 8.1 (latest)
appraise "rails-8.1" do
  gem "rails", "~> 8.1.2"
end
