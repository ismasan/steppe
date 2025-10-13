# frozen_string_literal: true

source 'https://rubygems.org'

# Specify your gem's dependencies in steppe.gemspec
gemspec

gem 'rake', '~> 13.0'

gem 'debug'
gem 'rack-test', '>= 2.1'
gem 'rspec', '~> 3.0'

group :examples do
  gem 'puma'
  gem 'rack-cors'
  gem 'rackup'
end

group :sinatra do
  gem 'sinatra'
end

group :hanami do
  gem 'hanami-router', '2.3.0.beta1'
end

group :docs do
  gem 'kramdown'
  gem 'kramdown-parser-gfm'
end
