# frozen_string_literal: true

require 'rack'

RSpec.describe Steppe::OpenAPIVisitor do
  specify 'request parameters schema' do
    endpoint = Steppe::Endpoint.new(:test, :get, path: '/users/:id') do |e|
      e.description = 'Test endpoint'
      e.query_schema(
        id: Steppe::Types::Lax::Integer.desc('user id'),
        q?: Steppe::Types::String.desc('search by name')
      )
    end

    data = described_class.new.visit(endpoint)
    expect(data.dig('/users/{id}', 'get', 'description')).to eq('Test endpoint')
    expect(data.dig('/users/{id}', 'get', 'operationId')).to eq('test')
    data.dig('/users/{id}', 'get', 'parameters').tap do |params|
      expect(pluck(params, 'name')).to eq(%w[id q])
      expect(pluck(params, 'in')).to eq(%w[path query])
      expect(pluck(params, 'required')).to eq([true, false])
      expect(pluck(params, 'description')).to eq(['user id', 'search by name'])
      expect(params.dig(0, 'schema', 'type')).to eq('integer')
      expect(params.dig(1, 'schema', 'type')).to eq('string')
    end
  end

  specify 'request parameters schema' do
    endpoint = Steppe::Endpoint.new(:test, :post, path: '/users') do |e|
      e.description = 'Test endpoint'
      e.payload_schema(
        name: Steppe::Types::String.desc('user name'),
        email: Steppe::Types::Email.desc('user email')
      )
    end
    data = described_class.new.visit(endpoint)
    expect(data.dig('/users', 'post', 'requestBody', 'required')).to be(true)
    expect(data.dig('/users', 'post', 'requestBody', 'content', 'application/json')).to eq({
                                                                                             'schema' => {
                                                                                               'properties' => { 'email' => { 'description' => 'user email', 'format' => 'email', 'type' => 'string' },
                                                                                                                 'name' => { 'description' => 'user name',
                                                                                                                             'type' => 'string' } }, 'required' => %w[name email], 'type' => 'object'
                                                                                             }
                                                                                           })
  end

  specify 'response body schema' do
    endpoint = Steppe::Endpoint.new(:test, :post, path: '/users') do |e|
      e.description = 'Test endpoint'
      e.serialize do
        attribute :name, String
        attribute :email, Steppe::Types::Email
      end
    end

    data = described_class.new.visit(endpoint)
    expect(data.dig('/users', 'post', 'description')).to eq('Test endpoint')
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

  def pluck(array, key)
    array.map { |h| h[key] }
  end
end
