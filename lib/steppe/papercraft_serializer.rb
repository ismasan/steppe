# frozen_string_literal: true

require 'papercraft'

module Steppe
  class PapercraftSerializer
    def initialize(template)
      @template = template
    end

    def call(conn)
      conn.copy value: @template.render(conn)
    end
  end
end
