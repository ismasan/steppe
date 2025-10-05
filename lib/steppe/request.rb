# frozen_string_literal: true

require 'rack/request'
require 'steppe/utils'

module Steppe
  class Request < Rack::Request
    ROUTER_PARAMS = 'router.params'
    BLANK_HASH = {}.freeze

    def steppe_url_params
      @steppe_url_params ||= begin
        upstream_params = env[ROUTER_PARAMS] || BLANK_HASH
        Utils.deep_symbolize_keys(params).merge(Utils.deep_symbolize_keys(upstream_params))
      end
    end
  end
end
