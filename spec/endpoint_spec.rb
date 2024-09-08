# frozen_string_literal: true

require 'rack'

RSpec.describe Steppe::Endpoint do
  let(:user_class) do
    Data.define(:id, :name)
  end

  specify 'processing request and building response' do
    endpoint = Steppe::Endpoint.new(:test) do |e|
      e.path '/users/:id'
      e.verb :get
      e.query_schema(
        id: Steppe::Types::Integer
      )
      e.step do |conn|
        conn.valid(user_class.new(conn.request.params['id'], 'Joe'))
      end

      # Compact syntax. Registers a responder
      # for JSON, (200..299) statuses with an
      # inline serializer
      e.serialize do
        attribute(:requested_at, Steppe::Types::Time.transform(String, &:iso8601))
        attribute :id, Integer
        attribute :name, String

        def requested_at = Time.now
      end
    end

    now = Time.now
    allow(Time).to receive(:now).and_return(now)

    request = Rack::Request.new(Rack::MockRequest.env_for('/users/1?id=1', 'CONTENT_TYPE' => 'application/json',
                                                                           'HTTP_ACCEPT' => 'application/json'))
    result = endpoint.run(request)
    expect(result.response.content_type).to eq('application/json')
    expect(JSON.parse(result.response.body)).to eq('requested_at' => now.iso8601, 'id' => '1', 'name' => 'Joe')
  end
end
