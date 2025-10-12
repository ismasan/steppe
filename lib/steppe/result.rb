# frozen_string_literal: true

require 'rack'

module Steppe
  class Result
    attr_reader :value, :params, :errors, :request, :response

    def initialize(value, params: {}, errors: {}, request:, response: nil)
      @value = value
      @params = params
      @errors = errors
      @request = request
      @response = response || Rack::Response.new('', 200, {})
    end

    def valid? = true
    def invalid? = !valid?
    # TODO: continue and valid are different things.
    # continue = pipeline can proceed with next step
    # valid = result has no errors.
    def continue? = valid?

    def inspect
      %(<#{self.class}##{object_id} [#{response.status}] value:#{value.inspect} errors:#{errors.inspect}>)
    end

    def copy(value: @value, params: @params, errors: @errors, request: @request, response: @response)
      self.class.new(value, params:, errors:, request:, response:)
    end

    def respond_with(status = nil, &)
      response.status = status if status
      @response = yield(response) if block_given?
      self
    end

    def reset(value)
      @value = value
      self
    end

    def valid(val = value)
      Continue.new(val, params:, errors:, request:, response:)
    end

    def invalid(val = value, errors: {})
      Halt.new(val, params:, errors:, request:, response:)
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
