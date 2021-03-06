# -*- encoding: utf-8 -*-

require 'erb'
require 'ostruct'
require 'thor'

require 'jamie'

module Jamie

  # The command line runner for Jamie.
  class CLI < Thor

    include Thor::Actions

    # Constructs a new instance.
    def initialize(*args)
      super
      @config = Jamie::Config.new(ENV['JAMIE_YAML'])
    end

    desc "list (all ['REGEX']|[INSTANCE])", "List all instances"
    def list(*args)
      result = parse_subcommand(args[0], args[1])
      say Array(result).map{ |i| i.name }.join("\n")
    end

    [:create, :converge, :setup, :verify, :test, :destroy].each do |action|
      desc(
        "#{action} (all ['REGEX']|[INSTANCE])",
        "#{action.capitalize} one or more instances"
      )
      define_method(action) { |*args| exec_action(action) }
    end

    desc "version", "Print Jamie's version information"
    def version
      say "Jamie version #{Jamie::VERSION}"
    end
    map %w(-v --version) => :version

    desc "console", "Jamie Console!"
    def console
      require 'pry'
      Pry.start(@config, :prompt => pry_prompts)
    rescue LoadError => e
      warn %{Make sure you have the pry gem installed. You can install it with:}
      warn %{`gem install pry` or including 'gem "pry"' in your Gemfile.}
      exit 1
    end

    desc "init", "Adds some configuration to your cookbook so Jamie can rock"
    def init
      InitGenerator.new.init
    end

    desc "new_plugin [NAME]", "Generate a new Jamie Driver plugin gem project"
    method_option :license, :aliases => "-l", :default => "apachev2",
      :desc => "Type of license for gem (apachev2, mit, gplv3, gplv2, reserved)"
    def new_plugin(name)
      g = NewPluginGenerator.new
      g.options = options
      g.new_plugin(name)
    end

    private

    attr_reader :task

    def exec_action(action)
      @task = action
      result = parse_subcommand(args[0], args[1])
      Array(result).each { |instance| instance.send(task) }
    end

    def parse_subcommand(name_or_all, regexp)
      if name_or_all.nil? || (name_or_all == "all" && regexp.nil?)
        get_all_instances
      elsif name_or_all == "all" && regexp
        get_filtered_instances(regexp)
      elsif name_or_all != "all" && regexp.nil?
        get_instance(name_or_all)
      else
        die task, "Invalid invocation."
      end
    end

    def get_all_instances
      result = @config.instances
      if result.empty?
        die task, "No instances defined"
      else
        result
      end
    end

    def get_filtered_instances(regexp)
      result = @config.instances.get_all(/#{regexp}/)
      if result.empty?
        die task, "No instances for regex `#{regexp}', try running `jamie list'"
      else
        result
      end
    end

    def get_instance(name)
      result = @config.instances.get(name)
      if result.nil?
        die task, "No instance `#{name}', try running `jamie list'"
      end
      result
    end

    def die(task, msg)
      error "\n#{msg}\n\n"
      help(task)
      exit 1
    end

    def pry_prompts
      [ proc { |target_self, nest_level, pry|
          [ "[#{pry.input_array.size}] ",
            "jc(#{Pry.view_clip(target_self.class)})",
            "#{":#{nest_level}" unless nest_level.zero?}> "
          ].join
        },
        proc { |target_self, nest_level, pry|
          [ "[#{pry.input_array.size}] ",
            "jc(#{Pry.view_clip(target_self.class)})",
            "#{":#{nest_level}" unless nest_level.zero?}* "
          ].join
        }
      ]
    end
  end

  # A project initialization generator, to help prepare a cookbook project for
  # testing with Jamie.
  class InitGenerator < Thor

    include Thor::Actions

    desc "init", "Adds some configuration to your cookbook so Jamie can rock"
    def init
      create_file ".jamie.yml", default_yaml
      append_to_file("Rakefile", <<-RAKE.gsub(/ {8}/, '')) if init_rakefile?

        begin
          require 'jamie/rake_tasks'
          Jamie::RakeTasks.new
        rescue LoadError
          puts ">>>>> Jamie gem not loaded, omitting tasks" unless ENV['CI']
        end
      RAKE
      append_to_file("Thorfile", <<-THOR.gsub(/ {8}/, '')) if init_thorfile?

        begin
          require 'jamie/thor_tasks'
          Jamie::ThorTasks.new
        rescue LoadError
          puts ">>>>> Jamie gem not loaded, omitting tasks" unless ENV['CI']
        end
      THOR
      empty_directory "test/integration/standard" if init_test_dir?
      append_to_gitignore(".jamie/")
      append_to_gitignore(".jamie.local.yml")
      add_plugins
    end

    private

    def default_yaml
      url_base = "https://opscode-vm.s3.amazonaws.com/vagrant/boxes"
      platforms = [
        { :n => 'ubuntu', :vers => %w(12.04 10.04), :rl => "recipe[apt]" },
        { :n => 'centos', :vers => %w(6.3 5.8), :rl => "recipe[yum::epel]" }
      ]
      platforms = platforms.map do |p|
        p[:vers].map do |v|
          { 'name' => "#{p[:n]}-#{v}",
            'driver_config' => {
              'box' => "opscode-#{p[:n]}-#{v}",
              'box_url' => "#{url_base}/opscode-#{p[:n]}-#{v}.box"
            },
            'run_list' => Array(p[:rl])
          }
        end
      end.flatten
      cookbook_name = MetadataChopper.extract('metadata.rb').first
      run_list = cookbook_name ? "recipe[#{cookbook_name}]" : nil
      attributes = cookbook_name ? { cookbook_name => nil } : nil

      { 'default_driver' => 'vagrant',
        'platforms' => platforms,
        'suites' => [
          { 'name' => 'standard',
            'run_list' => Array(run_list),
            'attributes' => attributes
          }
        ]
      }.to_yaml
    end

    def init_rakefile?
      File.exists?("Rakefile") &&
        IO.readlines("Rakefile").grep(%r{require 'jamie/rake_tasks'}).empty?
    end

    def init_thorfile?
      File.exists?("Thorfile") &&
        IO.readlines("Thorfile").grep(%r{require 'jamie/thor_tasks'}).empty?
    end

    def init_test_dir?
      Dir.glob("test/integration/*").select { |d| File.directory?(d) }.empty?
    end

    def append_to_gitignore(line)
      create_file(".gitignore") unless File.exists?(".gitignore")

      if IO.readlines(".gitignore").grep(%r{^#{line}}).empty?
        append_to_file(".gitignore", "#{line}\n")
      end
    end

    def add_plugins
      prompt_add  = "Add a Driver plugin to your Gemfile? (y/n)>"
      prompt_name = "Enter gem name, `list', or `skip'>"

      if yes?(prompt_add, :green)
        list_plugins while (plugin = ask(prompt_name, :green)) == "list"
        return if plugin == "skip"
        append_to_file("Gemfile", %{gem '#{plugin}', :group => :integration\n})
        say "You must run `bundle install' to fetch any new gems.", :red
      end
    end

    def list_plugins
      specs = fetch_gem_specs.map { |t| t.first }.map { |t| t[0, 2] }.
        sort { |x,y| x[0] <=> y[0] }
      specs = specs[0, 49].push(["...", "..."]) if specs.size > 49
      specs = specs.unshift(["Gem Name", "Latest Stable Release"])
      print_table(specs, :indent => 4)
    end

    def fetch_gem_specs
      require 'rubygems/spec_fetcher'
      req = Gem::Requirement.default
      dep = Gem::Deprecate.skip_during { Gem::Dependency.new(/jamie-/i, req) }
      fetcher = Gem::SpecFetcher.fetcher

      specs = fetcher.find_matching(dep, false, false, false)
    end

    # A rather insane and questionable class to quickly consume a metadata.rb
    # file and return the cookbook name and version attributes.
    #
    # @see https://twitter.com/fnichol/status/281650077901144064
    # @see https://gist.github.com/4343327
    class MetadataChopper < Hash

      # Return an Array containing the cookbook name and version attributes,
      # or nil values if they could not be parsed.
      #
      # @param metadata_file [String] path to a metadata.rb file
      # @return [Array<String>] array containing the cookbook name and version
      #   attributes or nil values if they could not be determined
      def self.extract(metadata_file)
        mc = new(File.expand_path(metadata_file))
        [ mc[:name], mc[:version] ]
      end

      # Creates a new instances and loads in the contents of the metdata.rb
      # file. If you value your life, you may want to avoid reading the
      # implementation.
      #
      # @param metadata_file [String] path to a metadata.rb file
      def initialize(metadata_file)
        eval(IO.read(metadata_file), nil, metadata_file)
      end

      def method_missing(meth, *args, &block)
        self[meth] = args.first
      end
    end
  end

  # A generator to create a new Jamie driver plugin.
  class NewPluginGenerator < Thor

    include Thor::Actions

    desc "new_plugin [NAME]", "Generate a new Jamie Driver plugin gem project"
    method_option :license, :aliases => "-l", :default => "apachev2",
      :desc => "Type of license for gem (apachev2, mit, gplv3, gplv2, reserved)"
    def new_plugin(plugin_name)
      if ! run("command -v bundle", :verbose => false)
        die "Bundler must be installed and on your PATH: `gem install bundler'"
      end

      @plugin_name = plugin_name
      @gem_name = "jamie-#{plugin_name}"
      @gemspec = "#{gem_name}.gemspec"
      @klass_name = Util.to_camel_case(plugin_name)
      @constant = Util.to_snake_case(plugin_name).upcase
      @license = options[:license]
      @author = %x{git config user.name}.chomp
      @email = %x{git config user.email}.chomp
      @year = Time.now.year

      create_plugin
    end

    private

    attr_reader :plugin_name, :gem_name, :gemspec, :klass_name,
                :constant, :license, :author, :email, :year

    def create_plugin
      run("bundle gem #{gem_name}") unless File.directory?(gem_name)

      inside(gem_name) do
        update_gemspec
        update_gemfile
        update_rakefile
        create_src_files
        cleanup
        create_license
        add_git_files
      end
    end

    def update_gemspec
      gsub_file(gemspec, %r{require '#{gem_name}/version'},
        %{require 'jamie/driver/#{plugin_name}_version.rb'})
      gsub_file(gemspec, %r{Jamie::#{klass_name}::VERSION},
        %{Jamie::Driver::#{constant}_VERSION})
      gsub_file(gemspec, %r{(gem\.executables\s*) =.*$},
        '\1 = []')
      gsub_file(gemspec, %r{(gem\.description\s*) =.*$},
        '\1 = "' + "Jamie::Driver::#{klass_name} - " +
        "A Jamie Driver for #{klass_name}\"")
      gsub_file(gemspec, %r{(gem\.summary\s*) =.*$},
        '\1 = gem.description')
      gsub_file(gemspec, %r{(gem\.homepage\s*) =.*$},
        '\1 = "https://github.com/jamie-ci/' +
        "#{gem_name}/\"")
      insert_into_file(gemspec,
        "\n  gem.add_dependency 'jamie'\n", :before => "end\n")
      insert_into_file(gemspec,
        "\n  gem.add_development_dependency 'cane'\n", :before => "end\n")
      insert_into_file(gemspec,
        "  gem.add_development_dependency 'tailor'\n", :before => "end\n")
    end

    def update_gemfile
      append_to_file("Gemfile", "\ngroup :test do\n  gem 'rake'\nend\n")
    end

    def update_rakefile
      append_to_file("Rakefile", <<-RAKEFILE.gsub(/^ {8}/, ''))
        require 'cane/rake_task'
        require 'tailor/rake_task'

        desc "Run cane to check quality metrics"
        Cane::RakeTask.new

        Tailor::RakeTask.new

        task :default => [ :cane, :tailor ]
      RAKEFILE
    end

    def create_src_files
      license_comments = rendered_license.gsub(/^/, '# ').gsub(/\s+$/, '')

      empty_directory("lib/jamie/driver")
      create_template("plugin/version.rb",
        "lib/jamie/driver/#{plugin_name}_version.rb",
        :klass_name => klass_name, :constant => constant,
        :license => license_comments)
      create_template("plugin/driver.rb",
        "lib/jamie/driver/#{plugin_name}.rb",
        :klass_name => klass_name, :license => license_comments)
    end

    def rendered_license
      TemplateRenderer.render("plugin/license_#{license}",
        :author => author, :email => email, :year => year)
    end

    def create_license
      dest_file = case license
      when "mit" then "LICENSE.txt"
      when "apachev2", "reserved" then "LICENSE"
      when "gplv2", "gplv3" then "COPYING"
      else
        raise ArgumentError, "No such license #{license}"
      end

      create_file(dest_file, rendered_license)
    end

    def cleanup
      %W(LICENSE.txt lib/#{gem_name}/version.rb lib/#{gem_name}.rb).each do |f|
        run("git rm -f #{f}") if File.exists?(f)
      end
      remove_dir("lib/#{gem_name}")
    end

    def add_git_files
      run("git add .")
    end

    def create_template(template, destination, data = {})
      create_file(destination, TemplateRenderer.render(template, data))
    end

    # Renders an ERB template with a hash of template variables.
    class TemplateRenderer < OpenStruct

      def self.render(template, data = {})
        renderer = new(template, data)
        yield renderer if block_given?
        renderer.render
      end

      def initialize(template, data = {})
        super()
        data[:template] = template
        data.each { |key, value| send("#{key}=", value) }
      end

      def render
        ERB.new(IO.read(template_file)).result(binding)
      end

      private

      def template_file
        Jamie.source_root.join("templates", "#{template}.erb").to_s
      end
    end
  end
end
