require 'utilrb/kernel/load_dsl_file'
module Orocos
    module RobyPlugin
        # This gets mixed in Roby::Application when the orocos plugin is loaded.
        # It adds the configuration facilities needed to plug-in orogen projects
        # in Roby.
        module Application
            attr_predicate :orocos_auto_configure?, true

            def self.resolve_constants(const_name, context, namespaces)
                candidates = ([context] + namespaces).
                    compact.
                    find_all do |namespace|
                        namespace.const_defined?(const_name)
                    end

                if candidates.size > 1 && candidates.first != context
                    raise "#{const_name} can refer to multiple models: #{candidates.map { |mod| "#{mod.name}::#{const_name}" }.join(", ")}. Please choose one explicitely"
                elsif candidates.empty?
                    raise NameError, "uninitialized constant #{const_name}", caller(3)
                end
                candidates.first.const_get(const_name)
            end

            module RobotExtension
                def each_device(&block)
                    Roby.app.orocos_engine.robot.devices.each_value(&block)
                end

                def devices(&block)
                    if block
                        Kernel.dsl_exec(Roby.app.orocos_engine.robot, [DataSources], !Roby.app.filter_backtraces?, &block)
                    else
                        each_device
                    end
                end
            end

            # The set of loaded orogen projects, as a mapping from the project
            # name to the corresponding TaskLibrary instance
            #
            # See #load_orogen_project.
            attribute(:loaded_orogen_projects) { Hash.new }
            # A mapping from task context model name to the corresponding
            # subclass of Orocos::RobyPlugin::TaskContext
            attribute(:orocos_tasks) { Hash.new }
            # A mapping from deployment name to the corresponding
            # subclass of Orocos::RobyPlugin::Deployment
            attribute(:orocos_deployments) { Hash.new }

            attribute(:main_orogen_project) do
                project = Orocos::Generation::Component.new
                project.name 'roby'
            end

            # The system model object
            attr_accessor :orocos_system_model
            # The orocos engine we are using
            attr_accessor :orocos_engine
            # If true, we will not load the component-specific code in
            # tasks/orocos/
            attr_predicate :orocos_load_component_extensions, true

            def self.load(app, options)
                app.orocos_load_component_extensions = true

                ::Robot.extend Application::RobotExtension
                mod = Module.new do
                    def self.method_missing(m, *args, &block)
                        Roby.app.orocos_engine.robot.send(m, *args, &block)
                    end

                    def self.const_missing(const_name)
                        Application.resolve_constants(const_name, DataSources, [DataSources])
                    end
                end
                ::Robot.const_set 'Devices', mod

            end

            # Returns true if the given orogen project has already been loaded
            # by #load_orogen_project
            def loaded_orogen_project?(name); loaded_orogen_projects.include?(name) end
            # Load the given orogen project and defines the associated task
            # models. It also loads the projects this one depends on.
            def load_orogen_project(name)
                return loaded_orogen_projects[name] if loaded_orogen_project?(name)

                orogen = main_orogen_project.using_task_library(name)
		Orocos.registry.merge(orogen.registry)
                loaded_orogen_projects[name] = orogen

                orogen.used_task_libraries.each do |lib|
                    load_orogen_project(lib.name)
                end

                orogen.self_tasks.each do |task_def|
                    if !orocos_tasks[task_def.name]
                        orocos_tasks[task_def.name] = Orocos::RobyPlugin::TaskContext.define_from_orogen(task_def, orocos_system_model)
                    end
                end
                orogen.deployers.each do |deployment_def|
                    if deployment_def.install? && !orocos_deployments[deployment_def.name]
                        orocos_deployments[deployment_def.name] = Orocos::RobyPlugin::Deployment.define_from_orogen(deployment_def)
                    end
                end

                # If we are loading under Roby, get the plugins for the orogen
                # project
                if orocos_load_component_extensions?
                    file = File.join('tasks', 'components', "#{name}.rb")
                    if File.exists?(file)
                        Application.load_task_extension(file, self)
                    end
                end

                orogen
            end

            def get_orocos_task_model(spec)
                if spec.respond_to?(:to_str)
                    if model = orocos_tasks[spec]
                        return model
                    end
                    raise ArgumentError, "there is no orocos task model named #{spec}"
                elsif !(spec < TaskContext)
                    raise ArgumentError, "#{spec} is not a task context model"
                else
                    spec
                end
            end

            def orogen_load_all
                Orocos.available_projects.each_key do |name|
                    load_orogen_project(name)
                end
            end

            # Called by Roby::Application on setup
            def self.setup(app)
                if !Roby.respond_to?(:orocos_engine)
                    def Roby.orocos_engine
                        Roby.app.orocos_engine
                    end
                end

                app.orocos_auto_configure = true
                Orocos.disable_sigchld_handler = true
                Orocos.load

                app.orocos_clear_models
                app.orocos_tasks['RTT::TaskContext'] = Orocos::RobyPlugin::TaskContext

                rtt_taskmodel = Orocos::Generation::Component.standard_tasks.
                    find { |m| m.name == "RTT::TaskContext" }
                Orocos::RobyPlugin::TaskContext.instance_variable_set :@orogen_spec, rtt_taskmodel
                Orocos::RobyPlugin.const_set :RTT, Module.new
                Orocos::RobyPlugin::RTT.const_set :TaskContext, Orocos::RobyPlugin::TaskContext

                app.orocos_system_model = SystemModel.new
                app.orocos_engine = Engine.new(Roby.plan || Roby::Plan.new, app.orocos_system_model)
                Orocos.singleton_class.class_eval do
                    attr_reader :engine
                end
                Orocos.instance_variable_set :@engine, app.orocos_engine
            end

            def self.require_models(app)
                Orocos.const_set('Deployments',  Orocos::RobyPlugin::Deployments)
                Orocos.const_set('DataServices', Orocos::RobyPlugin::DataServices)
                Orocos.const_set('DataSources',  Orocos::RobyPlugin::DataSources)
                Orocos.const_set('Compositions', Orocos::RobyPlugin::Compositions)

                # Load the data services and task models
                %w{data_services compositions}.each do |category|
                    all_files = app.list_dir(APP_DIR, "tasks", category).to_a +
                        app.list_robotdir(APP_DIR, 'tasks', 'ROBOT', category).to_a
                    all_files.each do |path|
                        app.load_system_model(path)
                    end
                end

                project_names = app.loaded_orogen_projects.keys
                task_models = (app.list_dir(APP_DIR, "tasks", 'components').to_a +
                    app.list_robotdir(APP_DIR, 'tasks', 'ROBOT', 'components').to_a)
                task_models.each do |path|
                    if project_names.include?(File.basename(path, ".rb"))
                        load_task_extension(path, app)
                    end
                end

                Orocos.const_set(:RTT, Orocos::RobyPlugin::RTT)
                projects = Set.new
                app.orocos_tasks.each_value do |model|
                    if model.orogen_spec
                        projects << model.orogen_spec.component.name.camelcase(true)
                    end
                end

                projects.each do |name|
                    name = name.camelcase(true)

                    # The RTT is already handled above
                    if name !~ /RTT/
                        Orocos.const_set(name, Orocos::RobyPlugin.const_get(name))
                    end
                end
            end

            def use_deployments_from(*args)
                orocos_engine.use_deployments_from(*args)
            end

            def orocos_clear_models
                projects = Set.new

                orocos_tasks.each_value do |model|
                    if model.orogen_spec
                        project_name = model.orogen_spec.component.name.camelcase(true)
                        task_name    = model.orogen_spec.basename.camelcase(true)
                        projects << project_name
                        constant("Orocos::RobyPlugin::#{project_name}").send(:remove_const, task_name)
                    end
                end
                orocos_tasks.clear

                orocos_deployments.each_key do |name|
                    name = name.camelcase(true)
                    Orocos::RobyPlugin::Deployments.send(:remove_const, name)
                end
                orocos_deployments.clear

                projects.each do |name|
                    name = name.camelcase(true)
                    Orocos::RobyPlugin.send(:remove_const, name)
                    if Orocos.const_defined?(name)
                        Orocos.send(:remove_const, name)
                    end
                end

                [DataServices, Compositions, DataSources].each do |mod|
                    mod.constants.each do |const_name|
                        mod.send(:remove_const, const_name)
                    end
                end

                project = Orocos::Generation::Component.new
                project.name 'roby'
                @main_orogen_project = project
            end

            def self.load_task_extension(file, app)
                search_path = [RobyPlugin,
                    RobyPlugin::DataServices,
                    RobyPlugin::DataSources,
                    RobyPlugin::Compositions]
                if Kernel.load_dsl_file(file, Roby.app.orocos_system_model, search_path, !Roby.app.filter_backtraces?)
                    RobyPlugin.info "loaded #{file}"
                end
            end

            # Load a part of the system model, i.e. composition and/or data
            # services
            def load_system_model(file)
                candidates = [file, File.join("tasks", file)]
                candidates = candidates.concat(candidates.map { |p| "#{p}.rb" })
                path = candidates.find do |path|
                    File.exists?(path)
                end

                if !path
                    raise ArgumentError, "there is no system model file called #{file}"
                end

                search_path = [RobyPlugin,
                    RobyPlugin::DataServices,
                    RobyPlugin::DataSources,
                    RobyPlugin::Compositions]
                if Kernel.load_dsl_file(path, orocos_system_model, search_path, !Roby.app.filter_backtraces?)
                    RobyPlugin.info "loaded #{path}"
                end
            end

            # Load a part of the system definition, i.e. the robot description
            # files
            def load_system_definition(file)
                search_path = [RobyPlugin,
                    RobyPlugin::DataServices,
                    RobyPlugin::DataSources,
                    RobyPlugin::Compositions]

                if Kernel.load_dsl_file(file, orocos_engine, search_path, false)
                    RobyPlugin.info "loaded #{file}"
                end
            end

            # Loads the specified orocos deployment file
            #
            # The deployment can either be a file name in
            # config/deployments/, config/ROBOT/deployments or a full path to a
            # separate deployment file.
            def load_orocos_deployment(name)
                if File.file?(name)
                    load_system_definition(name)
		elsif file = robotfile('config', 'ROBOT', 'deployments', "#{name}.rb")
		    load_system_definition(file)
		elsif File.file?(file = File.join('config', 'deployments', "#{name}.rb"))
		    load_system_definition(file)
		else
		    raise ArgumentError, "cannot find a deployment named '#{name}'"
		end
            end

            # Load the specified orocos deployment file and apply it to the main
            # plan
            #
            # The deployment can either be a file name in
            # config/deployments/, config/ROBOT/deployments or a full path to a
            # separate deployment file.
            #
            # If a block is given, it is instance_eval'd in orocos_engine. I.e.,
            # it can be used to modify the loaded deployment.
            #
            # This method accepts the same options than Engine#resolve
	    def apply_orocos_deployment(name, options = Hash.new, &block)
                load_orocos_deployment(name)
                orocos_engine.instance_eval(&block) if block_given?
		orocos_engine.resolve(options)
	    end

            # Start a process server on the local machine, and register it in
            # Orocos::RobyPlugin.process_servers under the 'localhost' name
            def self.start_local_process_server(
                    options = Orocos::ProcessServer::DEFAULT_OPTIONS,
                    port = Orocos::ProcessServer::DEFAULT_PORT)

                @server_pid = fork do
                    logfile = File.expand_path("local_process_server.txt", Roby.app.log_dir)
                    new_logger = ::Logger.new(File.open(logfile, 'w'))
                    new_logger.level = ::Logger::DEBUG
                    new_logger.formatter = Roby.logger.formatter
                    new_logger.progname = "ProcessServer(localhost)"
                    Orocos.logger = new_logger
                    ::Process.setpgrp
                    Orocos::ProcessServer.run(options, port)
                end
                # Wait for the server to be ready
                client = nil
                while !client
                    client =
                        begin Orocos::ProcessClient.new
                        rescue Errno::ECONNREFUSED
                        end
                end

                # Do *not* manage the log directory for that one ...
                Orocos::RobyPlugin.process_servers['localhost'] = [client, Roby.app.log_dir]
                client
            end

            # Stop the process server started by start_local_process_server if
            # one is running
            def self.stop_local_process_server
                return if !@server_pid

                if @server_pid
                    ::Process.kill('INT', @server_pid)
                    begin
                        ::Process.waitpid(@server_pid)
                        @server_pid = nil
                    rescue Errno::ESRCH
                    end
                end
                Orocos::RobyPlugin.process_servers.delete('localhost')
            end

            # Call to add a process server to to the set of servers that can be
            # used by this plan manager
            def orocos_process_server(name, host, options = Hash.new)
                if host =~ /^(.*):(\d+)$/
                    host = $1
                    port = Integer($2)
                end
                orocos_process_servers[name] = [[host, port].compact, options]
            end

            # :attr: orocos_process_servers
            #
            # A name => [host[, port]] mapping of all the defined process
            # servers. In addition, if the orocos_local_process_server?
            # predicate is true (the default), a process server called
            # 'localhost' will be started on the local machine
            attribute(:orocos_process_servers) { Hash.new }

            # :attr: disable_local_process_server?
            #
            # In normal operations, a local proces server called 'localhost' is
            # automatically started on the local machine. If this predicate is
            # set to true, using self.disable_local_process_server = true), then
            # this will be disabled
            #
            # See also #orocos_process_server
            attr_predicate :disable_local_process_server?, true

            def self.run(app)
                # Change to the log dir so that the IOR file created by the
                # CORBA bindings ends up there
                Dir.chdir(Roby.app.log_dir) do
                    Orocos.initialize
                    if !app.disable_local_process_server?
                        start_local_process_server
                    end
                end

                # Connect to the process servers
                app.orocos_process_servers.each do |name, (server_uri, options)|
                    client = Orocos::ProcessClient.new(*server_uri)
                    client.save_log_dir(options[:log_dir] || 'log', options[:result_dir] || 'results')
                    client.create_log_dir(options[:log_dir] || 'log', Roby.app.log_read_time_tag)
                    Orocos::RobyPlugin.process_servers[name] = [client, options[:log_dir] || 'log']
                end
                handler_id = Roby.engine.add_propagation_handler(&Orocos::RobyPlugin.method(:update))

                yield

            ensure
                remaining = Orocos.each_process.to_a
                if !remaining.empty?
                    RobyPlugin.warn "killing remaining Orocos processes: #{remaining.map(&:name).join(", ")}"
                    Orocos::Process.kill(remaining)
                end

                if handler_id
                    Roby.engine.remove_propagation_handler(handler_id)
                end

                # Stop the local process server if we started it ourselves
                stop_local_process_server
                Orocos::RobyPlugin.process_servers.each_value do |client, options|
                    client.disconnect
                end
                Orocos::RobyPlugin.process_servers.clear
            end
        end
    end

    Roby::Application.register_plugin('orocos', Orocos::RobyPlugin::Application) do
        require 'orocos/roby'
        require 'orocos/process_server'
    end
end

