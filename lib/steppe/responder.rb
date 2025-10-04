# frozen_string_literal: true

require 'steppe/content_type'

module Steppe
  class Responder < Plumb::Pipeline
    DEFAULT_STATUSES = (200..200).freeze
    DEFAULT_SERIALIZER = Types::Static[{}.freeze].freeze

    def self.inline_serializers
      @inline_serializers ||= {}
    end

    inline_serializers[:json] = proc do |block|
      Class.new(Serializer, &block)
    end

    attr_reader :statuses, :accepts, :content_type, :serializer
    attr_accessor :description

    def initialize(statuses: DEFAULT_STATUSES, accepts: ContentTypes::JSON, content_type: nil, &)
      @statuses = statuses.is_a?(Range) ? statuses : (statuses..statuses)
      @description = nil
      @accepts = ContentType.parse(accepts)
      @content_type = content_type ? ContentType.parse(content_type) : @accepts
      @content_type_subtype = @content_type.subtype.to_sym
      @serializer = DEFAULT_SERIALIZER
      super(&)
    end

    def serialize(serializer = nil, &block)
      @serializer = if serializer.nil?
        builder = self.class.inline_serializers.fetch(@content_type_subtype)
        builder.call(block)
      else
        serializer
      end

      step @serializer
    end

    def ==(other)
      other.is_a?(Responder) && other.statuses == statuses && other.content_type == content_type
    end

    def inspect = "<#{self.class}##{object_id} statuses:#{statuses} content_type:#{content_type}>"
    def node_name = :responder

    def call(conn)
      conn = super(conn)
      conn.respond_with(conn.response.status) do |response|
        response[Rack::CONTENT_TYPE] = content_type.to_s
        Rack::Response.new(conn.value, response.status, response.headers)
      end
    end
  end
end
