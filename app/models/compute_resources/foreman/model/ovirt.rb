require 'foreman/exception'
require 'uri'

module Foreman::Model
  class Ovirt < ComputeResource
    ALLOWED_DISPLAY_TYPES = %w(vnc spice)

    validates :url, :format => { :with => URI::DEFAULT_PARSER.make_regexp }, :presence => true,
              :url_schema => ['http', 'https']
    validates :display_type, :inclusion => { :in => ALLOWED_DISPLAY_TYPES }
    validates :keyboard_layout, :inclusion => { :in => ALLOWED_KEYBOARD_LAYOUTS }
    validates :user, :password, :presence => true
    after_validation :connect, :update_available_operating_systems unless Rails.env.test?

    alias_attribute :datacenter, :uuid

    delegate :clusters, :quotas, :templates, :instance_types, :to => :client

    def self.available?
      Fog::Compute.providers.include?(:ovirt)
    end

    def self.model_name
      ComputeResource.model_name
    end

    def user_data_supported?
      true
    end

    def host_compute_attrs(host)
      super.tap do |attrs|
        attrs[:os] = { :type => determine_os_type(host) } if supports_operating_systems?
      end
    end

    def capabilities
      [:build, :image, :new_volume]
    end

    def find_vm_by_uuid(uuid)
      super
    rescue Fog::Ovirt::Errors::OvirtEngineError
      raise(ActiveRecord::RecordNotFound)
    end

    def supports_update?
      true
    end

    def supports_operating_systems?
      if client.respond_to?(:operating_systems)
        unless self.attrs.key?(:available_operating_systems)
          update_available_operating_systems
          save
        end
        self.attrs[:available_operating_systems] != :unsupported
      else
        false
      end
    rescue Foreman::FingerprintException
      logger.info "Unable to verify OS capabilities, SSL certificate verification failed"
      false
    end

    def determine_os_type(host)
      return nil unless host
      return host.params['ovirt_ostype'] if host.params['ovirt_ostype']
      ret = "other_linux"
      return ret unless host.operatingsystem
      os_name = os_name_mapping(host)
      arch_name = arch_name_mapping(host)

      available = available_operating_systems.select { |os| os[:name].present? }
      match_found = false
      best_matches = available.sort_by do |os|
        rating = 0.0
        if os[:name].include?(os_name)
          match_found = true
          rating += 100
          # prefer the shorter names a bit in case we have not found more important some specifics
          rating += (1.0 / os[:name].length)
          # bonus for major or major_minor
          rating += 10 if os[:name].include?("#{os_name}_#{host.operatingsystem.major}")
          rating += 5 if os[:name].include?("#{os_name}_#{host.operatingsystem.major}_#{host.operatingsystem.minor}")
          # bonus for architecture
          rating += 10 if arch_name && os[:name].include?(arch_name)
        end
        rating
      end

      unless match_found
        logger.debug { "No oVirt OS type found, returning other OS" }
        return available.first[:name]
      end

      logger.debug { "Available oVirt OS types: #{best_matches.map {|x| x[:name]}.join(',')}" }
      best_matches.last[:name] if best_matches.last
    end

    def available_operating_systems
      if attrs.key?(:available_operating_systems)
        attrs[:available_operating_systems]
      else
        raise Foreman::Exception.new("Listing operating systems is not supported by the current version")
      end
    end

    def provided_attributes
      super.merge({:mac => :mac})
    end

    def max_cpu_count
      16
    end

    def max_socket_count
      16
    end

    def max_memory
      16.gigabytes
    end

    def use_v4=(value)
      value = case value
              when true, '1'
                true
              else
                false
              end
      self.attrs[:ovirt_use_v4] = value
    end

    def use_v4
      self.attrs[:ovirt_use_v4] || false
    end
    alias_method :use_v4?, :use_v4

    def ovirt_quota=(ovirt_quota_id)
      self.attrs[:ovirt_quota_id] = ovirt_quota_id
    end

    def ovirt_quota
      self.attrs[:ovirt_quota_id].presence
    end

    def available_images
      templates
    end

    def template(id)
      compute = client.templates.get(id) || raise(ActiveRecord::RecordNotFound)
      compute.interfaces
      compute.volumes
      compute
    end

    def instance_type(id)
      client.instance_types.get(id) || raise(ActiveRecord::RecordNotFound)
    end

    def display_types
      ALLOWED_DISPLAY_TYPES
    end

    # Check if HTTPS is mandatory, since rest_client will fail with a POST
    def test_https_required
      RestClient.post url, {} if URI(url).scheme == 'http'
      true
    rescue => e
      case e.message
      when /406/
        true
      else
        raise e
      end
    end
    private :test_https_required

    def test_connection(options = {})
      super
      connect(options)
    end

    def connect(options = {})
      return unless connection_properties_valid?

      update_public_key options
      datacenters && test_https_required
    rescue => e
      case e.message
        when /404/
          errors[:url] << e.message
        when /302/
          errors[:url] << _('HTTPS URL is required for API access')
        when /401/
          errors[:user] << e.message
        else
          errors[:base] << e.message
      end
    end

    def connection_properties_valid?
      errors[:url].empty? && errors[:username].empty? && errors[:password].empty?
    end

    def datacenters(options = {})
      client.datacenters(options).map { |dc| [dc[:name], dc[:id]] }
    end

    def get_datacenter_uuid(name)
      datacenter_uuid = datacenters.select {|dc| dc[0] == name}
      raise ::Foreman::Exception.new(N_('Datacenter was not found')) if datacenter_uuid.empty?
      datacenter_uuid.first[1]
    end

    def editable_network_interfaces?
      # we can't decide whether the networks are available when we
      # don't know the cluster_id, assuming it's possible
      true
    end

    def networks(opts = {})
      if opts[:cluster_id]
        client.clusters.get(opts[:cluster_id]).networks
      else
        []
      end
    end

    def available_clusters
      clusters
    end

    def available_networks(cluster_id = nil)
      raise ::Foreman::Exception.new(N_('Cluster ID is required to list available networks')) if cluster_id.nil?
      networks({:cluster_id => cluster_id})
    end

    def available_storage_domains(cluster_id = nil)
      storage_domains
    end

    def storage_domains(opts = {})
      client.storage_domains({:role => 'data'}.merge(opts))
    end

    def start_vm(uuid)
      vm = find_vm_by_uuid(uuid)
      if vm.comment.to_s =~ %r{cloud-config|^#!/}
        vm.start_with_cloudinit(:blocking => true, :user_data => vm.comment, :use_custom_script => true)
        vm.comment = ''
        vm.save
      else
        vm.start(:blocking => true)
      end
    end

    def start_with_cloudinit(uuid, user_data = nil)
      find_vm_by_uuid(uuid).start_with_cloudinit(:blocking => true, :user_data => user_data, :use_custom_script => true)
    end

    def sanitize_inherited_vm_attributes(args, template)
      # Cleanup memory an cores values if template and/or instance type provided when VM values are
      # * Blank values for these attributes, because oVirt will fail if empty values are present in VM definition
      # * Provided but identical to values present in the template or instance type
      # Instance type values take precedence on templates values
      if template.present?
        cores = template.cores.to_i if template.cores.present?
        memory = template.memory.to_i if template.memory.present?
      end
      if args[:instance_type].present?
        instance_type = instance_type(args[:instance_type])
        cores = instance_type.cores.to_i if instance_type.cores.present?
        memory = instance_type.memory.to_i if instance_type.memory.present?
      end
      args.delete(:cores) if (args[:cores].blank? && cores) || (args[:cores].to_i == cores)
      args.delete(:memory) if (args[:memory].blank? && memory) || (args[:memory].to_i == memory)
    end

    def create_vm(args = {})
      args[:comment] = args[:user_data] if args[:user_data]
      args[:template] = args[:image_id] if args[:image_id]
      template = template(args[:template]) if args[:template]

      sanitize_inherited_vm_attributes(args, template)
      preallocate_and_clone_disks(args, template) if args[:volumes_attributes].present? && template.present?

      vm = super({ :first_boot_dev => 'network', :quota => ovirt_quota }.merge(args))

      begin
        create_interfaces(vm, args[:interfaces_attributes])
        create_volumes(vm, args[:volumes_attributes])
      rescue => e
        destroy_vm vm.id
        raise e
      end
      vm
    end

    def preallocate_and_clone_disks(args, template)
      volumes_to_change = args[:volumes_attributes].values.select {|x| x[:id].present?}
      return unless volumes_to_change.present?

      template_disks = template.volumes

      disks = volumes_to_change.map do |volume|
        if volume[:preallocate] == '1'
          {:id => volume[:id], :sparse => 'false', :format => 'raw', :storage_domain => volume[:storage_domain]}
        else
          template_volume = template_disks.detect {|v| v.id == volume["id"]}
          {:id => volume["id"], :storage_domain => volume["storage_domain"]} if template_volume.storage_domain != volume["storage_domain"]
        end
      end.compact

      args.merge!(:clone => true, :disks => disks) if disks.present?
    end

    def vm_instance_defaults
      super.merge(
        :memory     => 1024.megabytes,
        :cores      => '1',
        :sockets    => '1',
        :display    => { :type => display_type,
                         :keyboard_layout => keyboard_layout,
                         :port => -1,
                         :monitors => 1 }
      )
    end

    def new_vm(attr = {})
      vm = super
      interfaces = nested_attributes_for :interfaces, attr[:interfaces_attributes]
      interfaces.map { |i| vm.interfaces << new_interface(i)}
      volumes = nested_attributes_for :volumes, attr[:volumes_attributes]
      volumes.map { |v| vm.volumes << new_volume(v) }
      vm
    end

    def new_interface(attr = {})
      Fog::Ovirt::Compute::Interface.new(attr)
    end

    def new_volume(attr = {})
      set_preallocated_attributes!(attr, attr[:preallocate])
      Fog::Ovirt::Compute::Volume.new(attr)
    end

    def save_vm(uuid, attr)
      vm = find_vm_by_uuid(uuid)
      vm.attributes.deep_merge!(attr.deep_symbolize_keys).deep_symbolize_keys
      update_interfaces(vm, attr[:interfaces_attributes])
      update_volumes(vm, attr[:volumes_attributes])
      vm.interfaces
      vm.volumes
      vm.save
    end

    def destroy_vm(uuid)
      find_vm_by_uuid(uuid).destroy
    rescue ActiveRecord::RecordNotFound
      true
    end

    def supports_vms_pagination?
      true
    end

    def parse_vms_list_params(params)
      max = (params['length'] || 10).to_i
      {
        :search => params['search']['value'] || '',
        :max => max,
        :page => (params['start'].to_i / max) + 1,
        :without_details => true,
      }
    end

    def console(uuid)
      vm = find_vm_by_uuid(uuid)
      raise "VM is not running!" if vm.status == "down"
      if vm.display[:type] =~ /spice/i
        xpi_opts = {:name => vm.name, :address => vm.display[:address], :secure_port => vm.display[:secure_port], :ca_cert => public_key, :subject => vm.display[:subject] }
        opts = if vm.display[:secure_port]
                 { :host_port => vm.display[:secure_port], :ssl_target => true }
               else
                 { :host_port => vm.display[:port] }
               end
        WsProxy.start(opts.merge(:host => vm.display[:address], :password => vm.ticket)).merge(xpi_opts).merge(:type => 'spice')
      else
        WsProxy.start(:host => vm.display[:address], :host_port => vm.display[:port], :password => vm.ticket).merge(:name => vm.name, :type => 'vnc')
      end
    end

    def update_required?(old_attrs, new_attrs)
      return true if super(old_attrs, new_attrs)

      new_attrs[:interfaces_attributes]&.each do |key, interface|
        return true if (interface[:id].blank? || interface[:_delete] == '1') && key != 'new_interfaces' # ignore the template
      end

      new_attrs[:volumes_attributes]&.each do |key, volume|
        return true if (volume[:id].blank? || volume[:_delete] == '1') && key != 'new_volumes' # ignore the template
      end

      false
    end

    def associated_host(vm)
      associate_by("mac", vm.interfaces.map(&:mac))
    end

    def self.provider_friendly_name
      "oVirt"
    end

    def display_type
      self.attrs[:display].presence || 'vnc'
    end

    def display_type=(display)
      self.attrs[:display] = display.downcase
    end

    def keyboard_layout
      self.attrs[:keyboard_layout].presence || 'en-us'
    end

    def keyboard_layout=(layout)
      self.attrs[:keyboard_layout] = layout.downcase
    end

    def public_key
      attrs[:public_key]
    end

    def public_key=(key)
      attrs[:public_key] = key
    end

    def normalize_vm_attrs(vm_attrs)
      normalized = slice_vm_attributes(vm_attrs, ['cores', 'interfaces_attributes', 'memory'])
      normalized['cluster_id'] = vm_attrs['cluster']
      normalized['cluster_name'] = self.clusters.detect { |c| c.id == normalized['cluster_id'] }.try(:name)

      normalized['template_id'] = vm_attrs['template']
      normalized['template_name'] = self.templates.detect { |t| t.id == normalized['template_id'] }.try(:name)

      cluster_networks = self.networks(:cluster_id => normalized['cluster_id'])

      interface_attrs = vm_attrs['interfaces_attributes'] || {}
      normalized['interfaces_attributes'] = interface_attrs.inject({}) do |interfaces, (key, nic)|
        interfaces.update(key => { 'name' => nic['name'],
                                'network_id' => nic['network'],
                                'network_name' => cluster_networks.detect { |n| n.id == nic['network'] }.try(:name),
                              })
      end

      volume_attrs = vm_attrs['volumes_attributes'] || {}
      normalized['volumes_attributes'] = volume_attrs.inject({}) do |volumes, (key, vol)|
        volumes.update(key => { 'size' => memory_gb_to_bytes(vol['size_gb']).to_s,
                                'storage_domain_id' => vol['storage_domain'],
                                'storage_domain_name' => storage_domains.detect { |d| d.id == vol['storage_domain'] }.try(:name),
                                'preallocate' => to_bool(vol['preallocate']),
                                'bootable' => to_bool(vol['bootable']),
                              })
      end

      normalized
    end

    def nictypes
      [
        OpenStruct.new({:id => 'virtio', :name => 'VirtIO'}),
        OpenStruct.new({:id => 'rtl8139', :name => 'rtl8139'}),
        OpenStruct.new({:id => 'e1000', :name => 'e1000'}),
        OpenStruct.new({:id => 'pci_passthrough', :name => 'PCI Passthrough'}),
      ]
    end

    protected

    def bootstrap(args)
      client.servers.bootstrap vm_instance_defaults.merge(args.to_h)
    rescue Fog::Errors::Error => e
      Foreman::Logging.exception("Failed to bootstrap vm", e)
      errors.add(:base, e.to_s)
      false
    end

    def client
      return @client if @client
      client = ::Fog::Compute.new(
        :provider         => "ovirt",
        :ovirt_username   => user,
        :ovirt_password   => password,
        :ovirt_url        => url,
        :ovirt_datacenter => uuid,
        :ovirt_ca_cert_store => ca_cert_store(public_key),
        :public_key       => public_key,
        :api_version      => use_v4? ? 'v4' : 'v3'
      )
      client.datacenters
      @client = client
    rescue => e
      if e.message =~ /SSL_connect.*certificate verify failed/ ||
          e.message =~ /Peer certificate cannot be authenticated with given CA certificates/
        raise Foreman::FingerprintException.new(
          N_("The remote system presented a public key signed by an unidentified certificate authority. If you are sure the remote system is authentic, go to the compute resource edit page, press the 'Test Connection' or 'Load Datacenters' button and submit"),
          ca_cert
        )
      else
        raise e
      end
    end

    def update_public_key(options = {})
      return unless public_key.blank? || options[:force]
      client
    rescue Foreman::FingerprintException => e
      self.public_key = e.fingerprint if self.public_key.blank?
    end

    def api_version
      @api_version ||= client.api_version
    end

    def ca_cert_store(certs)
      return if certs.blank?
      store = OpenSSL::X509::Store.new
      certs.split(/(?=-----BEGIN)/).each do |cert|
        store.add_cert(OpenSSL::X509::Certificate.new(cert))
      end
      store
    rescue => e
      raise _("Failed to create X509 certificate, error: %s" % e.message)
    end

    def fetch_unverified(path, query = '')
      ca_url = URI.parse(url)
      ca_url.path = path
      ca_url.query = query
      http = Net::HTTP.new(ca_url.host, ca_url.port)
      http.use_ssl = (ca_url.scheme == 'https')
      http.verify_mode = OpenSSL::SSL::VERIFY_NONE
      request = Net::HTTP::Get.new(ca_url)
      response = http.request(request)
      # response might be 404 or some other normal code,
      # that would not trigger any exception so we rather check what kind of response we got
      response.is_a?(Net::HTTPSuccess) ? response.body : nil
    rescue => e
      Foreman::Logging.exception("Unable to fetch CA certificate on path #{path}: #{e}", e)
      nil
    end

    def ca_cert
      fetch_unverified("/ovirt-engine/services/pki-resource", "resource=ca-certificate&format=X509-PEM-CA") || fetch_unverified("/ca.crt")
    end

    private

    def update_available_operating_systems
      return false if errors.any?
      ovirt_operating_systems = client.operating_systems if client.respond_to?(:operating_systems)

      attrs[:available_operating_systems] = ovirt_operating_systems.map do |os|
        { :id => os.id, :name => os.name, :href => os.href }
      end
    rescue Foreman::FingerprintException
      logger.info "Unable to verify OS capabilities, SSL certificate verification failed"
      true
    rescue Fog::Ovirt::Errors::OvirtEngineError => e
      if e.message =~ /404/
        attrs[:available_operating_systems] ||= :unsupported
      else
        raise e
      end
    end

    def os_name_mapping(host)
      (host.operatingsystem.name =~ /redhat|centos/i) ? 'rhel' : host.operatingsystem.name.downcase
    end

    def arch_name_mapping(host)
      return unless host.architecture
      (host.architecture.name == 'x86_64') ? 'x64' : host.architecture.name.downcase
    end

    def default_iface_name(interfaces)
      nic_name_num = 1
      name_blacklist = interfaces.map { |i| i[:name]}.reject {|n| n.blank?}
      nic_name_num += 1 while name_blacklist.include?("nic#{nic_name_num}")
      "nic#{nic_name_num}"
    end

    def create_interfaces(vm, attrs)
      # first remove all existing interfaces
      vm.interfaces&.each do |interface|
        # The blocking true is a work-around for ovirt bug, it should be removed.
        vm.destroy_interface(:id => interface.id, :blocking => true)
      end
      # add interfaces
      interfaces = nested_attributes_for :interfaces, attrs
      interfaces.map do |interface|
        interface[:name] = default_iface_name(interfaces) if interface[:name].empty?
        vm.add_interface(interface)
      end
      vm.interfaces.reload
    end

    def create_volumes(vm, attrs)
      # add volumes
      volumes = nested_attributes_for :volumes, attrs
      volumes.map do |vol|
        if vol[:id].blank?
          set_preallocated_attributes!(vol, vol[:preallocate])
          vol[:wipe_after_delete] = to_fog_ovirt_boolean(vol[:wipe_after_delete])
          # The blocking true is a work-around for ovirt bug fixed in ovirt version 3.1.
          vm.add_volume({:bootable => 'false', :quota => ovirt_quota, :blocking => api_version.to_f < 3.1}.merge(vol))
        end
      end
      vm.volumes.reload
    end

    def to_fog_ovirt_boolean(val)
      case val
      when '1'
        'true'
      when '0'
        'false'
      else
        val
      end
    end

    def set_preallocated_attributes!(volume_attributes, preallocate)
      if preallocate == '1'
        volume_attributes[:sparse] = 'false'
        volume_attributes[:format] = 'raw'
      else
        volume_attributes[:sparse] = 'true'
      end
    end

    def update_interfaces(vm, attrs)
      interfaces = nested_attributes_for :interfaces, attrs
      interfaces.each do |interface|
        vm.destroy_interface(:id => interface[:id]) if interface[:_delete] == '1' && interface[:id]
        if interface[:id].blank?
          interface[:name] = default_iface_name(interfaces) if interface[:name].empty?
          vm.add_interface(interface)
        end
      end
    end

    def update_volumes(vm, attrs)
      volumes = nested_attributes_for :volumes, attrs
      volumes.each do |volume|
        vm.destroy_volume(:id => volume[:id], :blocking => api_version.to_f < 3.1) if volume[:_delete] == '1' && volume[:id].present?
        vm.add_volume({:bootable => 'false', :quota => ovirt_quota, :blocking => api_version.to_f < 3.1}.merge(volume)) if volume[:id].blank?
      end
    end

    def set_vm_interfaces_attributes(vm, vm_attrs)
      if vm.respond_to?(:interfaces)
        interfaces = vm.interfaces || []
        vm_attrs[:interfaces_attributes] = interfaces.each_with_index.each_with_object({}) do |(interface, index), hsh|
          interface_attrs = {
            mac: interface.mac,
            compute_attributes: {
              name: interface.name,
              network: interface.network,
              interface: interface.interface,
            },
          }
          hsh[index.to_s] = interface_attrs
        end
      end
      vm_attrs
    end
  end
end
