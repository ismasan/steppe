# frozen_string_literal: true

require 'spec_helper'
require 'steppe/status_map'

RSpec.describe Steppe::StatusMap do
  specify do
    Responder = Data.define(:name, :statuses)

    lookup = Steppe::StatusMap.new

    lookup << Responder.new("Success", 200..299)
    lookup << Responder.new("Redirect", 300..399)
    # Overlapping ranges are now supported - most recently added wins in overlapping region
    lookup << Responder.new("Bad", 250..350)

    expect(lookup.find(204)&.name).to eq('Success')
    expect(lookup.find(350)&.name).to eq('Bad')
    expect(lookup.find(200)&.name).to eq('Success')
    expect(lookup.find(249)&.name).to eq('Success')
    expect(lookup.find(250)&.name).to eq('Bad')  # Overlapping region - Bad wins
    expect(lookup.find(299)&.name).to eq('Bad')  # Overlapping region - Bad wins
    expect(lookup.find(300)&.name).to eq('Bad')  # Overlapping region - Bad wins
    expect(lookup.find(351)&.name).to eq('Redirect')
  end
end
