require 'orocos/nameservice_interfaces.rb'

module Nameservice

    class AVAHI < Provider

        def initialize(options)
            super
            enable(options)
        end

        def self.options
            @@options[:searchdomains] = "Search domains as hash of 'label' => 'domain, where a plain domainname will by default be expaned to _domain._tcp"

            @@options
        end
    
        # Check is the nameserver is enabled
        def enabled?
            if @avahi_nameserver
                return true
            end
                
            return false
        end

        # Return the IOR 
        # Throws Nameservice::NoAccess if the IOR cannot be retrieved
        # due to an uninitialized nameserver
        # Throws Orocos::NotFound if the service could not be found
        # due to an uninitialized nameserver
        def get_ior(name)
            ior = nil
            services = @avahi_nameserver.find_services(name)
            if services.empty?
                raise Orocos::NotFound, "AVAHI nameservice could not find a task named '#{name}'"
            elsif services.size > 1
                warn "Nameservice: multiple services '#{name}' found. Possibly due to publishing on IPv4 and IPv6, or on multiple interfaces -- picking first one in list"
            end

            service = services.first
            ior = service.get_description("IOR")
            if not ior 
                raise Orocos::NotFound, "AVAHI nameservice could not retrieve an ior for task #{name}"
            end
    
            return ior
        end
    
        # Enable the avahi based nameserver
        # option :searchdomains is available and expects a hash { "label" => "domain-0", ...}
        def enable(options)
            if enabled?
                warn "Nameservice: ignoring request to enable, because nameservice is already running"
                return
            end
               
            ## Introduce alternative avahi based nameserver if corba does not work
            begin 
                require 'servicediscovery'
                if not @avahi_nameserver
                    @avahi_nameserver = ::Avahi::ServiceDiscovery.new
                end

                if not options.has_key?(:searchdomains)
                    raise ArgumentError, "Nameservice: required option :searchdomains is not provided. Call enable with at least one searchdomain given"
                end

                # Start listening on the given domains (this does refer to the _myservice._tcp service domain and not(!) the .local domain)
                # we listen only 
                @avahi_nameserver.listen_on(options[:searchdomains])

            rescue LoadError
                raise LoadError, "Nameservice: 'distributed_nameserver' needs to be installed for AVAHI nameservice support"
            end
        end

        # Resolve a service based on its name
        # return TaskContext
        # throws Exception if the service cannot be resolved
        def resolve(name)
            ior = get_ior(name)
            result=nil
            if ior
		result = Orocos::CORBA.get(:do_get_from_ior, ior)
            else 
                raise Orocos::NotFound
            end
            result
        end

    end # class AVAHI

end # Module Nameservice
