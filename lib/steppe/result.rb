# frozen_string_literal: true

require 'rack'

module Steppe
  class Result
    attr_reader :value, :errors, :request, :response

    def initialize(value, errors: {}, request:, response: nil)
      @value = value
      @errors = errors
      @request = request
      @response = response || Rack::Response.new('', 200, {})
    end

    def valid? = true
    def invalid? = !valid?

    def inspect
      %(<#{self.class}##{object_id} [#{response.status}] value:#{value.inspect} errors:#{errors.inspect}>)
    end

    def copy(value: @value, errors: @errors, request: @request, response: @response)
      self.class.new(value, errors:, request:, response:)
    end

    def valid(val = value)
      Continue.new(val, errors:, request:, response:)
    end

    def invalid(val = value, errors: {})
      Halt.new(val, errors:, request:, response:)
    end

    def continue(...) = valid(...)
    def halt(...) = invalid(...)

    class Continue < self
      def map(callable)
        callable.call(self)
      end
    end

    class Halt < self
      def valid? = false

      def map(_)
        self
      end
    end
  end
end
