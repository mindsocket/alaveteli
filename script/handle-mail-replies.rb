#!/usr/bin/env ruby
# -*- coding: utf-8 -*-

# Handle email responses sent to us.
#
# This script is invoked as a pipe command, i.e. with the raw email message on stdin.
# - If a message is identified as a permanent bounce, the user is marked as having a
#   bounced address, and will not be sent any more messages.
# - If a message is identified as an out-of-office autoreply, it is discarded.
# - Any other messages are forwarded to config.get("FORWARD_NONBOUNCE_RESPONSES_TO")


# We want to avoid loading rails unless we need it, so we start by just loading the
# config file ourselves.
$alaveteli_dir = File.expand_path(File.join(File.dirname(__FILE__), '..'))
$:.push(File.join($alaveteli_dir, "commonlib", "rblib"))
load "config.rb"
$:.push(File.join($alaveteli_dir, "lib"))
$:.push(File.join($alaveteli_dir, "lib", "mail_handler"))
require "configuration"
MySociety::Config.set_file(File.join($alaveteli_dir, 'config', 'general'), true)
MySociety::Config.load_default

require 'action_mailer'
require 'mail_handler'

def main(in_test_mode)
    Dir.chdir($alaveteli_dir) do
        raw_message = $stdin.read
        begin
            message = MailHandler.mail_from_raw_email(raw_message, decode=false)
        rescue
            # Error parsing message. Just pass it on, to be on the safe side.
            forward_on(raw_message) unless in_test_mode
            return 0
        end

        pfas = permanently_failed_addresses(message)
        if !pfas.empty?
            if in_test_mode
                puts pfas
            else
                pfas.each do |pfa|
                    record_bounce(pfa, raw_message)
                end
            end
            return 1
        end

        # If we are still here, there are no permanent failures,
        # so if the message is a multipart/report then it must be
        # reporting a temporary failure. In this case we discard it
        if message.content_type == "multipart/report"
          return 1
        end

        # Another style of temporary failure message
        subject = message.header_string("Subject")
        if message.content_type == "multipart/mixed" && subject == "Delivery Status Notification (Delay)"
          return 1
        end

        # Discard out-of-office messages
        if is_oof?(message)
            return 2 # Use a different return code, to distinguish OOFs from bounces
        end

        # Otherwise forward the message on
        forward_on(raw_message) unless in_test_mode
        return 0
    end
end

def permanently_failed_addresses(message)
    if message.header_string("Return-Path") == "<>"
        # Some sort of auto-response

        # Check for Exim’s X-Failed-Recipients header
        failed_recipients = message.header_string("X-Failed-Recipients")
        if !failed_recipients.nil?
            # The X-Failed-Recipients header contains the email address that failed
            # Check for the words "This is a permanent error." in the body, to indicate
            # a permanent failure
            if message.body =~ /This is a permanent error./
                return failed_recipients.split(/,\s*/)
            end
        end

        # Next, look for multipart/report
        if message.content_type == "multipart/report"
            permanently_failed_recipients = []
            message.parts.each do |part|
                if part.content_type == "message/delivery-status"
                    sections = part.body.split(/\r?\n\r?\n/)
                    # The first section is a generic header; subsequent sections
                    # represent a particular recipient. Since we
                    sections[1..-1].each do |section|
                        if section !~ /^Status: (\d)/ || $1 != '5'
                            # Either we couldn’t find the Status field, or it was a transient failure
                            break
                        end
                        if section =~ /^Final-Recipient: rfc822;(.+)/
                            permanently_failed_recipients.push($1)
                        end
                    end
                end
            end
            if !permanently_failed_recipients.empty?
                return permanently_failed_recipients
            end
        end
    end

    subject = message.header_string("Subject")
    # Then look for the style we’ve seen in WebShield bounces
    # (These do not have a return path of <> in the cases I have seen.)
    if subject == "Returned Mail: Error During Delivery"
      if message.body =~ /^\s*---- Failed Recipients ----\s*((?:<[^>]+>\n)+)/
        return $1.scan(/<([^>]+)>/).flatten
      end
    end

    return []
end

def is_oof?(message)
    # Check for out-of-office

    if message.header_string("X-POST-MessageClass") == "9; Autoresponder"
        return true
    end

    subject = message.header_string("Subject").downcase
    if message.header_string("Return-Path") == "<>"
        if subject.start_with? "out of office: "
            return true
        end
        if subject.start_with? "automatic reply: "
            return true
        end
    end

    if message.header_string("Auto-Submitted") == "auto-generated"
        if subject =~ /out of( the)? office/
            return true
        end
    end

    if subject.start_with? "out of office autoreply:"
        return true
    end
    if subject == "out of office"
        return true
    end
    if subject == "out of office reply"
        return true
    end
    if subject.end_with? "is out of the office"
        return true
    end
    return false
end

def forward_on(raw_message)
    IO.popen("/usr/sbin/sendmail -i #{Configuration::forward_nonbounce_responses_to}", "w") do |f|
        f.write(raw_message);
        f.close;
    end
end

def load_rails
    require File.join('config', 'boot')
    require File.join('config', 'environment')
end

def record_bounce(email_address, bounce_message)
    load_rails
    User.record_bounce_for_email(email_address, bounce_message)
end

in_test_mode = (ARGV[0] == "--test")
status = main(in_test_mode)
exit(status) if in_test_mode
