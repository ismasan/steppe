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
  end

  # describe 'html' do
  #   it 'returns a HTML response' do
  #     resp = described_class.new(statuses: 200, content_type: :html) do |pl|
  #       pl.serialize do |record|
  #         h1 record.name
  #         span "ID: #{record.id}"
  #       end
  #     end
  #
  #     conn = build_conn(record.new(1, 'John'))
  #
  #     conn = resp.call(conn)
  #     expect(conn.response.content_type).to eq('text/html')
  #     expect(conn.response.status).to eq(200)
  #     expect(conn.response.body).to eq([%(<h1>John</h1><span>ID: 1</span>)])
  #   end
  # end

  private

  def build_conn(value)
    request = build_request('/test')
    Steppe::Result::Continue.new(value, request:)
  end

  def build_request(path, query: {}, body: nil, content_type: 'application/json')
    Steppe::Request.new(Rack::MockRequest.env_for(
      path,
      'CONTENT_TYPE' => content_type,
      'action_dispatch.request.path_parameters' => query,
      Rack::RACK_INPUT => body ? StringIO.new(body) : nil
    ))
  end
end
