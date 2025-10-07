# frozen_string_literal: true

require 'rack'
require_relative './spec_helper'

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
      e.json do
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


  class UserSerializer < Steppe::Serializer
    attribute :id, Integer
    attribute :name, String
  end

  specify 'nested serializers' do
    user_struct = Data.define(:id, :name)

    endpoint = Steppe::Endpoint.new(:test, :get, path: '/users') do |e|
      e.step do |conn|
        u1 = user_struct.new(1, 'Joe')
        conn.continue [u1]
      end

      e.json do
        attribute :users, [UserSerializer]

        def users = object
      end
    end

    request = build_request('/users')
    result = endpoint.run(request)
    expect(parse_body(result.response)).to eq(users: [{ id: 1, name: 'Joe' }])
  end

  describe '#to_rack' do
    it 'returns a Rack-compatible app' do
      endpoint = Steppe::Endpoint.new(:test, :get, path: '/users/:id') do |e|
        e.step do |conn|
          conn.valid(user_class.new(conn.params[:id], 'Joe'))
        end

        e.json do
          attribute :name, String
        end
      end

      request = build_request('/users/1', query: { id: '1' })
      app = endpoint.to_rack
      response = app.call(request.env)
      expect(response.body).to eq(['{"name":"Joe"}'])
    end
  end

  describe 'content negotiation' do
    let(:endpoint) do
      Steppe::Endpoint.new(:test, :get, path: '/users/:id') do |e|
        e.query_schema(
          id: Steppe::Types::Lax::Integer
        )

        # An Arbitrary step to do some work
        e.step do |conn|
          conn.continue(name: 'Joe', id: conn.params[:id])
        end

        # Respond to text/html requests
        # with Papercraft template
        e.html do |conn|
          h1 "User: #{conn.value[:name]}."
          p "ID: #{conn.value[:id]}."
        end

        # Respond to application/json requests
        # with inline serializer
        # This will generate OpenAPI schema automatically
        e.json do
          attribute :id, Integer
          attribute :name, String
          def name = object[:name]
          def id = object[:id]
        end
      end
    end

    specify 'HTML response' do
      request = build_request('/users/1', query: {id: '1'}, accepts: 'text/html')
      result = endpoint.run(request)
      expect(result.response.status).to eq(200)
      expect(result.response.content_type).to eq('text/html')
      expect(result.response.body).to eq(['<h1>User: Joe.</h1><p>ID: 1.</p>'])
    end

    specify 'JSON response' do
      request = build_request('/users/1', query: {id: '1'}, accepts: 'application/json')
      result = endpoint.run(request)
      expect(result.response.status).to eq(200)
      expect(result.response.content_type).to eq('application/json')
      expect(result.response.body).to eq(["{\"id\":1,\"name\":\"Joe\"}"])
    end
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
          age: Steppe::Types::Lax::Integer[18..],
          file?: Steppe::Types::UploadedFile.with(type: 'text/plain')
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

    context 'with form-encoded payload' do
      it 'uses the same payload schema' do
        request = build_request(
          '/users/1',
          content_type: 'application/x-www-form-urlencoded',
          accepts: 'application/json',
          body: 'name=Joe&age=19'
        )
        result = endpoint.run(request)
        expect(result.valid?).to be true
        expect(result.response.status).to eq(200)
        expect(result.params).to eq(name: 'Joe', age: 19)
      end

      it 'validates form params' do
        request = build_request(
          '/users/1',
          content_type: 'application/x-www-form-urlencoded',
          accepts: 'application/json',
          body: 'name=Joe&age=16'
        )
        result = endpoint.run(request)
        expect(result.response.status).to eq(422)
        expect(result.params).to eq(name: 'Joe', age: 16)
        expect(result.errors).to eq(age: 'Must be within 18..')
      end

      it 'parses multipart form params and wraps uploaded files' do
        body = <<~MULTIPART
          ------12345\r
          Content-Disposition: form-data; name="name"\r
          \r
          Joe\r
          ------12345\r
          Content-Disposition: form-data; name="age"\r
          \r
          19\r
          ------12345\r
          Content-Disposition: form-data; name="file"; filename="example.txt"\r
          Content-Type: text/plain\r
          \r
          This is the file content.\r
          ------12345--\r
        MULTIPART

        request = build_request(
          '/users/1',
          content_type: 'multipart/form-data; boundary=----12345',
          accepts: 'application/json',
          body:
        )

        result = endpoint.run(request)
        expect(result.response.status).to eq(200)
        expect(result.params[:name]).to eq('Joe')
        expect(result.params[:age]).to eq(19)
        expect(result.params[:file]).to be_a(Steppe::Types::UploadedFile)
        expect(result.params[:file].filename).to eq('example.txt')
        expect(result.params[:file].type).to eq('text/plain')
        expect(result.params[:file].tempfile.read).to eq('This is the file content.')
      end

      it 'validates uploaded files like any other Plumb type' do
        # Pass unexpected file content type
        body = <<~MULTIPART
          ------12345\r
          Content-Disposition: form-data; name="name"\r
          \r
          Joe\r
          ------12345\r
          Content-Disposition: form-data; name="age"\r
          \r
          19\r
          ------12345\r
          Content-Disposition: form-data; name="file"; filename="example.txt"\r
          Content-Type: text/foo\r
          \r
          This is the file content.\r
          ------12345--\r
        MULTIPART

        request = build_request(
          '/users/1',
          content_type: 'multipart/form-data; boundary=----12345',
          accepts: 'application/json',
          body:
        )

        result = endpoint.run(request)
        expect(result.response.status).to eq(422)
        expect(result.params[:name]).to eq('Joe')
        expect(result.params[:age]).to eq(19)
        expect(result.params[:file]).to be_a(Steppe::Types::UploadedFile)
        expect(result.params[:file].filename).to eq('example.txt')
        expect(result.params[:file].type).to eq('text/foo')
        expect(result.errors[:file]).not_to be_nil
      end
    end
  end

  specify 'full responder API with halted conn' do
    endpoint = Steppe::Endpoint.new(:test, :post, path: '/users') do |e|
      e.step do |conn|
        conn.invalid(errors: { name: 'is invalid' })
      end

      e.respond(statuses: 200) do |r|
        r.description = 'preferred'
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

  specify 'default response for 204 no content' do
    endpoint = Steppe::Endpoint.new(:test, :post, path: '/users') do |e|
      e.step do |conn|
        conn.respond_with(204)
      end
    end

    request = build_request('/users')
    result = endpoint.run(request)
    expect(result.response.status).to eq(204)
    expect(result.response.body).to eq([])
  end

  specify 'default response for 304 not modified' do
    endpoint = Steppe::Endpoint.new(:test, :post, path: '/users') do |e|
      e.step do |conn|
        conn.respond_with(304)
      end
    end

    request = build_request('/users')
    result = endpoint.run(request)
    expect(result.response.status).to eq(304)
    expect(result.response.body).to eq([])
  end
end
