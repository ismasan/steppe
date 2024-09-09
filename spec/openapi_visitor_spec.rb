# frozen_string_literal: true

require 'rack'

RSpec.describe Steppe::OpenAPIVisitor do
  specify 'GET Steppe::Endpoint' do
    endpoint = Steppe::Endpoint.new(:test, :get, path: '/users/:id') do |e|
      e.description = 'Test endpoint'
      e.query_schema(
        id: Steppe::Types::Lax::Integer.desc('user id'),
        q?: Steppe::Types::String.desc('search by name')
      )
    end

    data = described_class.new.visit(endpoint)
    expect(data.dig('/users/{id}', 'get', 'description')).to eq('Test endpoint')
    data.dig('/users/{id}', 'get', 'parameters').tap do |params|
      expect(pluck(params, 'name')).to eq(%w[id q])
      expect(pluck(params, 'in')).to eq(%w[path query])
      expect(pluck(params, 'required')).to eq([true, false])
      expect(pluck(params, 'description')).to eq(['user id', 'search by name'])
      expect(params.dig(0, 'schema', 'type')).to eq('integer')
      expect(params.dig(1, 'schema', 'type')).to eq('string')
    end
  end

  def pluck(array, key)
    array.map { |h| h[key] }
  end
end
