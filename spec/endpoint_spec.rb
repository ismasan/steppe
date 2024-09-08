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

  describe '#query_schema' do
    it 'builds #params_schema from path params' do
      endpoint = Steppe::Endpoint.new(:test) do |e|
        e.path '/users/:id'
      end
      endpoint.params_schema.at_key(:id).tap do |field|
        expect(field).to be_a(Plumb::Composable)
        expect(field.metadata[:type]).to eq(String)
        expect(field.metadata[:in]).to eq(:path)
      end
    end

    it 'overrides path params definitions while keeping :in metadata' do
      endpoint = Steppe::Endpoint.new(:test) do |e|
        e.path '/users/:id'
        e.query_schema(
          id: Steppe::Types::Lax::Integer[10..100],
          q?: Steppe::Types::String
        )
      end

      endpoint.params_schema.at_key(:id).tap do |field|
        expect(field.metadata[:type]).to eq(Integer)
        expect(field.metadata[:in]).to eq(:path)
      end
      endpoint.params_schema.at_key(:q).tap do |field|
        expect(field.metadata[:type]).to eq(String)
        expect(field.metadata[:in]).to eq(:query)
      end
    end

    it 'merges query schema fields from steps that respond to #query_schema' do
      step_with_query_schema = Data.define(:query_schema) do
        def call(result) = result
      end

      endpoint = Steppe::Endpoint.new(:test) do |e|
        e.path '/users/:id'
        e.step step_with_query_schema.new(Steppe::Types::Hash[max: Integer])
      end
      expect(endpoint.params_schema.at_key(:id).metadata[:in]).to eq(:path)
      expect(endpoint.params_schema.at_key(:max).metadata[:in]).to eq(:query)
    end
  end

  describe '#payload_schema' do
    it 'adds fields to #params_schema' do
      endpoint = Steppe::Endpoint.new(:test) do |e|
        e.path '/users/:id'
        e.payload_schema(name: String)
      end
      expect(endpoint.params_schema.at_key(:id).metadata[:in]).to eq(:path)
      expect(endpoint.params_schema.at_key(:name).metadata[:in]).to eq(:body)
    end
  end
end
