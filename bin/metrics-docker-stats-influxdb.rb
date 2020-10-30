#! /usr/bin/env ruby
#
#   metrics-docker-stats
#
# DESCRIPTION:
#
# Supports the stats feature of the docker remote api ( docker server 1.5 and newer )
# Supports connecting to docker remote API over Unix socket or TCP
#
#
# OUTPUT:
#   metric-data
#
# PLATFORMS:
#   Linux
#
# DEPENDENCIES:
#   gem: sensu-plugin
#
# USAGE:
#   Gather stats from all containers on a host using socket:
#   metrics-docker-stats.rb -H /var/run/docker.sock
#
#   Gather stats from all containers on a host using HTTP:
#   metrics-docker-stats.rb -H localhost:2375
#
#   Gather stats from a specific container using socket:
#   metrics-docker-stats.rb -H /var/run/docker.sock -N 5bf1b82382eb
#
#   See metrics-docker-stats.rb --help for full usage flags
#
# NOTES:
#
# LICENSE:
#   Copyright 2015 Paul Czarkowski. Github @paulczar
#   Released under the same terms as Sensu (the MIT license); see LICENSE
#   for details.
#

require 'sensu-plugin/metric/cli'
require 'sensu-plugins-docker/client_helpers'

class Hash
  def self.to_dotted_hash(hash, recursive_key = '')
    hash.each_with_object({}) do |(k, v), ret|
      key = recursive_key + k.to_s
      if v.is_a? Hash
        ret.merge! to_dotted_hash(v, key + '.')
      else
        ret[key] = v
      end
    end
  end
end

class DockerStatsMetrics < Sensu::Plugin::Metric::CLI::Influxdb
  option :scheme,
         description: 'Metric naming scheme, text to prepend to metric',
         short: '-s SCHEME',
         long: '--scheme SCHEME',
         default: "#{Socket.gethostname}.docker"

  option :container,
         description: 'Name of container to collect metrics for',
         short: '-N CONTAINER',
         long: '--container-name CONTAINER',
         default: ''

  option :docker_host,
         description: 'Docker API URI. https://host, https://host:port, http://host, http://host:port, host:port, unix:///path',
         short: '-H DOCKER_HOST',
         long: '--docker-host DOCKER_HOST'

  option :friendly_names,
         description: 'use friendly name if available',
         short: '-n',
         long: '--names',
         boolean: true,
         default: false

  option :name_parts,
         description: 'Partial names by spliting and returning at index(es).
         eg. -m 3,4 my-docker-container-process_name-b2ffdab8f1aceae85300 for process_name.b2ffdab8f1aceae85300',
         short: '-m index',
         long: '--match index'

  option :delim,
         description: 'the deliminator to use with -m',
         short: '-d',
         long: '--deliminator',
         default: '-'

  option :tags,
         description: 'List of key=value tags separated by commas',
         short: '-t TAGS',
         long: '--tags TAGS'

  option :names_as_tags,
        description: "Include container name as a tag",
        long: "--name-as-tags",
        boolean: true,
        default: false

  option :with_labels,
         description: "Include labels from containers as tags",
         long: "--labels-as-tags",
         boolean: true,
         default: false

  option :extra_stats,
         description: 'List of key=value stats separated by commas',
         short: '-e STATS',
         long: '--extra-stats STATS'

  option :ioinfo,
         description: 'enable IO Docker metrics',
         short: '-i',
         long: '--ioinfo',
         boolean: true,
         default: false

  option :cpupercent,
         description: 'add cpu usage percentage metric',
         short: '-P',
         long: '--percentage',
         boolean: true,
         default: false

  def extra_stats
    return {} unless config[:extra_stats]
    config[:extra_stats].split(',').map { |x|
        k_v = x.split('=')
        k_v[1] =
            if k_v[1][/^[0-9]*$/]
                k_v[1].to_i
            elsif k_v[1][/^[0-9\.]*$/]
                k_v[1].to_f
            else
                k_v[1]
            end
        k_v
    }.to_h
  end

  def run
    @timestamp = Time.now.to_i
    @client = DockerApi.new(config[:docker_host])

    list = if config[:container] != ''
             [config[:container]]
           else
             list_containers
           end
    list.each do |container|
      stats = container_stats(container)
      scheme = ''
      if config[:name_parts]
        config[:name_parts].split(',').each do |key|
          scheme << '.' unless scheme == ''
          scheme << container.split(config[:delim])[key.to_i]
        end
      else
        scheme << container
      end
      stats.merge!(extra_stats)
      output_stats(scheme, stats)
    end
    ok
  end

  def output_stats(container, stats)
    dotted_stats = Hash.to_dotted_hash stats
    all_stats = {}
    name = nil
    id = nil
    stat_name = "#{config[:scheme]}"
    unless config[:names_as_tags]
      stat_name += ".#{container}"
    end
    dotted_stats.each do |key, value|
      next if key == 'read' # unecessary timestamp
      next if key == 'preread' # unecessary timestamp
      next if value.is_a?(Array)
      value.delete!('/') if key == 'name'
      if key == 'name'
        name = value
      elsif key == 'id'
        id = value
      end
      value = "\"#{value}\"" if value.is_a?(String)
      all_stats[key] = value
    end
    if config[:ioinfo]
      blkio_stats(stats['blkio_stats']).each do |key, value|
        all_stats[key] = value
      end
    end
    if config[:cpupercent]
      all_stats['cpu_stats.usage_percent'] = calculate_cpu_percent(stats)
    end
    output stat_name, all_stats.map{|k,v| "#{k}=#{v}"}.join(","), container_tags(container, name)
  end

  def list_containers
    list = []
    path = '/containers/json'
    containers = @client.parse(path)

    containers.each do |container|
      list << if config[:friendly_names]
                container['Names'][0].delete('/')
              elsif config[:name_parts]
                container['Names'][0].delete('/')
              else
                container['Id']
              end
    end
    list
  end

  def container_stats(container)
    path = "/containers/#{container}/stats?stream=0"
    response = @client.call(path)
    if response.code.to_i == 404
      critical "#{config[:container]} is not running on #{@client.uri}"
    end
    parse_json(response)
  end

  def container_tags(container, name)
    tag_list = []

    if name and config[:names_as_tags]
      tag_list << "name=#{name}"
    end

    # From args
    unless config[:tags].nil?
      tag_list = config[:tags].split(',')
    end

    # From container
    if config[:with_labels]
      path = "/containers/#{container}/json"
      response = @client.call(path)
      if response.code.to_i == 404
        critical "#{config[:container]} is not running on #{@client.uri}"
      end
      inspect = parse_json(response)
      inspect['Config']['Labels'].each do |k,v|
        tag_list << "#{k}=\"#{v}\""
      end
    end

    if tag_list.empty?
      tag_list = nil
    end
    tag_list
  end

  def blkio_stats(io_stats)
    stats_out = {}
    io_stats.each do |stats_type, stats_vals|
      stats_vals.each do |value|
        stats_out["#{stats_type}.#{value['op']}.#{value['major']}.#{value['minor']}"] = value['value']
      end
    end
    stats_out
  end

  def calculate_cpu_percent(stats)
    cpu_percent = 0.0
    previous_cpu = stats['precpu_stats']['cpu_usage']['total_usage']
    previous_system = stats['precpu_stats']['system_cpu_usage']
    cpu_delta = stats['cpu_stats']['cpu_usage']['total_usage'] - previous_cpu
    system_delta = 0
    system_delta = stats['cpu_stats']['system_cpu_usage'] - previous_system unless stats['cpu_stats']['system_cpu_usage'].nil?
    if system_delta > 0 && cpu_delta > 0
      number_of_cpu = stats['cpu_stats']['cpu_usage']['percpu_usage'].length
      cpu_percent = (cpu_delta.to_f / system_delta.to_f) * number_of_cpu * 100
    end
    format('%.2f', cpu_percent)
  end
end
