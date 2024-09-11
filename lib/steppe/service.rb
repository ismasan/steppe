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

    attr_reader :endpoints, :node_name, :servers, :tags
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

    VERBS.each do |verb|
      define_method(verb) do |name, path, &block|
        @lookup[name] = Endpoint.new(name, verb, path:, &block)
        self
      end
    end
  end
end
