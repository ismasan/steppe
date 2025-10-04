# frozen_string_literal: true

require 'spec_helper'
require 'steppe/status_map'

RSpec.describe Steppe::StatusMap do
  specify do
    Responder = Data.define(:name, :statuses)

    lookup = Steppe::StatusMap.new

    lookup << Responder.new("Success", 200..299)
    lookup << Responder.new("Redirect", 300..399)

    expect(lookup.find(204)&.name).to eq('Success')
    expect(lookup.find(350)&.name).to eq('Redirect')

    # Overlapping insert raises an error
    expect {
      lookup << Responder.new("Bad", 250..350)
    }.to raise_error(ArgumentError, /overlaps/)
  end
end
