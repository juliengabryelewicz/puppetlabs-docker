# frozen_string_literal: true

require 'deep_merge'

Puppet::Type.type(:docker_compose).provide(:ruby) do
  desc 'Support for Puppet running Docker Compose'

  mk_resource_methods

  has_command(:docker, 'docker')

  def set_tmpdir
    return unless resource[:tmpdir]

    # Check if the the tmpdir target exists
    Puppet.warning("#{resource[:tmpdir]} (defined as docker_compose tmpdir) does not exist") unless Dir.exist?(resource[:tmpdir])
    # Set TMPDIR environment variable only if defined among resources and exists
    ENV['TMPDIR'] = resource[:tmpdir] if Dir.exist?(resource[:tmpdir])
  end

  def exists?
    Puppet.info("Checking for compose project #{name}")
    compose_services = {}
    compose_containers = []

    set_tmpdir

    # get merged config using docker-compose config
    args = ['compose', compose_files, '-p', name, 'config'].insert(3, resource[:options]).compact
    compose_output = Puppet::Util::Yaml.safe_load(execute([command(:docker)] + args, combine: false), [Symbol])

    containers = docker([
                          'ps',
                          '--format',
                          "'{{.Label \"com.docker.compose.service\"}}-{{.Image}}'",
                          '--filter',
                          "label=com.docker.compose.project=#{name}",
                        ]).split("\n")
    compose_containers.push(*containers)

    compose_services = compose_output['services']

    return false if compose_services.count != compose_containers.uniq.count

    counts = Hash[*compose_services.each.map { |key, array|
                    Puppet.info("Checking for compose service #{key}")
                    [key, compose_containers.count("'#{key}'")]
                  }.flatten]

    # No containers found for the project
    if counts.empty? ||
       # Containers described in the compose file are not running
       counts.any? { |_k, v| v.zero? } ||
       # The scaling factors in the resource do not match the number of running containers
       (resource[:scale] && counts.merge(resource[:scale]) != counts)
      false
    else
      true
    end
  end

  def create
    Puppet.info("Running compose project #{name}")
    args = ['compose', compose_files, '-p', name, 'up', '-d', '--remove-orphans'].insert(3, resource[:options]).insert(5, resource[:up_args]).compact
    docker(args)
    return unless resource[:scale]

    instructions = resource[:scale].map { |k, v| "#{k}=#{v}" }
    Puppet.info("Scaling compose project #{name}: #{instructions.join(' ')}")
    args = ['compose', compose_files, '-p', name, 'scale'].insert(3, resource[:options]).compact + instructions
    docker(args)
  end

  def destroy
    Puppet.info("Removing all containers for compose project #{name}")
    kill_args = ['compose', compose_files, '-p', name, 'kill'].insert(3, resource[:options]).compact
    docker(kill_args)
    rm_args = ['compose', compose_files, '-p', name, 'rm', '--force', '-v'].insert(3, resource[:options]).compact
    docker(rm_args)
  end

  def restart
    return unless exists?

    Puppet.info("Rebuilding and Restarting all containers for compose project #{name}")
    kill_args = ['compose', compose_files, '-p', name, 'kill'].insert(3, resource[:options]).compact
    docker(kill_args)
    build_args = ['compose', compose_files, '-p', name, 'build'].insert(3, resource[:options]).compact
    docker(build_args)
    create
  end

  def compose_files
    resource[:compose_files].map { |x| ['-f', x] }.flatten
  end
end
