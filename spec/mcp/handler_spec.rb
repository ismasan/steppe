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

  describe 'configuration freezing' do
    it 'freezes instructions after initialization' do
      handler = described_class.new(service) do |mcp|
        mcp.instructions = 'Test instructions'
      end

      expect { handler.instructions = 'New instructions' }.to raise_error(FrozenError)
    end

    it 'freezes prompts after initialization' do
      handler = described_class.new(service)

      expect { handler.prompt('test') { |p| p.description = 'Test' } }.to raise_error(FrozenError)
    end

    it 'allows configuration within the block' do
      handler = described_class.new(service) do |mcp|
        mcp.instructions = 'Instructions'
        mcp.prompt('test') { |p| p.description = 'Test prompt' }
      end

      expect(handler.instructions).to eq('Instructions')
    end
  end

  def mcp_request(method, params = nil, id: 1, session_id: nil, headers: {})
    body = { jsonrpc: '2.0', id: id, method: method }
    body[:params] = params if params
    env_headers = { 'CONTENT_TYPE' => 'application/json' }.merge(headers)
    env_headers['HTTP_MCP_SESSION_ID'] = session_id if session_id
    Rack::MockRequest.env_for(
      '/mcp',
      method: 'POST',
      input: StringIO.new(JSON.dump(body)),
      **env_headers
    )
  end

  def parse_response(response)
    status, headers, body = response
    parsed_body = body.first&.empty? ? nil : JSON.parse(body.first, symbolize_names: true)
    [status, headers, parsed_body]
  end

  def initialize_session(hdlr = handler)
    env = mcp_request('initialize', {
      protocolVersion: '2025-06-18',
      capabilities: {},
      clientInfo: { name: 'TestClient', version: '1.0.0' }
    })
    _status, headers, _body = parse_response(hdlr.call(env))
    headers['Mcp-Session-Id']
  end

  describe 'initialize handshake' do
    it 'responds to initialize request with session ID' do
      env = mcp_request('initialize', {
        protocolVersion: '2025-06-18',
        capabilities: {},
        clientInfo: { name: 'TestClient', version: '1.0.0' }
      })

      status, headers, body = parse_response(handler.call(env))

      expect(status).to eq(200)
      expect(headers['Mcp-Session-Id']).to be_a(String)
      expect(headers['Mcp-Session-Id']).not_to be_empty
      expect(body[:jsonrpc]).to eq('2.0')
      expect(body[:id]).to eq(1)
      expect(body[:result][:protocolVersion]).to eq('2025-06-18')
      expect(body[:result][:capabilities]).to eq({ tools: {} })
      expect(body[:result][:serverInfo][:name]).to eq('Test API')
      expect(body[:result][:serverInfo][:version]).to eq('1.0.0')
    end

    it 'responds to initialized notification with 202' do
      session_id = initialize_session
      env = mcp_request('notifications/initialized', session_id: session_id)

      status, _headers, body = handler.call(env)

      expect(status).to eq(202)
      expect(body).to eq([])
    end

    it 'does not include instructions when not set' do
      env = mcp_request('initialize', {
        protocolVersion: '2025-06-18',
        capabilities: {},
        clientInfo: { name: 'TestClient', version: '1.0.0' }
      })

      _status, _headers, body = parse_response(handler.call(env))

      expect(body[:result]).not_to have_key(:instructions)
    end

    context 'with instructions configured' do
      subject(:handler) do
        described_class.new(service) do |mcp|
          mcp.instructions = 'Use the list_users tool to fetch users. Always filter by name when searching.'
        end
      end

      it 'includes instructions in initialize response' do
        env = mcp_request('initialize', {
          protocolVersion: '2025-06-18',
          capabilities: {},
          clientInfo: { name: 'TestClient', version: '1.0.0' }
        })

        _status, _headers, body = parse_response(handler.call(env))

        expect(body[:result][:instructions]).to eq(
          'Use the list_users tool to fetch users. Always filter by name when searching.'
        )
      end
    end
  end

  describe 'session management' do
    context 'stateless mode (no session store)' do
      it 'returns 404 for requests without session ID' do
        env = mcp_request('tools/list')

        status, _headers, body = handler.call(env)

        expect(status).to eq(404)
        parsed = JSON.parse(body.first, symbolize_names: true)
        expect(parsed[:error]).to eq('Session not found')
      end

      it 'accepts any session ID' do
        env = mcp_request('tools/list', session_id: 'any-session-id')

        status, _headers, _body = parse_response(handler.call(env))

        expect(status).to eq(200)
      end

      it 'echoes session ID in response headers' do
        env = mcp_request('tools/list', session_id: 'my-session-123')

        _status, headers, _body = parse_response(handler.call(env))

        expect(headers['Mcp-Session-Id']).to eq('my-session-123')
      end

      it 'allows DELETE with any session ID' do
        env = Rack::MockRequest.env_for(
          '/mcp',
          method: 'DELETE',
          'HTTP_MCP_SESSION_ID' => 'any-session-id'
        )

        status, _headers, _body = handler.call(env)
        expect(status).to eq(204)
      end

      it 'returns 404 when DELETE has no session ID' do
        env = Rack::MockRequest.env_for('/mcp', method: 'DELETE')

        status, _headers, body = handler.call(env)
        expect(status).to eq(404)
      end
    end

    context 'with session store' do
      let(:session_store) do
        Class.new do
          def initialize
            @sessions = {}
          end

          def create
            id = SecureRandom.uuid
            @sessions[id] = true
            id
          end

          def valid?(id)
            @sessions.key?(id)
          end

          def delete(id)
            @sessions.delete(id)
          end
        end.new
      end

      subject(:handler) { described_class.new(service, session_store: session_store) }

      it 'validates session ID from store' do
        env = mcp_request('tools/list', session_id: 'invalid-session')

        status, _headers, body = handler.call(env)

        expect(status).to eq(404)
      end

      it 'accepts valid session from store' do
        session_id = initialize_session

        env = mcp_request('tools/list', session_id: session_id)
        status, _headers, _body = parse_response(handler.call(env))

        expect(status).to eq(200)
      end

      it 'DELETE invalidates session' do
        session_id = initialize_session
        env = Rack::MockRequest.env_for(
          '/mcp',
          method: 'DELETE',
          'HTTP_MCP_SESSION_ID' => session_id
        )

        status, _headers, _body = handler.call(env)
        expect(status).to eq(204)

        # Session should now be invalid
        env = mcp_request('tools/list', session_id: session_id)
        status, _headers, _body = handler.call(env)
        expect(status).to eq(404)
      end

      it 'returns 404 when deleting invalid session' do
        env = Rack::MockRequest.env_for(
          '/mcp',
          method: 'DELETE',
          'HTTP_MCP_SESSION_ID' => 'non-existent'
        )

        status, _headers, _body = handler.call(env)
        expect(status).to eq(404)
      end
    end
  end

  describe 'tools/list' do
    let(:session_id) { initialize_session }

    it 'returns all specced endpoints as tools' do
      env = mcp_request('tools/list', session_id: session_id)

      status, _headers, body = parse_response(handler.call(env))

      expect(status).to eq(200)
      expect(body[:result][:tools]).to be_an(Array)
      expect(body[:result][:tools].length).to eq(3)

      tool_names = body[:result][:tools].map { |t| t[:name] }
      expect(tool_names).to contain_exactly('list_users', 'get_user', 'create_user')
    end

    it 'includes tool descriptions' do
      env = mcp_request('tools/list', session_id: session_id)

      _status, _headers, body = parse_response(handler.call(env))

      list_users = body[:result][:tools].find { |t| t[:name] == 'list_users' }
      expect(list_users[:description]).to eq('List all users')
    end

    it 'includes input schemas' do
      env = mcp_request('tools/list', session_id: session_id)

      _status, _headers, body = parse_response(handler.call(env))

      list_users = body[:result][:tools].find { |t| t[:name] == 'list_users' }
      expect(list_users[:inputSchema]).to be_a(Hash)
      expect(list_users[:inputSchema][:type]).to eq('object')
    end
  end

  describe 'tools/call' do
    let(:session_id) { initialize_session }

    it 'executes a GET endpoint with query params' do
      env = mcp_request('tools/call', {
        name: 'list_users',
        arguments: { q: 'alice', limit: 5 }
      }, session_id: session_id)

      status, _headers, body = parse_response(handler.call(env))

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
      }, session_id: session_id)

      status, _headers, body = parse_response(handler.call(env))

      expect(status).to eq(200)
      expect(body[:result][:isError]).to eq(false)

      content = JSON.parse(body[:result][:content].first[:text], symbolize_names: true)
      expect(content[:id]).to eq(42)
    end

    it 'executes a POST endpoint with body params' do
      env = mcp_request('tools/call', {
        name: 'create_user',
        arguments: { name: 'Charlie', email: 'charlie@example.com' }
      }, session_id: session_id)

      status, _headers, body = parse_response(handler.call(env))

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
      }, session_id: session_id)

      status, _headers, body = parse_response(handler.call(env))

      expect(status).to eq(200)
      expect(body[:error]).to be_a(Hash)
      expect(body[:error][:code]).to eq(-32602)
      expect(body[:error][:message]).to include('Unknown tool')
    end
  end

  describe 'error handling' do
    let(:session_id) { initialize_session }

    it 'returns error for unknown method' do
      env = mcp_request('unknown/method', session_id: session_id)

      status, _headers, body = parse_response(handler.call(env))

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

    let(:session_id) { initialize_session(handler) }

    it 'passes Authorization header to endpoint' do
      env = mcp_request('tools/call',
        { name: 'protected', arguments: {} },
        session_id: session_id,
        headers: { 'HTTP_AUTHORIZATION' => 'Bearer validtoken' }
      )

      status, _headers, body = parse_response(handler.call(env))

      expect(status).to eq(200)
      expect(body[:result][:isError]).to eq(false)
    end

    it 'returns error when auth fails' do
      env = mcp_request('tools/call',
        { name: 'protected', arguments: {} },
        session_id: session_id
        # No Authorization header
      )

      status, _headers, body = parse_response(handler.call(env))

      expect(status).to eq(200)
      expect(body[:result][:isError]).to eq(true)
    end
  end

  describe 'prompts' do
    subject(:handler) do
      described_class.new(service) do |mcp|
        mcp.prompt 'greet_user' do |p|
          p.description = 'Greet a user by name'
          p.argument :name, required: true, description: 'User name'
          p.messages do |args|
            [{ role: 'user', content: { type: 'text', text: "Say hello to #{args[:name]}" } }]
          end
        end

        mcp.prompt 'code_review' do |p|
          p.description = 'Review code quality'
          p.argument :code, required: true
          p.argument :language, required: false, description: 'Programming language'
          p.messages do |args|
            lang = args[:language] ? " (#{args[:language]})" : ''
            [
              { role: 'user', content: { type: 'text', text: "Review this code#{lang}:\n#{args[:code]}" } },
              { role: 'assistant', content: { type: 'text', text: "I'll analyze this code for quality issues..." } }
            ]
          end
        end
      end
    end

    let(:session_id) { initialize_session(handler) }

    describe 'initialize with prompts' do
      it 'includes prompts capability' do
        env = mcp_request('initialize', {
          protocolVersion: '2025-06-18',
          capabilities: {},
          clientInfo: { name: 'TestClient', version: '1.0.0' }
        })

        _status, _headers, body = parse_response(handler.call(env))

        expect(body[:result][:capabilities]).to eq({ tools: {}, prompts: {} })
      end
    end

    describe 'prompts/list' do
      it 'returns all defined prompts' do
        env = mcp_request('prompts/list', session_id: session_id)

        status, _headers, body = parse_response(handler.call(env))

        expect(status).to eq(200)
        expect(body[:result][:prompts]).to be_an(Array)
        expect(body[:result][:prompts].length).to eq(2)

        prompt_names = body[:result][:prompts].map { |p| p[:name] }
        expect(prompt_names).to contain_exactly('greet_user', 'code_review')
      end

      it 'includes prompt descriptions' do
        env = mcp_request('prompts/list', session_id: session_id)

        _status, _headers, body = parse_response(handler.call(env))

        greet = body[:result][:prompts].find { |p| p[:name] == 'greet_user' }
        expect(greet[:description]).to eq('Greet a user by name')
      end

      it 'includes prompt arguments' do
        env = mcp_request('prompts/list', session_id: session_id)

        _status, _headers, body = parse_response(handler.call(env))

        greet = body[:result][:prompts].find { |p| p[:name] == 'greet_user' }
        expect(greet[:arguments]).to eq([
          { name: 'name', required: true, description: 'User name' }
        ])

        review = body[:result][:prompts].find { |p| p[:name] == 'code_review' }
        expect(review[:arguments]).to contain_exactly(
          { name: 'code', required: true },
          { name: 'language', required: false, description: 'Programming language' }
        )
      end
    end

    describe 'prompts/get' do
      it 'returns prompt with generated messages' do
        env = mcp_request('prompts/get', {
          name: 'greet_user',
          arguments: { name: 'Alice' }
        }, session_id: session_id)

        status, _headers, body = parse_response(handler.call(env))

        expect(status).to eq(200)
        expect(body[:result][:description]).to eq('Greet a user by name')
        expect(body[:result][:messages]).to eq([
          { role: 'user', content: { type: 'text', text: 'Say hello to Alice' } }
        ])
      end

      it 'returns prompt with multiple messages' do
        env = mcp_request('prompts/get', {
          name: 'code_review',
          arguments: { code: 'def foo; end', language: 'ruby' }
        }, session_id: session_id)

        status, _headers, body = parse_response(handler.call(env))

        expect(status).to eq(200)
        expect(body[:result][:messages].length).to eq(2)
        expect(body[:result][:messages].first[:content][:text]).to include('ruby')
        expect(body[:result][:messages].first[:content][:text]).to include('def foo; end')
      end

      it 'returns error for unknown prompt' do
        env = mcp_request('prompts/get', {
          name: 'unknown_prompt',
          arguments: {}
        }, session_id: session_id)

        status, _headers, body = parse_response(handler.call(env))

        expect(status).to eq(200)
        expect(body[:error]).to be_a(Hash)
        expect(body[:error][:code]).to eq(-32602)
        expect(body[:error][:message]).to include('Unknown prompt')
      end
    end

    context 'handler without prompts' do
      subject(:handler) { described_class.new(service) }

      it 'does not include prompts capability' do
        env = mcp_request('initialize', {
          protocolVersion: '2025-06-18',
          capabilities: {},
          clientInfo: { name: 'TestClient', version: '1.0.0' }
        })

        _status, _headers, body = parse_response(handler.call(env))

        expect(body[:result][:capabilities]).to eq({ tools: {} })
      end

      it 'returns empty prompts list' do
        session_id = initialize_session(handler)
        env = mcp_request('prompts/list', session_id: session_id)

        _status, _headers, body = parse_response(handler.call(env))

        expect(body[:result][:prompts]).to eq([])
      end
    end
  end
end
