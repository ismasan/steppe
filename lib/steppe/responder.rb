# frozen_string_literal: true

require 'json'
require 'steppe/content_type'

module Steppe
  class Responder < Plumb::Pipeline
    DEFAULT_STATUSES = (200..200).freeze
    DEFAULT_SERIALIZER = Types::Static[{}.freeze].freeze

    attr_reader :statuses, :content_type, :serializer
    attr_accessor :description

    def initialize(statuses: DEFAULT_STATUSES, accepts: nil, content_type: ContentTypes::JSON, &)
      @statuses = statuses.is_a?(Range) ? statuses : (statuses..statuses)
      @description = nil
      @content_type = ContentType.parse(content_type)
      @serializer = DEFAULT_SERIALIZER
      super(&)
    end

    def serialize(serializer = nil, &block)
      @serializer = serializer || Class.new(Serializer, &block)
      step @serializer
    end

    def ==(other)
      other.is_a?(Responder) && other.statuses == statuses && other.content_type == content_type
    end

    def inspect = "<#{self.class}##{object_id} statuses:#{statuses} content_type:#{content_type}>"
    def node_name = :responder

    # TODO: Content negotiation here
    # Perhaps wrap Request in this
    # https://github.com/sinatra/sinatra/blob/main/lib/sinatra/base.rb
    def accepts?(request)
      accept_header = request.env['HTTP_ACCEPT'] || request.content_type || ContentTypes::JSON
      accepts == accept_header
    end

    def call(conn)
      conn = super(conn)
      # Format the response body
      # TODO: this should do content negotiation
      # ie check the request's Accept header
      # for now we assume JSON
      conn = conn.respond_with(conn.response.status) do |response|
        response[Rack::CONTENT_TYPE] = ContentTypes::JSON
        body = conn.value.nil? ? nil : JSON.dump(conn.value)
        Rack::Response.new(body, response.status, response.headers)
      end
    end
  end
end
