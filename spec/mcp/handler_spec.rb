# frozen_string_literal: true

require 'spec_helper'
require 'steppe/mcp/handler'

RSpec.describe Steppe::MCP::Handler do
  let(:service) do
    Steppe::Service.new do |api|
      api.title = 'Test API'
      api.version = '1.0.0'

      api.get :list_users, '/users' do |e|
        e.description = 'List all users'
        e.query_schema(
          q?: Steppe::Types::String.desc('Search query'),
          limit?: Steppe::Types::Lax::Integer.default(10)
        )
        e.step do |conn|
          users = [{ id: 1, name: 'Alice' }, { id: 2, name: 'Bob' }]
          users = users.select { |u| u[:name].downcase.include?(conn.params[:q].downcase) } if conn.params[:q]
          conn.valid(users.take(conn.params[:limit]))
        end
        e.json 200 do
          attribute :users, Steppe::Types::Array
          def users = object
        end
      end

      api.get :get_user, '/users/:id' do |e|
        e.description = 'Get a user by ID'
        e.query_schema(id: Steppe::Types::Lax::Integer.desc('User ID'))
        e.step do |conn|
          user = { id: conn.params[:id], name: 'Alice' }
          conn.valid(user)
        end
        e.json 200 do
          attribute :id, Steppe::Types::Integer
          attribute :name, Steppe::Types::String
          def id = object[:id]
          def name = object[:name]
        end
      end

      api.post :create_user, '/users' do |e|
        e.description = 'Create a new user'
        e.payload_schema(
          name: Steppe::Types::String.desc('User name'),
          email: Steppe::Types::String.desc('User email')
        )
        e.step do |conn|
          user = { id: 3, name: conn.params[:name], email: conn.params[:email] }
          conn.respond_with(201).valid(user)
        end
        e.json 201 do
          attribute :id, Steppe::Types::Integer
          attribute :name, Steppe::Types::String
          attribute :email, Steppe::Types::String
          def id = object[:id]
          def name = object[:name]
          def email = object[:email]
        end
      end
    end
  end

  subject(:handler) { described_class.new(service) }

  def mcp_request(method, params = nil, id: 1)
    body = { jsonrpc: '2.0', id: id, method: method }
    body[:params] = params if params
    Rack::MockRequest.env_for(
      '/mcp',
      method: 'POST',
      input: StringIO.new(JSON.dump(body)),
      'CONTENT_TYPE' => 'application/json'
    )
  end

  def parse_response(response)
    status, _headers, body = response
    [status, JSON.parse(body.first, symbolize_names: true)]
  end

  describe 'initialize handshake' do
    it 'responds to initialize request' do
      env = mcp_request('initialize', {
        protocolVersion: '2025-06-18',
        capabilities: {},
        clientInfo: { name: 'TestClient', version: '1.0.0' }
      })

      status, body = parse_response(handler.call(env))

      expect(status).to eq(200)
      expect(body[:jsonrpc]).to eq('2.0')
      expect(body[:id]).to eq(1)
      expect(body[:result][:protocolVersion]).to eq('2025-06-18')
      expect(body[:result][:capabilities]).to eq({ tools: {} })
      expect(body[:result][:serverInfo][:name]).to eq('Test API')
      expect(body[:result][:serverInfo][:version]).to eq('1.0.0')
    end

    it 'responds to initialized notification with 202' do
      env = mcp_request('notifications/initialized')

      status, _headers, body = handler.call(env)

      expect(status).to eq(202)
      expect(body).to eq([])
    end
  end

  describe 'tools/list' do
    it 'returns all specced endpoints as tools' do
      env = mcp_request('tools/list')

      status, body = parse_response(handler.call(env))

      expect(status).to eq(200)
      expect(body[:result][:tools]).to be_an(Array)
      expect(body[:result][:tools].length).to eq(3)

      tool_names = body[:result][:tools].map { |t| t[:name] }
      expect(tool_names).to contain_exactly('list_users', 'get_user', 'create_user')
    end

    it 'includes tool descriptions' do
      env = mcp_request('tools/list')

      _status, body = parse_response(handler.call(env))

      list_users = body[:result][:tools].find { |t| t[:name] == 'list_users' }
      expect(list_users[:description]).to eq('List all users')
    end

    it 'includes input schemas' do
      env = mcp_request('tools/list')

      _status, body = parse_response(handler.call(env))

      list_users = body[:result][:tools].find { |t| t[:name] == 'list_users' }
      expect(list_users[:inputSchema]).to be_a(Hash)
      expect(list_users[:inputSchema][:type]).to eq('object')
    end
  end

  describe 'tools/call' do
    it 'executes a GET endpoint with query params' do
      env = mcp_request('tools/call', {
        name: 'list_users',
        arguments: { q: 'alice', limit: 5 }
      })

      status, body = parse_response(handler.call(env))

      expect(status).to eq(200)
      expect(body[:result][:isError]).to eq(false)
      expect(body[:result][:content]).to be_an(Array)
      expect(body[:result][:content].first[:type]).to eq('text')

      content = JSON.parse(body[:result][:content].first[:text], symbolize_names: true)
      expect(content[:users]).to eq([{ id: 1, name: 'Alice' }])
    end

    it 'executes a GET endpoint with path params' do
      env = mcp_request('tools/call', {
        name: 'get_user',
        arguments: { id: 42 }
      })

      status, body = parse_response(handler.call(env))

      expect(status).to eq(200)
      expect(body[:result][:isError]).to eq(false)

      content = JSON.parse(body[:result][:content].first[:text], symbolize_names: true)
      expect(content[:id]).to eq(42)
    end

    it 'executes a POST endpoint with body params' do
      env = mcp_request('tools/call', {
        name: 'create_user',
        arguments: { name: 'Charlie', email: 'charlie@example.com' }
      })

      status, body = parse_response(handler.call(env))

      expect(status).to eq(200)
      expect(body[:result][:isError]).to eq(false)

      content = JSON.parse(body[:result][:content].first[:text], symbolize_names: true)
      expect(content[:name]).to eq('Charlie')
      expect(content[:email]).to eq('charlie@example.com')
    end

    it 'returns error for unknown tool' do
      env = mcp_request('tools/call', {
        name: 'unknown_tool',
        arguments: {}
      })

      status, body = parse_response(handler.call(env))

      expect(status).to eq(200)
      expect(body[:error]).to be_a(Hash)
      expect(body[:error][:code]).to eq(-32602)
      expect(body[:error][:message]).to include('Unknown tool')
    end
  end

  describe 'error handling' do
    it 'returns error for unknown method' do
      env = mcp_request('unknown/method')

      status, body = parse_response(handler.call(env))

      expect(status).to eq(200)
      expect(body[:error]).to be_a(Hash)
      expect(body[:error][:code]).to eq(-32601)
      expect(body[:error][:message]).to include('Method not found')
    end

    it 'returns 400 for invalid JSON' do
      env = Rack::MockRequest.env_for(
        '/mcp',
        method: 'POST',
        input: StringIO.new('not valid json'),
        'CONTENT_TYPE' => 'application/json'
      )

      status, _headers, body = handler.call(env)

      expect(status).to eq(400)
      parsed = JSON.parse(body.first, symbolize_names: true)
      expect(parsed[:error]).to eq('Invalid JSON')
    end
  end

  describe 'authentication passthrough' do
    let(:service_with_auth) do
      Steppe::Service.new do |api|
        api.title = 'Auth API'
        api.bearer_auth('BearerAuth', store: { 'validtoken' => ['read'] })

        api.get :protected, '/protected' do |e|
          e.security 'BearerAuth', ['read']
          e.description = 'Protected endpoint'
          e.step { |conn| conn.valid({ message: 'secret' }) }
          e.json 200 do
            attribute :message, Steppe::Types::String
            def message = object[:message]
          end
        end
      end
    end

    subject(:handler) { described_class.new(service_with_auth) }

    it 'passes Authorization header to endpoint' do
      env = Rack::MockRequest.env_for(
        '/mcp',
        method: 'POST',
        input: StringIO.new(JSON.dump({
          jsonrpc: '2.0',
          id: 1,
          method: 'tools/call',
          params: { name: 'protected', arguments: {} }
        })),
        'CONTENT_TYPE' => 'application/json',
        'HTTP_AUTHORIZATION' => 'Bearer validtoken'
      )

      status, body = parse_response(handler.call(env))

      expect(status).to eq(200)
      expect(body[:result][:isError]).to eq(false)
    end

    it 'returns error when auth fails' do
      env = Rack::MockRequest.env_for(
        '/mcp',
        method: 'POST',
        input: StringIO.new(JSON.dump({
          jsonrpc: '2.0',
          id: 1,
          method: 'tools/call',
          params: { name: 'protected', arguments: {} }
        })),
        'CONTENT_TYPE' => 'application/json'
        # No Authorization header
      )

      status, body = parse_response(handler.call(env))

      expect(status).to eq(200)
      expect(body[:result][:isError]).to eq(true)
    end
  end
end
