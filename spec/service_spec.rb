# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Steppe::Service do
  subject(:service) do
    described_class.new do |api|
      api.title = 'Users'
      api.description = 'Users service'
      api.version = '1.0.0'

      api.specs('/schemas')

      api.get :users, '/users' do |e|
        e.description = 'List users'
      end

      api.post :create_user, '/users' do |e|
        e.description = 'Create user'
      end

      api.put :update_user, '/users/:id' do |e|
        e.description = 'Update user'
      end

      api.patch :patch_user, '/users/:id' do |e|
        e.description = 'Patch user'
      end

      api.delete :delete_user, '/users/:id' do |e|
        e.description = 'Delete user'
      end
    end
  end

  specify do
    expect(service.title).to eq('Users')
    expect(service.description).to eq('Users service')
    expect(service.version).to eq('1.0.0')
    expect(service[:users].description).to eq('List users')
    expect(service[:create_user].description).to eq('Create user')
  end

  specify 'GET /schemas' do
    specs_endpoint = service[:__open_api]
    expect(specs_endpoint.path.to_s).to eq('/schemas')
    expect(specs_endpoint.verb).to eq(:get)

    request = build_request('/schemas')
    result = specs_endpoint.run(request)
    expect(result.valid?).to be true
    spec = parse_body(result.response)
    expect(spec.keys).to match_array(%i[openapi info servers tags paths])
  end
end
