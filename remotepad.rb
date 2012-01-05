require 'bundler/setup'
require 'goliath'
require 'goliath/websocket'
require 'set'
require 'json'

SLAVES = Set.new
MASTERS = Set.new

class SlaveEndpoint < Goliath::WebSocket
  def on_open(env)
    puts "slave open"
    SLAVES << env.handler
  end

  def on_close(env)
    puts "slave close"
    SLAVES.delete(env.handler)
  end

  def on_message(env, msg)
    return if msg==''
    puts "slave msg #{msg}"
    MASTERS.each do |master|
      master.send_text_frame(msg)
    end
  end
end

class MasterEndpoint < Goliath::WebSocket
  def on_open(env)
    puts "master open"
    MASTERS << env.handler
  end

  def on_close(env)
    puts "master close"
    MASTERS.delete env.handler
  end

  def on_message(env, msg)
    obj = JSON.parse(msg)
    return if obj.empty?
    puts "master msg #{msg}"
    SLAVES.each do |slave|
      slave.send_text_frame msg
    end
  end
end

class MasterWebapp < Goliath::API
  use Rack::Static, :root => 'public', :urls => ['/slave.html', '/js']

  map '/mws', MasterEndpoint
  map '/sws', SlaveEndpoint

  def response(env)
    [404, {}, env.inspect]
  end
end