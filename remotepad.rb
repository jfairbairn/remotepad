require 'bundler/setup'
require 'goliath'
require 'goliath/websocket'
require 'em-http'
require 'em-synchrony/em-http'
require 'nokogiri'
require 'set'
require 'yajl'
require 'yaml'
require 'pp'

SLAVES = Set.new unless defined? SLAVES
MASTERS = Set.new unless defined? MASTERS
MAP = {} unless defined? MAP # map of url => local url
RMAP = {} unless defined? RMAP# reverse map: local url => url

class SlaveEndpoint < Goliath::WebSocket
  def on_open(env)
    puts "slave open"
    SLAVES << env['handler']
  end

  def on_close(env)
    puts "slave close"
    SLAVES.delete(env['handler'])
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
    MASTERS << env['handler']
  end

  def on_close(env)
    puts "master close"
    MASTERS.delete env['handler']
  end

  def on_message(env, msg)
    msg ||= '{}'
    # puts msg
    obj = Yajl.load(msg)
    return if obj.empty?
    # puts "master msg #{msg}"
    if (src = obj.delete('src')) && url = obj.delete('url')
      host = env['HTTP_HOST']
      obj['url'] = "http://#{host}/doc/#{DocumentCache.add(transform_and_map(url, src, host))}"
    end
    SLAVES.each do |slave|
      msg = Yajl.dump(obj)
      msg.force_encoding 'UTF-8'
      slave.send_text_frame(msg)
    end
  end

  def transform_and_map(url, html, host)
    uri = URI.parse(url)
    str = "<!DOCTYPE html>\n<html>\n#{html}\n</html>"
    doc = Nokogiri::HTML(str)
    base = get_base(url)
    %w(href src).each do |att|
      doc.css("*[#{att}]").each do |el|
        next if el.name == 'a'
        old = el[att]
        el.attribute(att).value = translate(old, base, host)
      end
    end

    base_el = doc.css('base')
    base_el.each do |el|
      base = el['href']
      el['href'] = "http://#{uri.host}:#{uri.port}/"
    end

    if base_el.empty?
      doc.css('head').each do |head_el|
        child = head_el.first_element_child
        newel = "<base href=\"http://#{uri.host}:#{uri.port}\">"
        if child
          child.add_previous_sibling(newel)
        else
          head_el.add_child(newel)
        end
      end
    end

   doc.css("*[onclick]").each do |el|
      el['onclick'] = ''
    end

    doc.to_html

    #{'head'=>doc.css('html>head').inner_html,'body'=>doc.css('html>body').inner_html}
  end

  def get_base(url)
    url.sub(/\?.*/, '').sub(/(.*\/).*/, '\1')
  end

  def translate(url, base, host)
    return url if url =~ /^data:/
    parsed = URI.parse(url)
    old_url = url
    if url =~ /^\/\//
      url = "#{parsed.scheme}:#{url}"
    end
    if url !~ /^https?:\/\//
      if url =~ /^\//
        # absolute path. only prepend the protocol and host.
        url = "#{base.sub(/^(https?:\/\/[^\/]*)\/.*$/, '\1')}#{url}"
      else 
        # relative path. prepend the protocol, host and base directory.
        url = "#{base}#{url}" 
      end
    end
    #puts "*** #{old_url} -> #{url}"
    return MAP[url] if MAP[url]
    @url_id += 1

    "http://#{host}/resource/#{@url_id}".tap do |local_url|
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
    url = RMAP["http://#{env['HTTP_HOST']}/resource/#{resource_id}"]
    return not_found(url) if resource_id < 1
    # if url == '' || url.nil?
    #   pp RMAP
    # end
    # puts url, resource_id
    req = EM::HttpRequest.new(url)
    status = 302
    redirect_count = 0
    req_hdrs = env.reject{|k,v| k !~ /^HTTP_/}
    req_headers = {}
    req_hdrs.each do |k,v|
      next if %w(
        HTTP_ACCEPT_ENCODING HTTP_HOST HTTP_IF_MODIFIED_SINCE HTTP_IF_NONE_MATCH
      ).member? k
      req_headers[to_http_header(k)] = v
    end
    while [302, 301].member?(status) && redirect_count < 5
      opts = {:query=>env.params, :head=>req_headers}
      resp = req.get(opts)
      status = resp.response_header.status.to_i
      response_headers = {}
      resp.response_header.each_pair do |k,v|
        next if to_http_header(k) == 'Connection'
        next if to_http_header(k) == 'Transfer-Encoding' && v == 'chunked'
        response_headers[to_http_header(k)] = v
      end
      if status == 302
        url = response_headers['Location']
        redirect_count += 1
        puts "redirected to #{url}"
      elsif status != 200
        puts "**** FAIL"
        puts url
        pp req_headers.reject{|k,v|k=='Cookie'}
        puts status
        pp response_headers
        puts "redirect_count: #{redirect_count}"
        puts "**** /FAIL"
      end
    end
    response_headers['X-Remotepad-URL'] = url
    response_headers['Cache-Control'] = 'no-cache' #for now
    [resp.response_header.status, response_headers, resp.response]
  end

  def not_found(url)
    [404, {}, 'not found']
  end

  def to_http_header(k)
    k.sub(/^HTTP_/, '').downcase.split('_').map{|i|i.capitalize}.join('-')
  end
end

class DocumentCache < Goliath::API
  DOCS = {}

  def response(env)
    puts self.class
    if env['PATH_INFO'] == '/map'
      return [200, {'Content-Type'=>'text/plain'}, DOCS.inspect]
    end
    doc_id = env['PATH_INFO'].sub(/^\//, '').to_i
    doc = DOCS[doc_id]
    return [404, {'Content-Type'=>'text/plain'}, 'Not found'] if doc_id < 1 || doc.nil?
    [200, {'Content-Type'=>'text/html'}, doc]
  end

  def self.add(doc)
    @@count ||= 0
    @@count+=1
    DOCS[@@count] =doc
    @@count
  end

end


class MasterWebapp < Goliath::API
  use Rack::Static, :root => 'public', :urls => ['/slave.html', '/chromeext.crx', '/empty.html']

  map '/mws', MasterEndpoint
  map '/sws', SlaveEndpoint
  map '/resource/*', EvilProxy
  map '/doc/*', DocumentCache

  def response(env)
    [404, {}, env.inspect]
  end
end
