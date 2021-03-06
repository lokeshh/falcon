# Copyright, 2017, by Samuel G. D. Williams. <http://www.codeotaku.com>
# 
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
# 
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
# 
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.

require_relative 'input'
require_relative 'response'

require 'async/logger'

module Falcon
	module Adapters
		class Rack
			def initialize(app, logger = Async.logger)
				@app = app
				
				@logger = logger
			end
			
			# Rack separates multiple headers with the same key, into a single field with multiple "lines".
			def unwrap_headers(headers, env)
				headers.each do |key, value|
					http_key = "HTTP_#{key.upcase.tr('-', '_')}"
					
					if current_value = env[http_key]
						env[http_key] = "#{current_value}\n#{value}"
					else
						env[http_key] = value
					end
				end
			end
			
			def call(request)
				request_path, query_string = request.path.split('?', 2)
				server_name, server_port = (request.authority || '').split(':', 2)
				
				env = {
					'rack.version' => [2, 0, 0],
					
					'rack.input' => Input.new(request.body),
					'rack.errors' => $stderr,
					
					'rack.multithread' => true,
					'rack.multiprocess' => true,
					'rack.run_once' => false,
					
					# The HTTP request method, such as “GET” or “POST”. This cannot ever be an empty string, and so is always required.
					'REQUEST_METHOD' => request.method,
					
					# The initial portion of the request URL's “path” that corresponds to the application object, so that the application knows its virtual “location”. This may be an empty string, if the application corresponds to the “root” of the server.
					'SCRIPT_NAME' => '',
					
					# The remainder of the request URL's “path”, designating the virtual “location” of the request's target within the application. This may be an empty string, if the request URL targets the application root and does not have a trailing slash. This value may be percent-encoded when originating from a URL.
					'PATH_INFO' => request_path,
					
					# The portion of the request URL that follows the ?, if any. May be empty, but is always required!
					'QUERY_STRING' => query_string || '',
					
					# The server protocol, e.g. HTTP/1.1
					'SERVER_PROTOCOL' => request.version,
					'rack.url_scheme' => 'http',
					
					# I'm not sure what sane defaults should be here:
					'SERVER_NAME' => server_name || '',
					'SERVER_PORT' => server_port || '',
				}
				
				if content_type = request.headers.delete('content-type')
					env['CONTENT_TYPE'] = content_type
				end
				
				if content_length = request.headers.delete('content-length')
					env['CONTENT_LENGTH'] = content_length
				end
				
				self.unwrap_headers(request.headers, env)
				
				# HTTP/2 prefers `:authority` over `host`, so we do this for backwards compatibility.
				env['HTTP_HOST'] ||= request.authority
				
				if remote_address = request.remote_address
					env['REMOTE_ADDR'] = remote_address.ip_address if remote_address.ip?
				end
				
				if request.hijack?
					env['rack.hijack?'] = true
					
					env['rack.hijack'] = lambda do
						wrapper = request.hijack
						
						# We dup this as it might be taken out of the normal control flow, and the io will be closed shortly after returning from this method.
						io = wrapper.io.dup
						wrapper.close
						
						env['rack.hijack_io'] = io
					end
				else
					env['rack.hijack?'] = false
				end
				
				status, headers, body = @app.call(env)
				
				# if hijack = headers.delete('rack.hijack')
				# 	body = Async::HTTP::Body::Writable.new
				# 
				# 	Task.current.async do
				# 		hijack.call(body)
				# 	end
				# 	return nil
				# end
				
				# if env['rack.hijack_io']
				# 	return nil
				# end
				
				@logger.debug(request) {"Rack response: #{status} #{headers.inspect} #{body.class}"}
				return Response.wrap(status, headers, body)
			rescue => exception
				@logger.error "#{exception.class}: #{exception.message}\n\t#{$!.backtrace.join("\n\t")}"
				
				return failure_response(exception)
			end
			
			def failure_response(exception)
				Async::HTTP::Response.for_exception(exception)
			end
		end
	end
end
