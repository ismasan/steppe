# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Steppe::Responder do
  let(:record) { Data.define(:id, :name) }

  specify 'instantiating' do
    resp = described_class.new(statuses: 200, accepts: :json)
    expect(resp.statuses).to eq(200..200)
    expect(resp.accepts).to be_a(Steppe::ContentType)
    expect(resp.accepts.to_s).to eq('application/json')
    expect(resp.content_type).to be_a(Steppe::ContentType)
    expect(resp.content_type.to_s).to eq('application/json')
  end

  describe 'json' do
    it 'returns a JSON response' do
      resp = described_class.new(statuses: 200, content_type: :json) do |pl|
        pl.serialize do
          attribute :id, Integer
          attribute :name, String
        end
      end

      conn = build_conn(record.new(1, 'John'))

      conn = resp.call(conn)
      expect(conn.response.content_type).to eq('application/json')
      expect(conn.response.status).to eq(200)
      expect(conn.response.body).to eq(['{"id":1,"name":"John"}'])
    end

    it 'supports a named serializer' do
      serializer = Class.new(Steppe::Serializer) do
        attribute :id, Integer
        attribute :name, String
      end

      resp = described_class.new(statuses: 200, content_type: :json) do |pl|
        pl.serialize serializer
      end

      conn = build_conn(record.new(1, 'John'))

      conn = resp.call(conn)
      expect(conn.response.content_type).to eq('application/json')
      expect(conn.response.status).to eq(200)
      expect(conn.response.body).to eq(['{"id":1,"name":"John"}'])
    end
  end

  describe 'html' do
    it 'returns a HTML response' do
      resp = described_class.new(statuses: 200, content_type: :html) do |pl|
        pl.serialize do |conn|
          h1 conn.value.name
          span "ID: #{conn.value.id}"
        end
      end

      conn = build_conn(record.new(1, 'John'))

      conn = resp.call(conn)
      expect(conn.response.content_type).to eq('text/html')
      expect(conn.response.status).to eq(200)
      expect(conn.response.body).to eq([%(<h1>John</h1><span>ID: 1</span>)])
    end

    it 'supports a named serializer' do
      serializer = ->(conn) {
        h1 conn.value.name
        span "ID: #{conn.value.id}"
      }
      resp = described_class.new(statuses: 200, content_type: :html) do |pl|
        pl.serialize serializer
      end

      conn = build_conn(record.new(1, 'John'))

      conn = resp.call(conn)
      expect(conn.response.content_type).to eq('text/html')
      expect(conn.response.status).to eq(200)
      expect(conn.response.body).to eq([%(<h1>John</h1><span>ID: 1</span>)])
    end
  end
end
