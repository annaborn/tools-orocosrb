BASE_DIR = File.expand_path( '..', File.dirname(__FILE__))
$LOAD_PATH.unshift BASE_DIR
require 'test/unit'
require 'roby'
require 'roby/test/common'
require 'roby/test/testcase'
require 'roby/test/tasks/simple_task'
require 'orocos/roby/app'
require 'orocos/roby'

APP_DIR = File.join(BASE_DIR, "test")

class TC_Orocos < Test::Unit::TestCase
    include Roby::Test
    include Roby::Test::Assertions

    WORK_DIR = File.join(BASE_DIR, '..', 'test', 'working_copy')
    def setup
        super

        ::Orocos.initialize
        Roby.app.extend Orocos::RobyPlugin::Application
        save_collection Roby.app.loaded_orogen_projects
        save_collection Roby.app.orocos_tasks
        save_collection Roby.app.orocos_deployments

        @update_handler = engine.each_cycle(&Orocos::RobyPlugin.method(:update))

        FileUtils.mkdir_p Roby.app.log_dir
        @old_pkg_config = ENV['PKG_CONFIG_PATH'].dup
        ENV['PKG_CONFIG_PATH'] += ":#{File.join(WORK_DIR, "prefix", 'lib', 'pkgconfig')}"

        Orocos::RobyPlugin::Application.setup
    end

    def teardown
        Roby.app.orocos_clear_models
        ::Orocos.instance_variable_set :@registry, Typelib::Registry.new
        ::Orocos::CORBA.instance_variable_set :@loaded_toolkits, []
        ENV['PKG_CONFIG_PATH'] = @old_pkg_config

        FileUtils.rm_rf Roby.app.log_dir

        super
    end

    def test_deployment_nominal_actions
        Roby.app.load_orogen_project "echo"

	engine.run

        task = Orocos::RobyPlugin::Deployments::Echo.new
        assert_any_event(task.ready_event) do
            plan.add_permanent(task)
	    task.start!
	end

        assert_any_event(task.stop_event) do
            task.stop!
        end
    end

    def test_deployment_crash_handling
        Roby.app.load_orogen_project "echo"

	engine.run

        task = Orocos::RobyPlugin::Deployments::Echo.new
        assert_any_event(task.ready_event) do
            plan.add_permanent(task)
	    task.start!
	end

        assert_any_event(task.failed_event) do
            task.orogen_deployment.kill
        end
    end

    def test_deployment_task
        Roby.app.load_orogen_project "echo"
        deployment = Orocos::RobyPlugin::Deployments::Echo.new
        task       = deployment.task 'echo_Echo'
        assert task.child_object?(deployment, TaskStructure::ExecutionAgent)
        plan.add(task)
    end

    def test_task_model_definition
        Roby.app.load_orogen_project "echo"

        assert_kind_of(Orocos::RobyPlugin::Project, Orocos::RobyPlugin::Echo)
        # Should have a task context model
        assert(Orocos::RobyPlugin::Echo::Echo < Orocos::RobyPlugin::TaskContext)
        # And a deployment model
        assert(Orocos::RobyPlugin::Deployments::Echo < Orocos::RobyPlugin::Deployment)
        # The orogen_spec should be a task context model
        assert_kind_of(Orocos::Generation::TaskContext, Orocos::RobyPlugin::Echo::Echo.orogen_spec)
    end

    def test_task_model_inheritance
        Roby.app.load_orogen_project "echo"

        assert(root_model = Roby.app.orocos_tasks['RTT::TaskContext'])
        assert_same root_model, Orocos::RobyPlugin::TaskContext
        assert(echo_model = Roby.app.orocos_tasks['echo::Echo'])
        assert(echo_model < root_model)
        assert(echo_submodel = Roby.app.orocos_tasks['echo::EchoSubmodel'])
        assert(echo_submodel < echo_model)
    end

    def test_task_nominal
        Roby.app.load_orogen_project "echo"
	engine.run

        deployment = Orocos::RobyPlugin::Deployments::Echo.new
        task       = deployment.task 'echo_Echo'
        assert_any_event(task.start_event) do
            plan.add_permanent(task)
            task.start!
	end

        assert_any_event(task.stop_event) do
            task.stop!
        end
    end

    def test_task_extended_states_definition
        Roby.app.load_orogen_project "states"
        deployment = Orocos::RobyPlugin::Deployments::States.new
        plan.add(task = deployment.task('states_Task'))

        assert task.has_event?(:custom_runtime)
        assert !task.event(:custom_runtime).terminal?
        assert task.has_event?(:custom_fatal)
        assert task.event(:custom_fatal).terminal?
        assert task.has_event?(:custom_error)
        assert task.event(:custom_error).terminal?
    end

    def test_task_runtime_error
        Roby.app.load_orogen_project "states"
	engine.run

        means_of_termination = [
            [:stop            ,  :success],
            [:do_runtime_error,  :runtime_error],
            [:do_custom_error ,  :custom_error],
            [:do_fatal_error  ,  :fatal_error],
            [:do_custom_fatal ,  :custom_fatal] ]

        deployment = Orocos::RobyPlugin::Deployments::States.new
        plan.add_permanent(deployment)

        means_of_termination.each do |method, state|
            task = deployment.task 'states_Task'
            assert_any_event(task.start_event) do
                plan.add_permanent(task)
                task.start!
            end

            assert_any_event(task.event(state)) do
                task.orogen_task.send(method)
            end

            sleep 1
        end
    end

    def test_task_fatal_error
        Roby.app.load_orogen_project "states"
	engine.run

        deployment = Orocos::RobyPlugin::Deployments::States.new
        task       = deployment.task 'states_Task'
        assert_any_event(task.start_event) do
            plan.add_permanent(task)
            task.start!
	end

        assert_any_event(task.fatal_error_event) do
            task.orogen_task.do_fatal_error
        end
        assert(task.failed?)
    end
end

