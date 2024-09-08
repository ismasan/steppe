# frozen_string_literal: true

require 'rack'

RSpec.describe Steppe do
  it 'has a version number' do
    expect(Steppe::VERSION).not_to be nil
  end
end
