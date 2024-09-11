# frozen_string_literal: true

require 'rack'

RSpec.describe Steppe::Service do
  subject(:service) do
    described_class.new do |s|
      s.title = 'Users'
      s.description = 'Users service'
      s.version = '1.0.0'

      s.get :users, '/users' do |e|
        e.description = 'List users'
      end

      s.post :create_user, '/users' do |e|
        e.description = 'Create user'
      end

      s.put :update_user, '/users/:id' do |e|
        e.description = 'Update user'
      end

      s.patch :patch_user, '/users/:id' do |e|
        e.description = 'Patch user'
      end

      s.delete :delete_user, '/users/:id' do |e|
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
end
