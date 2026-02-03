# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Steppe::Auth::Bearer do
  subject(:scheme) do
    described_class.new('Test', store:, format: 'opaque')
  end

  let(:store) do
    {
      'admintoken' => %w[read write],
      'publictoken' => %w[read]
    }
  end

  specify '#to_openapi' do
    expect(scheme.to_openapi).to eq(
      'type' => 'http', 
      'scheme' => 'bearer',
      'bearerFormat' => 'opaque'
    )
  end

  describe '#handle(conn)' do
    it 'returns 401 when no credentials given' do
      conn = conn_with('/users')
      conn = scheme.handle(conn, %[write])
      expect(conn.continue?).to be(false)
      expect(conn.response.status).to eq(401)
      expect(conn.response.headers['www-authenticate']).to match(/Bearer realm="Test"/)
    end

    it 'returns 401 when wrong header scheme given' do
      conn = conn_with(
        '/users', 
        headers: { 'HTTP_AUTHORIZATION' => 'Foo nope' }
      )

      conn = scheme.handle(conn, %w[write])
      expect(conn.continue?).to be(false)
      expect(conn.response.status).to eq(401)
      expect(conn.response.headers['www-authenticate']).to match(/Bearer realm="Test"/)
    end

    it 'returns 403 when wrong credentials given' do
      conn = conn_with(
        '/users', 
        headers: { 'HTTP_AUTHORIZATION' => 'Bearer nope' }
      )

      conn = scheme.handle(conn, %w[write])
      expect(conn.continue?).to be(false)
      expect(conn.response.status).to eq(403)
    end

    it 'returns 403 when token with insufficient scopes given' do
      conn = conn_with(
        '/users', 
        headers: { 'HTTP_AUTHORIZATION' => 'Bearer publictoken' }
      )

      conn = scheme.handle(conn, %w[write])
      expect(conn.continue?).to be(false)
      expect(conn.response.status).to eq(403)
    end

    it 'is successful when token with appropriate scopes given' do
      conn = conn_with(
        '/users',
        headers: { 'HTTP_AUTHORIZATION' => 'Bearer admintoken' }
      )

      conn = scheme.handle(conn, %w[write])
      expect(conn.continue?).to be(true)
      expect(conn.response.status).to eq(200)
    end

    it 'stores the access token in request env on success' do
      conn = conn_with(
        '/users',
        headers: { 'HTTP_AUTHORIZATION' => 'Bearer admintoken' }
      )

      conn = scheme.handle(conn, %w[write])
      access_token = conn.request.env[Steppe::Auth::Bearer::ACCESS_TOKEN_ENV_KEY]
      expect(access_token).to be_a(Steppe::Auth::Bearer::HashTokenStore::AccessToken)
      expect(access_token.scopes).to eq(%w[read write])
    end

    context 'with custom token store' do
      let(:access_token_class) do
        Class.new do
          attr_reader :user_id

          def initialize(user_id)
            @user_id = user_id
          end

          def allows?(conn, required_scopes)
            # Custom logic: check scopes and path
            required_scopes.include?('admin') || conn.request.path.start_with?('/public')
          end
        end
      end

      let(:custom_store) do
        token_class = access_token_class
        Class.new do
          define_method(:initialize) do |tokens|
            @tokens = tokens.transform_values { |user_id| token_class.new(user_id) }
          end

          def get(token)
            @tokens[token]
          end
        end.new({ 'usertoken' => 123 })
      end

      let(:scheme) do
        described_class.new('Custom', store: custom_store)
      end

      it 'delegates authorization to the access token' do
        conn = conn_with(
          '/users',
          headers: { 'HTTP_AUTHORIZATION' => 'Bearer usertoken' }
        )

        # Without admin scope and not on /public path, should be forbidden
        conn = scheme.handle(conn, %w[read])
        expect(conn.continue?).to be(false)
        expect(conn.response.status).to eq(403)
      end

      it 'allows access when token allows? returns true' do
        conn = conn_with(
          '/users',
          headers: { 'HTTP_AUTHORIZATION' => 'Bearer usertoken' }
        )

        # With admin scope, should be allowed
        conn = scheme.handle(conn, %w[admin])
        expect(conn.continue?).to be(true)
      end

      it 'passes conn to allows? for context-aware authorization' do
        conn = conn_with(
          '/public/resource',
          headers: { 'HTTP_AUTHORIZATION' => 'Bearer usertoken' }
        )

        # On /public path, should be allowed regardless of scopes
        conn = scheme.handle(conn, %w[read])
        expect(conn.continue?).to be(true)
      end
    end
  end
end
