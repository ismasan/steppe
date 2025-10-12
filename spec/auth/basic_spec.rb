# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Steppe::Auth::Basic do
  subject(:scheme) do
    described_class.new('Test', store:)
  end

  let(:store) do
    {
      'joe' => 'secret'
    }
  end

  specify '#to_openapi' do
    expect(scheme.to_openapi).to eq('type' => 'http', 'scheme' => 'basic')
  end

  describe '#handle(conn)' do
    it 'returns 401 when no credentials given' do
      conn = conn_with('/users')
      conn = scheme.handle(conn)
      expect(conn.continue?).to be(false)
      expect(conn.response.status).to eq(401)
      expect(conn.response.headers['www-authenticate']).to match(/Basic realm="Test"/)
    end

    it 'returns 401 when wrong header scheme given' do
      conn = conn_with(
        '/users', 
        headers: { 'HTTP_AUTHORIZATION' => 'Bearer nope' }
      )

      conn = scheme.handle(conn)
      expect(conn.continue?).to be(false)
      expect(conn.response.status).to eq(401)
      expect(conn.response.headers['www-authenticate']).to match(/Basic realm="Test"/)
    end

    it 'returns 403 when wrong credentials given' do
      conn = conn_with(
        '/users', 
        headers: { 'HTTP_AUTHORIZATION' => encode('jane', '123') }
      )

      conn = scheme.handle(conn)
      expect(conn.continue?).to be(false)
      expect(conn.response.status).to eq(403)
    end

    it 'succeeds when right credentials given' do
      conn = conn_with(
        '/users', 
        headers: { 'HTTP_AUTHORIZATION' => encode('joe', 'secret') }
      )

      conn = scheme.handle(conn)
      expect(conn.continue?).to be(true)
      expect(conn.response.status).to eq(200)
    end
  end

  private

  def conn_with(...)
    request = build_request(...)
    Steppe::Result::Continue.new(nil, request:)
  end

  def encode(username, password)
    # concatenate by ':' and base64-encode credentials
    creds = [[username, password].join(':')].pack("m*")
    "Basic #{creds}"
  end
end
