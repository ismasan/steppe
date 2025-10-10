# frozen_string_literal: true

require 'steppe/auth'

module Steppe
  class Service
    VERBS = %i[get post put patch delete].freeze

    class Server < Types::Data
      attribute :url, Types::Forms::URI::HTTP
      attribute? :description, String

      def node_name = :server
    end

    class Tag < Types::Data
      attribute :name, String
      attribute :description, Types::String.nullable
      attribute :external_docs, Types::Forms::URI::HTTP.nullable
      def node_name = :tag
    end

    attr_reader :node_name, :servers, :tags, :security_schemes
    attr_accessor :title, :description, :version

    def initialize(&)
      @lookup = {}
      @title = ''
      @description = ''
      @version = '0.0.1'
      @node_name = :service
      @servers = []
      @tags = []
      @security_schemes = {}
      yield self if block_given?
      freeze
    end

    def [](name) = @lookup[name]
    def endpoints = @lookup.values

    def server(args = {})
      @servers << Server.parse(args)
      self
    end

    def tag(name, description: nil, external_docs: nil)
      @tags << Tag.parse(name:, description:, external_docs:)
      self
    end

    HashTokenStoreInterface = Types::Hash[String, Types::Array[String]]
    TokenStoreInterface = Types::Interface[:get]

    class HashTokenStore
      class AccessToken < Data.define(:scopes)
        def allows?(required_scopes)
          (scopes & required_scopes).any?
        end
      end

      def self.wrap(store)
        case store
        when HashTokenStoreInterface
          new(store)
        when TokenStoreInterface
          store
        else
          raise ArgumentError, "expected a TokenStore interface #{TokenStoreInterface}, but got #{store.inspect}"
        end
      end

      def initialize(hash)
        @lookup = hash.transform_values { |scopes| AccessToken.new(scopes) }
      end

      def get(token)
        @lookup[token]
      end
    end

    # Security schemes
    # https://swagger.io/docs/specification/v3_0/authentication/
    def bearer_auth(name, store: {}, format: 'string')
      store = HashTokenStore.wrap(store)
      security_scheme Auth::Bearer.new(name, store:, format:)
    end

    def security_scheme(scheme)
      @security_schemes[scheme.name] = scheme
      self
    end

    # A custom serializer that generates the OpenAPI specification in JSON format.
    class OpenAPISerializer
      # @param service [Steppe::Service] The service instance to generate the OpenAPI spec from.
      def initialize(service)
        @service = service
      end

      # @param conn [Steppe::Result]
      # @return [String] JSON data
      def render(conn)
        spec = Steppe::OpenAPIVisitor.from_request(@service, conn.request)
        JSON.dump(spec)
      end
    end

    # Generates an endpoint that serves the OpenAPI specification in JSON format.
    # @param path [String] The path where the OpenAPI spec will be available (default: '/')
    def specs(path = '/')
      get :__open_api, path do |e|
        e.no_spec!
        e.json 200..299, OpenAPISerializer.new(self)
      end
    end

    # Registers all defined endpoints with the given router.
    # The router is expected to respond to HTTP verb methods (e.g., get, post).
    # ie. router.get '/users/:id', to: rack_endpoint
    # @example
    #   app = MyService.route_with(Hanami::Router.new)
    #   run app
    #
    # @example
    #   app = Hanami::Router.new do
    #     scope '/api' do
    #       MyService.route_with(self)
    #     end
    #   end
    #
    # @param router [Object] A router instance that responds to HTTP verb methods (e.g., get, post).
    # @return [Object] The router with registered endpoints.
    def route_with(router)
      endpoints.each do |endpoint|
        router.public_send(endpoint.verb, endpoint.path.to_s, to: endpoint.to_rack)
      end
      router
    end

    VERBS.each do |verb|
      define_method(verb) do |name, path, &block|
        @lookup[name] = Endpoint.new(self, name, verb, path:, &block)
        self
      end
    end
  end
end
