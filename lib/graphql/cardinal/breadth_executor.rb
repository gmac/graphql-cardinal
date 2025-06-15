# frozen_string_literal: true

module GraphQL
  module Cardinal
    class AggregateFieldNode
      def initialize
        @node = nil
        @nodes = nil
      end
      
      def add_node(n)
        if !@node
          @node = n
        elsif !@nodes
          @nodes = [@node, n]
        else
          @nodes << n
        end
      end

      def selections
        if @nodes
          @nodes.flat_map(&:selections)
        else
          @node.selections
        end
      end

      def arguments(vars)
        return EMPTY_OBJECT if @node.arguments.empty?

        @node.arguments.each_with_object({})do |a, args|
          args[a.name] = a.value
        end
      end
    end
    
    class BreadthExecutor
      include Scalars

      attr_reader :exec_count

      def initialize(schema, resolvers, document, root_object)
        @schema = schema
        @resolvers = resolvers
        @document = document
        @root_object = root_object
        @variables = {}
        @context = {}
        @data = {}
        @exec_count = 0
        @non_null_violation = false
      end

      def perform
        @query = GraphQL::Query.new(@schema, document: @document) # << for schema reference
        operation = @query.selected_operation
        parent_type = @query.root_type_for_operation(operation.operation_type)
        exec_scope(parent_type, operation.selections, [@root_object], [@data], path: [])
        @non_null_violation ? Cardinal::Shaper.perform(@query, @data) : @data
      end

      private

      def exec_scope(parent_type, selections, sources, responses, path:)
        selections = aggregate_selections_by_name(parent_type, selections)
        selections.each do |field_key, node|
            field = @query.get_field(parent_type, node.name)
            field_type = field.type.unwrap
            path.push(field_key)

            resolved_sources = begin
              @resolvers.dig(parent_type.graphql_name, node.name).call(sources, node.arguments(@variables), @context)
            rescue StandardError
              # oh shit...
            end

            @exec_count += 1
            raise ExecutionError, "Incorrect results" if resolved_sources.length != sources.length

            if field_type.kind.leaf?
              resolved_sources.each_with_index do |val, i|
                responses[i][field_key] = if val.nil? || val.is_a?(StandardError)
                  @non_null_violation = true if field.type.non_null?
                  # format error if val (error)...
                  nil
                elsif field_type.kind.scalar?
                  coerce_scalar_value(field_type, val)
                else
                  val
                end
              end
            else
              next_sources = []
              next_responses = []
              resolved_sources.each_with_index do |src, i|
                responses[i][field_key] = if val.nil? || val.is_a?(StandardError)
                  @non_null_violation = true if field.type.non_null?
                  # format error if val (error)...
                  nil
                elsif field.type.list?
                  build_list_response(field.type, src, next_sources, next_responses)
                else
                  next_sources << src
                  next_responses << {}
                  next_responses.last
                end
              end

              exec_scope(field_type, node.selections, next_sources, next_responses, path: path)
            end
            path.pop
          end
        end
      end

      def build_list_response(list_type, sources, next_sources, next_responses)
        list_type = list_type.of_type while list_type.non_null?
        next_type = list_type.of_type

        sources.map do |src|
          if src.nil? || src.is_a?(StandardError)
            @non_null_violation = true if next_type.non_null?
            # format error if val (error)...
            nil
          elsif next_type.list?
            build_list_response(next_type, src, next_sources, next_responses)
          else
            next_sources << src
            next_responses << {}
            next_responses.last
          end
        end
      end

      def aggregate_selections_by_name(parent_type, selections, map: Hash.new { |h, k| h[k] = AggregateFieldNode.new })
        selections.each do |node|
          case node
          when GraphQL::Language::Nodes::Field
            # next if skipped...
            map[node.alias || node.name].add_node(node)
          when GraphQL::Language::Nodes::InlineFragment
            # next if skipped...
            fragment_type = node.type ? @query.get_type(node.type.name) : parent_type
            aggregate_selections_by_name(parent_type, node.selections, map: map)

          when GraphQL::Language::Nodes::FragmentSpread
            # next if skipped...? is this possible?
            fragment = @query.fragments[node.name]
            fragment_type = @query.get_type(fragment.type.name)
            aggregate_selections_by_name(parent_type, node.selections, map: map)
            
          else
            raise DocumentError.new("selection node type")
          end
        end
      end
    end
  end
end
