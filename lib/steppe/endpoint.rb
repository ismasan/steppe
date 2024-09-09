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

    attr_reader :rel_name, :params_schema, :responders
    attr_accessor :description

    def initialize(rel_name, verb, path: '/', &)
      @rel_name = rel_name
      @verb = verb
      @path = Mustermann.new(path)
      @responders = ResponderRegistry.new
      @params_schema = Types::Hash
      @description = 'An endpoint'
      merge_path_params_into_params_schema!
      super(&)
      # Fallback responders
      respond 200..201, 'application/json', DefaultEntitySerializer
      respond 204, 'application/json', BLANK_JSON_OBJECT
      respond 404, 'application/json', DefaultEntitySerializer
      respond 422, 'application/json', DefaultEntitySerializer
    end

    def node_name = :endpoint

    QueryValidator = Data.define(:query_schema) do
      def call(result) = result
    end

    PayloadValidator = Data.define(:payload_schema) do
      def call(result) = result
    end

    def query_schema(sc)
      step(QueryValidator.new(sc))
    end

    def payload_schema(sc)
      step PayloadValidator.new(sc)
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
      result = validate_params(result)
      result = super(result) if result.valid?
      responder = responders.resolve(result) || FALLBACK_RESPONDER
      responder.call(result)
    end

    private

    def validate_params(result)
      # TODO: handle deep symbolization in a more robust way
      params_result = @params_schema.resolve(deep_symbolize_keys(result.request.params))
      result = result.copy(params: params_result.value)
      return result if params_result.valid?

      result.response.status = 422
      result.invalid(errors: params_result.errors)
    end

    def deep_symbolize_keys(hash)
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

    def prepare_step(callable)
      merge_query_schema(callable.query_schema) if callable.respond_to?(:query_schema)
      merge_payload_schema(callable.payload_schema) if callable.respond_to?(:payload_schema)
      callable
    end

    def merge_query_schema(sc)
      sc = sc._schema if sc.respond_to?(:_schema)
      annotated_sc = sc.each_with_object({}) do |(k, v), h|
        pin = @path.names.include?(k.to_s) ? :path : :query
        h[k] = Plumb::Composable.wrap(v).metadata(in: pin)
      end
      @params_schema += annotated_sc
    end

    def merge_payload_schema(sc)
      sc = sc._schema if sc.respond_to?(:_schema)
      annotated_sc = sc.each_with_object({}) do |(k, v), h|
        h[k] = Plumb::Composable.wrap(v).metadata(in: :body)
      end
      @params_schema += annotated_sc
    end

    def merge_path_params_into_params_schema!
      sc = @path.names.each_with_object({}) do |name, h| 
        name = name.to_sym
        field = @params_schema.at_key(name) || Steppe::Types::String
        field = field.metadata(in: :path)
        h[name] = field
      end
      @params_schema += sc
    end
  end
end
