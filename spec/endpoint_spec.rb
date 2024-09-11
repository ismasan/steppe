# frozen_string_literal: true

require 'rack'

RSpec.describe Steppe::Endpoint do
  let(:user_class) do
    Data.define(:id, :name)
  end

  specify 'processing request and building response' do
    endpoint = Steppe::Endpoint.new(:test, :get, path: '/users/:id') do |e|
      e.query_schema(
        id: Steppe::Types::Lax::Integer
      )
      e.step do |conn|
        conn.valid(user_class.new(conn.params[:id], 'Joe'))
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

    request = build_request('/users/1', query: { id: '1' })
    result = endpoint.run(request)
    expect(result.response.status).to eq(200)
    expect(result.response.content_type).to eq('application/json')
    expect(parse_body(result.response)).to eq(requested_at: now.iso8601, id: 1, name: 'Joe')
  end

  describe '#query_schema' do
    it 'builds #query_schema from path params' do
      endpoint = Steppe::Endpoint.new(:test, :get, path: '/users/:id')

      endpoint.query_schema.at_key(:id).tap do |field|
        expect(field).to be_a(Plumb::Composable)
        expect(field.metadata[:type]).to eq(String)
        expect(field.metadata[:in]).to eq(:path)
      end
    end

    it 'overrides path params definitions while keeping :in metadata' do
      endpoint = Steppe::Endpoint.new(:test, :get, path: '/users/:id') do |e|
        e.query_schema(
          id: Steppe::Types::Lax::Integer[10..100],
          q?: Steppe::Types::String
        )
      end

      endpoint.query_schema.at_key(:id).tap do |field|
        expect(field.metadata[:type]).to eq(Integer)
        expect(field.metadata[:in]).to eq(:path)
      end
      endpoint.query_schema.at_key(:q).tap do |field|
        expect(field.metadata[:type]).to eq(String)
        expect(field.metadata[:in]).to eq(:query)
      end
    end

    it 'merges query schema fields from steps that respond to #query_schema' do
      step_with_query_schema = Data.define(:query_schema) do
        def call(result) = result
      end

      endpoint = Steppe::Endpoint.new(:test, :get, path: '/users/:id') do |e|
        e.step step_with_query_schema.new(Steppe::Types::Hash[max: Integer])
      end
      expect(endpoint.query_schema.at_key(:id).metadata[:in]).to eq(:path)
      expect(endpoint.query_schema.at_key(:max).metadata[:in]).to eq(:query)
    end
  end

  describe '#payload_schema' do
    it 'adds schemas to #payload_schemas' do
      endpoint = Steppe::Endpoint.new(:test, :post, path: '/users') do |e|
        # Payload schemas are merged
        e.payload_schema(
          name: String,
          age: Integer
        )
        e.payload_schema(title: String)
        # Non-mergeable types are just replaced
        e.payload_schema 'text/plain', Steppe::Types::String
        e.payload_schema 'text/plain', Steppe::Types::String
      end
      expect(endpoint.payload_schemas['application/json'].at_key(:age).metadata[:type]).to eq(Integer)
      expect(endpoint.payload_schemas['application/json'].at_key(:name).metadata[:type]).to eq(String)
      expect(endpoint.payload_schemas['application/json'].at_key(:title).metadata[:type]).to eq(String)
      expect(endpoint.payload_schemas['text/plain']).to eq(Steppe::Types::String)
    end
  end

  describe 'validating query params' do
    subject(:endpoint) do
      Steppe::Endpoint.new(:test, :get, path: '/users/:id') do |e|
        e.query_schema(
          id: Steppe::Types::String[/^user-/],
          age?: Steppe::Types::Lax::Integer[18..]
        )
      end
    end

    context 'with invalid query or path params' do
      it 'sets status to 422 and uses built-in errors serializer' do
        request = build_request('/users/1', query: { id: '1', age: '19' })
        result = endpoint.run(request)
        expect(result.errors.any?).to be true
        expect(result.response.status).to eq(422)
        expect(result.response.content_type).to eq('application/json')
        expect(parse_body(result.response)).to eq(
          http: { status: 422 },
          params: { id: '1', age: 19 },
          errors: { id: 'Must match /^user-/' }
        )
      end
    end
  end

  describe 'validating payload params' do
    subject(:endpoint) do
      Steppe::Endpoint.new(:test, :post, path: '/users') do |e|
        e.payload_schema(
          name: Steppe::Types::String.present,
          age: Steppe::Types::Lax::Integer[18..]
        )
      end
    end

    context 'with invalid request body params' do
      it 'sets status to 422 and uses built-in errors serializer' do
        request = build_request('/users/1', query: { id: '1' }, body: '{"name": "Joe", "age": "17"}')
        result = endpoint.run(request)
        expect(result.response.status).to eq(422)
        expect(result.response.content_type).to eq('application/json')
        expect(parse_body(result.response)).to eq(
          http: { status: 422 },
          params: { name: 'Joe', age: 17 },
          errors: { age: 'Must be within 18..' }
        )
      end
    end

    context 'with valid params and no explicit responder' do
      it 'uses default responder/serializer' do
        request = build_request('/users/1', body: '{"name": "Joe", "age": "19"}')
        result = endpoint.run(request)
        expect(result.valid?).to be true
        expect(result.response.status).to eq(200)
        expect(parse_body(result.response)).to eq(
          http: { status: 200 },
          params: { name: 'Joe', age: 19 },
          errors: {}
        )
      end
    end
  end

  specify 'full responder API with halted conn' do
    endpoint = Steppe::Endpoint.new(:test, :post, path: '/users') do |e|
      e.step do |conn|
        conn.invalid(errors: { name: 'is invalid' })
      end

      e.respond(200) do |r|
        r.step do |conn|
          conn.valid(user_class.new(1, 'Joe'))
        end
        r.serialize do
          attribute :id, Integer
          attribute :name, String
        end
      end
    end

    request = build_request('/users')
    result = endpoint.run(request)
    expect(result.response.status).to eq(200)
    expect(parse_body(result.response)).to eq(
      id: 1,
      name: 'Joe'
    )
  end

  private

  def build_request(path, query: {}, body: nil, content_type: 'application/json')
    Steppe::Request.new(Rack::MockRequest.env_for(
                          path,
                          'CONTENT_TYPE' => content_type,
                          'action_dispatch.request.path_parameters' => query,
                          Rack::RACK_INPUT => body ? StringIO.new(body) : nil
                        ))
  end

  def parse_body(response)
    JSON.parse(response.body.first, symbolize_names: true)
  end
end
