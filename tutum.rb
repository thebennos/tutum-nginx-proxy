require 'faye/websocket'
require 'eventmachine'
require 'json'
require 'tutum'
require 'erb'
require 'logger'
require 'uri'

if !ENV['TUTUM_AUTH']
  puts "Nginx doesn't have access to Tutum API - you might want to give an API role to this service for automatic backend reconfiguration"
  exit 1
end

$stdout.sync = true
CLIENT_URL = URI.escape("wss://stream.tutum.co/v1/events?auth=#{ENV['TUTUM_AUTH']}")

LOGGER = Logger.new($stdout)
LOGGER.level = Logger::INFO

# PATCH
class Tutum
  attr_reader :tutum_auth
  def initialize(options = {})
    @tutum_auth = options[:tutum_auth]
  end
  def headers
    {
      'Authorization' => @tutum_auth,
      'Accept' => 'application/json',
      'Content-Type' => 'application/json'
    }
  end
end


class NginxConf

  TEMPLATE = File.open("./nginx.conf.erb", "r").read

  def initialize()
    @renderer = ERB.new(TEMPLATE)
  end

  def write(services, file)
    @services = services
    LOGGER.info @services.map {|s| s.container_ips}.inspect
    result = @renderer.result(binding) #rescue nil
    if result
      File.open(file, "w+") do |f|
        f.write(result)
      end
    end
  end

end


class Container
  attr_reader :id, :attributes

  def initialize(attributes)
    @id = attributes['uuid']
    @attributes = attributes
  end

  def ip
    attributes['private_ip']
  end

  def host
    attributes['container_envvars'].find {|e| e['key'] == 'VIRTUAL_HOST' }['value']
  end

  def ssl?
    !!attributes['container_envvars'].find {|e| e['key'] == 'FORCE_SSL' }['value']
  end

  def running?
    ['Starting', 'Running'].include?(attributes['state'])
  end

end

class Service
  attr_reader :id, :attributes, :session
  def initialize(attributes, session)
    @id = attributes['uuid']
    @attributes = attributes
    @session = session
  end

  def name
    attributes['name']
  end

  def port_types
    @port_types ||= attributes['container_ports'].map {|p| p['port_name']}
  end

  def container_ips
    @container_ips ||= containers.map {|c| c.ip if running? }.sort
  end

  def http?
    (port_types & ['http', 'https']).count > 0
  end

  def host
    @host ||= containers.first.host rescue nil
  end

  def ssl?
    @ssl ||= containers.first.ssl? rescue nil
  end

  def running?
    @state ||= begin
      reload!
      ['Running', 'Partly running'].include?(attributes['state'])
    end
  end

  def containers
    @containers ||= begin
      reload!
      attributes['containers'].map do |container_url|
        id = container_url.split("/").last
        Container.new(session.containers.get(id))
      end
    end
  end

  def reload!
    @attributes = session.services.get(id)
  end

end

class HttpServices

  def self.reload!
    LOGGER.info 'Reloding Nginx...'
    EventMachine.system("nginx -s reload")
  end

  attr_reader :session
  def initialize(tutum_auth)
    @session = Tutum.new(tutum_auth: tutum_auth)
    @services = get_services
  end

  def write_conf(file_path)
    @nginx_conf ||= NginxConf.new()
    @nginx_conf.write(@services, file_path)
    LOGGER.info 'Writing new nginx config'
    self
  end

  private

  def get_services
    services = []
    services_list.each do |service|
      if service.http? && service.running?
        services << service
      end
    end
    services
  end

  def services_list(filters = {})
    session.services.list(filters)['objects'].map {|data| Service.new(data, session) }
  end

end

module NginxConfHandler
  def file_modified
    @timer ||= EventMachine::Timer.new(0)
    @timer.cancel
    @timer = EventMachine::Timer.new(3) do
      HttpServices.reload!
    end
  end
end

EventMachine.kqueue = true if EventMachine.kqueue?

EM.run {
  LOGGER.info "Connecting to #{CLIENT_URL}"
  ws = Faye::WebSocket::Client.new(CLIENT_URL)
  services_changing = []
  services_changed = false
  timer = EventMachine::Timer.new(0)

  ws.on :open do |event|
    LOGGER.info 'Init Nginx config'

    HttpServices.new(ENV['TUTUM_AUTH']).write_conf(ENV['NGINX_DEFAULT_CONF'])
    HttpServices.reload!

    EventMachine.watch_file(ENV['NGINX_DEFAULT_CONF'], NginxConfHandler)
  end

  ws.on :message do |event|
    data = JSON.parse(event.data)

    if data['type'] == 'service'

      case data['state']
      when 'Scaling', 'Redeploying', 'Stopping', 'Starting', 'Terminating'
        LOGGER.info "Service: #{data['uuid']} is #{data['state']}..."
        timer.cancel # cancel any conf writes
        services_changing << data['uuid']
      when 'Running', 'Stopped', 'Not running', 'Terminated'
        if services_changing.count > 0
          LOGGER.info "Service: #{data['uuid']} is #{data['state']}!"
          services_changing.shift
          timer.cancel # cancel any conf writes
          services_changed = true
        end
      end

      if services_changed && services_changing == []
        LOGGER.info "Services changed - Rewrite Nginx config"
        services_changed = false
        timer.cancel
        timer = EventMachine::Timer.new(5) do
          HttpServices.new(ENV['TUTUM_AUTH']).write_conf(ENV['NGINX_DEFAULT_CONF'])
        end
      end

    end
  end

  ws.on(:error) do |event|
    LOGGER.info JSON.parse(event.data).inspect
  end


}
