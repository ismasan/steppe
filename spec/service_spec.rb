# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Steppe::Service do
  subject(:service) do
    described_class.new do |api|
      api.title = 'Users'
      api.description = 'Users service'
      api.version = '1.0.0'

      api.bearer_auth(
        'BearerAuth', 
        store: {
          'readtoken' => %w[all:read one:read],
          'writetoken' => %w[all:write one:write]
        }
      )

      api.specs('/schemas')

      api.get :users, '/users' do |e|
        e.security 'BearerAuth', ['all:read']
        e.description = 'List users'
      end

      api.post :create_user, '/users' do |e|
        e.security 'BearerAuth', ['all:write']
        e.description = 'Create user'
      end

      api.put :update_user, '/users/:id' do |e|
        e.description = 'Update user'
      end

      api.patch :patch_user, '/users/:id' do |e|
        e.description = 'Patch user'
      end

      api.delete :delete_user, '/users/:id' do |e|
        e.description = 'Delete user'
      end
    end
  end

  let(:token_store) do
    Class.new do
      def initialize(tokens)
        @tokens = tokens
      end

      def get(token) = @tokens.fetch(token)
    end
  end

  specify 'properties' do
    expect(service.title).to eq('Users')
    expect(service.description).to eq('Users service')
    expect(service.version).to eq('1.0.0')
    expect(service[:users].description).to eq('List users')
    expect(service[:create_user].description).to eq('Create user')
  end

  specify 'GET /schemas' do
    specs_endpoint = service[:__open_api]
    expect(specs_endpoint.path.to_s).to eq('/schemas')
    expect(specs_endpoint.verb).to eq(:get)

    request = build_request('/schemas')
    result = specs_endpoint.run(request)
    expect(result.valid?).to be true
    spec = parse_body(result.response)
    expect(spec.keys).to match_array(%i[openapi info servers tags paths components])
  end

  context 'security schemes' do
    describe '#security_scheme' do
      it 'allows valid interface' do
        scheme = Steppe::Auth::Bearer.new('test', store: {})
        endpoint = described_class.new do |api|
          api.security_scheme scheme
        end
        expect(endpoint.security_schemes['test']).to eq(scheme)
      end

      it 'blows up on unknown interface' do
        expect {
          endpoint = described_class.new do |api|
            api.security_scheme Object.new
          end
        }.to raise_error(NoMatchingPatternError)
      end
    end

    describe '#basic_auth' do
      it 'registers a BasicAuth scheme' do
        service = described_class.new do |api|
          api.basic_auth('MyAuth', store: {})
        end

        expect(service.security_schemes['MyAuth']).to be_a(Steppe::Auth::Basic)
      end
    end

    context 'handling request with an auth-protected endpoint' do
      it 'forbids access if no bearer token given' do
        request = build_request('/users')
        endpoint = service[:users]
        result = endpoint.run(request)
        expect(result.response.status).to eq(401)
      end

      it 'forbids access if wrong bearer token given' do
        request = build_request('/users', headers: { 'HTTP_AUTHORIZATION' => 'Bearer writetoken' })
        endpoint = service[:users]
        result = endpoint.run(request)
        expect(result.response.status).to eq(403)
      end
    end

    context 'applying security schemes at the service level' do
      subject(:service) do
        described_class.new do |api|
          api.title = 'Users'
          api.bearer_auth(
            'BearerAuth', 
            store: { 'readtoken' => %w[all:read one:read] }
          )

          # This endpoint doesn't get the BearerAuth scheme applied
          api.get :root, '/'

          # Endpoints registered after this get the BearerAuth scheme applied
          api.security 'BearerAuth', %w[all:read]

          api.get :users, '/users'
          api.post :create_user, '/users'
        end
      end

      it 'applies security scheme to all endpoints in the service' do
        expect(service[:root].registered_security_schemes['BearerAuth']).to be_nil
        expect(service[:users].registered_security_schemes['BearerAuth']).not_to be_nil
        expect(service[:create_user].registered_security_schemes['BearerAuth']).not_to be_nil
      end

      it 'registers header validators' do
        expect(service[:root].header_schema.at_key('HTTP_AUTHORIZATION')).to be_nil
        expect(service[:users].header_schema.at_key('HTTP_AUTHORIZATION')).not_to be_nil
        expect(service[:create_user].header_schema.at_key('HTTP_AUTHORIZATION')).not_to be_nil
      end
    end
  end
end
