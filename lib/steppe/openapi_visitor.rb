# frozen_string_literal: true

require 'plumb/visitor_handlers'

module Steppe
  class OpenAPIVisitor
    include Plumb::VisitorHandlers

    ENVELOPE = {
      'openapi' => '3.0.0'
    }.freeze

    def self.call(node, root: true)
      data = new.visit(node)
      return data unless root

      ENVELOPE.merge(data)
    end

    on(:service) do |node, props|
      props.merge(
        'info' => {
          'title' => node.title,
          'description' => node.description,
          'version' => node.version
        },
        'servers' => [],
        'paths' => node.endpoints.values.reduce({}) { |memo, e| visit(e, memo) }
      )
    end

    on(:endpoint) do |node, paths|
      path_template = node.path.to_templates.first
      path = paths[path_template] || {}
      verb = path[node.verb.to_s] || {}
      verb = verb.merge(
        'summary' => node.rel_name,
        # operationId can be used for links
        # https://swagger.io/docs/specification/links/
        'operationId' => node.rel_name,
        'description' => node.description,
        'parameters' => visit_parameters(node.params_schema),
        'responses' => visit(node.responders)
      )
      path = path.merge(node.verb.to_s => verb)
      paths.merge(path_template => path)
    end

    on(:responders) do |responders, _props|
      responders.reduce({}) { |memo, r| visit(r, memo) }
    end

    on(:responder) do |responder, props|
      # Naive implementation
      # of OpenAPI responses status ranges
      # https://swagger.io/docs/specification/describing-responses/
      # TODO: OpenAPI only allows 1XX, 2XX, 3XX, 4XX, 5XX
      status = responder.statuses.size == 1 ? responder.statuses.first.to_s : "#{responder.statuses.first.to_s[0]}XX"
      status_prop = props[status]
      return props if status_prop

      status_prop = {}
      content = status_prop['content'] || {}
      content = content.merge(
        responder.accepts.to_s => {
          'schema' => responder.serializer.to_json_schema
        }
      )
      status_prop = status_prop.merge(
        'description' => responder.description,
        'content' => content
      )
      props.merge(status => status_prop)
    end

    def visit_parameters(schema)
      ins = %i[query path].freeze
      specs = schema._schema.each.with_object({}) do |(name, type), h|
        h[name.to_s] = type if ins.include?(type.metadata[:in])
      end
      specs.map do |name, type|
        spec = type.to_json_schema
        # Here we should recursively visit the type
        # to extract metadata, etc.
        meta = type.metadata.reduce({}) { |m, (k, v)| m.merge(k.to_s => v.to_s.downcase) }

        {
          'name' => name,
          'in' => meta['in'],
          'description' => meta['description'],
          'required' => (meta['in'] == 'path'),
          'schema' => spec.except('in')
        }
      end
    end
  end
end
