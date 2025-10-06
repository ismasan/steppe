# frozen_string_literal: true

# From root, run with:
#   bundle exec ruby examples/sinatra.rb -p 4567
#
require 'bundler'
Bundler.setup(:examples, :sinatra)

require 'sinatra/base'
require 'rack/cors'
require_relative './service'

class SinatraRequestWrapper < SimpleDelegator
  def initialize(request, params)
    super(request)
    @steppe_url_params = params
  end

  attr_reader :steppe_url_params
end

class App < Sinatra::Base
  use Rack::Cors do
    allow do
      origins '*'
      resource '*', headers: :any, methods: :any
    end
  end

  Service.endpoints.each do |endpoint|
    public_send(endpoint.verb, endpoint.path.to_templates.first) do
      resp = endpoint.run(SinatraRequestWrapper.new(request, params)).response
      resp.finish
    end
  end

  run! if 'examples/sinatra.rb' == $0
end
