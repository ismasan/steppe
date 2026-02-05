# frozen_string_literal: true

module Steppe
  module MCP
    # Defines an MCP prompt template that can be invoked by clients.
    #
    # Prompts return structured messages that get injected into the LLM's
    # conversation context, guiding how it should approach a task.
    #
    # @example Basic prompt
    #   Prompt.new('greet_user') do |p|
    #     p.description = 'Greet a user by name'
    #     p.argument :name, required: true, description: 'User name'
    #     p.messages do |args|
    #       [{ role: 'user', content: { type: 'text', text: "Say hello to #{args[:name]}" } }]
    #     end
    #   end
    #
    # @example Few-shot prompt with user/assistant pairs
    #   Prompt.new('code_review') do |p|
    #     p.description = 'Review code quality'
    #     p.argument :code, required: true
    #     p.messages do |args|
    #       [
    #         { role: 'user', content: { type: 'text', text: "Review this code:\n#{args[:code]}" } },
    #         { role: 'assistant', content: { type: 'text', text: "I'll analyze this code for quality issues..." } }
    #       ]
    #     end
    #   end
    #
    class Prompt
      attr_reader :name, :arguments
      attr_accessor :description

      # @param name [String, Symbol] Unique identifier for the prompt
      def initialize(name, &block)
        @name = name.to_s
        @description = nil
        @arguments = []
        @messages_block = nil
        block&.call(self)
      end

      # Define an argument for the prompt
      # @param name [Symbol, String] Argument name
      # @param required [Boolean] Whether the argument is required
      # @param description [String, nil] Human-readable description
      def argument(name, required: false, description: nil)
        @arguments << {
          name: name.to_s,
          required: required,
          description: description
        }.compact
      end

      # Define the messages block that generates prompt messages
      # @yield [args] Block that receives arguments hash and returns messages array
      def messages(&block)
        @messages_block = block
      end

      # Generate messages for the given arguments
      # @param args [Hash] Arguments provided by the client
      # @return [Array<Hash>] Array of message objects with role and content
      def generate_messages(args = {})
        return [] unless @messages_block

        args = args.transform_keys(&:to_sym)
        @messages_block.call(args)
      end

      # Convert to MCP prompt definition for prompts/list
      # @return [Hash]
      def to_definition
        defn = {
          name: @name,
          description: @description
        }
        defn[:arguments] = @arguments if @arguments.any?
        defn.compact
      end

      # Convert to MCP prompt result for prompts/get
      # @param args [Hash] Arguments provided by the client
      # @return [Hash]
      def to_result(args = {})
        {
          description: @description,
          messages: generate_messages(args)
        }.compact
      end
    end
  end
end
