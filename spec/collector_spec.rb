require 'genesis_collector/collector'

RSpec.describe GenesisCollector::Collector do
  let(:config) { {} }
  let(:collector) { GenesisCollector::Collector.new(config) }
  describe '#get_sku' do
    before do
      stub_dmi('baseboard-manufacturer', 'Supermicro')
      stub_dmi('baseboard-serial-number', '34524623454')
    end
    it 'should get sku' do
      expect(collector.send(:get_sku)).to eq('SPM-34524623454')
    end
    context 'broken bios' do
      before do
        stub_dmi('baseboard-serial-number', '0123456789')
        stub_dmi('system-serial-number', '0123456789')
        stub_shellout('ipmitool fru', fixture('ipmitool_fru'))
      end
      it 'should get sku with real serial number' do
        expect(collector.send(:get_sku)).to eq('SPM-ZM234234235234')
      end
    end
  end

  describe '#collect_basic_data' do
    before do
      allow(Socket).to receive(:gethostname).and_return('test1234.example.com')
      stub_file_content('/etc/lsb-release', fixture('lsb-release'))
      stub_dmi('system-product-name', 'ABC123+')
      stub_dmi('system-manufacturer', 'Acme Inc')
      stub_dmi('system-serial-number', '1234567891234')
      stub_dmi('baseboard-manufacturer', 'Super Acme Inc')
      stub_dmi('baseboard-product-name', 'ABC456B+')
      stub_dmi('baseboard-serial-number', '34524623454')
      stub_dmi('chassis-manufacturer', 'Acme Chassis Inc')
      stub_dmi('chassis-serial-number', '2376482364')
    end
    before { collector.collect_basic_data }
    let(:payload) { collector.payload }
    it 'should get hostname' do
      expect(payload[:hostname]).to eq('test1234.example.com')
    end
    it 'should get os attributes' do
      skip('TODO')
      expect(payload[:os][:distribution]).to eq('Ubuntu')
      expect(payload[:os][:release]).to eq('14.04')
      expect(payload[:os][:codename]).to eq('trusty')
      expect(payload[:os][:description]).to eq('Ubuntu 14.04.2 LTS')
    end
    it 'should get product name' do
      expect(payload[:product]).to eq('ABC123+')
    end
    it 'should get vendor name' do
      expect(payload[:vendor]).to eq('Acme Inc')
    end
    it 'should get extra properties' do
      expect(payload[:properties]['SYSTEM_SERIAL_NUMBER']).to eq('1234567891234')
      expect(payload[:properties]['BASEBOARD_VENDOR']).to eq('Super Acme Inc')
      expect(payload[:properties]['BASEBOARD_PRODUCT_NAME']).to eq('ABC456B+')
      expect(payload[:properties]['BASEBOARD_SERIAL_NUMBER']).to eq('34524623454')
      expect(payload[:properties]['CHASSIS_VENDOR']).to eq('Acme Chassis Inc')
      expect(payload[:properties]['CHASSIS_SERIAL_NUMBER']).to eq('2376482364')
    end
  end

  describe '#collect_chef' do
    before { stub_shellout('knife node show `hostname` -c /etc/chef/client.rb', '') }
    let(:payload) { collector.collect_chef; collector.payload }
    context 'with chef environment set' do
      before { stub_file_content('/etc/chef/current_environment', 'some-branch') }
      it 'should get environment' do
        expect(payload[:chef][:environment]).to eq('some-branch')
      end
    end
    context 'with no chef environment set' do
      it 'should fallback to default environment string' do
        expect(payload[:chef][:environment]).to eq('unknown')
      end
    end
    context 'with chef node' do
      let(:config) { { chef_node: { 'roles' => ['role-one', 'role-two'], 'run_list' => 'role[location--lax], role[app--genesis--server]' } } }
      it 'should get roles' do
        expect(payload[:chef][:roles]).to eq(['role-one', 'role-two'])
      end
      it 'should get run list' do
        expect(payload[:chef][:run_list]).to eq('role[location--lax], role[app--genesis--server]')
      end
    end
    context 'when knife works' do
      before { stub_shellout('knife node show `hostname` -c /etc/chef/client.rb', fixture('knife_node_show')) }
      it 'should get tags' do
        expect(payload[:chef][:tags]).to eq(['tagone', 'secondary'])
      end
    end
    context 'when knife fails' do
      before { stub_shellout('knife node show `hostname` -c /etc/chef/client.rb', nil) }
      it 'should get tags' do
        expect(payload[:chef][:tags]).to eq([])
      end
    end
  end

  describe '#collect_ipmi' do
    before { stub_shellout('ipmitool lan print', fixture('ipmitool_lan_print')) }
    let(:payload) { collector.collect_ipmi; collector.payload }
    it 'should get address' do
      expect(payload[:ipmi][:address]).to eq('1.2.1.2')
    end
    it 'should get netmask' do
      expect(payload[:ipmi][:netmask]).to eq('255.255.0.0')
    end
    it 'should get mac' do
      expect(payload[:ipmi][:mac]).to eq('0c:ca:ca:03:dc:23')
    end
    it 'should get gateway' do
      expect(payload[:ipmi][:gateway]).to eq('1.2.0.1')
    end
  end

  describe '#collect_network_interfaces', focus: true do
    before do
      allow(Socket).to receive(:getifaddrs).and_return([
        instance_double('Socket::Ifaddr', name: 'eth0', addr: instance_double('Socket::Addrinfo', ip_address: '1.2.3.4', ipv4?: true), netmask: instance_double('Socket::Addrinfo', ip_address: '255.255.255.0')),
        instance_double('Socket::Ifaddr', name: 'eth1', addr: instance_double('Socket::Addrinfo', ip_address: '1.2.3.5', ipv4?: true), netmask: instance_double('Socket::Addrinfo', ip_address: '255.255.0.0')),
        instance_double('Socket::Ifaddr', name: 'eth1', addr: instance_double('Socket::Addrinfo', ip_address: '1.2.3.6', ipv4?: true), netmask: instance_double('Socket::Addrinfo', ip_address: '255.0.0.0')),
        instance_double('Socket::Ifaddr', name: 'eth2', addr: instance_double('Socket::Addrinfo', ip_address: '2001:0db8:0000:0000:0000:ff00:0042:8329', ipv4?: false))
      ])
      stub_file_content('/sys/class/net/eth0/address', '0c:ca:ca:03:12:34')
      stub_file_content('/sys/class/net/eth1/address', '0c:ca:ca:03:12:35')
      stub_file_content('/sys/class/net/eth0/speed', '10000')
      stub_file_content('/sys/class/net/eth1/speed', '1000')
      stub_file_exists('/sys/class/net/eth0/bonding_slave/perm_hwaddr', exists: false)
      stub_file_exists('/sys/class/net/eth1/bonding_slave/perm_hwaddr', exists: false)
      stub_file_content('/sys/class/net/eth0/duplex', 'full')
      stub_file_content('/sys/class/net/eth1/duplex', 'half')
      stub_shellout('ethtool --driver eth0', fixture('ethtool_driver1'))
      stub_shellout('ethtool --driver eth1', fixture('ethtool_driver2'))
    end
    let(:payload) { collector.collect_network_interfaces; collector.payload }
    it 'should get 2 interfaces' do
      expect(payload[:network_interfaces].count).to eq(2)
    end
    it 'should get names' do
      expect(payload[:network_interfaces][0][:name]).to eq('eth0')
      expect(payload[:network_interfaces][1][:name]).to eq('eth1')
    end
    it 'should get product' do
      skip('TODO')
      expect(payload[:network_interfaces][0][:product]).to eq('Ethernet Controller 10-Gigabit X540-AT2')
      expect(payload[:network_interfaces][1][:product]).to eq('Ethernet Controller 10-Gigabit X540-AT2')
    end
    it 'should get vendor name' do
      skip('TODO')
      expect(payload[:network_interfaces][0][:vendor_name]).to eq('Intel')
      expect(payload[:network_interfaces][1][:vendor_name]).to eq('Intel')
    end
    it 'should get mac address' do
      expect(payload[:network_interfaces][0][:mac_address]).to eq('0c:ca:ca:03:12:34')
      expect(payload[:network_interfaces][1][:mac_address]).to eq('0c:ca:ca:03:12:35')
    end
    it 'should get speed' do
      expect(payload[:network_interfaces][0][:speed]).to eq('10000')
      expect(payload[:network_interfaces][1][:speed]).to eq('1000')
    end
    it 'should get addresses and netmasks' do
      expect(payload[:network_interfaces][0][:addresses].count).to eq(1)
      expect(payload[:network_interfaces][0][:addresses][0][:address]).to eq('1.2.3.4')
      expect(payload[:network_interfaces][0][:addresses][0][:netmask]).to eq('255.255.255.0')
      expect(payload[:network_interfaces][1][:addresses].count).to eq(2)
      expect(payload[:network_interfaces][1][:addresses][0][:address]).to eq('1.2.3.5')
      expect(payload[:network_interfaces][1][:addresses][1][:address]).to eq('1.2.3.6')
      expect(payload[:network_interfaces][1][:addresses][0][:netmask]).to eq('255.255.0.0')
      expect(payload[:network_interfaces][1][:addresses][1][:netmask]).to eq('255.0.0.0')
    end
    context 'with bonded interfaces' do
      before do
        stub_file_content('/sys/class/net/eth0/address', '0c:ca:ca:03:12:34')
        stub_file_content('/sys/class/net/eth1/address', '0c:ca:ca:03:12:34')
        stub_file_content('/sys/class/net/eth0/bonding_slave/perm_hwaddr', '0c:ca:ca:03:12:34')
        stub_file_content('/sys/class/net/eth1/bonding_slave/perm_hwaddr', '0c:ca:ca:03:12:35')
      end
      it 'should get the real permanent mac address' do
        expect(payload[:network_interfaces][0][:mac_address]).to eq('0c:ca:ca:03:12:34')
        expect(payload[:network_interfaces][1][:mac_address]).to eq('0c:ca:ca:03:12:35')
      end
    end
    it 'should get driver' do
      expect(payload[:network_interfaces][0][:driver]).to eq('ixgbe')
      expect(payload[:network_interfaces][1][:driver]).to eq('igb')
    end
    it 'should get driver version' do
      expect(payload[:network_interfaces][0][:driver_version]).to eq('3.19.1-k')
      expect(payload[:network_interfaces][1][:driver_version]).to eq('5.2.15-k')
    end
    it 'should get duplex' do
      expect(payload[:network_interfaces][0][:duplex]).to eq('full')
      expect(payload[:network_interfaces][1][:duplex]).to eq('half')
    end
    it 'should get link type' do
      skip('TODO')
      expect(payload[:network_interfaces][0][:link_type]).to eq('')
      expect(payload[:network_interfaces][1][:link_type]).to eq('')
    end
  end
end