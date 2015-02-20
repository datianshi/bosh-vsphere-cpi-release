require 'spec_helper'

module VSphereCloud
  describe DiskProvider do
    subject(:disk_provider) do
      described_class.new(
        virtual_disk_manager,
        datacenter,
        resources,
        'fake-disk-path',
        client
      )
    end

    let(:virtual_disk_manager) { instance_double('VimSdk::Vim::VirtualDiskManager') }
    let(:datacenter) do
      instance_double('VSphereCloud::Resources::Datacenter', name: 'fake-datacenter-name', mob: datacenter_mob)
    end
    let(:datacenter_mob) { instance_double('VimSdk::Vim::Datacenter') }
    let(:resources) { instance_double('VSphereCloud::Resources') }
    let(:client) { instance_double('VSphereCloud::Client', wait_for_task: nil) }

    describe '#create' do
      before do
        allow(SecureRandom).to receive(:uuid).and_return('uuid')
        allow(resources).to receive(:pick_persistent_datastore).
          with(24).
          and_return(datastore)
      end

      let(:datastore) { instance_double('VSphereCloud::Resources::Datastore', name: 'fake-datastore-name') }

      it 'creates disk using VirtualDiskManager' do
        expect(virtual_disk_manager).to receive(:create_virtual_disk) do |path, dc, spec|
          expect(path).to eq('[fake-datastore-name] fake-disk-path/disk-uuid.vmdk')
          expect(dc).to eq(datacenter_mob)
          expect(spec.disk_type).to eq('preallocated')
          expect(spec.capacity_kb).to eq(24576)
          expect(spec.adapter_type).to eq('lsiLogic')
        end

        disk = disk_provider.create(24576)
        expect(disk.uuid).to eq('disk-uuid')
        expect(disk.size_in_kb).to eq(24576)
        expect(disk.path).to eq('[fake-datastore-name] fake-disk-path/disk-uuid.vmdk')
        expect(disk.datastore).to eq(datastore)
      end

      context 'when there are no datastores on host cluster that can fit disk size' do
        before do
          allow(resources).to receive(:pick_persistent_datastore).
            with(24).
            and_return(nil)
        end

        it 'raises an error' do
          expect {
            disk_provider.create(24576)
          }.to raise_error Bosh::Clouds::NoDiskSpace
        end
      end
    end

    describe '#find' do
      let(:cluster) { instance_double('VSphereCloud::Resources::Cluster') }

      let(:datastore) do
        Resources::Datastore.new(
          'name' => 'fake-datastore-name',
          'summary.freeSpace' => 1024,
          'summary.capacity' => 2048,
        )
      end

      context 'when disk exists' do
        before do
          allow(virtual_disk_manager).to receive(:query_virtual_disk_geometry).
            with('[fake-datastore-name] fake-disk-path/disk-uuid.vmdk', datacenter_mob).
            and_return(
              double(:host_disk_dimensions_chs, cylinder: 2048, head: 4, sector: 8)
            )
        end

        context 'when disk is in persistent datastores' do
          before do
            allow(cluster).to receive(:persistent_datastores).and_return(
              {'fake-datastore-name' => datastore}
            )
            allow(cluster).to receive(:shared_datastores).and_return({})
          end

          it 'returns disk' do
            disk = disk_provider.find('disk-uuid', cluster)
            expect(disk.uuid).to eq('disk-uuid')
            expect(disk.size_in_kb).to eq(128)
            expect(disk.datastore).to eq(datastore)
            expect(disk.path).to eq('[fake-datastore-name] fake-disk-path/disk-uuid.vmdk')
          end
        end

        context 'when disk is in shared datastores' do
          before do
            allow(cluster).to receive(:persistent_datastores).and_return({})
            allow(cluster).to receive(:shared_datastores).and_return(
              {'fake-datastore-name' => datastore}
            )
          end

          it 'returns disk' do
            disk = disk_provider.find('disk-uuid', cluster)
            expect(disk.uuid).to eq('disk-uuid')
            expect(disk.size_in_kb).to eq(128)
            expect(disk.datastore).to eq(datastore)
            expect(disk.path).to eq('[fake-datastore-name] fake-disk-path/disk-uuid.vmdk')
          end
        end
      end

      context 'when disk does not exist' do
        before do
          allow(cluster).to receive(:persistent_datastores).and_return({})
          allow(cluster).to receive(:shared_datastores).and_return({})
          allow(virtual_disk_manager).to receive(:query_virtual_disk_geometry).
            with('[fake-datastore-name] fake-disk-path/disk-uuid.vmdk', datacenter).
            and_raise(VimSdk::SoapError.new('fake-message', 'fake-fault'))
        end

        it 'raises DiskNotFound' do
          expect {
            disk_provider.find('disk-uuid', cluster)
          }.to raise_error Bosh::Clouds::DiskNotFound
        end
      end
    end
  end
end
