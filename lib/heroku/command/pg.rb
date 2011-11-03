require "heroku/command/base"
require "heroku/pgutils"
require "heroku/pg_resolver"
require "heroku-postgresql/client"
require "heroku-shared-postgresql/client"

module Heroku::Command
  # manage heroku postgresql databases
  class Pg < BaseWithApp
    include PgUtils
    include PGResolver

    # pg:info [DATABASE]
    #
    # display database information
    #
    # defaults to all databases if no DATABASE is specified
    #
    def info
      specified_db_or_all { |db| display_db_info db }
    end

    # pg:ingress [DATABASE]
    #
    # allow direct connections to the database from this IP for one minute
    #
    # (dedicated only)
    # defaults to DATABASE_URL databases if no DATABASE is specified
    #
    def ingress
      deprecate_dash_dash_db("pg:ingress")
      abort " !  Temporary ingress is not available for #{db[:name]}, try `pg:psql` instead" if db[:name] == Resolver.shared_addon_prefix
      uri = generate_ingress_uri("Granting ingress for 60s")
      display "Connection info string:"
      display "   \"dbname=#{uri.path[1..-1]} host=#{uri.host} user=#{uri.user} password=#{uri.password} sslmode=required\""
    end

    # pg:promote <DATABASE>
    #
    # sets DATABASE as your DATABASE_URL
    #
    def promote
      deprecate_dash_dash_db("pg:promote")
      follower_db = resolve_db(:required => 'pg:promote')
      abort( " !   DATABASE_URL is already set to #{follower_db[:name]}") if follower_db[:default]

      working_display "-----> Promoting #{follower_db[:name]} to DATABASE_URL" do
        heroku.add_config_vars(app, {"DATABASE_URL" => follower_db[:url]})
      end
    end

    # pg:psql [DATABASE]
    #
    # open a psql shell to the database
    #
    # (dedicated only)
    # defaults to DATABASE_URL databases if no DATABASE is specified
    #
    def psql
      deprecate_dash_dash_db("pg:psql")
      uri = generate_ingress_uri("Connecting")
      ENV["PGPASSWORD"] = uri.password
      ENV["PGSSLMODE"]  = 'require'
      begin
        exec "psql -U #{uri.user} -h #{uri.host} -p #{uri.port || 5432} #{uri.path[1..-1]}"
      rescue Errno::ENOENT
        display " !   The local psql command could not be located"
        display " !   For help installing psql, see http://devcenter.heroku.com/articles/local-postgresql"
        abort
      end
    end

    # pg:reset <DATABASE>
    #
    # delete all data in DATABASE
    def reset
      deprecate_dash_dash_db("pg:reset")
      db = resolve_db(:required => 'pg:reset')

      display "Resetting #{db[:pretty_name]}"
      return unless confirm_command

      working_display 'Resetting' do
        case db[:name]
        when Resolver.shared_addon_prefix
          display " getting new database credentials...", false
          response = heroku_shared_postgresql_client(db[:url]).reset_database
          detected_app = app
          heroku.add_config_vars(detected_app, response)
          display " done", false

          begin
            release = heroku.releases(detected_app).last
            display(", #{release["name"]}", false) if release
          rescue RestClient::RequestFailed => e
          end
          display "."
        when "SHARED_DATABASE"
          heroku.database_reset(app)
        else
          heroku_postgresql_client(db[:url]).reset
        end
      end
    end

    # pg:reset_password <DATABASE>
    #
    # Reset the password on the database
    #
    def reset_password
      db = resolve_db
      display "Resetting password on #{db[:pretty_name]}"
      return unless confirm_command
      working_display 'Resetting password' do
        case db[:name]
        when "SHARED_DATABASE"
          display " !    Resetting password is not supported on SHARED_DATABASE"
        when Resolver.shared_addon_prefix
          response = heroku_shared_postgresql_client(db[:url]).reset_password
          detected_app = app
          display "Setting new password...", false
          heroku.add_config_vars(detected_app, response)
          display " done", false
          begin
            release = heroku.releases(detected_app).last
            display(", #{release["name"]}", false) if release
          rescue RestClient::RequestFailed => e
          end
          display "."
        else
          display " !    Resetting password is not yet supported on #{db[:name]}"
        end
      end
    end

    # pg:unfollow <REPLICA>
    #
    # stop a replica from following and make it a read/write database
    #
    def unfollow
      follower_db = resolve_db(:required => 'pg:unfollow')

      if ["SHARED_DATABASE", Resolver.shared_addon_prefix].include? follower_db[:name]
        abort " !    #{follower_db[:name]} does not support forking and following."
      end

      follower_name = follower_db[:pretty_name]
      follower_db_info = heroku_postgresql_client(follower_db[:url]).get_database
      origin_db_url = follower_db_info[:following]

      unless origin_db_url
        display " !    #{follower_name} is not following another database"
        return
      end

      origin_name = name_from_url(origin_db_url)

      display " !    #{follower_name} will become writable and no longer"
      display " !    follow #{origin_name}. This cannot be undone."
      return unless confirm_command

      working_display "Unfollowing" do
        heroku_postgresql_client(follower_db[:url]).unfollow
      end
    end

    # pg:wait [DATABASE]
    #
    # monitor database creation, exit when complete
    #
    # defaults to all databases if no DATABASE is specified
    #
    def wait
      specified_db_or_all { |db| wait_for db }
    end

private

    def working_display(msg)
      redisplay "#{msg}..."
      yield if block_given?
      redisplay "#{msg}... done\n"
    end

    def heroku_postgresql_client(url)
      HerokuPostgresql::Client.new(url)
    end

    def heroku_shared_postgresql_client(url)
      HerokuSharedPostgresql::Client.new(url)
    end

    def wait_for(db)
      return if ["SHARED_DATABASE", Resolver.shared_addon_prefix].include? db[:name]

      ticking do |ticks|
        wait_status = heroku_postgresql_client(db[:url]).get_wait_status
        break if !wait_status[:waiting?] && ticks == 0
        redisplay("Waiting for database %s... %s%s" % [
                    db[:pretty_name],
                    wait_status[:waiting?] ? "#{spinner(ticks)} " : "",
                    wait_status[:message]],
                  !wait_status[:waiting?]) # only display a newline on the last tick
        break unless wait_status[:waiting?]
      end
    end

    def display_db_info(db)
      display("=== #{db[:pretty_name]}")
      case db[:name]
      when "SHARED_DATABASE"
        display_info_shared
      when Resolver.shared_addon_prefix
        display_info_shared_postgresql(db)
      else
        display_info_dedicated(db)
      end
    end

    def display_info_shared
      attrs = heroku.info(app)
      display_info("Data Size", "#{format_bytes(attrs[:database_size].to_i)}")
    end

    def display_info_shared_postgresql(db)
      response = heroku_shared_postgresql_client(db[:url]).show_info
      response.each do |key, value|
        display " #{key.gsub('_', ' ').capitalize}: #{value ? value : 0}"
      end
    end

    def display_info_dedicated(db)
      db_info = heroku_postgresql_client(db[:url]).get_database

      db_info[:info].each do |i|
        if i['value']
          val = i['resolve_db_name'] ? name_from_url(i['value']) : i['value']
          display_info i['name'], val
        elsif i['values']
          i['values'].each_with_index do |val,idx|
            name = idx.zero? ? i['name'] : nil
            val = i['resolve_db_name'] ? name_from_url(val) : val
            display_info name, val
          end
        end
      end
    end

    def generate_ingress_uri(action)
      db = resolve_db(:allow_default => true)
      case db[:name]
      when "SHARED_DATABASE"
        abort " !  Cannot ingress to a shared database" if "SHARED_DATABASE" == db[:name]
      when Resolver.shared_addon_prefix
        working_display("#{action} to #{db[:name]}")
        return URI.parse(db[:url])
      else
        hpc = heroku_postgresql_client(db[:url])
        abort " !  The database is not available for ingress" unless hpc.get_database[:available_for_ingress]
        working_display("#{action} to #{db[:name]}") { hpc.ingress }
        return URI.parse(db[:url])
      end
    end

    def display_progress(progress, ticks)
      progress ||= []
      new_progress = ((progress || []) - (@seen_progress || []))
      if !new_progress.empty?
        new_progress.each { |p| display_progress_part(p, ticks) }
      elsif !progress.empty? && progress.last[0] != "finish"
        display_progress_part(progress.last, ticks)
      end
      @seen_progress = progress
    end

  end
end
