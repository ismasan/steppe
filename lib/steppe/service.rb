# frozen_string_literal: true

module Steppe
  class Service
    attr_reader :endpoints, :node_name
    attr_accessor :title, :description, :version

    def initialize
      @endpoints = {}
      @title = ''
      @description = ''
      @version = '0.0.1'
      @node_name = :service
    end

    def get(name, path, &)
      @endpoints[name] = Endpoint.new(name, :get, path:, &)
      self
    end
  end
end
