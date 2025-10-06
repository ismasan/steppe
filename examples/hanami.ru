# frozen_string_literal: true

# From the root, run with:
#   bundle exec rackup examples/hanami.ru
#
require 'bundler'
Bundler.setup(:examples, :sinatra)

require 'hanami/router'
require 'rack/cors'
require_relative './service'

app = Hanami::Router.new do
  Service.endpoints.each do |endpoint|
    public_send(endpoint.verb, endpoint.path.to_s, to: endpoint.to_rack)
  end
end

use Rack::Cors do
  allow do
    origins '*'
    resource '*', headers: :any, methods: :any
  end
end

run app
