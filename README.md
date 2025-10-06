# Steppe - Composable, self-documenting REST APIs for Ruby

Steppe is a Ruby gem that provides a DSL for building REST APIs with an emphasis on:

* Composability - Built on composable pipelines, allowing endpoints to be assembled from reusable, testable validation and processing
steps
* Type Safety & Validation - Uses the Plumb library to define schemas for query parameters and request bodies, ensuring data is
validated and coerced before reaching business logic
* Expandable API - start with a terse DSL for defining endpoints, and extend with custom steps as needed.
* Self-Documentation - Automatically generates OpenAPI specifications from endpoint definitions, keeping documentation in sync with
implementation
* Content Negotiation - Handles multiple response formats through a Responder system that matches status codes and content types
* Mountable on Rack routers, and (soon) standalone with its own router.

## Installation

TODO: Replace `UPDATE_WITH_YOUR_GEM_NAME_IMMEDIATELY_AFTER_RELEASE_TO_RUBYGEMS_ORG` with your gem name right after releasing it to RubyGems.org. Please do not do it earlier due to security reasons. Alternatively, replace this section with instructions to install your gem from git if you don't plan to release to RubyGems.org.

Install the gem and add to the application's Gemfile by executing:

    $ bundle add UPDATE_WITH_YOUR_GEM_NAME_IMMEDIATELY_AFTER_RELEASE_TO_RUBYGEMS_ORG

If bundler is not being used to manage dependencies, install the gem by executing:

    $ gem install UPDATE_WITH_YOUR_GEM_NAME_IMMEDIATELY_AFTER_RELEASE_TO_RUBYGEMS_ORG

## Usage

### Defining a service

A Service is a container for API endpoints with metadata:

```ruby
require 'steppe'

Service = Steppe::Service.new do |api|
  api.title = 'Users API'
  api.description = 'API for managing users'
  api.server(
    url: 'http://localhost:4567',
    description: 'Production server'
  )
  api.tag('users', description: 'User management operations')

  # Define endpoints here...
end
```

### Defining endpoints

Endpoints define HTTP routes with validation, processing steps, and response serialization:

```ruby
# GET endpoint with query parameter validation
api.get :users, '/users' do |e|
  e.description = 'List users'
  e.tags = %w[users]

  # Validate query parameters
  e.query_schema(
    q?: Types::String.desc('Search by name'),
    limit?: Types::Lax::Integer.default(10).desc('Number of results')
  )

  # Business logic step
  e.step do |conn|
    users = User.filter_by_name(conn.params[:q])
                .limit(conn.params[:limit])
    conn.valid users
  end

  # JSON response serialization
  e.json do
    attribute :users, [UserSerializer]

    def users
      object
    end
  end
end
```

### Request Body Validation

Use `payload_schema` to validate request bodies:

```ruby
api.post :create_user, '/users' do |e|
  e.description = 'Create a user'
  e.tags = %w[users]

  # Validate request body
  e.payload_schema(
    user: {
      name: Types::String.desc('User name').example('Alice'),
      email: Types::Email.desc('User email').example('alice@example.com'),
      age: Types::Lax::Integer.desc('User age').example(30)
    }
  )

  # Create user (only runs if payload is valid)
  e.step do |conn|
    user = User.create(conn.params[:user])
    conn.respond_with(201).valid user
  end

  # Serialize response
  e.json 201, UserSerializer
end
```

### It's pipeline steps all the way down

Query and payload schemas are themselves steps in the processing pipeline, so you can insert steps before or after each of them.

```ruby
# Coerce and validate query parameters
e.query_schema(
  id: Types::Lax::Integer.present  
)

# Use (validated, coerced) ID to locate resource
# and do some custom authorization
e.step do |conn|
  user = User.find(conn.params[:id])
  if user.can_update_account?
    conn.continue user
  else
    conn.respond_with(401).halt
  end
end

# Only NOW parse and validate request body
e.payload_schema(
  name: Types::String.present.desc('Account name'),
  email: Types::Email.presen.desc('Account email')
)
```

A "step" is an `#call(Steppe::Result) => Steppe::Result` interface. You can use procs, or you can use your own objects.

```ruby
class FindAndAuthorizeUser
  def self.call(conn)
    user = User.find(conn.params[:id])
    return conn.respond_with(401).halt unless user.can_update_account?
    
    conn.continue(user)
  end
end

# In your endpoint
e.step FindAndAuthorizeUser
```



It's up to you how/if your custom steps manage their own state (ie. classes vs. instances). You can use instances for configuration, for example.

```ruby
# Works as long as the instance responds to #call(Result) => Result
e.step MyCustomAuthorizer.new(role: 'admin')
```

#### Halting the pipeline

A step that returns a `Continue` result passes the result on to the next step.

```ruby
e.step do |conn|
  conn.continue('hello')
end
```

A step that returns a `Halt` step signals the pipeline to stop processing.

```ruby
# This step halts the pipeline
e.step do |conn|
  conn.halt
  # Or
  # conn.invalid(errors: {name: 'is invalid'})
end

# This step will never run
e.step do |conn|
  # etc
end
```

#### Steps with schemas

A custom step that also supports `#query_schema` or `#payload_schema` will have those schemas merged into the endpoint's schemas, which can be used to generate OpenAPI documentation.

This is so that you're free to bring your own domain objects that do their own validation.

```ruby
class CreateUser
  def self.payload_schema = Types::Hash[name: String, age: Types::Integer[18..]]
  
  def self.call(conn)
    # Instantiate, manage state, run your domain logic, etc
    conn
  end
end
  
# CreateUser.payload_schema will be merged into the endpoint's own payload_schema
e.step CreateUser

# You can add further fields to the payload schema
e.payload_schema(
  email: Types::Email.present
)
```



### URL Parameters

URL parameters are automatically extracted and merged into `conn.params`:

```ruby
api.get :user, '/users/:id' do |e|
  e.description = 'Fetch a user by ID'

  # Validate URL parameter
  e.query_schema(
    id: Types::Lax::Integer.desc('User ID')
  )

  e.step do |conn|
    user = User.find(conn.params[:id])
    user ? conn.valid(user) : conn.invalid(errors: { id: 'Not found' })
  end

  e.json 200...300, UserSerializer
end
```

### File Uploads

Handle file uploads with the `UploadedFile` type:

```ruby
api.post :upload, '/files' do |e|
  e.payload_schema(
    file: Types::UploadedFile.with(type: 'text/plain')
  )

  e.step do |conn|
    file = conn.params[:file]
    # file.tempfile, file.filename, file.type available
    conn.valid(process_file(file))
  end

  e.json 201, FileSerializer
end
```

### Custom Serializers

Define reusable serializers:

```ruby
class UserSerializer < Steppe::Serializer
  attribute :id, Types::Integer.example(1)
  attribute :name, Types::String.example('Alice')
  attribute :email, Types::Email.example('alice@example.com')
end

# Use in endpoints
e.json 200, UserSerializer
```

### Multiple Response Formats

Support multiple content types:

```ruby
api.get :user, '/users/:id' do |e|
  e.step { |conn| conn.valid(User.find(conn.params[:id])) }

  # JSON response
  e.json 200, UserSerializer

  # HTML response (using Papercraft)
  e.html do |conn|
    html5 {
      body {
        h1 conn.value.name
        p "Email: #{conn.value.email}"
      }
    }
  end
end
```

#### HTML templates

HTML templates rely on [Papercraft](https://papercraft.noteflakes.com). It's possible to register your own templating though.

You can pass inline templates like in the example above, or named constants pointing to HTML components.

```ruby
# Somewhere in your app:
UserTemplate = proc do |conn|
  html5 {
    body {
      h1 conn.value.name
      p "Email: #{conn.value.email}"
    }
  }
end

# In your endpoint
e.html(200..299, UserTemplate)
```

See Papercraft's documentation to learn how to work with [layouts](https://papercraft.noteflakes.com/docs/03-template-composition/02-working-with-layouts), nested [components](https://papercraft.noteflakes.com/docs/03-template-composition/01-component-templates), and more.

### Reusable Action Classes

Encapsulate logic in action classes:

```ruby
class UpdateUser
  SCHEMA = Types::Hash[
    name: Types::String.present,
    age: Types::Lax::Integer[18..]
  ]

  def self.payload_schema = SCHEMA

  def self.call(conn)
    user = User.update(conn.params[:id], conn.params)
    conn.valid user
  end
end

# Use in endpoint
api.put :update_user, '/users/:id' do |e|
  e.step UpdateUser
  e.json 200, UserSerializer
end
```

### OpenAPI Documentation

Use a service's `#specs` helper to mount a GET route to automatically serve OpenAPI schemas from.

```ruby
MyAPI = Steppe::Service.new do |api|
  api.title = 'Users API'
  api.description = 'API for managing users'
  
  # OpenAPI JSON schemas for this service
  # will be available at GET /schemas (defaults to /)
  api.specs('/schemas')
  
  # Define API endpoints
  api.get :list_users, '/users' do |e|
    # etc
  end
end
```


Or use the `OpenAPIVisitor` directly

```ruby
# Get OpenAPI JSON
openapi_spec = Steppe::OpenAPIVisitor.from_request(MyAPI, rack_request)

# Or generate manually
openapi_spec = Steppe::OpenAPIVisitor.call(MyAPI)
```

<img width="831" height="855" alt="CleanShot 2025-10-06 at 18 04 55" src="https://github.com/user-attachments/assets/fea61225-538b-4653-bdd0-9f8b21c8c389" />
Using the [Swagger UI](https://swagger.io/tools/swagger-ui/) tool to view a Steppe API definition.

### Integration with Rack/Sinatra

Mount Steppe services in Rack-based applications:

```ruby
require 'sinatra/base'

class App < Sinatra::Base
  Service.endpoints.each do |endpoint|
    public_send(endpoint.verb, endpoint.path.to_templates.first) do
      resp = endpoint.run(request).response
      resp.finish
    end
  end
end
```

### Custom Types

Define custom validation types using Plumb:

```ruby
module Types
  include Plumb::Types

  UserCategory = String
    .options(%w[admin customer guest])
    .default('guest')
    .desc('User category')

  DowncaseString = String.invoke(:downcase)
end

# Use in schemas
e.query_schema(
  category?: Types::UserCategory
)
```

### Error Handling

Endpoints automatically handle validation errors with 422 responses. Customize error responses:

```ruby
e.json 422 do
  attribute :errors, Types::Hash

  def errors
    object
  end
end
```

### Content negotiation

The `#json` and `#html` Endpoint methods are shortcuts for `Responder` objects that can be tailored to specific combinations of request accepted content types, and response status.

```ruby
# equivalent to e.json(200, UserSerializer)
e.respond 200, :json do |r|
  r.description = "JSON response"
  r.serialize UserSerializer
end
```

Responders switch their serializer type depending on their resulting content type. 

This is a responder that accepts HTML requests, and responds with JSON.

```ruby
e.respond statuses: 200..299, accepts: :html, content_type: :json do |r|
  # Using an inline JSON serializer this time
  e.serialize do
    attribute :name, String
    attribute :age, Integer
  end
end
```

Responders can accept wildcard media types, and an endpoint can define multiple responders, from more to less specific.

```ruby
e.respond 200, :json, UserSerializer
e.respond 200, 'text/*', UserTextSerializer
```



## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake spec` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and the created tag, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/[USERNAME]/steppe.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
