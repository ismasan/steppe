# frozen_string_literal: true

require 'json'

module Steppe
  # Base class for response serialization in Steppe endpoints.
  #
  # Serializers transform response data into structured output using Plumb types
  # and attributes. They provide a declarative way to define the structure of
  # response bodies with type validation and examples for OpenAPI documentation.
  #
  # @example Basic serializer for a user resource
  #   class UserSerializer < Steppe::Serializer
  #     attribute :id, Types::Integer.example(1)
  #     attribute :name, Types::String.example('Alice')
  #     attribute :email, Types::Email.example('alice@example.com')
  #
  #     # Optional: custom attribute methods
  #     def name
  #       object.full_name.titleize
  #     end
  #   end
  #
  # @example Nested serializers and arrays
  #   class UserListSerializer < Steppe::Serializer
  #     attribute :users, [UserSerializer]
  #     attribute :count, Types::Integer
  #     attribute :page, Types::Integer.default(1)
  #
  #     def users
  #       object # Assuming object is an array of user objects
  #     end
  #
  #     def count
  #       object.size
  #     end
  #   end
  #
  # @example Error response serializer
  #   class ErrorSerializer < Steppe::Serializer
  #     attribute :errors, Types::Hash.example({ 'name' => 'is required' })
  #     attribute :message, Types::String.example('Validation failed')
  #
  #     def errors
  #       result.errors
  #     end
  #
  #     def message
  #       'Request validation failed'
  #     end
  #   end
  #
  # @example Using in endpoint responses
  #   api.get :users, '/users' do |e|
  #     e.step do |conn|
  #       users = User.all
  #       conn.valid(users)
  #     end
  #
  #     # Using a predefined serializer class
  #     e.serialize 200, UserListSerializer
  #
  #     # Using inline serializer definition
  #     e.serialize 404 do
  #       attribute :error, String
  #       def error = 'Users not found'
  #     end
  #   end
  #
  # @example Accessing result context
  #   class UserWithMetaSerializer < Steppe::Serializer
  #     attribute :user, UserSerializer
  #     attribute :request_id, String
  #
  #     def user
  #       object
  #     end
  #
  #     def request_id
  #       result.request.env['HTTP_X_REQUEST_ID'] || 'unknown'
  #     end
  #   end
  #
  # @note Serializers automatically generate attribute reader methods that delegate
  #   to the @object instance variable (the response data)
  # @note The #result method provides access to the full Result context including
  #   request, params, errors, and response data
  # @note Type definitions support .example() for OpenAPI documentation generation
  #
  # @see Endpoint#serialize
  # @see Responder#serialize
  # @see Result
  class Serializer
    extend Plumb::Composable
    include Plumb::Attributes

    class << self
      # Serialize an object using this serializer class.
      #
      # @private
      # Internal method that defines attribute reader methods.
      # Automatically creates methods that delegate to @object.attribute_name
      def __plumb_define_attribute_reader_method__(name)
        class_eval <<~RUBY, __FILE__, __LINE__ + 1
        def #{name} = @object.#{name}
        RUBY
      end

      RenderError = Class.new(StandardError)

      # @param conn [Result] The result object containing the value to serialize
      # @return [String, nil] JSON string of serialized value or nil if no value
      def render(conn)
        result = call(conn)
        raise RenderError, result.errors if result.invalid?

        result.value ? JSON.dump(result.value) : nil
      end

      # @private
      # Internal method called during endpoint processing to serialize results.
      #
      # @param conn [Result] The result object containing the value to serialize
      # @return [Result] New result with serialized value
      def call(conn)
        hash = new(conn).serialize
        conn.copy(value: hash)
      end
    end

    # @!attribute [r] object
    #   @return [Object] The object being serialized (same as result.value)

    # @!attribute [r] result
    #   @return [Result] The full result context with request, params, errors, etc.
    attr_reader :object, :result

    # Initialize a new serializer instance.
    #
    # @param result [Result] The result object containing the value to serialize
    #   and full request context
    def initialize(result)
      @result = result
      @object = result.value
    end

    # Serialize the object to a hash using defined attributes.
    #
    # Iterates through all defined attributes, calls the corresponding method
    # (either auto-generated or custom), and applies the attribute's type
    # transformation and validation.
    #
    # @return [Hash] The serialized hash with symbol keys
    # @example
    #   serializer = UserSerializer.new(result)
    #   serializer.serialize
    #   # => { id: 1, name: "Alice", email: "alice@example.com" }
    def serialize
      self.class._schema._schema.each.with_object({}) do |(key, type), ret|
        ret[key.to_sym] = serialize_attribute(key.to_sym, type)
      end
    end

    # Serialize a single attribute using its defined type.
    #
    # @param key [Symbol] The attribute name
    # @param type [Plumb::Type] The Plumb type definition for the attribute
    # @return [Object] The serialized attribute value
    # @example
    #   serialize_attribute(:name, Types::String)
    #   # => "Alice"
    def serialize_attribute(key, type)
      # Ex. value = self.name
      value = send(key)
      type.call(result.copy(value:)).value
    end
  end
end
