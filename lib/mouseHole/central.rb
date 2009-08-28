require 'fileutils'
require 'mouseHole/page'

module MouseHole

  class Central

    attr_accessor :sandbox, :logger, :proxy_host, :proxy_port

    def initialize(server, options)
      @server = server
      options.each do |k, v|
        if respond_to? "#{k}="
          send("#{k}=", v) 
        end
      end

      # add MouseHole hosts entries
      DOMAINS.each do |domain|
        HOSTS[domain] = "#{ options.host }:#{ options.port }"
      end

      # built-in applications
      @apps = {'$INSTALLER' => InstallerApp.new(@server)}
      # user-specific directories and utilities
      @etags, @sandbox = {}, {}
      @working_dir = options.working_dir
      @dir = options.mouse_dir
      FileUtils.mkdir_p( @dir )
      @started = Time.now

      # connect to the database, get some data
      ActiveRecord::Base.establish_connection options.database
      ActiveRecord::Base.logger = options.logger
      MouseHole.create
      # load_conf

      # read user apps on startup
      @last_refresh = Time.now
      @min_interval = 5.seconds
      load_all_apps :force
    end

    def user_apps
      @apps.reject { |rb,| rb =~ /^\$/ }
    end

    def load_all_apps action = nil
      apps = self.user_apps.keys + Dir["#{ @dir }/*.rb"].map { |rb| File.basename(rb) }
      apps.uniq!

      apps.each do |rb|
        path = File.join(@dir, rb)
        unless File.exists? path
          @apps.delete(rb) 
          next
        end
        unless action == :force
          next if @apps[rb] and File.mtime(path) <= @apps[rb].mtime
        end
        load_app rb
      end
    end

    def save_app url, full_script
      rb = File.basename(url)
      path = File.join(@dir, rb)
      open(path, 'w') do |f|
        f << full_script
      end
      Models::App.create(:script => rb, :uri => url)
      load_app rb
    end

    def load_app rb
      return @apps[rb] if rb =~ /^\$/
      if @apps.has_key? rb
        @apps[rb].unload(@server)
      end
      path = File.join(@dir, rb)
      app = @apps[rb] = App.load(@server, rb, path)
      app.mtime = File.mtime(path)
      app
    end

    def refresh_apps
      return if Time.now - @last_refresh < @min_interval
      load_all_apps
    end

    def find_rewrites page
      refresh_apps
      @apps.values.find_all do |app|
        app.rewrites? page
      end
    end

    def rewrite(page, resin)
      apps = find_rewrites(page)
      return false if apps.empty?

      if page.decode(resin)
        apps.each do |app|
          app.do_rewrite(page)
        end
      end
      true
    end
   
    def app_list
      refresh_apps
      self.user_apps.values
    end

    def find_app crit
      case crit
      when String
        self.user_apps[crit]
      when Hash
        (self.user_apps.detect { |name, app|
          crit.all? { |k,v| app.send(k) == v }
        } || []).last
      end
    end

    def doorblocks
      app_list.inject([]) do |ary, app|
        app.doorblock_classes.each do |k|
          ary << [app, k]
        end
        ary
      end
    end

  end

end
