# frozen_string_literal: true

# From the root, run with:
#   bundle exec rackup examples/hanami.ru
#
require 'bundler'
Bundler.setup(:examples, :sinatra)

require 'hanami/router'
require 'rack/cors'
require_relative './service'

app = Service.route_with(Hanami::Router.new)
# app = Hanami::Router.new do
#   scope '/api' do
#     Service.route_with(self)
#   end
# end

# Allowing all origins
# to make Swagger UI work
use Rack::Cors do
  allow do
    origins '*'
    resource '*', headers: :any, methods: :any
  end
end

run app
