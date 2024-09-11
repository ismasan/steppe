# frozen_string_literal: true

require 'mustermann'
require 'steppe/responder'
require 'steppe/responder_registry'
require 'steppe/serializer'
require 'steppe/result'

module Steppe
  class Endpoint < Plumb::Pipeline
    BLANK_JSON_OBJECT = Types::Static[{}.freeze]

    FALLBACK_RESPONDER = Responder.new(statuses: (100..599), accepts: 'application/json') do |r|
      r.serialize do
        attribute :message, String
        def message = "no responder registered for response status: #{result.response.status}"
      end
    end

    class DefaultEntitySerializer < Steppe::Serializer
      attribute :http, Steppe::Types::Hash[status: Types::Integer.example(200)]
      attribute :params, Steppe::Types::Hash.example({'param' => 'value'}.freeze)
      attribute :errors, Steppe::Types::Hash.example({'param' => 'is invalid'}.freeze)

      def http = { status: result.response.status }
      def params = result.params
      def errors = result.errors
    end

    class QueryValidator
      attr_reader :query_schema

      def initialize(query_schema)
        @query_schema = query_schema.is_a?(Hash) ? Types::Hash[query_schema] : query_schema
      end

      def call(conn)
        result = query_schema.resolve(conn.request.steppe_url_params)
        conn = conn.copy(params: conn.params.merge(result.value))
        return conn if result.valid?

        conn.respond_with(422).invalid(errors: result.errors)
      end
    end

    class PayloadValidator
      attr_reader :content_type, :payload_schema

      def initialize(content_type, payload_schema)
        @content_type = content_type
        @payload_schema = payload_schema.is_a?(Hash) ? Types::Hash[payload_schema] : payload_schema
      end

      def call(conn)
        return conn unless content_type == conn.request.content_type

        result = payload_schema.resolve(conn.request.body)
        conn = conn.copy(params: conn.params.merge(result.value))
        return conn if result.valid?

        conn.respond_with(422).invalid(errors: result.errors)
      end
    end

    class BodyParser
      MissingParserError = Class.new(ArgumentError)

      include Plumb::Composable

      def self.parsers
        @parsers ||= {}
      end

      parsers[ContentTypes::JSON] = proc do |body|
        ::JSON.parse(body.read, symbolize_names: true)
      end

      parsers[ContentTypes::TEXT] = proc do |body|
        body.read
      end

      def self.build(content_type)
        parser = parsers[content_type]
        raise MissingParserError, "No parser for content type: #{content_type}" unless parser

        new(content_type, parser)
      end

      def initialize(content_type, parser)
        @content_type = content_type
        @parser = parser
      end

      def call(conn)
        if conn.request.body
          body = @parser.call(conn.request.body)
          request = Rack::Request.new(conn.request.env.merge(::Rack::RACK_INPUT => body))
          return conn.copy(request:)
        end
        conn
      rescue StandardError => e
        conn.respond_with(400).invalid(errors: { body: e.message })
      end
    end

    attr_reader :rel_name, :payload_schemas, :responders
    attr_accessor :description, :tags

    def initialize(rel_name, verb, path: '/', &)
      @rel_name = rel_name
      @verb = verb
      @path = Mustermann.new('')
      @responders = ResponderRegistry.new
      @query_schema = Types::Hash
      @payload_schemas = {}
      @body_parsers = {}
      @description = 'An endpoint'
      @tags = []
      self.path = path
      super(freeze_after: false, &)

      # Fallback responders
      respond 200..201, 'application/json', DefaultEntitySerializer
      respond 204, 'application/json', BLANK_JSON_OBJECT
      respond 404, 'application/json', DefaultEntitySerializer
      respond 422, 'application/json', DefaultEntitySerializer
      freeze
    end

    def node_name = :endpoint

    def query_schema(sc = nil)
      if sc
        step(QueryValidator.new(sc))
      else
        @query_schema
      end
    end

    def payload_schema(*args)
      ctype, stp = case args
      in [Hash => sc]
        [ContentTypes::JSON, sc]
      in [Plumb::Composable => sc]
        [ContentTypes::JSON, sc]
      in [String => content_type, Hash => sc]
        [content_type, sc]
      in [String => content_type, Plumb::Composable => sc]
        [content_type, sc]
      else
        raise ArgumentError, "Invalid arguments: #{args.inspect}. Expects [Hash] or [Plumb::Composable], and an optional content type."
      end

      unless @body_parsers[ctype]
        step BodyParser.build(ctype)
        @body_parsers[ctype] = true
      end
      step PayloadValidator.new(ctype, stp)
    end

    def verb(vrb = nil)
      @verb = vrb if vrb
      @verb
    end

    def path(pth = nil)
      if pth
        @path = Mustermann.new(pth)
        merge_path_params_into_params_schema!
      end
      @path
    end

    def serialize(status = (200...300), serializer = nil, &block)
      serializer ||= Class.new(Serializer, &block)
      respond(status) do |r|
        r.description = "Response for status #{status}"
        r.serialize serializer
      end
      self
    end

    def respond(*args, &)
      case args
      in [Integer => status] if block_given?
        @responders << Responder.new(statuses: (status..status), &)
      in [Integer => status, String => accepts] if block_given?
        @responders << Responder.new(statuses: status, accepts:, &)
      in [Integer => status, String => accepts, Plumb::Composable => serializer]
        @responders << Responder.new(statuses: status, accepts:) { |r| r.serialize(serializer) }
      in [Range => status, String => accepts, Plumb::Composable => serializer]
        @responders << Responder.new(statuses: status, accepts:) { |r| r.serialize(serializer) }
      in [Range => statuses] if block_given?
        @responders << Responder.new(statuses:, &)
      in [Range => statuses, String => accepts] if block_given?
        @responders << Responder.new(statuses:, accepts:, &)
      in [Responder => responder]
        @responders << responder
      else
        raise ArgumentError, "Invalid arguments: #{args.inspect}"
      end
      self
    end

    def debug!
      step do |conn|
        debugger
        conn
      end
    end

    def to_rack
      proc do |env|
      end
    end

    def run(request)
      result = Result::Continue.new(nil, request:)
      call(result)
    end

    def call(conn)
      conn = super(conn)
      responder = responders.resolve(conn) || FALLBACK_RESPONDER
      # Conn might be a Halt now, because a step halted processing.
      # We set it back to Continue so that the responder pipeline
      # can process it through its steps.
      responder.call(conn.valid)
    end

    private

    def prepare_step(callable)
      merge_query_schema(callable.query_schema) if callable.respond_to?(:query_schema)
      merge_payload_schema(callable) if callable.respond_to?(:payload_schema)
      callable
    end

    def merge_query_schema(sc)
      annotated_sc = sc._schema.each_with_object({}) do |(k, v), h|
        pin = @path.names.include?(k.to_s) ? :path : :query
        h[k] = Plumb::Composable.wrap(v).metadata(in: pin)
      end
      @query_schema += annotated_sc
    end

    def merge_payload_schema(callable)
      content_type = callable.respond_to?(:content_type) ? callable.content_type : ContentTypes::JSON

      existing = @payload_schemas[content_type]
      if existing && existing.respond_to?(:+)
        existing += callable.payload_schema
      else
        existing = callable.payload_schema
      end
      @payload_schemas[content_type] = existing
    end

    def path=(pt)
      @path = Mustermann.new(pt)
      sc = @path.names.each_with_object({}) do |name, h| 
        name = name.to_sym
        field = @query_schema.at_key(name) || Steppe::Types::String
        field = field.metadata(in: :path)
        h[name] = field
      end
      @query_schema += sc
      @path
    end
  end
end
