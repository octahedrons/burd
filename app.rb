require 'guillotine'
require 'redis'

module Katana
    class App < Guillotine::App
      # use redis adapter with redistogo
      if ENV["REDIS_URL"]
        uri = URI.parse(ENV["REDIS_URL"])
        redis_options = {
          host: uri.host,
          port: uri.port,
          password: uri.password,
          reconnect_attempts: (1..10).to_a,
        }
        REDIS = Redis.new(redis_options)
      else
        REDIS = Redis.new
      end
      adapter = Guillotine::RedisAdapter.new REDIS
      set :service => Guillotine::Service.new(adapter, :strip_query => false,
                                              :strip_anchor => false)

      # authenticate everything except GETs
      before do
        unless request.request_method == "GET"
          params[:code] = nil if params[:code] == ""
          protected!
        end
      end

      get '/' do
        "Shorten all the URLs"
      end

      get '/all' do
        protected!

        code_and_urls = REDIS
          .scan_each(match: "guillotine:hash:*")
          .map do |key|
            code = key.split(":").last
            url  = REDIS.get(key)

            [code, url]
          end
          .to_h
          .sort_by { |code, _url| code }

        html =<<~HTML
        <html>
          <head>
            <title>burd urls</title>
          </head>
          <body>
            <pre>
        #{code_and_urls.map { |code, url| "#{code} => <a href='#{url}'>#{url}</a>" }.join("\n")}
            </pre>
          </body>
        </html>
        HTML

        if cli_agent?
          headers \
            "content-type" => "text/plain"
          body code_and_urls.map { |code, url| "#{code} => #{url}" }.join("\n")
        else
          body html
        end
      end

      if ENV['TWEETBOT_API']
        # experimental (unauthenticated) API endpoint for tweetbot
        get '/api/create/?' do
          params[:code] = nil if params[:code] == ""
          status, head, body = settings.service.create(params[:url], params[:code])

          if loc = head['Location']
            "#{File.join(request.scheme, request.host, loc)}"
          else
            500
          end
        end
      end

      # helper methods
      helpers do
        def cli_agent?
          agents = %w[
            curl
            wget
          ]
          agents.any? { |agent| request.user_agent.include?(agent) }
        end

        # Private: helper method to protect URLs with Rack Basic Auth
        #
        # Throws 401 if authorization fails
        def protected!
          return unless ENV["HTTP_USER"]
          unless authorized?
            response['WWW-Authenticate'] = %(Basic realm="Restricted Area")
            throw(:halt, [401, "Not authorized\n"])
          end
        end

        # Private: helper method to check if authorization parameters match the
        # set environment variables
        #
        # Returns true or false
        def authorized?
          @auth ||=  Rack::Auth::Basic::Request.new(request.env)
          user = ENV["HTTP_USER"]
          pass = ENV["HTTP_PASS"]
          @auth.provided? && @auth.basic? && @auth.credentials && @auth.credentials == [user, pass]
        end
      end

    end
end
