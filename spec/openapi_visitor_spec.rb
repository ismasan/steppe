# frozen_string_literal: true

require 'rack'

RSpec.describe Steppe::OpenAPIVisitor do
  let(:service) do
    Steppe::Service.new do |s|
      s.bearer_auth 'BearerAuth', store: {}, format: 'JWT'
    end
  end

  specify 'query and header parameters schemas' do
    endpoint = Steppe::Endpoint.new(service, :test, :get, path: '/users/:id') do |e|
      e.description = 'Test endpoint'
      e.query_schema(
        id: Steppe::Types::Lax::Integer.desc('user id'),
        q?: Steppe::Types::String.desc('search by name')
      )
      e.header_schema 'ApiKey' => Steppe::Types::String.present.desc('The API key')
    end

    data = described_class.new.visit(endpoint)
    expect(data.dig('/users/{id}', 'get', 'description')).to eq('Test endpoint')
    expect(data.dig('/users/{id}', 'get', 'operationId')).to eq('test')
    data.dig('/users/{id}', 'get', 'parameters').tap do |params|
      expect(pluck(params, 'name')).to eq(%w[id q ApiKey])
      expect(pluck(params, 'in')).to eq(%w[path query header])
      expect(pluck(params, 'required')).to eq([true, false, true])
      expect(pluck(params, 'description')).to eq(['user id', 'search by name', 'The API key'])
      expect(params.dig(0, 'schema', 'type')).to eq('integer')
      expect(params.dig(1, 'schema', 'type')).to eq('string')
      expect(params.dig(2, 'schema', 'type')).to eq('string')
    end
  end

  specify 'payload parameters schema' do
    endpoint = Steppe::Endpoint.new(service, :test, :post, path: '/users') do |e|
      e.description = 'Test endpoint'
      e.payload_schema(
        name: Steppe::Types::String.desc('user name'),
        email: Steppe::Types::Email.desc('user email'),
        file?: Steppe::Types::UploadedFile.desc('user file')
      )
    end

    data = described_class.new.visit(endpoint)
    expect(data.dig('/users', 'post', 'requestBody', 'required')).to be(true)
    expect(data.dig('/users', 'post', 'requestBody', 'content', 'application/json')).to eq({
      'schema' => {
        'properties' => { 
          'email' => { 'description' => 'user email', 'format' => 'email', 'type' => 'string' },
          'name' => { 'description' => 'user name', 'type' => 'string' },
          'file' => { 'description' => 'user file', 'format' => 'byte', 'type' => 'string' },
        }, 
        'required' => %w[name email], 'type' => 'object'
      }
    })
  end

  specify 'security schemes' do
    endpoint = Steppe::Endpoint.new(service, :test, :post, path: '/users') do |e|
      e.security 'BearerAuth', %w[scope1 scope2]
    end

    data = described_class.new.visit(endpoint)
    # https://swagger.io/docs/specification/v3_0/authentication/bearer-authentication/
    expect(data.dig('/users', 'post', 'security', 0, 'BearerAuth')).to match_array(%w[scope1 scope2])
  end

  specify 'response body schema' do
    endpoint = Steppe::Endpoint.new(service, :test, :post, path: '/users') do |e|
      e.description = 'Test endpoint'
      e.tags = %w[users]
      e.json do
        attribute :name, String
        attribute :email, Steppe::Types::Email
      end
      # This one should be ignored by OpenAPIVisitor
      e.html(200) do |c|
      end
    end

    data = described_class.new.visit(endpoint)
    expect(data.dig('/users', 'post', 'description')).to eq('Test endpoint')
    expect(data.dig('/users', 'post', 'tags')).to eq(%w[users])
    expect(data.dig('/users', 'post', 'operationId')).to eq('test')
    expect(data.dig('/users', 'post', 'parameters')).to eq([])
    expect(data.dig('/users', 'post', 'responses', '2XX')).to eq({
      'description' => 'Response for status 200...300',
      'content' => {
        'application/json' => {
          'schema' => {
            'type' => 'object',
            'properties' => {
              'name' => {
                'type' => 'string'
              },
              'email' => {
                'type' => 'string',
                'format' => 'email'
              }
            },
            'required' => %w[name email]
          }
        }
      }
    })
  end

  describe 'Steppe::Service' do
    subject(:service) do
      Steppe::Service.new do |s|
        s.title = 'Users'
        s.description = 'Users service'
        s.version = '1.0.0'
        s.tag(
          'users',
          description: 'Users operations',
          external_docs: 'https://example.com/docs/users'
        )

        s.bearer_auth 'BearerAuth', store: {}, format: 'JWT'

        s.server(url: 'http://example.com', description: 'Production server')

        s.get :users, '/users' do |e|
          e.description = 'List users'
          e.security 'BearerAuth', %w[scope1 scope2]
        end

        s.post :create_user, '/users' do |e|
          e.description = 'Create user'
        end

        s.put :update_user, '/users/:id' do |e|
          e.query_schema(
            id: Steppe::Types::Lax::Integer.desc('user id').example(1)
          )
          e.description = 'Update user'
        end

        s.patch :patch_user, '/users/:id' do |e|
          e.description = 'Patch user'
        end

        s.delete :delete_user, '/users/:id' do |e|
          e.description = 'Delete user'
        end
      end
    end

    it 'generates OpenAPI spec for entire service' do
      data = described_class.call(service)
      expect(data['openapi']).to eq('3.0.0')
      expect(data['info']['title']).to eq('Users')
      expect(data['info']['description']).to eq('Users service')
      expect(data['info']['version']).to eq('1.0.0')
      expect(data['servers'][0]['url']).to eq('http://example.com')
      expect(data['servers'][0]['description']).to eq('Production server')
      expect(data['tags'][0]['name']).to eq('users')
      expect(data['tags'][0]['description']).to eq('Users operations')
      expect(data['tags'][0]['externalDocs']['url']).to eq('https://example.com/docs/users')
      id_param = data['paths'].values.last['put']['parameters'].first
      expect(id_param['name']).to eq('id')
      expect(id_param['in']).to eq('path')
      expect(id_param['required']).to be(true)
      expect(id_param['description']).to eq('user id')
      expect(id_param['schema']['type']).to eq('integer')
      expect(id_param['example']).to eq(1)
      expect(data.dig('components', 'securitySchemes', 'BearerAuth')).to eq(
        'type' => 'http',
        'scheme' => 'bearer',
        'bearerFormat' => 'JWT'
      )
    end
  end

  describe '.from_request' do
    let(:service) do
      Steppe::Service.new do |s|
        s.title = 'Test API'
        s.server(url: 'http://example.com', description: 'Production server')
      end
    end

    let(:request) { Rack::Request.new(Rack::MockRequest.env_for('https://foo.bar.com/users')) }

    it 'adds current server from request' do
      data = described_class.from_request(service, request)
      expect(data['servers'].last['url']).to eq('https://foo.bar.com')
      expect(data['servers'].last['description']).to eq('Current server')
    end

    it 'appends path_prefix to current server URL' do
      data = described_class.from_request(service, request, path_prefix: 'api')
      expect(data['servers'].last['url']).to eq('https://foo.bar.com/api')
    end

    it 'does not add duplicate server if URL already exists' do
      data = described_class.from_request(service, request, path_prefix: 'api')
      expect(data['servers'].count { |s| s['url'] == 'https://foo.bar.com/api' }).to eq(1)

      # Call again - should not add duplicate
      data = described_class.from_request(service, request, path_prefix: 'api')
      expect(data['servers'].count { |s| s['url'] == 'https://foo.bar.com/api' }).to eq(1)
    end

    it 'keeps paths relative to the server URL (no path prefix in paths)' do
      service = Steppe::Service.new do |s|
        s.title = 'Test API'
        s.get :users, '/users'
        s.get :user, '/users/:id'
      end

      data = described_class.from_request(service, request, path_prefix: 'api')
      # Paths remain relative - the server URL includes the prefix
      expect(data['paths'].keys).to contain_exactly('/users', '/users/{id}')
      expect(data['servers'].last['url']).to eq('https://foo.bar.com/api')
    end
  end

  def pluck(array, key)
    array.map { |h| h[key] }
  end
end
