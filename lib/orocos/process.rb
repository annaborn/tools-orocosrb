require 'utilrb/pkgconfig'
require 'orogen'
require 'fcntl'

module Orocos
    # call-seq:
    #   Orocos.run('mod1', 'mod2')
    #   Orocos.run('mod1', 'mod2', :wait => false, :output => '%m-%p.log')
    #   Orocos.run('mod1', 'mod2', :wait => false, :output => '%m-%p.log') do |mod1, mod2|
    #   end
    #
    # Valid options are:
    # wait::
    #   wait that number of seconds (can be floating-point) for the
    #   processes to be ready. If it did not start into the provided
    #   timeout, an Orocos::NotFound exception raised.
    # output::
    #   redirect the process output to the given file. The %m and %p
    #   patterns will be replaced by respectively the name and the PID of
    #   each process.
    # valgrind::
    #   start some or all the processes under valgrind. It can either be an
    #   array of process names (e.g. :valgrind => ['p1', 'p2']) or 'true'.
    #   In the first case, the listed processes will be added to the list of
    #   processes to start (if they are not already in it) and will be
    #   started under valgrind. In the second case, all processes are
    #   started under valgrind.
    def self.run(*args, &block)
        Process.spawn(*args, &block)
    end

    # Deprecated. Use Orocos.run instead.
    def self.spawn(*args, &block)
        STDERR.puts "#{caller(1)}: Orocos.spawn is deprecated, use Orocos.run instead"
        run(*args, &block)
    end

    # The representation of an Orocos process. It manages
    # starting the process and cleaning up when the process
    # dies.
    class Process
        # The component name
        attr_reader :name
        # The component PkgConfig instance
        attr_reader :pkg
        # The component process ID
        attr_reader :pid
        # The orogen description
        def orogen; model end
        # The Orocos::Generation::StaticDeployment instance that represents
        # this process
        attr_reader :model
        # The set of task contexts for this process. This is valid only after
        # the process is actually started
        attr_reader :tasks

	def self.from_pid(pid)
	    ObjectSpace.enum_for(:each_object, Orocos::Process).find { |mod| mod.pid == pid }
	end

        # Creates a new Process instance which will be able to
        # start and supervise the execution of the given Orocos
        # component
        def initialize(name)
            @name  = name
            @tasks = []
            @pkg = Orocos.available_deployments[name]
            if !pkg
                raise NotFound, "deployment #{name} does not exist or its pkg-config orogen-#{name} is not found by pkg-config\ncheck your PKG_CONFIG_PATH environment var. Current value is #{ENV['PKG_CONFIG_PATH']}"
            end

            # Load the orogen's description
            orogen_project = Orocos.master_project.load_orogen_project(pkg.project_name)
            @model = orogen_project.deployers.find do |d|
                d.name == name
            end
	    if !model
	    	Orocos.warn "cannot locate deployment #{name} in #{orogen_project.name}"
	    end
        end


        # Waits until the process dies
        #
        # This is valid only if the module has been started
        # under rOrocos supervision, using #spawn
        def join
            return unless alive?

	    begin
		::Process.waitpid(pid)
                exit_status = $?
                dead!(exit_status)
	    rescue Errno::ECHILD
	    end
        end
        
        # True if the process is running
        def alive?; !!@pid end
        # True if the process is running
        def running?; alive? end

        # Called externally to announce a component dead.
	def dead!(exit_status) # :nodoc:
            exit_status = (@exit_status ||= exit_status)
            if !exit_status
                Orocos.info "deployment #{name} exited, exit status unknown"
            elsif exit_status.success?
                Orocos.info "deployment #{name} exited normally"
            elsif exit_status.signaled?
                if @expected_exit == exit_status.termsig
                    Orocos.info "deployment #{name} terminated with signal #{exit_status.termsig}"
                elsif @expected_exit
                    Orocos.info "deployment #{name} terminated with signal #{exit_status.termsig} but #{@expected_exit} was expected"
                else
                    Orocos.warn "deployment #{name} unexpectedly terminated with signal #{exit_status.termsig}"
                end
            else
                Orocos.warn "deployment #{name} terminated with code #{exit_status.to_i}"
            end

	    @pid = nil 

            # Force unregistering the task contexts from CORBA naming
            # service
            task_names.each do |name|
                Orocos::CORBA.unregister(name)
            end
	end

	@@logfile_indexes = Hash.new

        # The set of [task_name, port_name] that represent the ports being
        # currently logged by this process' default logger
        attr_reader :logged_ports

        # Requires all known ports of +self+ to be logged by the default logger
        def log_all_ports(options = Hash.new)
            @logged_ports |= Orocos.log_all_process_ports(self, options)
        end

        def setup_default_logger(options)
            Orocos.setup_default_logger(self, options)
        end
        
        # Deprecated
        #
        # Use Orocos.run directly instead
        def self.spawn(*names)
            if !Orocos::CORBA.initialized?
                raise "CORBA layer is not initialized, did you forget to call 'Orocos.initialize' ?"
            end

            if names.last.kind_of?(Hash)
                options = names.pop
            end

            begin
                options = validate_options options, :wait => nil, :output => nil, :working_directory => nil, :valgrind => false, :valgrind_options => []

		options[:wait] ||=
		    if options[:valgrind] then 60
		    else 2
		    end
		    
                valgrind = options[:valgrind]
                if !valgrind.respond_to?(:to_hash)
                    if !valgrind
                        valgrind = Array.new
                    elsif valgrind.respond_to?(:to_str)
                        valgrind = [valgrind]
                    elsif !valgrind.respond_to?(:to_ary)
                        valgrind = names.dup
                    end

                    valgrind_options = options[:valgrind_options]
                    valgrind = valgrind.inject(Hash.new) { |h, name| h[name] = valgrind_options; h }
                end

                # First thing, do create all the named processes
                processes = names.map { |name| [name, Process.new(name)] }
                # Then spawn them, but without waiting for them
                processes.each do |name, p|
                    output = if options[:output]
                                 options[:output].gsub '%m', name
                             end

                    p.spawn(:working_directory => options[:working_directory], :output => output, :valgrind => valgrind[name])
                end

                # Finally, if the user required it, wait for the processes to run
                if options[:wait]
                    timeout = if options[:wait].kind_of?(Numeric)
                                  options[:wait]
                              end
                    processes.each { |_, p| p.wait_running(timeout) }
                end
            rescue Exception
                # Kill the processes that are already running
                if processes
                    kill(processes.map { |name, p| p if p.running? }.compact)
                end
                raise
            end

            processes = processes.map { |_, p| p }
            if block_given?
                Orocos.guard do
                    yield(*processes)
                end
            else
                processes
            end
        end
        
        # Kills the given processes. If +wait+ is true, will also wait for the
        # processes to be destroyed.
        def self.kill(processes, wait = true)
            processes.each { |p| p.kill if p.running? }
            if wait
                processes.each { |p| p.join }
            end
        end

        # Spawns this process
        #
        # Valid options:
        # output::
        #   if non-nil, the process output is redirected towards that
        #   file. Special patterns %m and %p are replaced respectively by the
        #   process name and the process PID value.
        # valgrind::
        #   if true, the process is started under valgrind. If :output is set
        #   as well, valgrind's output is redirected towards the value of output
        #   with a .valgrind extension added.
        def spawn(options = Hash.new)
	    raise "#{name} is already running" if alive?
	    Orocos.debug { "Spawning module #{name}" }

            # If possible, check that we won't clash with an already running
            # process
            task_names.each do |name|
                if TaskContext.reachable?(name)
                    raise ArgumentError, "there is already a running task called #{name}, are you starting the same component twice ?"
                end
            end

            options = Kernel.validate_options options, :output => nil,
                :valgrind => nil, :working_directory => nil
            output   = options[:output]
            if options[:valgrind]
                valgrind = true
                valgrind_options =
                    if options[:valgrind].respond_to?(:to_ary)
                        options[:valgrind]
                    else []
                    end
            end

            workdir  = options[:working_directory]

            ENV['ORBInitRef'] = "NameService=corbaname::#{CORBA.name_service}"

            module_bin = pkg.binfile
            if !module_bin # assume an older orogen version
                module_bin = "#{pkg.exec_prefix}/bin/#{name}"
            end
            cmdline = [module_bin]

	    if output.respond_to?(:to_str)
		output_format = output.to_str
		output = Tempfile.open('orocos-rb', File.dirname(output_format))
	    end
		    
	    read, write = IO.pipe
	    @pid = fork do 
		if output_format
		    output_file_name = output_format.
			gsub('%m', name).
			gsub('%p', ::Process.pid.to_s)
                    if workdir
                        output_file_name = File.expand_path(output_file_name, workdir)
                    end
		    FileUtils.mv output.path, output_file_name
		end
		
		if output
		    STDERR.reopen(output)
		    STDOUT.reopen(output)
		end

                if valgrind
                    if output_file_name
                        cmdline.unshift "--log-file=#{output_file_name}.valgrind"
                    end
                    cmdline = valgrind_options + cmdline
                    cmdline.unshift "valgrind"
                end

		read.close
		write.fcntl(Fcntl::F_SETFD, 1)
		::Process.setpgrp
                begin
                    if workdir
                        Dir.chdir(workdir)
                    end
                    exec(*cmdline)
                rescue Exception => e
                    write.write("FAILED")
                end
	    end

	    write.close
	    if read.read == "FAILED"
		raise "cannot start #{name}"
	    end
        end

	def self.wait_running(process, timeout = nil)
	    if timeout == 0
		return nil if !process.alive?
                
                # Get any task name from that specific deployment, and check we
                # can access it. If there is none
                all_reachable = process.task_names.all? do |task_name|
                    if TaskContext.reachable?(task_name)
                        Orocos.debug "#{task_name} is reachable"
                        true
                    else
                        Orocos.debug "could not access #{task_name}, #{name} is not running yet ..."
                        false
                    end
                end
                if all_reachable
                    Orocos.info "all tasks of #{name} are reachable, assuming it is up and running"
                end
                all_reachable
	    else
                start_time = Time.now
                got_alive = process.alive?
                while true
                    if wait_running(process, 0)
                        return true
                    elsif timeout && timeout < (Time.now - start_time)
                        raise Orocos::NotFound, "cannot get a running #{name} module"
                    end

                    if got_alive && !process.alive?
                        raise Orocos::NotFound, "#{name} was started but crashed"
                    end
                    sleep 0.1
                end
	    end
	end

        # Wait for the module to be started. If timeout is 0, the function
        # returns immediatly, with a false return value if the module is not
        # started yet and a true return value if it is started.
        #
        # Otherwise, it waits for the process to start for the specified amount
        # of seconds. It will throw Orocos::NotFound if the process was not
        # started within that time.
        #
        # If timeout is nil, the method will wait indefinitely
	def wait_running(timeout = nil)
            Process.wait_running(self, timeout)
	end

        SIGNAL_NUMBERS = {
            'SIGABRT' => 1,
            'SIGINT' => 2,
            'SIGKILL' => 9,
            'SIGSEGV' => 11
        }
        # Kills the process either cleanly by requesting a shutdown if signal ==
        # nil, or forcefully by using UNIX signals if signal is a signal name.
        def kill(wait = true, signal = nil)
            # Stop all tasks and disconnect the ports
            if !signal
                clean_shutdown = true
                begin
                    each_task do |task|
                        begin
                            task.stop
                            if task.model && task.model.needs_configuration?
                                task.cleanup
                            end
                        rescue StateTransitionFailed
                        end

                        task.each_port do |port|
                            port.disconnect_all
                        end
                    end
                rescue Exception => e
                    Orocos.warn "clean shutdown of #{name} failed: #{e.message}"
                    e.backtrace.each do |line|
                        Orocos.warn line
                    end
                    clean_shutdown = false
                end
            end

            expected_exit = nil
            if clean_shutdown
                expected_exit = signal = SIGNAL_NUMBERS['SIGINT']
            end

            if signal 
                if !expected_exit
                    Orocos.warn "sending #{signal} to #{name}"
                end

                if signal.respond_to?(:to_str) && signal !~ /^SIG/
                    signal = "SIG#{signal}"
                end

                expected_exit ||=
                    if signal.kind_of?(Integer) then signal
                    else SIGNAL_NUMBERS[signal] || signal
                    end

                @expected_exit = expected_exit
                begin
                    ::Process.kill(signal, pid)
                rescue Errno::ESRCH
                    # Already exited
                    return
                end
            end

            if wait
                join
                if @exit_status && @exit_status.signaled?
                    if !expected_exit
                        Orocos.warn "#{name} unexpectedly exited with signal #{@exit_status.termsig}"
                    elsif @exit_status.termsig != expected_exit
                        Orocos.warn "#{name} was expected to quit with signal #{expected_exit} but terminated with signal #{@exit_status.termsig}"
                    end
                end
            end
        end

        # Returns the name of the tasks that are running in this process
        #
        # See also #each_task
        def task_names
            if !model
                raise Orocos::NotOrogenComponent, "#{name} does not seem to have been generated by orogen"
            end
            model.task_activities.map(&:name)
        end

        # Enumerate the TaskContext instances of the tasks that are running in
        # this process.
        #
        # See also #task_names
        def each_task
            task_names.each do |name|
                yield(task(name))
            end
        end

        # Returns the TaskContext instance for a task that runs in this process,
        # or raises Orocos::NotFound.
        def task(task_name)
            full_name = "#{name}_#{task_name}"
            if result = tasks.find { |t| t.name == task_name || t.name == full_name }
                return result
            end

            result = if task_names.include?(task_name)
                         TaskContext.get task_name, self
                     elsif task_names.include?(full_name)
                         TaskContext.get full_name, self
                     else
                         raise Orocos::NotFound, "no task #{task_name} defined on #{name}"
                     end

            @tasks << result
            result
        end
    end

    # Enumerates the Orocos::Process objects that are currently available in
    # this Ruby instance
    def self.each_process
        if !block_given?
            return enum_for(:each_process)
        end

        ObjectSpace.each_object(Orocos::Process) do |p|
            yield(p) if p.alive?
        end
    end

    # call-seq:
    #   guard { }
    #
    # All processes started in the provided block will be automatically killed
    def self.guard
        yield
    ensure
        tasks = ObjectSpace.enum_for(:each_object, Orocos::TaskContext)
        tasks.each do |t|
            begin
                if t.running? && t.process
                    t.stop
                    if t.model && t.model.needs_configuration?
                        t.cleanup 
                    end
		end
            rescue
            end
        end

        processes = ObjectSpace.enum_for(:each_object, Orocos::Process)
        processes.each { |mod| mod.kill if mod.running? }
        processes.each { |mod| mod.join if mod.running? }
    end
end

