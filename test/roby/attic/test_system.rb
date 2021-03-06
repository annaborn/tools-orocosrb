BASE_DIR = File.expand_path( '../..', File.dirname(__FILE__))
APP_DIR = File.join(BASE_DIR, "test")
$LOAD_PATH.unshift BASE_DIR
require 'test/roby/common'

class TC_RobySpec_System < Test::Unit::TestCase
    include RobyPluginCommonTest

    attr_reader :can_bus
    attr_reader :imu_driver
    attr_reader :camera_driver
    attr_reader :motors
    attr_reader :controldev

    needs_orogen_projects 'system_test'

    def test_robot_device_definition
        stereo_device_model = sys_model.device_type 'Stereo' do
            output_port 'disparity', 'camera/Image'
            output_port 'cloud', 'base/PointCloud3D'
        end
        sys_model.data_service_type 'Camera' do
            output_port 'image', 'camera/Image'
        end
        stereo_model = SystemTest::Stereo
        stereo_model.provides Dev::Stereo

        stereo_driver = SystemTest::StereoCamera
        stereo_driver.driver_for Dev::Stereo
        stereo_driver.provides Srv::Camera, :as => 'left',  :slave_of => 'stereo'
        stereo_driver.provides Srv::Camera, :as => 'right', :slave_of => 'stereo'

        orocos_engine.robot do
            device Dev::Stereo,  :as => 'frontStereo'
        end
        
        driver_task = orocos_engine.robot.devices['frontStereo']
        assert_equal(stereo_device_model, driver_task.device_model)
    end

    def complete_robot_definition
        orocos_engine.robot do
            device 'imu'
            device 'camera',  :as => 'leftCamera'
            device :camera,   :as => :rightCamera

            com_bus 'can', :as => 'can0'
            through 'can0' do
                device 'joystick'
                device 'sliderbox'
                device 'motors'
            end
        end
    end

    def complete_system_model
        sys_model.com_bus_type 'Can', :message_type => 'can/Message'

        sys_model.data_service_type 'Image' do
            output_port 'image', 'camera/Image'
        end
        sys_model.device_type 'Camera' do
            provides Srv::Image
        end
        sys_model.data_service_type 'Stereo' do
            output_port 'disparity', 'camera/Image'
            output_port 'cloud', 'base/PointCloud3D'
        end
        sys_model.data_service_type 'Imu' do
            output_port 'orientation', 'imu::Orientation'
        end
        sys_model.device_type 'Motors' do
            output_port "motor_state", "control/MotorsState"
        end
        sys_model.data_service_type 'Joystick' do
            output_port "joystick",      "controldev/Joystick"
            output_port "motionCommand", "controldev/MotionCommand"
        end
        sys_model.data_service_type 'Sliderbox' do
            output_port "sliderbox",        "controldev/Sliderbox"
            output_port "fourWheelCommand", "controldev/FourWheelCommand"
        end

        @can_bus        = SystemTest::CanBus
        can_bus.driver_for Dev::Can
        @camera_driver  = SystemTest::CameraDriver
        camera_driver.driver_for Dev::Camera
        @imu_driver     = SystemTest::IMU
        imu_driver.provides Srv::Imu
        @motors         = SystemTest::MotorController
        motors.driver_for Dev::Motors
        @controldev     = SystemTest::ControlDevices
        controldev.provides Srv::Joystick
        controldev.provides Srv::Sliderbox

        sys_model.composition "ImageAcquisition" do
            add Dev::Camera, :as => 'acquisition'
            add SystemTest::CameraFilter, :as => 'filter'
            export filter.out, :as => "image"

            provides Srv::Image
            autoconnect
        end
        sys_model.composition "Stereo" do
            stereo = add SystemTest::StereoProcessing, :as => 'processing'
            image0 = add Srv::Image, :as => "image0"
            image1 = add Srv::Image, :as => "image1"
            connect image0.image => stereo.leftImage
            connect image1.image => stereo.rightImage

            export stereo.disparity
            export stereo.cloud

            provides Srv::Stereo
        end
    end

    def test_device_definition
        complete_system_model
        orocos_engine.robot do
            device Dev::Camera, :as => "leftCamera"
            device Dev::Camera, :as => "rightCamera"
        end

        robot = orocos_engine.robot
        left  = robot.devices['leftCamera']
        right = robot.devices['rightCamera']
        assert(left != right)
        assert(left.task_model < Srv::Image)
        assert_equal('leftCamera', left.task_arguments["camera_name"])
        assert(right.task_model < Srv::Image)
        assert_equal('rightCamera', right.task_arguments["camera_name"])
    end

    def check_left_right_disambiguated_structure
        # Check the camera drivers in the plan
        assert_equal(2, plan.find_tasks(camera_driver).to_a.size)
        acquisition = plan.find_tasks(Compositions::ImageAcquisition).
            with_child(SystemTest::CameraDriver).
            with_child(SystemTest::CameraFilter).to_a
        assert_equal(2, acquisition.size)

        # Both structures should be separated
        assert((acquisition[0].children.to_value_set & acquisition[1].children.to_value_set).empty?)

        # the :model flag on the dependency should be set right
        cameras = plan.find_tasks(SystemTest::CameraDriver).to_a
        cameras.each do |cam|
            acq = cam.parents.first
            assert_equal([Dev::Camera], acq[cam, TaskStructure::Dependency][:model].first)
        end
        return acquisition
    end

    def check_stereo_disambiguated_structure
        acquisition = check_left_right_disambiguated_structure
        assert(stereo = plan.find_tasks(Compositions::Stereo).to_a.first)

        stereo_processing = plan.find_tasks(SystemTest::StereoProcessing).to_value_set
        assert_equal(acquisition.to_value_set | stereo_processing, stereo.children.to_value_set)
    end

    def test_device_model_disambiguation
        complete_system_model
        orocos_engine.robot do
            device Dev::Camera, :as => "leftCamera"
            device Dev::Camera, :as => "rightCamera"
        end
        orocos_engine.add(Compositions::ImageAcquisition).
            use(Dev::Camera => "leftCamera")
        orocos_engine.add(Compositions::ImageAcquisition).
            use(Dev::Camera => "rightCamera")
        orocos_engine.instanciate

        assert_equal(6, plan.size)
        check_left_right_disambiguated_structure
    end

    def test_child_name_direct_disambiguation
        complete_system_model
        orocos_engine.robot do
            device Dev::Camera, :as => "leftCamera"
            device Dev::Camera, :as => "rightCamera"
        end
        orocos_engine.add(Compositions::ImageAcquisition).
            use("acquisition" => "leftCamera")
        orocos_engine.add(Compositions::ImageAcquisition).
            use("acquisition" => "rightCamera")
        orocos_engine.instanciate

        assert_equal(6, plan.size)
        check_left_right_disambiguated_structure
    end

    def test_child_name_indirect_disambiguation
        complete_system_model
        orocos_engine.robot do
            device Dev::Camera, :as => "leftCamera"
            device Dev::Camera, :as => "rightCamera"
        end
        orocos_engine.add(Compositions::Stereo).
            use("image0" => Compositions::ImageAcquisition.use('acquisition' => 'leftCamera')).
            use("image1" => Compositions::ImageAcquisition.use('acquisition' => 'rightCamera'))

        orocos_engine.instanciate

        assert_equal(8, plan.size)
        check_stereo_disambiguated_structure
    end

    def test_instance_name_direct_disambiguation
        complete_system_model
        orocos_engine.robot do
            device Dev::Camera, :as => "leftCamera"
            device Dev::Camera, :as => "rightCamera"
        end
        orocos_engine.add(Compositions::ImageAcquisition, :as => 'leftImage').
            use("acquisition" => "leftCamera")
        orocos_engine.add(Compositions::ImageAcquisition, :as => 'rightImage').
            use("acquisition" => "rightCamera")
        orocos_engine.add(Compositions::Stereo).
            use("image0" => "leftImage").
            use("image1" => "rightImage")
        orocos_engine.instanciate

        assert_equal(8, plan.size)
        check_stereo_disambiguated_structure
    end

    def test_merge_cycles
        complete_system_model
        orocos_engine.robot do
            device Dev::Motors
        end
        sys_model.composition 'Control' do
            add SystemTest::Control
            add Dev::Motors
            autoconnect
        end
        orocos_engine.add(Compositions::Control).
            use 'motors' => 'motors'
        orocos_engine.add(Compositions::Control).
            use 'motors' => 'motors'
        orocos_engine.resolve(:compute_deployments => false)

        assert_equal(3, plan.size)
    end

    def test_merge
        complete_system_model
        orocos_engine.robot do
            device "camera", :as => 'leftCamera'
            device 'camera', :as => 'rightCamera'
            device 'imu'
            device 'motors'
        end

        # Add those two tasks so that two type of tasks of unrelated models are
        # found at the same level in the merge process. This tests the ordering
        # capability of the merge process
        orocos_engine.add(orocos_engine.robot.devices['imu'].task_model)
        orocos_engine.add(orocos_engine.robot.devices['motors'].task_model)

        sys_model.composition "Safety" do
            add DataServices::Imu
            add Compositions::ImageAcquisition, :as => 'image'
        end
        orocos_engine.add(Compositions::Stereo).
            use("image0" => Compositions::ImageAcquisition).
            use("image1" => Compositions::ImageAcquisition).
            use("image0.camera" => "leftCamera").
            use("image1.camera" => "rightCamera")
        orocos_engine.add(Compositions::Safety).
            use("camera" => "leftCamera")

        orocos_engine.resolve(:compute_deployments => false)
        engine.garbage_collect

        assert_equal(11, plan.size)

        # Check the stereo substructure
        check_stereo_disambiguated_structure
        # Now check the safety substructure
        safety_tasks = plan.find_tasks(Compositions::Safety).to_a
        acq_tasks    = plan.find_tasks(Compositions::ImageAcquisition).
            with_child(SystemTest::CameraDriver, :camera_name => 'leftCamera').to_a
        imu_tasks    = plan.find_tasks(SystemTest::IMU).to_a

        assert_equal(1, safety_tasks.size)
        assert_equal(1, acq_tasks.size)
        assert_equal(1, imu_tasks.size)

        safety = safety_tasks.first
        acq    = acq_tasks.first
        imu    = imu_tasks.first
        assert_equal([imu, acq].to_value_set, safety.children.to_value_set)
    end

    def test_select_slave_data_service
        sys_model.data_service_type 'stereo', :interface => SystemTest::Stereo
        sys_model.data_service_type 'camera', :interface => SystemTest::CameraDriver

        SystemTest::StereoCamera.class_eval do
            driver_for 'stereo'
            data_service 'camera', :as => 'left', :slave_of => 'stereo'
            data_service 'camera', :as => 'right', :slave_of => 'stereo'
        end

        sys_model.composition "ImageAcquisition" do
            add SystemTest::CameraFilter
            add DataServices::Camera
        end

        orocos_engine.robot do
            device "stereo", :as => 'front_stereo'
        end
        orocos_engine.add(Compositions::ImageAcquisition ).
            use("camera" => "front_stereo.left")

        orocos_engine.instanciate

        assert_equal(3, plan.size)
        root_tasks = plan.find_tasks(Compositions::ImageAcquisition).
            with_child(SystemTest::StereoCamera, :stereo_name => "front_stereo").
            with_child(SystemTest::CameraFilter).to_a
        assert_equal(1, root_tasks.size)
    end

    def test_failed_resolve_does_not_impact_the_plan
        sys_model.data_service_type 'stereo', :interface => SystemTest::Stereo
        sys_model.data_service_type 'camera', :interface => SystemTest::CameraDriver

        SystemTest::StereoCamera.class_eval do
            driver_for 'stereo'
            data_service 'camera', :as => 'left', :slave_of => 'stereo'
            data_service 'camera', :as => 'right', :slave_of => 'stereo'
        end
        SystemTest::CameraDriver.driver_for 'camera'

        sys_model.composition "Stereo" do
            stereo = add SystemTest::StereoProcessing, :as => 'processing'
            image0 = add DataServices::Camera, :as => "image0"
            image1 = add DataServices::Camera, :as => "image1"
            connect image0.image => stereo.leftImage
            connect image1.image => stereo.rightImage
            
            export stereo.disparity
            export stereo.cloud
            data_service 'stereo'
        end

        sys_model.composition "StereoComparison" do
            add DataServices::Stereo, :as => "stereo0"
            add DataServices::Stereo, :as => "stereo1"
        end

        dev_stereo = nil
        orocos_engine.robot do
            dev_stereo       = device 'stereo', :as => 'front_stereo'
        end
        orocos_engine.add Compositions::Stereo
        root_task = orocos_engine.add(Compositions::StereoComparison)

        # Try to instanciate without disambiguation. This should fail miserably
        # since there's multiple options for selection in StereoComparison
        assert_equal(0, plan.size)
        assert_raises(Ambiguous) { orocos_engine.resolve(:export_plan_on_error => false) }
        assert_equal(0, plan.size)
    end

    def test_port_mapping_at_instanciation_time
        sys_model.data_service_type 'Stereo', :interface => SystemTest::Stereo
        sys_model.data_service_type 'Camera', :interface => SystemTest::CameraDriver

        SystemTest::StereoCamera.driver_for 'stereo'
        SystemTest::StereoCamera.data_service 'camera', :as => 'left', :slave_of => 'stereo'
        SystemTest::StereoCamera.data_service 'camera', :as => 'right', :slave_of => 'stereo'
        SystemTest::CameraDriver.driver_for 'camera'

        sys_model.composition "Stereo" do
            stereo = add SystemTest::StereoProcessing, :as => 'processing'
            image0 = add DataServices::Camera, :as => "image0"
            image1 = add DataServices::Camera, :as => "image1"
            connect image0.image => stereo.leftImage
            connect image1.image => stereo.rightImage

            export stereo.disparity
            export stereo.cloud
            data_service 'stereo'
        end

        sys_model.composition "StereoComparison" do
            add DataServices::Stereo, :as => "stereo0"
            add DataServices::Stereo, :as => "stereo1"
        end

        dev_stereo = nil
        orocos_engine.robot do
            dev_stereo = device 'stereo', :as => 'front_stereo'
        end

        # We compare the stereovision engine on the stereocamera with our own
        # algorithm by instanciating the stereocamera directly, and using its
        # cameras to inject into the Stereo composition.
        root_task = orocos_engine.add(Compositions::StereoComparison).
            use('stereo0' => 'front_stereo').
            use('stereo1' => Compositions::Stereo).
            use('stereo1.image0'  => 'front_stereo.left').
            use('stereo1.image1'  => 'front_stereo.right')

        # Add disambiguation information and reinstanciate
        orocos_engine.resolve(:compute_deployments => false)

        # A stereocamera, a stereoprocessing, a Stereo composition
        # and a StereoComparison composition => 4 tasks
        assert_equal(4, plan.size)

        # Check the dependency structure
        tasks = plan.find_tasks(Compositions::StereoComparison).
            with_child(Compositions::Stereo).
            with_child(SystemTest::StereoCamera).to_a
        assert_equal(1, tasks.size)

        tasks = plan.find_tasks(Compositions::Stereo).
            with_child(SystemTest::StereoCamera, :roles => ['image0', 'image1'].to_set).
            to_a
        assert_equal(1, tasks.size)

        # Check the data flow
        expected_connections = {
            ['rightImage', 'rightImage'] => Hash.new,
            ['leftImage', 'leftImage']   => Hash.new
        }

        stereo_camera = orocos_engine.robot.devices['front_stereo'].task
        stereo_processing = plan.find_tasks(SystemTest::StereoProcessing).to_a.first
        tasks = plan.find_tasks(SystemTest::StereoCamera).
            with_child( SystemTest::StereoProcessing, Flows::DataFlow, expected_connections ).
            to_a
        assert_equal(1, tasks.size)
    end

    def test_device_merging
        complete_system_model
        orocos_engine.robot do
            device "joystick"
            device "sliderbox"
            device "imu"

            com_bus "can", :as => "can0"
            through "can0" do
                device "joystick", :as => "joystick1"
                device "sliderbox", :as => "sliderbox1"
            end

            com_bus "can", :as => "can1"
            through "can1" do
                device "sliderbox", :as => "sliderbox2"
            end
        end

        orocos_engine.resolve(
            :compute_deployments => false,
            :compute_policies => false,
            :garbage_collect => false)
        assert_equal 6, plan.size

        joystick   = orocos_engine.tasks['joystick']
        joystick1  = orocos_engine.tasks['joystick1']
        sliderbox  = orocos_engine.tasks['sliderbox']
        sliderbox1 = orocos_engine.tasks['sliderbox1']
        sliderbox2 = orocos_engine.tasks['sliderbox2']

        assert(joystick.can_merge?(sliderbox))
        assert(sliderbox.can_merge?(joystick))
        assert(joystick1.can_merge?(sliderbox1))
        assert(sliderbox1.can_merge?(joystick1))
        assert(!sliderbox.can_merge?(sliderbox2))
        assert(!sliderbox1.can_merge?(sliderbox2))
        assert(!joystick.can_merge?(sliderbox2))
        assert(!joystick1.can_merge?(sliderbox2))

    end

    def test_communication_busses
        complete_system_model
        complete_robot_definition

        assert_equal 'can0', orocos_engine.robot.devices['motors'].com_bus
        assert_equal 'can0', orocos_engine.robot.devices['joystick'].com_bus
        assert_equal 'can0', orocos_engine.robot.devices['sliderbox'].com_bus

        orocos_engine.resolve(:compute_deployments => false, :garbage_collect => false)
        #engine.garbage_collect

        tasks = plan.find_tasks(SystemTest::MotorController).
            with_child(orocos_engine.tasks['can0']).to_a
        assert_equal(1, tasks.to_a.size)

        tasks = plan.find_tasks(SystemTest::MotorController).
            with_child(orocos_engine.tasks['can0'], Flows::DataFlow, ['can_out', 'wmotors'] => Hash.new).
            with_parent(orocos_engine.tasks['can0'], Flows::DataFlow, ['motors', 'can_in'] => Hash.new).
            to_a
        assert_equal(1, tasks.to_a.size)

        tasks = plan.find_tasks(SystemTest::ControlDevices).
            with_child(orocos_engine.tasks['can0']).to_a
        assert_equal(1, tasks.to_a.size)

        tasks = plan.find_tasks(SystemTest::ControlDevices).
            with_parent(orocos_engine.tasks['can0'], Flows::DataFlow,
                        ['joystick', 'can_in_joystick'] => Hash.new,
                        ['sliderbox', 'can_in_sliderbox'] => Hash.new).
            to_a
        assert_equal(1, tasks.to_a.size)
        assert(! tasks.first.child_object?(orocos_engine.tasks['can0'], Flows::DataFlow))
    end
end

