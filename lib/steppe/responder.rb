# frozen_string_literal: true

require 'json'

module Steppe
  class Responder < Plumb::Pipeline
    DEFAULT_STATUSES = (200..200).freeze

    attr_reader :statuses, :accepts, :serializer

    def initialize(statuses: DEFAULT_STATUSES, accepts: ContentTypes::JSON, &)
      @statuses = statuses.is_a?(Range) ? statuses : (statuses..statuses)
      @accepts = accepts
      @serializer = Types::Static[{}.freeze]
      super(&)
    end

    def serialize(serializer = nil, &block)
      @serializer = serializer || Class.new(Serializer, &block)
      step @serializer
    end

    # TODO: Content negotiation here
    # Perhaps wrap Request in this
    # https://github.com/sinatra/sinatra/blob/main/lib/sinatra/base.rb
    def accepts?(request)
      accept_header = request.env['HTTP_ACCEPT'] || request.content_type || ContentTypes::JSON
      accepts == accept_header
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
            @accepts => {
              schema: @serializer.to_json_schema
            }
          }
        }
      }
    end
  end
end
