# frozen_string_literal: true

module Steppe
  class Serializer
    extend Plumb::Composable
    include Plumb::Attributes

    class << self
      def serialize(object)
        parse(object)
      end

      def __plumb_define_attribute_method__(name)
        define_method(name) { object.send(name) }
      end

      def call(result)
        hash = new(result).serialize
        result.copy(value: hash)
      end
    end

    attr_reader :object, :result

    def initialize(result)
      @result = result
      @object = result.value
    end

    def serialize
      self.class._schema._schema.each.with_object({}) do |(key, type), ret|
        ret[key.to_sym] = serialize_attribute(key.to_sym, type)
      end
    end

    def serialize_attribute(key, type)
      # Ex. value = self.name
      value = send(key)
      type.call(result.copy(value:)).value
    end
  end
end
