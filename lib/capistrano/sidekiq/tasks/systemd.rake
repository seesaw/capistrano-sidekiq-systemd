namespace :load do
  task :defaults do
    set :sidekiq_default_hooks, true
    set :sidekiq_env, -> { fetch(:rack_env, fetch(:rails_env, fetch(:stage))) }
    set :sidekiq_roles, fetch(:sidekiq_role, :app)
    set :sidekiq_options_per_process, nil
    set :sidekiq_user, nil
    set :sidekiq_systemd_user, nil
    set :sidekiq_systemd_group, nil
    set :sidekiq_max_mem, nil
    set :service_unit_name, "sidekiq-#{fetch(:stage)}.service"
    set :sidekiq_service_unit_user, :user
    set :sidekiq_log, nil
    set :sidekiq_error_log, nil
    # Rbenv, Chruby, and RVM integration
    set :rbenv_map_bins, fetch(:rbenv_map_bins).to_a.concat(%w[sidekiq])
    set :rvm_map_bins, fetch(:rvm_map_bins).to_a.concat(%w[sidekiq])
    set :chruby_map_bins, fetch(:chruby_map_bins).to_a.concat(%w[sidekiq])
    # Bundler integration
    set :bundle_bins, fetch(:bundle_bins).to_a.concat(%w[sidekiq])
    # Options for single process setup
    set :sidekiq_require, nil
    set :sidekiq_tag, nil
    set :sidekiq_queue, nil
    set :sidekiq_config, nil
    set :sidekiq_concurrency, nil
    set :sidekiq_options, nil
  end
end

namespace :deploy do
  before :starting, :check_sidekiq_hooks do
    invoke 'sidekiq:add_default_hooks' if fetch(:sidekiq_default_hooks)
  end
end

namespace :sidekiq do
  task :add_default_hooks do
    after 'deploy:starting',  'sidekiq:quiet'
    after 'deploy:updated',   'sidekiq:stop'
    after 'deploy:published', 'sidekiq:start'
    after 'deploy:failed', 'sidekiq:restart'
  end

  desc 'Quiet sidekiq (stop fetching new tasks from Redis)'
  task :quiet do
    on roles fetch(:sidekiq_roles) do |role|
      switch_user(role) do
        sidekiq_options_per_process.each_index do |index|
          systemctl(command: 'reload', service_unit_name: service_unit_name(index), raise_on_non_zero_exit: false)
        end
      end
    end
  end

  desc 'Stop sidekiq (graceful shutdown within timeout, put unfinished tasks back to Redis)'
  task :stop do
    on roles fetch(:sidekiq_roles) do |role|
      switch_user(role) do
        sidekiq_options_per_process.each_index do |index|
          systemctl(command: 'stop', service_unit_name: service_unit_name(index))
        end
      end
    end
  end

  desc 'Start sidekiq'
  task :start do
    on roles fetch(:sidekiq_roles) do |role|
      switch_user(role) do
        sidekiq_options_per_process.each_index do |index|
          systemctl(command: 'start', service_unit_name: service_unit_name(index))
        end
      end
    end
  end

  desc 'Restart sidekiq'
  task :restart do
    invoke! 'sidekiq:stop'
    invoke! 'sidekiq:start'
  end

  desc 'Generate and upload .service files'
  task :install do
    on roles fetch(:sidekiq_roles) do |role|
      switch_user(role) do
        create_systemd_template(role)
        sidekiq_options_per_process.each_index do |index|
          systemctl(command: 'enable', service_unit_name: service_unit_name(index))
        end
      end
    end
  end

  desc 'Uninstall .service files'
  task :uninstall do
    on roles fetch(:sidekiq_roles) do |role|
      switch_user(role) do
        sidekiq_options_per_process.each_index do |index|
          systemctl(command: 'disable', service_unit_name: service_unit_name(index))
          execute :rm, File.join(fetch(:service_unit_path, fetch_systemd_unit_path(capture(:pwd))), service_unit_name(index))
        end
      end
    end
  end

  def create_systemd_template(role)
    template = File.read(File.expand_path('../../../../generators/capistrano/sidekiq/systemd/templates/sidekiq.service.capistrano.erb', __FILE__))
    home_dir = capture :pwd
    systemd_path = fetch(:service_unit_path, fetch_systemd_unit_path(home_dir))
    sidekiq_cmd = SSHKit.config.command_map[:sidekiq].gsub('~', home_dir)
    if fetch(:sidekiq_service_unit_user) == :user
      execute :mkdir, "-p", systemd_path
    end
    sidekiq_options_per_process.each_index do |index|
      upload_template(data: StringIO.new(ERB.new(template).result(binding)),
        systemd_path: systemd_path, service_unit_name: service_unit_name(index)
      )
    end
    systemctl(command: 'daemon-reload')
  end

  def process_options(index = 0)
    args = []
    args.push "--environment #{fetch(:sidekiq_env)}"
    %w{require queue config concurrency}.each do |option|
      options = fetch(:sidekiq_options_per_process)&.[](index)
      Array((options.is_a?(Hash) && options[option.to_sym]) || fetch(:"sidekiq_#{option}")).each do |value|
        args.push "--#{option} #{value}"
      end
    end
    if (process_options = fetch(:sidekiq_options_per_process)&.[](index)).is_a?(String)
      args.push process_options
    end

    args.push "--tag #{service_unit_name(index)}" # Used to be able to identify service by monit via regex

    # use sidekiq_options for special options
    options = fetch(:sidekiq_options_per_process)&.[](index)
    Array((options.is_a?(Hash) && options[:sidekiq_options]) || fetch(:sidekiq_options)).each do |value|
      args.push value
    end
    args.compact.join(' ')
  end

  def switch_user(role)
    su_user = sidekiq_user(role)
    if su_user == role.user
      yield
    else
      as su_user do
        yield
      end
    end
  end

  def sidekiq_user(role)
    properties = role.properties
    properties.fetch(:sidekiq_user) || # local property for sidekiq only
      fetch(:sidekiq_user) ||
      properties.fetch(:run_as) || # global property across multiple capistrano gems
      role.user
  end

  def sidekiq_options_per_process
    fetch(:sidekiq_options_per_process) || [nil]
  end

  def service_unit_name(index)
    if multiple_processes?
      options = fetch(:sidekiq_options_per_process)&.[](index)
      (options.is_a?(Hash) && options[:service_unit_name]) || fetch(:service_unit_name).gsub(/(.*)\.service/, "\\1-#{index}.service")
    else
      fetch(:service_unit_name)
    end
  end

  def max_mem(index, service = :systemd)
    if multiple_processes?
      options = fetch(:sidekiq_options_per_process)&.[](index)
      case service
      when :systemd
        (options.is_a?(Hash) && options[:sidekiq_max_mem]) || fetch(:sidekiq_max_mem)
      when :monit
        (options.is_a?(Hash) && options[:sidekiq_monit_max_mem]) || fetch(:sidekiq_monit_max_mem)
      end
    elsif service == :systemd
      fetch(:sidekiq_max_mem)
    elsif service == :monit
      fetch(:sidekiq_monit_max_mem)
    end
  end

  def systemctl(command:, service_unit_name: nil, raise_on_non_zero_exit: true)
    if fetch(:sidekiq_service_unit_user) == :user
      execute :systemctl, "--user", command, service_unit_name, raise_on_non_zero_exit: raise_on_non_zero_exit
    elsif fetch(:sidekiq_service_unit_user) == :system
      execute :sudo, :systemctl, command, service_unit_name, raise_on_non_zero_exit: raise_on_non_zero_exit
    end
  end

  def fetch_systemd_unit_path(home_dir)
    if fetch(:sidekiq_service_unit_user) == :user
      File.join(home_dir, ".config", "systemd", "user")
    elsif fetch(:sidekiq_service_unit_user) == :system
      File.join("/", "etc", "systemd", "system")
    end
  end

  def upload_template(data:, systemd_path:, service_unit_name:)
    temp_file_path = File.join('/', 'tmp', "#{service_unit_name}")
    upload!(data, temp_file_path)
    if fetch(:sidekiq_service_unit_user) == :system
      execute :sudo, :mv, temp_file_path, File.join(systemd_path, service_unit_name)
    else
      execute :mv, temp_file_path, File.join(systemd_path, service_unit_name)
    end
    systemctl(command: 'daemon-reload')
  end

  def multiple_processes?
    fetch(:sidekiq_options_per_process) && fetch(:sidekiq_options_per_process).size > 1
  end
end
