# frozen_string_literal: true

require 'steppe/content_type'
require 'steppe/serializer'

module Steppe
  # Handles response formatting for specific HTTP status codes and content types.
  #
  # A Responder is a pipeline that processes a result and formats it into a Rack response.
  # Each responder is registered for a specific range of status codes and content type,
  # and includes a serializer to format the response body.
  #
  # @example Basic JSON responder
  #   Responder.new(statuses: 200, accepts: :json) do |r|
  #     r.serialize do
  #       attribute :message, String
  #       def message = "Success"
  #     end
  #   end
  #
  # @example HTML responder with Papercraft
  #   Responder.new(statuses: 200, accepts: :html) do |r|
  #     r.serialize do |result|
  #       html5 do
  #         h1 result.params[:title]
  #       end
  #     end
  #   end
  #
  # @example Responder for a range of status codes
  #   Responder.new(statuses: 200..299, accepts: :json) do |r|
  #     r.description = "Successful responses"
  #     r.serialize SuccessSerializer
  #   end
  #
  # @see Serializer
  # @see PapercraftSerializer
  class Responder < Plumb::Pipeline
    DEFAULT_STATUSES = (200..200).freeze
    DEFAULT_SERIALIZER = Types::Static[{}.freeze].freeze

    def self.inline_serializers
      @inline_serializers ||= {}
    end

    inline_serializers[:json] = proc do |block|
      block.is_a?(Proc) ? Class.new(Serializer, &block) : block
    end

    # Papercraft is an optional dependency, only required for HTML responses.
    # It is lazy-loaded here so JSON-only usage never needs it installed.
    inline_serializers[:html] = proc do |block|
      require 'papercraft'
      block
    rescue LoadError
      raise LoadError,
        "The 'papercraft' gem is required for HTML responses. Add `gem 'papercraft'` to your Gemfile."
    end

    # @return [Range] The range of HTTP status codes this responder handles
    attr_reader :statuses

    # @return [ContentType] The content type pattern this responder matches (from Accept header)
    attr_reader :accepts

    # @return [ContentType] The actual Content-Type header value set in the response
    attr_reader :content_type

    # @return [Serializer, Proc] The serializer used to format the response body
    attr_reader :serializer

    # @return [String, nil] Optional description of this responder (used in documentation)
    attr_accessor :description

    # Creates a new Responder instance.
    #
    # @param statuses [Integer, Range] HTTP status code(s) to handle (default: 200)
    # @param accepts [String, Symbol] Content type to match from Accept header (default: :json)
    # @param content_type [String, Symbol, nil] Specific Content-Type header for response (defaults to accepts value)
    # @param serializer [Class, Proc, nil] Serializer to format response body
    # @yield [responder] Optional configuration block
    # @yieldparam responder [Responder] self for configuration
    #
    # @example Basic responder
    #   Responder.new(statuses: 200, accepts: :json)
    #
    # @example With custom Content-Type header
    #   Responder.new(statuses: 200, accepts: :json, content_type: 'application/vnd.api+json')
    #
    # @example With inline serializer
    #   Responder.new(statuses: 200, accepts: :json) do |r|
    #     r.serialize { attribute :data, Object }
    #   end
    def initialize(statuses: DEFAULT_STATUSES, accepts: ContentTypes::JSON, content_type: nil, serializer: nil, &)
      @statuses = statuses.is_a?(Range) ? statuses : (statuses..statuses)
      @description = nil
      @accepts = ContentType.parse(accepts)
      @content_type = content_type ? ContentType.parse(content_type) : @accepts
      @content_type_subtype = @content_type.subtype.to_sym
      super(freeze_after: false, &)
      serialize(serializer) if serializer
      freeze
    end

    # Registers a serializer for this responder.
    #
    # The serializer is selected based on the content type's subtype (:json or :html).
    # For JSON responses, pass a Serializer class or a block that defines attributes.
    # For HTML responses, pass a Papercraft template or block.
    #
    # @param serializer [Class, Proc, nil] Serializer class or template
    # @yield Block to define inline serializer
    #
    # @raise [ArgumentError] If responder already has a serializer
    #
    # @example JSON serializer with block
    #   responder.serialize do
    #     attribute :users, [UserType]
    #     def users = result.params[:users]
    #   end
    #
    # @example JSON serializer with class
    #   responder.serialize(UserListSerializer)
    #
    # @example HTML serializer with Papercraft
    #   responder.serialize do |result|
    #     html5 { h1 result.params[:title] }
    #   end
    #
    # @return [void]
    def serialize(serializer = nil, &block)
      raise ArgumentError, "this responder already has a serializer" if @serializer

      builder = self.class.inline_serializers.fetch(@content_type_subtype)
      @serializer = builder.call(serializer || block)
      step do |conn|
        output = @serializer.render(conn)
        conn.copy(value: output)
      end
    end

    # Compares two responders for equality.
    #
    # Two responders are equal if they handle the same status codes and content type.
    #
    # @param other [Object] Object to compare
    # @return [Boolean] True if responders are equal
    def ==(other)
      other.is_a?(Responder) && other.statuses == statuses && other.content_type == content_type
    end

    # @return [String] Human-readable representation of the responder
    def inspect = "<#{self.class}##{object_id} #{description} statuses:#{statuses} content_type:#{content_type}>"

    # @return [Symbol] Node name for pipeline inspection
    def node_name = :responder

    # Processes the result through the serializer pipeline and creates a Rack response.
    #
    # @param conn [Result] The result object to process
    # @return [Result::Halt] Result with Rack response
    def call(conn)
      conn = super(conn)
      conn.respond_with(conn.response.status) do |response|
        response[Rack::CONTENT_TYPE] = content_type.to_s
        Rack::Response.new(conn.value, response.status, response.headers)
      end
    end
  end
end
