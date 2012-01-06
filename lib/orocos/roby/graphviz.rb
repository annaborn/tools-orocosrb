module Orocos
    module RobyPlugin
        # General support to export a generated plan into a dot-compatible
        # format
        #
        # This class generates the dot specification files (and runs dot for
        # you), exporting the component-related information out of a plan.
        #
        # It also contains an API that allows to add "annotations" to the
        # generated graph. Four types of annotations can be generated:
        #
        # * port annotations: text is added to the port descriptions
        #   (#add_port_annotation)
        # * task annotations: text is added to the task description
        #   (#add_task_annotation)
        # * additional vertices (#add_vertex)
        # * additional edges (#add_edge)
        #
        class Graphviz
            # The plan object containing the structure we want to display
            attr_reader :plan
            # Annotations for connections
            attr_reader :conn_annotations
            # Annotations for tasks
            attr_reader :task_annotations
            # Annotations for ports
            attr_reader :port_annotations
            # Additional vertices that should be added to the generated graph
            attr_reader :additional_vertices
            # Additional edges that should be added to the generated graph
            attr_reader :additional_edges

            def initialize(plan, engine)
                @plan = plan
                @engine = engine

                @task_annotations = Hash.new { |h, k| h[k] = Hash.new { |a, b| a[b] = Array.new } }
                @port_annotations = Hash.new { |h, k| h[k] = Hash.new { |a, b| a[b] = Array.new } }
                @conn_annotations = Hash.new { |h, k| h[k] = Array.new }
                @additional_vertices = Hash.new { |h, k| h[k] = Array.new }
                @additional_edges    = Array.new
            end

            def annotate_tasks(annotations)
                task_annotations.merge!(annotations) do |_, old, new|
                    old.merge!(new) do |_, old_array, new_array|
                        if new_array.respond_to?(:to_ary)
                            old_array.concat(new_array)
                        else
                            old_array << new_array
                        end
                    end
                end
            end

            # Add an annotation block to a task label.
            #
            # @arg task is the task to which the information should be added
            # @arg name is the annotation name. It appears on the left column of
            #           the task label
            # @arg ann is the annotation itself, as an array. Each line in the
            #          array is displayed as a separate line in the label.
            def add_task_annotation(task, name, ann)
                if !ann.respond_to?(:to_ary)
                    ann = [ann]
                end

                task_annotations[task].merge!(name => ann) do |_, old, new|
                    old.concat(new)
                end
            end

            def annotate_ports(annotations)
                port_annotations.merge!(annotations) do |_, old, new|
                    old.merge!(new) do |_, old_array, new_array|
                        if new_array.respond_to?(:to_ary)
                            old_array.concat(new_array)
                        else
                            old_array << new_array
                        end
                    end
                end
            end

            # Add an annotation block to a port label.
            #
            # @arg task is the task in which the port 
            # @arg port_name is the port name
            # @arg name is the annotation name. It appears on the left column of
            #           the task label
            # @arg ann is the annotation itself, as an array. Each line in the
            #          array is displayed as a separate line in the label.
            def add_port_annotation(task, port_name, name, ann)
                port_annotations[[task, port_name]].merge!(name => ann) do |_, old, new|
                    old.concat(new)
                end
            end

            def annotate_connections(annotations)
                conn_annotations.merge!(annotations) do |_, old, new|
                    if new.respond_to?(:to_ary)
                        old.concat(new)
                    else
                        old << new
                    end
                end
            end

            def add_vertex(task, vertex_name, vertex_label)
                additional_vertices[task] << [vertex_name, vertex_label]
            end

            def add_edge(from, to, label = nil)
                additional_edges << [from, to, label]
            end

            # Generate a svg file representing the current state of the
            # deployment
            def to_file(kind, format, output_io = nil, options = Hash.new)
                # For backward compatibility reasons
                filename ||= kind
                if File.extname(filename) != ".#{format}"
                    filename += ".#{format}"
                end

                file_options, display_options = Kernel.filter_options options,
                    :graphviz_tool => "dot"

                Tempfile.open('roby_orocos_graphviz') do |io|
                    io.write send(kind, display_options)
                    io.flush

                    if output_io.respond_to?(:to_str)
                        File.open(output_io, 'w') do |io|
                            io.puts(`#{file_options[:graphviz_tool]} -T#{format} #{io.path}`)
                        end
                    else
                        output_io.puts(`#{file_options[:graphviz_tool]} -T#{format} #{io.path}`)
                        output_io.flush
                    end
                end
            end

            COLORS = {
                :normal => %w{#000000 red},
                :toned_down => %w{#D3D7CF #D3D7CF}
            }

            # Generates a dot graph that represents the task hierarchy in this
            # deployment
            def relation_to_dot(options = Hash.new)
                options = Kernel.validate_options options,
                    :accessor => nil,
                    :dot_edge_mark => "->",
                    :dot_graph_type => 'digraph',
                    :highlights => [],
                    :toned_down => []

                if !options[:accessor]
                    raise ArgumentError, "no :accessor option given"
                end

                result = []
                result << "#{options[:dot_graph_type]} {"
                result << "  mindist=0"
                result << "  rankdir=TB"
                result << "  node [shape=record,height=.1,fontname=\"Arial\"];"

                all_tasks = ValueSet.new

                plan.find_local_tasks(Component).each do |task|
                    all_tasks << task
                    task.send(options[:accessor]) do |child_task, _|
                        all_tasks << child_task
                        result << "  #{task.dot_id} #{options[:dot_edge_mark]} #{child_task.dot_id};"
                    end
                end

                all_tasks.each do |task|
                    attributes = []
                    task_label = format_task_label(task)
                    label = "  <TABLE ALIGN=\"LEFT\" COLOR=\"white\" BORDER=\"1\" CELLBORDER=\"0\" CELLSPACING=\"0\">\n#{task_label}</TABLE>"
                    attributes << "label=<#{label}>"
                    color_set =
                        if options[:toned_down].include?(task)
                            COLORS[:toned_down]
                        else COLORS[:normal]
                        end
                    color =
                        if task.abstract? then color_set[1]
                        else color_set[0]
                        end
                    attributes << "color=\"#{color}\""
                    if options[:highlights].include?(task)
                        attributes << "penwidth=3"
                    end

                    result << "  #{task.dot_id} [#{attributes.join(" ")}];"
                end

                result << "};"
                result.join("\n")
            end

            # Generates a dot graph that represents the task hierarchy in this
            # deployment
            #
            # It takes no options. The +options+ argument is used to have a
            # common signature with #dataflow
            def hierarchy(options = Hash.new)
                relation_to_dot(:accessor => :each_child)
            end

            def self.available_annotations
                instance_methods.to_a.map(&:to_s).grep(/^add_\w+_annotations/).
                    map { |s| s.gsub(/add_(\w+)_annotations/, '\1') }
            end

            def add_port_details_annotations
                plan.find_local_tasks(Component).each do |task|
                    task.model.each_port do |p|
                        add_port_annotation(task, p.name, "Type", p.type_name)
                    end
                end
            end

            def add_task_info_annotations
                plan.find_local_tasks(TaskContext).each do |task|
                    add_task_annotation(task, "Arguments", task.arguments.map { |k, v| "#{k}: #{v}" })
                    add_task_annotation(task, "Roles", task.roles.to_a.sort.join(", "))
                end
            end

            def add_connection_policy_annotations
                plan.find_local_tasks(TaskContext).each do |source_task|
                    source_task.each_concrete_output_connection do |source_port, sink_port, sink_task, policy|
                        policy = policy.dup
                        policy.delete(:fallback_policy)
                        if policy.empty?
                            policy_s = "(no policy)"
                        else
                            policy_s = if policy.empty? then ""
                                       elsif policy[:type] == :data then 'data'
                                       elsif policy[:type] == :buffer then  "buffer:#{policy[:size]}"
                                       else policy.to_s
                                       end
                        end
                        conn_annotations[[source_task, source_port, sink_task, sink_port]] << policy_s
                    end
                end
            end

            def add_trigger_annotations
                plan.find_local_tasks(TaskContext).each do |task|
                    task.model.each_port do |p|
                        if dyn = task.port_dynamics[p.name]
                            ann = dyn.triggers.map do |tr|
                                "#{tr.name}[p=#{tr.period},s=#{tr.sample_count}]"
                            end
                            port_annotations[[task, p.name]]['Triggers'].concat(ann)
                        end
                    end
                    if dyn = task.dynamics
                        ann = dyn.triggers.map do |tr|
                                "#{tr.name}[p=#{tr.period},s=#{tr.sample_count}]"
                        end
                        task_annotations[task]['Triggers'].concat(ann)
                    end
                end
            end

            # Generates a dot graph that represents the task dataflow in this
            # deployment
            def dataflow(options = Hash.new, excluded_models = ValueSet.new, annotations = Set.new)
                # For backward compatibility with the signature
                # dataflow(remove_compositions = false, excluded_models = ValueSet.new, annotations = Set.new)
                if !options.kind_of?(Hash)
                    options = { :remove_compositions => options, :excluded_models => excluded_models, :annotations => annotations }
                end

                options = Kernel.validate_options options,
                    :remove_compositions => false,
                    :excluded_models => ValueSet.new,
                    :annotations => Set.new
                    
                options[:annotations].each do |ann|
                    send("add_#{ann}_annotations")
                end

                result = []
                result << "digraph {"
                result << "  splines=ortho;"
                result << "  rankdir=LR;"
                result << "  node [shape=none,margin=0,height=.1,fontname=\"Arial\"];"

                output_ports = Hash.new { |h, k| h[k] = Set.new }
                input_ports  = Hash.new { |h, k| h[k] = Set.new }
                connections = Hash.new

                all_tasks = plan.find_local_tasks(Deployment).to_value_set

                # Register all ports and all connections
                #
                # Note that a connection is not guaranteed to be from an output
                # to an input: on compositions, exported ports are represented
                # as connections between either two inputs or two outputs
                plan.find_local_tasks(Component).each do |source_task|
                    next if options[:remove_compositions] && source_task.kind_of?(Composition)
                    next if options[:excluded_models].include?(source_task.model)

                    source_task.model.each_input_port do |port|
                        input_ports[source_task] << port.name
                    end
                    source_task.model.each_output_port do |port|
                        output_ports[source_task] << port.name
                    end

                    all_tasks << source_task

                    if !source_task.kind_of?(Composition)
                        source_task.each_concrete_output_connection do |source_port, sink_port, sink_task, policy|
                            next if excluded_models.include?(sink_task.model)
                            connections[[source_task, source_port, sink_port, sink_task]] = policy
                        end
                    end
                    source_task.each_output_connection do |source_port, sink_port, sink_task, policy|
                        next if connections.has_key?([source_port, sink_port, sink_task])
                        next if excluded_models.include?(sink_task.model)
                        next if options[:remove_compositions] && sink_task.kind_of?(Composition)
                        connections[[source_task, source_port, sink_port, sink_task]] = policy
                    end
                end

                # Register ports that are part of connections, but are not
                # defined on the task's interface. They are dynamic ports.
                connections.each do |(source_task, source_port, sink_port, sink_task), policy|
                    if !input_ports[source_task].include?(source_port)
                        output_ports[source_task] << source_port
                    end
                    if !output_ports[sink_task].include?(sink_port)
                        input_ports[sink_task] << sink_port
                    end
                end

                # Finally, emit the dot code for connections
                connections.each do |(source_task, source_port, sink_port, sink_task), policy|
                    source_type =
                        if input_ports[source_task].include?(source_port)
                            "inputs"
                        else
                            "outputs"
                        end
                    sink_type =
                        if output_ports[sink_task].include?(sink_port)
                            "outputs"
                        else
                            "inputs"
                        end

                    if source_task.kind_of?(Composition) || sink_task.kind_of?(Composition)
                        style = "style=dashed,"
                    end

                    source_port_id = source_port.gsub(/[^\w]/, '_')
                    sink_port_id   = sink_port.gsub(/[^\w]/, '_')

                    label = conn_annotations[[source_task, source_port, sink_task, sink_port]].join(",")
                    result << "  #{source_type}#{source_task.dot_id}:#{source_port_id} -> #{sink_type}#{sink_task.dot_id}:#{sink_port_id} [#{style}label=\"#{label}\"];"
                end

                # Group the tasks by deployment
                clusters = Hash.new { |h, k| h[k] = Array.new }
                all_tasks.each do |task|
                    if !task.kind_of?(Deployment)
                        clusters[task.execution_agent] << task
                    end
                end

                # Allocate one color for each task. The ideal would be to do a
                # graph coloring so that two related tasks don't get the same
                # color, but that's TODO
                task_colors = Hash.new
                used_deployments = all_tasks.map(&:execution_agent).to_value_set
                used_deployments.each do |task|
                    task_colors[task] = RobyPlugin.allocate_color
                end

                clusters.each do |deployment, task_contexts|
                    if deployment
                        result << "  subgraph cluster_#{deployment.dot_id} {"
                        task_label, task_dot_attributes = format_task_label(deployment, task_colors)
                        label = "  <TABLE ALIGN=\"LEFT\" COLOR=\"white\" BORDER=\"1\" CELLBORDER=\"0\" CELLSPACING=\"0\">\n"
                        label << "    #{task_label}\n"
                        label << "  </TABLE>"
                        result << "      label=< #{label} >;"
                    end

                    task_contexts.each do |task|
                        if !task
                            raise "#{task} #{deployment} #{task_contexts.inspect}"
                        end
                        result << render_task(task, input_ports[task].to_a.sort, output_ports[task].to_a.sort)
                    end

                    if deployment
                        result << "  };"
                    end
                end

                additional_edges.each do |from, to, label|
                    from_id = dot_id(*from)
                    to_id   = dot_id(*to)
                    result << "  #{from_id} -> #{to_id} [#{label}];"
                end

                result << "};"
                result.join("\n")
            end

            def dot_id(object, context = nil)
                case object
                when Orocos::RobyPlugin::TaskContext
                    "label#{object.dot_id}"
                when Orocos::Spec::InputPort
                    "inputs#{context.dot_id}:#{object.name}"
                when Orocos::Spec::OutputPort
                    "outputs#{context.dot_id}:#{object.name}"
                else
                    if object.respond_to?(:to_str) && context.respond_to?(:object_id)
                        "#{object}#{context.dot_id}"
                    else
                        raise ArgumentError, "don't know how to generate a dot ID for #{object} in context #{context}"
                    end
                end
            end

            def render_task(task, input_ports, output_ports)
                result = []
                result << "    subgraph cluster_#{task.dot_id} {"
                result << "        label=\"\";"
                if task.abstract?
                    result << "      color=\"red\";"
                end

                additional_vertices[task].each do |vertex_name, vertex_label|
                    result << "      #{vertex_name}#{task.dot_id} [#{vertex_label}];"
                end

                task_label, attributes = format_task_label(task)
                task_label = "  <TABLE ALIGN=\"LEFT\" COLOR=\"white\" BORDER=\"1\" CELLBORDER=\"0\" CELLSPACING=\"0\">#{task_label}</TABLE>"
                result << "    label#{task.dot_id} [shape=none,label=< #{task_label} >];";

                if !input_ports.empty?
                    input_port_label = "<TABLE BORDER=\"0\" CELLBORDER=\"1\" CELLSPACING=\"0\">"
                    input_ports.each do |p|
                        port_id = p.gsub(/[^\w]/, '_')
                        ann = format_annotations(port_annotations, [task, p])
                        input_port_label << "<TR><TD><TABLE BORDER=\"0\" CELLBORDER=\"0\"><TR><TD PORT=\"#{port_id}\" COLSPAN=\"2\">#{p}</TD></TR>#{ann}</TABLE></TD></TR>"
                    end
                    input_port_label << "\n</TABLE>"
                    result << "    inputs#{task.dot_id} [label=< #{input_port_label} >,shape=none];"
                    result << "    inputs#{task.dot_id} -> label#{task.dot_id} [style=invis];"
                end

                if !output_ports.empty?
                    output_port_label = "<TABLE BORDER=\"0\" CELLBORDER=\"1\" CELLSPACING=\"0\">"
                    output_ports.each do |p|
                        port_id = p.gsub(/[^\w]/, '_')
                        ann = format_annotations(port_annotations, [task, p])
                        output_port_label << "<TR><TD><TABLE BORDER=\"0\" CELLBORDER=\"0\"><TR><TD PORT=\"#{port_id}\" COLSPAN=\"2\">#{p}</TD></TR>#{ann}</TABLE></TD></TR>"
                    end
                    output_port_label << "\n</TABLE>"
                    result << "    outputs#{task.dot_id} [label=< #{output_port_label} >,shape=none];"
                    result << "    label#{task.dot_id} -> outputs#{task.dot_id} [style=invis];"
                end

                result << "    }"
                result.join("\n")
            end
            def format_annotations(annotations, key = nil, options = Hash.new)
                options = Kernel.validate_options options,
                    :include_empty => false

                if key
                    if !annotations.has_key?(key)
                        return
                    end
                    ann = annotations[key]
                else
                    ann = annotations
                end

                result = []
                result = ann.map do |category, values|
                    next if (values.empty? && !options[:include_empty])

                    values = values.map { |v| v.tr("<>", "[]") }
                    "<TR><TD ROWSPAN=\"#{values.size()}\" VALIGN=\"TOP\" ALIGN=\"RIGHT\">#{category}</TD><TD ALIGN=\"LEFT\">#{values.first}</TD></TR>\n" +
                    values[1..-1].map { |v| "<TR><TD ALIGN=\"LEFT\">#{v}</TD></TR>" }.join("\n")
                end.flatten

                if !result.empty?
                    result.map { |l| "    #{l}" }.join("\n")
                end
            end


            def format_task_label(task, task_colors = Hash.new)
                label = []
                
                if task.respond_to?(:proxied_data_services)
                    name = task.proxied_data_services.map(&:short_name).join(", ").tr("<>", '[]')
                    label << "<TR><TD COLSPAN=\"2\">#{name}</TD></TR>"
                else
                    annotations = Array.new
                    if task.model.respond_to?(:is_specialization?) && task.model.is_specialization?
                        annotations = [["Specialized On", [""]]]
                        name = task.model.root_model.name
                        task.model.specialized_children.each do |child_name, child_models|
                            child_models = child_models.map(&:short_name)
                            annotations << [child_name, child_models.shift]
                            child_models.each do |m|
                                annotations << ["", m]
                            end
                        end

                    else
                        name = task.model.name
                    end
                    name = name.gsub("Orocos::RobyPlugin::", "").tr("<>", '[]')

                    if task.execution_agent && task.respond_to?(:orocos_name)
                        name << "[#{task.orocos_name}]"
                    end
                    label << "<TR><TD COLSPAN=\"2\">#{name}</TD></TR>"
                    ann = format_annotations(annotations)
                    label << ann
                end
                
                if ann = format_annotations(task_annotations, task)
                    label << ann
                end

                label = "    " + label.join("\n    ")
                return label
            end
        end
    end
end
