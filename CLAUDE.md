# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Steppe is a Ruby gem for building composable, self-documenting REST APIs. It provides a DSL for defining endpoints with built-in request validation, response serialization, and OpenAPI documentation generation.

## Development Commands

```bash
# Install dependencies
bundle install

# Run tests
rake spec
# or
bundle exec rspec

# Run specific test file
bundle exec rspec spec/endpoint_spec.rb

# Run console for experimentation
bin/console

# Install gem locally
bundle exec rake install

# Release new version (updates version, creates git tag, pushes to rubygems)
bundle exec rake release
```

## Architecture

### Core Components

- **Service** (`lib/steppe/service.rb`): Main container that holds multiple endpoints. Defines API metadata like title, description, servers, and tags.

- **Endpoint** (`lib/steppe/endpoint.rb`): Individual API endpoints that inherit from `Plumb::Pipeline`. Each endpoint defines:
  - HTTP verb and path (with Mustermann pattern matching)
  - Query parameter validation via `query_schema`
  - Request body validation via `payload_schema`
  - Response serialization via `respond`/`serialize`
  - Processing steps via `step`

- **Responder** (`lib/steppe/responder.rb`): Handles response formatting for specific status codes and content types. Uses ResponderRegistry for resolution.

- **Serializer** (`lib/steppe/serializer.rb`): Base class for response serialization using Plumb types.

- **Request** (`lib/steppe/request.rb`): Wrapper around Rack::Request with additional Steppe-specific functionality.

- **Result** (`lib/steppe/result.rb`): Represents processing state (Continue/Halt) with params, errors, and response data.

### Key Dependencies

- **Plumb**: Type validation and coercion library (used for schemas and pipelines)
- **Mustermann**: Pattern matching for URL routes
- **Rack**: Web server interface
- **MIME Types**: Content type handling

### Request Processing Flow

1. Request hits Service endpoint
2. URL parameters extracted via Mustermann
3. Query parameters validated against `query_schema`
4. Request body parsed and validated against `payload_schema`
5. Business logic steps executed via `step` blocks
6. Response serialized via matching Responder
7. Rack response returned

### Testing

Tests use RSpec and are located in `spec/`. The main test files are:
- `spec/endpoint_spec.rb` - Endpoint functionality
- `spec/service_spec.rb` - Service container
- `spec/responder_spec.rb` - Response handling
- `spec/openapi_visitor_spec.rb` - OpenAPI generation

### Example Usage

See `examples/sinatra.rb` for a complete working example that integrates Steppe with Sinatra and demonstrates:
- Defining a Service with multiple endpoints
- Query parameter validation
- Request body validation
- Custom serializers
- OpenAPI documentation generation

The gem follows standard Ruby gem conventions with lib/ containing source code and spec/ containing tests.