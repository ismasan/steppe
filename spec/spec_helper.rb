# frozen_string_literal: true

require 'debug'
require 'steppe'

module TestHelpers
  private

  def build_conn(value)
    request = build_request('/test')
    Steppe::Result::Continue.new(value, request:)
  end

  def build_request(path, query: {}, body: nil, headers: {}, accepts: 'application/json', content_type: nil)
    content_type ||= accepts

    Steppe::Request.new(Rack::MockRequest.env_for(
      path,
      headers.merge({
        'CONTENT_TYPE' => content_type,
        'HTTP_ACCEPT' => accepts,
        Steppe::Request::ROUTER_PARAMS => query,
        Rack::RACK_INPUT => body ? StringIO.new(body) : nil
      })
    ))
  end

  def parse_body(response)
    JSON.parse(response.body.first, symbolize_names: true)
  end
end

RSpec.configure do |config|
  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = '.rspec_status'

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  config.include TestHelpers
end
