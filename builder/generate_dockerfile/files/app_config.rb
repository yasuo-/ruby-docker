# Copyright 2017 Google Inc. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require "json"
require "optparse"
require "psych"

class AppConfig
  DEFAULT_WORKSPACE_DIR = "/workspace"
  DEFAULT_APP_YAML_PATH = "./app.yaml"
  DEFAULT_ENTRYPOINT = "bundle exec rackup -p $PORT"
  DEFAULT_SERVICE_NAME = "default"
  RAILS_ASSETS_BUILD_SCRIPT = "bundle exec rake assets:precompile || true"

  attr_reader :workspace_dir
  attr_reader :app_yaml_path
  attr_reader :project_id
  attr_reader :service_name
  attr_reader :env_variables
  attr_reader :cloud_sql_instances
  attr_reader :build_scripts
  attr_reader :runtime_config
  attr_reader :raw_entrypoint
  attr_reader :entrypoint
  attr_reader :install_packages
  attr_reader :ruby_version
  attr_reader :has_gemfile

  def initialize workspace_dir
    @workspace_dir = workspace_dir
    init_app_config
    init_env_variables
    init_build_scripts
    init_cloud_sql_instances
    init_entrypoint
    init_packages
    init_ruby_config
  end

  private

  def init_app_config
    @project_id = ::ENV["PROJECT_ID"] || "(unknown)"
    @app_yaml_path = ::ENV["GAE_APPLICATION_YAML_PATH"] || DEFAULT_APP_YAML_PATH
    @app_config =
      ::Psych.load_file("#{@workspace_dir}/#{@app_yaml_path}") rescue {}
    @runtime_config = @app_config["runtime_config"] || {}
    @beta_settings = @app_config["beta_settings"] || {}
    @lifecycle = @app_config["lifecycle"] || {}
    @service_name = @app_config["service"] || DEFAULT_SERVICE_NAME
  end

  def init_env_variables
    @env_variables = @app_config["env_variables"] || {}
    @env_variables.each do |k, v|
      if k !~ %r{\A[a-zA-Z]\w*\z}
        report_error "Illegal environment variable name: #{k.inspect}"
      end
    end
  end

  def init_build_scripts
    if ::File.directory?("#{@workspace_dir}/app/assets") &&
        ::File.file?("#{@workspace_dir}/config/application.rb")
      default_build_scripts = [RAILS_ASSETS_BUILD_SCRIPT]
    else
      default_build_scripts = []
    end
    raw_build_scripts = @lifecycle["build"] || @runtime_config["build"]
    @build_scripts = raw_build_scripts ?
        Array(raw_build_scripts) : default_build_scripts
    @build_scripts.each do |script|
      if script.include? "\n"
        report_error "Illegal build command: newlines not permitted"
      end
    end
  end

  def init_cloud_sql_instances
    @cloud_sql_instances = Array(@beta_settings["cloud_sql_instances"])
    @cloud_sql_instances.each do |name|
      if name !~ %r{\A[\w:.-]+\z}
        report_error "Illegal cloud sql instance name: #{name.inspect}"
      end
    end
  end

  def init_entrypoint
    @raw_entrypoint =
        @runtime_config["entrypoint"] ||
        @app_config["entrypoint"] ||
        DEFAULT_ENTRYPOINT
    if @raw_entrypoint.include? "\n"
      report_error "Illegal entrypoint: newlines not permitted"
    end
    @entrypoint = decorate_entrypoint @raw_entrypoint
  end

  # Prepare entrypoint for rendering into the dockerfile.
  # If the provided entrypoint is an array, render it in exec format.
  # If the provided entrypoint is a string, we have to render it in shell
  # format. Now, we'd like to prepend "exec" so signals get caught properly.
  # However, there are some edge cases that we omit for safety.
  def decorate_entrypoint entrypoint
    return JSON.generate entrypoint if entrypoint.is_a? Array
    return entrypoint if entrypoint.start_with? "exec "
    return entrypoint if entrypoint =~ /;|&&|\|/
    "exec #{entrypoint}"
  end

  def init_packages
    @install_packages = Array(
      @runtime_config["packages"] || @app_config["packages"]
    )
    @install_packages.each do |pkg|
      if pkg !~ %r{\A[\w.-]+\z}
        report_error "Illegal debian package name: #{pkg.inspect}"
      end
    end
  end

  def init_ruby_config
    @ruby_version = ::File.read("#{@workspace_dir}/.ruby-version") rescue ''
    @ruby_version.strip!
    if @ruby_version !~ %r{\A[\w.-]*\z}
      report_error "Illegal ruby version: #{@ruby_version.inspect}"
    end
    @has_gemfile = ::File.readable? "#{@workspace_dir}/Gemfile.lock"
  end

  def report_error str
    STDERR.puts str
    exit 1
  end
end