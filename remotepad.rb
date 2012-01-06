require 'bundler/setup'
require 'goliath'
require 'goliath/websocket'
require 'em-http'
require 'em-synchrony/em-http'
require 'nokogiri'
require 'set'
require 'json'
require 'yaml'
require 'pp'

SLAVES = Set.new
MASTERS = Set.new
MAP = {} # map of url => local url
RMAP = {} # reverse map: local url => url

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
    @url_id = 0
    MASTERS << env.handler
  end

  def on_close(env)
    puts "master close"
    MASTERS.delete env.handler
  end

  def on_message(env, msg)
    obj = JSON.parse(msg)
    return if obj.empty?
    # puts "master msg #{msg}"
    if obj['src'] && obj['url']
      obj['src'] = transform_and_map(obj['url'], obj['src'])
    end
    SLAVES.each do |slave|
      slave.send_text_frame(obj.to_json)
    end
  end

  def transform_and_map(url, html)
    uri = URI.parse(url)
    str = "<!DOCTYPE html>\n<html>\n#{html}\n</html>"
    puts "input:"
    puts str[0..600]
    doc = Nokogiri::HTML(str)
    base = get_base(url)
    base_el = doc.css('base')
    base_el.each do |el|
      base = el['href']
      el['href'] = 'http://james02:9000/'
    end
    
    %w(href src).each do |att|
      doc.css("*[#{att}]").each do |el|
        next if el.name == 'a'
        old = el[att]
        el.attribute(att).value = translate(old, base)
      end
    end

    doc.css("*[onclick]").each do |el|
      el['onclick'] = ''
    end

    {'head'=>doc.css('html>head').inner_html,'body'=>doc.css('html>body').inner_html}
  end

  def get_base(url)
    url.sub(/\?.*/, '').sub(/(.*\/).*/, '\1')
  end

  def translate(url, base)
    return url if url =~ /^data:/
    unless url =~ /^http[s]:\/\//
      if url =~ /^\//
        # absolute path. only prepend the protocol and host.
        url = "#{base.sub(/(^https?:\/\/[^\/]*)\/.*$/, '\1')}#{url}"
      else 
        # relative path. prepend the protocol, host and base directory.
        url = "#{base}#{url}" 
      end
    end
    return MAP[url] if MAP[url]
    @url_id += 1

    "/resource/#{@url_id}".tap do |local_url|
      MAP[url] = local_url
      RMAP[local_url] = url
    end
  end
end

class EvilProxy < Goliath::API
  def response(env)
    if env['PATH_INFO']=='/map'
      return [200, {'Content-Type'=>'text/plain'}, MAP.to_yaml]
    end
    if env['PATH_INFO']=='/rmap'
      return [200, {'Content-Type'=>'text/plain'}, RMAP.to_yaml]
    end
    resource_id = env['PATH_INFO'].sub(/^\//, '').to_i
    return [404, {}, 'not found'] if resource_id < 1
    url = RMAP["/resource/#{resource_id}"]
    if url == '' || url.nil?
      pp RMAP
    end
    req = EM::HttpRequest.new(url)
    status = 302
    while status == 302
      resp = req.get({:query=>env.params})
      status = resp.response_header.status.to_i
      response_headers = {}
      resp.response_header.each_pair do |k,v|
        response_headers[to_http_header(k)] = v
      end
      if status == 302
        url = response_headers['Location']
      elsif status != 200
        puts "**** FAIL"
        puts url
        puts resp.response_header.status
        pp response_headers
        puts "**** /FAIL"
      end
    end
    [resp.response_header.status, response_headers, resp.response]
  end
  def to_http_header(k)
    k.downcase.split('_').map{|i|i.capitalize}.join('-')
  end
end

class MasterWebapp < Goliath::API
  use Rack::Static, :root => 'public', :urls => ['/slave.html', '/chromeext.crx', '/empty.html']

  map '/mws', MasterEndpoint
  map '/sws', SlaveEndpoint
  map '/resource/*', EvilProxy

  def response(env)
    [404, {}, env.inspect]
  end
end
