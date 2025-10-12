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
  end
end
