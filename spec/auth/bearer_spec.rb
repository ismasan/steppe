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

    context 'when request already has an access token' do
      it 'skips the store and continues if token has required scopes' do
        conn = conn_with(
          '/users',
          headers: { 'HTTP_AUTHORIZATION' => 'Bearer admintoken' }
        )

        # First call authenticates and stores the token
        conn = scheme.handle(conn, %w[read])
        expect(conn.continue?).to be(true)

        # Second call skips the store lookup and checks scopes on existing token
        conn = scheme.handle(conn, %w[write])
        expect(conn.continue?).to be(true)
      end

      it 'returns 403 if existing token lacks required scopes' do
        conn = conn_with(
          '/users',
          headers: { 'HTTP_AUTHORIZATION' => 'Bearer publictoken' }
        )

        # First call authenticates with 'read' scope
        conn = scheme.handle(conn, %w[read])
        expect(conn.continue?).to be(true)

        # Second call requires 'write' scope, which publictoken doesn't have
        conn = scheme.handle(conn, %w[write])
        expect(conn.continue?).to be(false)
        expect(conn.response.status).to eq(403)
      end
    end

    context 'with custom authorizer' do
      it 'calls the authorizer block and continues when it returns conn' do
        conn = conn_with(
          '/users',
          headers: { 'HTTP_AUTHORIZATION' => 'Bearer admintoken' }
        )

        authorizer = ->(c, _scopes, _token) { c }
        conn = scheme.handle(conn, %w[write], authorizer:)
        expect(conn.continue?).to be(true)
        expect(conn.response.status).to eq(200)
      end

      it 'calls the authorizer block and halts when it returns a halted conn' do
        conn = conn_with(
          '/users',
          headers: { 'HTTP_AUTHORIZATION' => 'Bearer admintoken' }
        )

        authorizer = ->(c, _scopes, _token) { c.respond_with(403).invalid(errors: { auth: 'denied' }) }
        conn = scheme.handle(conn, %w[write], authorizer:)
        expect(conn.continue?).to be(false)
        expect(conn.response.status).to eq(403)
      end

      it 'works with an object that responds to #call' do
        conn = conn_with(
          '/users',
          headers: { 'HTTP_AUTHORIZATION' => 'Bearer admintoken' }
        )

        authorizer_class = Class.new do
          def call(conn, _scopes, _token)
            conn
          end
        end

        conn = scheme.handle(conn, %w[write], authorizer: authorizer_class.new)
        expect(conn.continue?).to be(true)
      end

      it 'receives the correct conn, required_scopes, and access_token arguments' do
        conn = conn_with(
          '/users',
          headers: { 'HTTP_AUTHORIZATION' => 'Bearer admintoken' }
        )

        received_args = nil
        authorizer = ->(c, scopes, token) {
          received_args = { conn: c, scopes: scopes, token: token }
          c
        }
        scheme.handle(conn, %w[write], authorizer:)

        expect(received_args[:conn]).to be_a(Steppe::Result::Continue)
        expect(received_args[:scopes]).to eq(%w[write])
        expect(received_args[:token]).to be_a(Steppe::Auth::Bearer::HashTokenStore::AccessToken)
        expect(received_args[:token].scopes).to eq(%w[read write])
      end

      it 'still runs authorizer with pre-authenticated request (token already in env)' do
        conn = conn_with(
          '/users',
          headers: { 'HTTP_AUTHORIZATION' => 'Bearer admintoken' }
        )

        # Pre-authenticate
        conn = scheme.handle(conn, %w[read])
        expect(conn.continue?).to be(true)

        # Now call with authorizer - should still run the authorizer
        authorizer_called = false
        authorizer = ->(c, _scopes, token) {
          authorizer_called = true
          expect(token.scopes).to eq(%w[read write])
          c
        }
        conn = scheme.handle(conn, %w[write], authorizer:)
        expect(authorizer_called).to be(true)
        expect(conn.continue?).to be(true)
      end

      it 'bypasses the default allows? check' do
        conn = conn_with(
          '/users',
          headers: { 'HTTP_AUTHORIZATION' => 'Bearer publictoken' }
        )

        # publictoken only has 'read' scope, so default check would fail for 'write'
        # but our custom authorizer allows it
        authorizer = ->(c, _scopes, _token) { c }
        conn = scheme.handle(conn, %w[write], authorizer:)
        expect(conn.continue?).to be(true)
      end
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
