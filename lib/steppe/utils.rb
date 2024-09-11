# frozen_string_literal: true

module Steppe
  module Utils
    def self.deep_symbolize_keys(hash)
      hash.each.with_object({}) do |(k, v), h|
        value = case v
                when Hash
                  deep_symbolize_keys(v)
                when Array
                  v.map { |e| e.is_a?(Hash) ? deep_symbolize_keys(e) : e }
                else
                  v
                end
        h[k.to_sym] = value
      end
    end
  end
end
