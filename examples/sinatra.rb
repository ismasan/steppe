# frozen_string_literal: true

require 'bundler'
Bundler.setup(:examples)

require 'sinatra/base'
require 'rack/cors'
require 'steppe'

# From root, run with:
# bundle exec ruby examples/sinatra.rb -p 4567
#
class User
  Record = Data.define(:id, :name, :age)

  class << self
    def data
      @data ||= [
        Record.new(1, 'Alice', 30),
        Record.new(2, 'Bob', 25),
        Record.new(3, 'Bill', 20)
      ]
    end

    def filter_by_name(name)
      return data unless name

      data.select { |u| u.name.downcase.start_with?(name) }
    end

    def find(id)
      data.find { |u| u.id == id }
    end

    def create(attrs)
      rec = Record.new(id: data.size + 1, name: attrs[:name], age: attrs[:age])
      data << rec
      rec
    end
  end
end

module Types
  include Plumb::Types

  UserCategory = String
                 .options(%w[any admin customer guest])
                 .default('any')
                 .desc('search by category')

  DowncaseString = String.invoke(:downcase)
end

class UserSerializer < Steppe::Serializer
  attribute :id, Types::Integer.example(1)
  attribute :name, Types::String.example('Alice')
end

class HashTokenStore
  def initialize(hash)
    @hash = hash
  end

  def set(claims)
    key = SecureRandom.hex
    @hash[key] = claims.each_with_object({}) { |(k, v), h| h[k.to_s] = v }
    key
  end

  def get(key)
    @hash[key]
  end
end

class BooticAuth
  attr_reader :scopes, :type, :description, :store

  def initialize(authorization_url:, scopes: [], store: {})
    @scopes = scopes
    @type = :oauth2
    @description = 'Bootic Auth'
    @store = store.is_a?(Hash) ? HashTokenStore.new(store) : store
  end
end

# bootic = BooticAuth.new(scopes: %w[admin god])

Service = Steppe::Service.new do |api|
  api.title = 'Users API'
  api.description = 'API for managing users'
  api.server(
    url: 'http://localhost:4567',
    description: 'prod server'
  )
  api.tag(
    'users',
    description: 'Users operations',
    external_docs: 'https://example.com/docs/users'
  )

  # api.security_scheme(:bootic_auth, bootic)

  # An endpoint to list users
  api.get :users, '/users' do |e|
    e.description = 'List users'
    e.tags = %w[users]
    # Custom steps, authentication, etc.
    e.step do |conn|
      puts conn.request.env['HTTP_AUTHORIZATION'].inspect
      conn
    end

    # Validate and coerce URL parameters
    e.query_schema(
      q?: Types::DowncaseString.desc('search by name'),
      cat?: Types::UserCategory
    )

    # A step with your business logic
    # In this case filtering users by name
    # This step will only run if the params are valid
    e.step do |conn|
      users = User.filter_by_name(conn.params[:q])
      conn.valid users
    end

    e.json do
      attribute :users, [UserSerializer]

      def users
        object
      end
    end

    # Or, use a named serializer class
    # e.json 200, UserListSerializer
    #
    # Or, use #respond for more detailed control
    # e.respond 200...300, :json, UserListSerializer
    #
    # Or, expand into a responder block
    # e.respond 200...300, :json do |r|
    #   r.description = "A list of users"
    #   r.step CustomStep1
    #   r.serializer UserListSerializer
    #   r.step CustomStep1
    # end
    #
    # Or, register named responder
    # e.respond UserListResponder

    # Respond with HTML
    e.html do |conn|
      html5 {
        body {
          h1 'Users'
          ul {
            conn.value.each do |user|
              li {
                text "#{user.id}:"
                a(user.name, href: "/users/#{user.id}")
                text " (#{user.age})"
              }
            end
          }
        }
      }
    end
  end

  # A Standalone action class
  # with its own schema
  class UpdateUser
    SCHEMA = Plumb::Types::Hash[
      name: Steppe::Types::String.present,
      age: Steppe::Types::Lax::Integer[18..]
    ]

    def self.payload_schema = SCHEMA

    def self.call(conn)
      # Validate payload, pass valid params to instance, etc
      # new(conn).call
      conn
    end
  end

  # Another standalone action 
  # with its own schema
  class ProcessFile
    def self.payload_schema = Plumb::Types::Hash[
      file: Steppe::Types::UploadedFile.with(type: 'text/plain')
    ]

    def self.call(conn)
      # process the uploaded file
      conn
    end
  end

  api.put :update_user, '/users/:id' do |e|
    e.description = 'Update a user'
    e.tags = %w[users]

    # Endpoint will consolidate schemas from steps
    # that respond to .payload_schema
    e.step UpdateUser
    e.step ProcessFile


    # e.payload_schema(
    #   name: Steppe::Types::String.present,
    #   age: Steppe::Types::Lax::Integer[18..],
    #   file?: Steppe::Types::UploadedFile.with(type: 'text/plain')
    # )
  end

  api.get :user, '/users/:id' do |e|
    e.description = 'Fetch a user'
    e.tags = %w[users]
    e.query_schema(
      id: Types::Lax::Integer.desc('User ID')
    )
    e.step do |conn|
      user = User.find(conn.params[:id])
      if user
        conn.valid user
      else
        conn.response.status = 404
        conn.invalid(errors: { id: 'User not found' })
      end
    end

    e.json 200...300, UserSerializer

    e.html do |conn|
      html5 {
        body {
          a('users', href: '/users')
          h1 'User'
          dl {
            dt 'ID'
            dd conn.value.id
            dt 'name'
            dd conn.value.name
          }
        }
      }
    end
  end

  api.post :create_user, '/users' do |e|
    e.tags = %w[users]
    e.description = 'Create a user'

    # Validate request BODY payload
    # request body is parsed at this point in the pipeline
    e.payload_schema(
      user: {
        name: Types::String.desc('User name').example('Alice'),
        email: Types::Email.desc('User email').example('alice@server.com'),
        age: Types::Lax::Integer.desc('User age').example(30)
      }
    )

    # Create a user, only if params above are valid
    e.step do |conn|
      user = User.create(conn.params[:user])
      conn.respond_with(201).valid user
    end

    # Serialize the user (valid case)
    # status 422 (invalid) will be handled by default responder
    e.json 201, UserSerializer

    # Or, register a custom responder for 422
    # e.serialize 422 do
    #   attribute :errors, Types::Hash
    #   private def errors = conn.errors
    # end
  end
end

class SinatraRequestWrapper < SimpleDelegator
  def initialize(request, params)
    super(request)
    @steppe_url_params = params
  end

  attr_reader :steppe_url_params
end

Foo = proc do |env|
  req = Rack::Request.new(env)
  [200, { 'Content-Type' => 'text/plain' }, [req.params.inspect]]
end

class App < Sinatra::Base
  use Rack::Cors do
    allow do
      origins '*'
      resource '*', headers: :any, methods: :any
    end
  end

  get '/?' do
    content_type 'application/json'
    JSON.dump(Steppe::OpenAPIVisitor.from_request(Service, request))
  end

  get '/foo/:id' do
    params.inspect
  end

  Service.endpoints.each do |endpoint|
    public_send(endpoint.verb, endpoint.path.to_templates.first) do
      resp = endpoint.run(SinatraRequestWrapper.new(request, params)).response
      resp.finish
    end
  end

  run! if 'examples/sinatra.rb' == $0
end
