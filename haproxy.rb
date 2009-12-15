#!/bin/env ruby

##############################################################################
# HAProxy 1.3 (or higher) Collectd Plugin
# Copyright (C) 2009 Clinicsoft. LLC http://liveedit.com
# Author: Ryan Schlesinger <ryan@instanceinc.com>
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
##############################################################################

require 'optparse'
require 'fileutils'
require 'socket'

#default options
options = {
	:socket => "/home/haproxy/haproxy-stats",
	:wait_time => 10
}

STATSCOMMAND = "show stat\n"
BACKENDSTRING = "BACKEND"

class HaproxyStats
	attr_accessor :haproxy_vars

	
	def initialize(section, instance, name)
		@columnTypes = nil
		@section = section
		@instance = instance
		@name = name

		#typei == type-instance
		@haproxy_vars = {
			"haproxy_status" => { 
				:typei => [:server], 
				:data_desc => ["status"]},
			"haproxy_traffic" => { 
				:typei => [:server, :total], 
				:data_desc => ["stot", "eresp", "chkfail"]},
			"haproxy_sessions" => { 
				:typei => [:server, :total], 
				:data_desc => ["qcur", "scur"]}
		}

		@translate = { "status" => [
			[/^UP$/, "2"],
			[/^UP.*$/, "-1"], #Going Down
			[/^DOWN$/, "-2"],
			[/^DOWN.*$/, "1"], #Going Up
			[/^no check$/, "0"]
			]
		}
	end

	def parse(input, time)

		output = ""
		backend_line = nil
		accumulator = {}

		if @columnTypes == nil
			parseColumnTypes(input)
		end

		#init accumulator
		@haproxy_vars.each do |type, data|
			if data[:typei].include?(:total)
				accumulator[type] = [].fill(0, 0, data[:data_desc].length)
			end
		end

		input.each_with_index do |line, index|
			if index == 0
				next
			end

			if line =~ /^#{@section}/
				values = line.split(',')

				if values[@columnTypes["svname"]] == BACKENDSTRING
					backend_line = line.clone
				else
					@haproxy_vars.each do |type, data|
						if data[:typei].include?(:server)
							output << "PUTVAL #{@instance}/haproxy-#{@name}/"\
								+ type + "-" + \
								values[@columnTypes["svname"]].downcase.gsub(/-/, '_') +\
								" #{time}"
							data[:data_desc].each_with_index do |column, index|
								if @translate[column] != nil
									output << ":"
									@translate[column].each do |pattern,val|
										if values[@columnTypes[column]] =~ pattern
											output << val
											break
										end
									end
								else
									if values[@columnTypes[column]] == ""
										output << ":0"
									else
										if data[:typei].include?(:total)
											accumulator[type][index] += values[@columnTypes[column]].to_i
										end
										output << ":" << values[@columnTypes[column]]
									end
								end
							end
							output << "\n"
						end
					end
				end
			end
		end

		
		values = backend_line.split(",")
		if values[@columnTypes["svname"]] != BACKENDSTRING
			raise "Unable to find BACKEND string"
		end

		#handle backend string
		@haproxy_vars.each do |type, data|
			if data[:typei].include?(:total)
				output << "PUTVAL #{@instance}/haproxy-#{@name}/"\
					+ type + "-total #{time}"
				data[:data_desc].each_with_index do |column, index|
					if values[@columnTypes[column]] == ""
						output << ":" << accumulator[type][index].to_s
					else
						output << ":" << values[@columnTypes[column]]
					end
				end
				output << "\n"
			end
		end

		output
	end

	private
	def parseColumnTypes(input)
		if input.length == 0
			raise "Empty input not allowed"
		end

		match = input.index("\n")
		if match.nil? || match == 0
			raise "Invalid input: No line breaks found"
		end

		line = input[0..match]
		
		if line[0].chr != "#"
			raise "Invalid input: No column types found"
		end

		@columnTypes = {}
		line.slice!(0..1)
		line.chomp!
		columns = line.split(",")

		#Build hash
		columns.each_with_index do |column, index|
			if !column.nil? && column != ""
				@columnTypes[column] = index
			end
		end

		@columnTypes
	end

end

opts = OptionParser.new

opts.banner = "Usage: haproxy-stats.rb [options]"

opts.separator ""
opts.separator "Specific options:"

opts.on("-sSOCKET", "--socket=SOCKET", "Location of the haproxy stats socket", "Default: /home/haproxy/haproxy-stats"){|str| options[:socket] = str}
opts.on("-iINSTANCE", "--instance=INSTANCE", "Instance id"){|str| options[:instance] = str}
opts.on("-wWAITTIME", "--wait=WAITTIME", "Time to wait between samples", "Default: 10"){|str| options[:wait_time] = str.to_i}
opts.on("-eSECTION", "--section=SECTION", "Haproxy section to search for stats") {|str| options[:section] = str}
opts.on("-nNAME", "--name=NAME", "Config name for haproxy stats (ie www)"){|str| options[:name] = str}
opts.separator ""
opts.separator "Common options:"

opts.on_tail("-h", "--help", "Shows this message") {
    exit
}

begin
    opts.parse(ARGV)
    if ARGV.length == 0
        exit
    end

    #Check for required args
	raise "Instance id is required" unless options[:instance]
	raise "Section is required" unless options[:section]
	raise "Name is required" unless options[:name]

rescue SystemExit
    puts opts
    exit
rescue Exception => e
    puts "Error: #{e}"
    puts opts
    exit
end

#Options Done

begin
	socket_data = ""


	stats = HaproxyStats.new(options[:section], options[:instance], options[:name])

	while true do
		start_run = Time.now.to_i
		next_run = start_run + options[:wait_time]

		socket = UNIXSocket.open(options[:socket])
		socket.write(STATSCOMMAND)
		socket_data = socket.read
		socket.close

		puts stats.parse(socket_data, start_run)

		#sleep until it's time to run again
		while((time_left = (next_run - Time.now.to_i)) > 0) do
		      sleep(time_left)
	    end
	end

rescue Exception => e
	puts e
	puts e.backtrace
ensure
	socket.close if !socket.nil? && !socket.closed?
end

