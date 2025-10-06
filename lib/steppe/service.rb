# frozen_string_literal: true

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

    attr_reader :node_name, :servers, :tags
    attr_accessor :title, :description, :version

    def initialize(&)
      @lookup = {}
      @title = ''
      @description = ''
      @version = '0.0.1'
      @node_name = :service
      @servers = []
      @tags = []
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

    # A custom serializer that generates the OpenAPI specification in JSON format.
    class OpenAPISerializer
      # @param service [Steppe::Service] The service instance to generate the OpenAPI spec from.
      def initialize(service)
        @service = service
      end

      # @param conn [Steppe::Result]
      # @return [Steppe::Result] The result containing the OpenAPI spec in JSON format.
      def call(conn)
        spec = Steppe::OpenAPIVisitor.from_request(@service, conn.request)
        conn.continue JSON.dump(spec)
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

    VERBS.each do |verb|
      define_method(verb) do |name, path, &block|
        @lookup[name] = Endpoint.new(name, verb, path:, &block)
        self
      end
    end
  end
end
