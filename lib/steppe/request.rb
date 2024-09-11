# frozen_string_literal: true

require 'rack/request'
require 'steppe/utils'

module Steppe
  class Request < Rack::Request
    ACTION_DISPATCH_REQUEST_PARAMS = 'action_dispatch.request.path_parameters'
    BLANK_HASH = {}.freeze

    def steppe_url_params
      @steppe_url_params ||= begin
        upstream_params = env[ACTION_DISPATCH_REQUEST_PARAMS] || BLANK_HASH
        Utils.deep_symbolize_keys(params).merge(Utils.deep_symbolize_keys(upstream_params))
      end
    end
  end
end
