# frozen_string_literal: true

require 'json'

module Steppe
  class Responder < Plumb::Pipeline
    attr_reader :status, :serializer

    attr_reader :status

    def initialize(status: 200, &)
      @status = status
      @serializer = Types::Static[{}.freeze]
      super(&)
    end

    def serialize(serializer = nil, &block)
      @serializer = serializer || Class.new(Serializer, &block)
      step @serializer
    end

    def call(result)
      result = super(result)
      # Format the response body
      # TODO: this should do content negotiation
      # ie check the request's Accept header
      # for now we assume JSON
      result.response.body = JSON.dump(result.value)
      result.response.headers['Content-Type'] = 'application/json'
      result
    end

    def to_open_api
      {
        status.to_s => {
          description: 'TODO',
          content: {
            'application/json' => {
              schema: @serializer.to_json_schema
            }
          }
        }
      }
    end
  end
end
