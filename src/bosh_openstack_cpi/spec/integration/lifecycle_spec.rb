require_relative './spec_helper'

describe Bosh::OpenStackCloud::Cloud do
  # @formatter:off
  before(:all) do
    @config = IntegrationConfig.new
    @cpi_for_stemcell = @config.create_cpi
    @stemcell_id, _ = upload_stemcell(@cpi_for_stemcell, @config.stemcell_path)
  end
  # @formatter:on
  
  before { allow(Bosh::Clouds::Config).to receive(:logger).and_return(@config.logger) }

  after(:all) do
    @cpi_for_stemcell.delete_stemcell(@stemcell_id)
  end

  let(:boot_from_volume) { false }
  let(:config_drive) { nil }
  let(:use_dhcp) { true }
  let(:human_readable_vm_names) { false }
  let(:use_nova_networking) { false }
  let(:openstack) { @config.create_openstack }

  subject(:cpi) do
    @config.create_cpi(boot_from_volume: boot_from_volume, config_drive: config_drive, human_readable_vm_names: human_readable_vm_names, use_nova_networking: use_nova_networking, use_dhcp: use_dhcp)
  end

  before { allow(Bosh::Cpi::RegistryClient).to receive(:new).and_return(double('registry').as_null_object) }

  describe 'dynamic network' do
    # even for dynamic networking we need to set the net_id as we may be in an environment
    # with multiple networks
    let(:network_spec) do
      {
        'default' => {
          'type' => 'dynamic',
          'cloud_properties' => {
            'net_id' => @config.net_id
          }
        }
      }
    end

    context 'without existing disks and with a floating ip' do
      let(:network_spec_with_vip_network) do
        {
            'vip_network' => {
                'type' => 'vip',
                'ip' => @config.floating_ip
            }
        }.merge(network_spec)
      end

      before { @vm_with_assigned_floating_ip = create_vm(@stemcell_id, network_spec_with_vip_network, []) }
      after { clean_up_vm(@vm_with_assigned_floating_ip, network_spec) if @vm_with_assigned_floating_ip }

      it 'exercises the vm lifecycle and reassigns the floating ip' do
        vm_lifecycle(@stemcell_id, network_spec_with_vip_network)
      end
    end

    context 'with existing disks' do
      before do
        @temp_vm_cid = create_vm(@stemcell_id, network_spec, [])
        @existing_volume_id = cpi.create_disk(2048, {}, @temp_vm_cid)
        cpi.delete_vm(@temp_vm_cid)
      end
      after { cpi.delete_disk(@existing_volume_id) if @existing_volume_id }

      it 'exercises the vm lifecycle' do
        expect {
          vm_lifecycle(@stemcell_id, network_spec, @existing_volume_id)
        }.to_not raise_error
      end
    end

    describe 'set_vm_metadata' do
      let(:human_readable_vm_names) { true }
      before { @human_readable_vm_name_id = create_vm(@stemcell_id, network_spec, []) }
      after { clean_up_vm(@human_readable_vm_name_id, network_spec) if @human_readable_vm_name_id }

      it 'sets the vm name according to the metadata' do
        vm = openstack.compute.servers.get(@human_readable_vm_name_id)
        expect(vm.name).to eq 'openstack_cpi_spec/instance_id'
      end
    end

    describe 'attach_disk' do
      before do
        @vm_id = create_vm(@stemcell_id, network_spec, [])

        cpi.set_vm_metadata(@vm_id, {
          'id' => 'my-id',
          'deployment' => 'my-deployment',
          'job' => 'my-job',
          'index' => 'my-index',
          'some_key' => 'some_value'
        })

        @metadata_disk_id = cpi.create_disk(2048, {}, @vm_id)
      end

      after do
        cpi.detach_disk(@vm_id, @metadata_disk_id) if @metadata_disk_id && @vm_id
        clean_up_disk(@metadata_disk_id) if @metadata_disk_id
        clean_up_vm(@vm_id, network_spec) if @vm_id
      end

      it 'copies the vm metadata into the disk' do
        cpi.attach_disk(@vm_id, @metadata_disk_id)

        disk = openstack.volume.volumes.get(@metadata_disk_id)
        expect(disk.metadata).to include('id' => 'my-id',
                                         'deployment' => 'my-deployment',
                                         'job' => 'my-job',
                                         'index' => 'my-index')
        expect(disk.metadata).not_to include('some_key' => 'some_value')
      end
    end
  end

  describe 'manual network' do
    let(:network_spec) do
      {
        'default' => {
          'type' => 'manual',
          'ip' => @config.manual_ip,
          'cloud_properties' => {
            'net_id' => @config.net_id
          }
        }
      }
    end

    context 'without existing disks' do
      it 'exercises the vm lifecycle' do
        expect {
          vm_lifecycle(@stemcell_id, network_spec)
        }.to_not raise_error
      end
    end

    context 'with existing disks' do

      before do
        @temp_vm_cid = create_vm(@stemcell_id, network_spec, [])
        @existing_volume_id = cpi.create_disk(2048, {}, @temp_vm_cid)
        clean_up_vm(@temp_vm_cid, network_spec)
      end

      after { cpi.delete_disk(@existing_volume_id) if @existing_volume_id }

      it 'exercises the vm lifecycle' do
        expect {
          vm_lifecycle(@stemcell_id, network_spec, @existing_volume_id)
        }.to_not raise_error
      end
    end

    context 'with multiple networks and config_drive' do

      let(:multiple_network_spec) do
        {
          'network_1' => {
            'type' => 'manual',
            'ip' => @config.no_dhcp_manual_ip_1,
            'cloud_properties' => {
              'net_id' => @config.net_id_no_dhcp_1
            }
          },
          'network_2' => {
            'type' => 'manual',
            'ip' => @config.no_dhcp_manual_ip_2,
            'cloud_properties' => {
              'net_id' => @config.net_id_no_dhcp_2
            },
            'use_dhcp' => false
          }
        }
      end

      let(:config_drive) { 'cdrom' }
      let(:use_dhcp) { false }

      after { clean_up_vm(@multiple_nics_vm_id, network_spec) if @multiple_nics_vm_id }

      it 'creates writes the mac addresses of the two networks to the registry' do
        registry = double('registry')
        registry_settings = nil
        allow(Bosh::Cpi::RegistryClient).to receive(:new).and_return(registry)
        allow(registry).to receive_messages(endpoint: nil, delete_settings: nil)
        allow(registry).to receive(:update_settings) do |_, settings|
          registry_settings = settings
        end

        @multiple_nics_vm_id = create_vm(@stemcell_id, multiple_network_spec, [])

        vm = openstack.compute.servers.get(@multiple_nics_vm_id)
        network_interfaces = vm.addresses.map { |_, network_interfaces| network_interfaces }.flatten
        network_interface_1 = network_interfaces.find(&where_ip_address_is(@config.no_dhcp_manual_ip_1))
        network_interface_2 = network_interfaces.find(&where_ip_address_is(@config.no_dhcp_manual_ip_2))

        expect(network_interface_1['OS-EXT-IPS-MAC:mac_addr']).to eq(registry_settings['networks']['network_1']['mac'])
        expect(network_interface_2['OS-EXT-IPS-MAC:mac_addr']).to eq(registry_settings['networks']['network_2']['mac'])

        ports = openstack.network.ports.all(:device_id => @multiple_nics_vm_id)
        clean_up_vm(@multiple_nics_vm_id, network_spec) if @multiple_nics_vm_id
        expect(ports.find { |port| openstack.network.ports.get port.id }).to be_nil
      end

      def where_ip_address_is(ip)
        lambda { |network_interface| network_interface['addr'] == ip }
      end
    end
  end

  context 'when booting from volume' do
    let(:boot_from_volume) { true }
    let(:network_spec) do
      {
        'default' => {
          'type' => 'manual',
          'ip' => @config.manual_ip,
          'cloud_properties' => {
            'net_id' => @config.net_id
          }
        }
      }
    end

    def test_boot_volume
      @vm_id = create_vm(@stemcell_id, network_spec, [])
      volumes = volumes(@vm_id)
      expect(volumes.size).to eq(1)
      expect(volumes.first['device']).to eq('/dev/vda')
    end

    after(:each) { clean_up_vm(@vm_id, network_spec) if @vm_id }

    it 'creates a vm with boot_volume on /dev/vda' do
      test_boot_volume
    end

    context 'and flavor has root disk size 0' do
      let(:resource_pool) do
        {
          'instance_type' => @config.instance_type_with_no_root_disk
        }
      end

      context 'and root disk size given in manifest' do
        before do
          resource_pool['root_disk'] = {
            'size' => 20
          }
        end

        it 'creates a vm with boot_volume on /dev/vda' do
          test_boot_volume
        end
      end

      context 'and root disk size not given in manifest' do

        it 'raises an error' do
          expect {
            vm_lifecycle(@stemcell_id, network_spec, nil, {}, resource_pool)
          }.to raise_error(Bosh::Clouds::CloudError, /Flavor '#{@config.instance_type_with_no_root_disk}' has a root disk size of 0/)
        end
      end
    end
  end

  context 'when using cloud_properties' do
    let(:cloud_properties) { { 'type' => @config.volume_type } }

    let(:network_spec) do
      {
        'default' => {
          'type' => 'dynamic',
          'cloud_properties' => {
            'net_id' => @config.net_id
          }
        }
      }
    end

    it 'exercises the vm lifecycle' do
      expect {
        vm_lifecycle(@stemcell_id, network_spec, nil, cloud_properties)
      }.to_not raise_error
    end
  end

  context 'when using config drive as cdrom' do
    let(:config_drive) { @config.config_drive }

    let(:network_spec) do
      {
        'default' => {
          'type' => 'dynamic',
          'cloud_properties' => {
            'net_id' => @config.net_id
          }
        }
      }
    end

    it 'exercises the vm lifecycle' do
      expect {
        vm_lifecycle(@stemcell_id, network_spec)
      }.to_not raise_error
    end
  end

  context 'when vm creation fails' do
    let(:network_spec_that_fails) do
      {
        'default' => {
          'type' => 'manual',
          'ip' => @config.manual_ip,
          'cloud_properties' => {
            'net_id' => @config.net_id
          }
        },
        'vip' => {
          'type' => 'vip',
          'ip' => '255.255.255.255',
        }
      }
    end

    def no_active_vm_with_ip?(ip)
      openstack.compute.servers.none? do |s|
        s.private_ip_address == ip && [:active].include?(s.state.downcase.to_sym)
      end
    end

    it 'cleans up vm' do
      expect {
        create_vm(@stemcell_id, network_spec_that_fails, [])
      }.to raise_error Bosh::Clouds::VMCreationFailed, /Floating IP '255.255.255.255' not allocated/

      expect(no_active_vm_with_ip?(@config.manual_ip)).to be
    end

    it 'better error message for wrong net ID' do
      network_spec_with_wrong_net_id = {
        'default' => {
          'type' => 'dynamic',
          'cloud_properties' => {
            'net_id' => '00000000-0000-0000-0000-000000000000'
          }
        }
      }
      expect {
        create_vm(@stemcell_id, network_spec_with_wrong_net_id, [])
      }.to raise_error Bosh::Clouds::VMCreationFailed, /'00000000-0000-0000-0000-000000000000'/
    end
  end

  context 'when detaching a non-existing disk' do
    # Detaching a non-existing disk from vm should NOT raise error
    let(:network_spec) do
      {
        'default' => {
          'type' => 'dynamic',
          'cloud_properties' => {
            'net_id' => @config.net_id
          }
        }
      }
    end

    it 'exercises the vm lifecycles' do
      vm_id = create_vm(@stemcell_id, network_spec, [])

      expect {
        @config.logger.info("Detaching disk vm_id=#{vm_id} disk_id=non-existing-disk")
        cpi.detach_disk(vm_id, "non-existing-disk")
      }.to_not raise_error

      clean_up_vm(vm_id, network_spec)
    end
  end

  describe 'use_nova_networking=true' do
    let(:network_spec) do
      {
          'default' => {
              'type' => 'dynamic',
              'cloud_properties' => {
                  'net_id' => @config.net_id
              }
          }
      }
    end

    let(:use_nova_networking) { true }
    after { clean_up_vm(@vm_id_for_nova_compatibility, network_spec) if @vm_id_for_nova_compatibility }

    it 'create vm does not use neutron for security groups' do
      stub_request(:any, /.*\/v2\.0\/security-groups/)

      @vm_id_for_nova_compatibility = create_vm(@stemcell_id, network_spec, [])

      expect(WebMock).to_not have_requested(:any, /.*\/v2\.0\/security-groups/)
    end
  end

  describe 'light stemcell' do
    let(:light_stemcell_id){ "#{@stemcell_id} light" }

    describe '#create_stemcell' do
      it 'returns the stemcell id with ` light` suffix' do
        cloud_properties = {
          'image_id' => @stemcell_id
        }

        expect(cpi.create_stemcell('not_relevant_path', cloud_properties)).to eq(light_stemcell_id)
      end

      context 'when referenced image does not exist' do
        it 'raises an error' do
          cloud_properties = {
            'image_id' => 'non-existing-id'
          }

          expect{
            cpi.create_stemcell('not_relevant_path', cloud_properties)
          }.to raise_error Bosh::Clouds::CloudError
        end
      end
    end

    describe '#create_vm' do
      let(:network_spec) do
        {
          'default' => {
            'type' => 'dynamic',
            'cloud_properties' => {
              'net_id' => @config.net_id
            }
          }
        }
      end

      it 'creates a vm with the heavy stemcell id' do
        vm_lifecycle(light_stemcell_id, network_spec)
      end
    end
  end

  def volumes(vm_id)
    openstack.compute.servers.get(vm_id).volume_attachments
  end

  def vm_lifecycle(stemcell_id, network_spec, disk_id = nil, cloud_properties = {}, resource_pool = {})
    vm_id = create_vm(stemcell_id, network_spec, Array(disk_id), resource_pool)

    if disk_id
      @config.logger.info("Reusing disk #{disk_id} for VM vm_id #{vm_id}")
    else
      @config.logger.info("Creating disk for VM vm_id #{vm_id}")
      disk_id = cpi.create_disk(2048, cloud_properties, vm_id)
      expect(disk_id).to be
    end

    @config.logger.info("Checking existence of disk vm_id=#{vm_id} disk_id=#{disk_id}")
    expect(cpi.has_disk?(disk_id)).to be(true)

    @config.logger.info("Attaching disk vm_id=#{vm_id} disk_id=#{disk_id}")
    cpi.attach_disk(vm_id, disk_id)

    @config.logger.info("Detaching disk vm_id=#{vm_id} disk_id=#{disk_id}")
    cpi.detach_disk(vm_id, disk_id)

    disk_snapshot_id = create_disk_snapshot(disk_id) unless @config.disable_snapshots
  rescue Exception => create_error
  ensure
    funcs = [
      lambda { clean_up_disk(disk_id) },
      lambda { clean_up_vm(vm_id, network_spec) },
    ]
    funcs.unshift(lambda { clean_up_disk_snapshot(disk_snapshot_id) }) unless @config.disable_snapshots
    run_all_and_raise_any_errors(create_error, funcs)
  end

  def create_vm(stemcell_id, network_spec, disk_locality, resource_pool = {})
    @config.logger.info("Creating VM with stemcell_id=#{stemcell_id}")
    vm_id = cpi.create_vm(
      'agent-007',
      stemcell_id,
      { 'instance_type' => @config.instance_type,
        'availability_zone' => @config.availability_zone
      }.merge(resource_pool),
      network_spec,
      disk_locality,
      { 'key' => 'value' }
    )
    expect(vm_id).to be

    @config.logger.info("Checking VM existence vm_id=#{vm_id}")
    expect(cpi).to have_vm(vm_id)

    @config.logger.info("Setting VM metadata vm_id=#{vm_id}")
    cpi.set_vm_metadata(vm_id, {
      'deployment' => 'deployment',
      'name' => 'openstack_cpi_spec/instance_id',
    })

    vm_id
  end

  def clean_up_vm(vm_id, network_spec)
    if vm_id
      @config.logger.info("Deleting VM vm_id=#{vm_id}")
      cpi.delete_vm(vm_id)

      @config.logger.info("Checking VM existence vm_id=#{vm_id}")
      expect(cpi).to_not have_vm(vm_id)
    else
      @config.logger.info('No VM to delete')
    end
  end

  def clean_up_disk(disk_id)
    if disk_id
      @config.logger.info("Deleting disk disk_id=#{disk_id}")
      cpi.delete_disk(disk_id)
    else
      @config.logger.info('No disk to delete')
    end
  end

  def create_disk_snapshot(disk_id)
    @config.logger.info("Creating disk snapshot disk_id=#{disk_id}")
    disk_snapshot_id = cpi.snapshot_disk(disk_id, {
      :deployment => 'deployment',
      :job => 'openstack_cpi_spec',
      :index => '0',
      :instance_id => 'instance',
      :agent_id => 'agent',
      :director_name => 'Director',
      :director_uuid => '6d06b0cc-2c08-43c5-95be-f1b2dd247e18',
    })
    expect(disk_snapshot_id).to be

    @config.logger.info("Created disk snapshot disk_snapshot_id=#{disk_snapshot_id}")
    disk_snapshot_id
  end

  def clean_up_disk_snapshot(disk_snapshot_id)
    if disk_snapshot_id
      @config.logger.info("Deleting disk snapshot disk_snapshot_id=#{disk_snapshot_id}")
      cpi.delete_snapshot(disk_snapshot_id)
    else
      @config.logger.info('No disk snapshot to delete')
    end
  end

  def run_all_and_raise_any_errors(existing_errors, funcs)
    exceptions = Array(existing_errors)
    funcs.each do |f|
      begin
        f.call
      rescue Exception => e
        exceptions << e
      end
    end
    # Prints all exceptions but raises original exception
    exceptions.each { |e| @config.logger.info("Failed with: #{e.inspect}\n#{e.backtrace.join("\n")}\n") }
    raise exceptions.first if exceptions.any?
  end
end
