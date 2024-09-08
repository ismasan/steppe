# frozen_string_literal: true

require 'mustermann'
require 'steppe/responder'
require 'steppe/responder_registry'
require 'steppe/serializer'
require 'steppe/result'

module Steppe
  class Endpoint < Plumb::Pipeline
    DEFAULT_CLIENT_ERROR_RESPONDER = Responder.new(statuses: 400...500) do |r|
      r.serialize do
        attribute :errors, Steppe::Types::Hash
        def errors = result.errors
      end
    end

    FALLBACK_RESPONDER = Responder.new(statuses: 100...500) do |r|
      r.serialize do
        attribute :message, Steppe::Types::String
        attribute :params, Steppe::Types::Hash
        def params = result.params
        def message = "This endpoint has no responder/serializer defined for HTTP status #{result.response.status}"
      end
    end

    attr_reader :name, :params_schema

    def initialize(name, &)
      @name = name
      @verb = :get
      @path = Mustermann.new('/')
      @responders = ResponderRegistry.new
      @params_schema = Types::Hash
      super(&)
      respond DEFAULT_CLIENT_ERROR_RESPONDER
      respond FALLBACK_RESPONDER
    end

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

    def to_open_api
      {
        path => {
          verb => {
            summary: 'TODO',
            description: 'TODO',
            parameters: [],
            responses: @responders.each.reduce({}) { |ret, r| ret.merge(r.to_open_api) }
          }
        }
      }
    end

    def serialize(status = (200...300), serializer = nil, &block)
      serializer ||= Class.new(Serializer, &block)
      respond(status) do |r|
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

    def run(request)
      result = Result::Continue.new(nil, request:)
      call(result)
    end

    def call(result)
      result = validate_params(result)
      result = super(result) if result.valid?
      responder = @responders.resolve(result)
      responder.call(result)
    end

    private

    def validate_params(result)
      params_result = @params_schema.resolve(result.request.params)
      result = result.copy(params: params_result.value)
      return result if params_result.valid?

      result.response.status = 422
      result.invalid(errors: params_result.errors)
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
