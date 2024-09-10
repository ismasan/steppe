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

    attr_reader :rel_name, :payload_schemas, :responders
    attr_accessor :description

    def initialize(rel_name, verb, path: '/', &)
      @rel_name = rel_name
      @verb = verb
      @path = Mustermann.new('')
      @responders = ResponderRegistry.new
      @query_schema = Types::Hash
      @payload_schemas = {}
      @description = 'An endpoint'
      self.path = path
      super(&)
      # Fallback responders
      respond 200..201, 'application/json', DefaultEntitySerializer
      respond 204, 'application/json', BLANK_JSON_OBJECT
      respond 404, 'application/json', DefaultEntitySerializer
      respond 422, 'application/json', DefaultEntitySerializer
    end

    def node_name = :endpoint

    module Utils
      def self.deep_symbolize_keys(hash)
        hash.each.with_object({}) do |(k, v), h|
          value = case v
          when Hash
            deep_symbolize_keys(v)
          when Array
            v.map { |e| e.is_a?(Hash) ? deep_symbolize_keys(e) : e }
          else
            v
          end
          h[k.to_sym] = value
        end
      end
    end

    class QueryValidator
      attr_reader :query_schema

      def initialize(query_schema)
        @query_schema = query_schema.is_a?(Hash) ? Types::Hash[query_schema] : query_schema
      end

      def call(conn)
        # TODO: handle deep symbolization in a more robust way
        # TODO: we should only validate the request PATH and QUERY params here
        result = query_schema.resolve(conn.request.params)
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

        # TODO: we should only validate the request BODY here
        # but we want to avoid parsing the body again
        # if an upstream framework already did it
        result = payload_schema.resolve(conn.request.params)
        conn = conn.copy(params: conn.params.merge(result.value))
        return conn if result.valid?

        conn.respond_with(422).invalid(errors: result.errors)
      end
    end

    def query_schema(sc = nil)
      if sc
        step(QueryValidator.new(sc))
      else
        @query_schema
      end
    end

    def payload_schema(*args)
      case args
      in [Hash => sc]
        step PayloadValidator.new(ContentTypes::JSON, sc)
      in [Plumb::Composable => sc]
        step PayloadValidator.new(ContentTypes::JSON, sc)
      in [String => content_type, Hash => sc]
        step PayloadValidator.new(content_type, sc)
      in [String => content_type, Plumb::Composable => sc]
        step PayloadValidator.new(content_type, sc)
      else
        raise ArgumentError, "Invalid arguments: #{args.inspect}. Expects [Hash] or [Plumb::Composable], and an optional content type."
      end
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

    def to_rack
      proc do |env|
      end
    end

    def run(request)
      result = Result::Continue.new(nil, request:)
      call(result)
    end

    def call(result)
      result = super(result)
      responder = responders.resolve(result) || FALLBACK_RESPONDER
      responder.call(result)
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
