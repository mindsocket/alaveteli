# Monkeypatch! Adding some extra members to store extra info in.
module TMail
    class Mail
        attr_accessor :url_part_number
        attr_accessor :rfc822_attachment # when a whole email message is attached as text
        attr_accessor :within_rfc822_attachment # for parts within a message attached as text (for getting subject mainly)
        attr_accessor :count_parts_count
        attr_accessor :count_first_uudecode_count
        # Monkeypatch!
        # Bug fix to this function - is for message in humberside-police-odd-mime-type.email
        # See test in spec/lib/tmail_extensions.rb
        def set_content_type( str, sub = nil, param = nil )
          if sub
            main, sub = str, sub
          else
            main, sub = str.split(%r</>, 2)
            raise ArgumentError, "sub type missing: #{str.inspect}" unless sub
          end
          if h = @header['content-type']
            h.main_type = main
            h.sub_type  = sub
            h.params.clear if !h.params.nil? # XXX this if statement is the fix # XXX disabled until works with test
          else
            store 'Content-Type', "#{main}/#{sub}"
          end
          @header['content-type'].params.replace param if param
          str
        end
        # Need to make sure this alias calls the Monkeypatch too
        alias content_type= set_content_type
    end

end


module MailParsingWithTmail

    include MailParsingGeneral

    # Return the structured TMail::Mail object
    # Documentation at http://i.loveruby.net/en/projects/tmail/doc/
    def MailParsingWithTmail.mail_from_raw_email(data)
        # Hack round bug in TMail's MIME decoding.
        copy_of_raw_data = data.gsub(/; boundary=\s+"/im,'; boundary="')
        mail = TMail::Mail.parse(copy_of_raw_data)
        mail.base64_decode
        return mail
    end

    def MailParsingWithTmail.get_from_name(mail)
        if mail.from && mail.from_addrs[0].name
            return TMail::Unquoter.unquote_and_convert_to(mail.from_addrs[0].name, "utf-8")
        else
            return nil
        end
    end

    def MailParsingWithTmail.get_from_address(mail)
        if mail.from_addrs.nil? || mail.from_addrs.size == 0
            return nil
        end
        mail.from_addrs[0].spec
    end

    def MailParsingWithTmail.get_envelope_to_address(mail)
        mail.envelope_to
    end

    def MailParsingWithTmail.empty_return_path?(mail)
        return false if mail['return-path'].nil?
        return true if mail['return-path'].addr.to_s == '<>'
        return false
    end

    def MailParsingWithTmail.get_auto_submitted(mail)
        mail['auto-submitted'] ? mail['auto-submitted'].body : nil
    end

    def MailParsingWithTmail.get_part_file_name(mail_part)
        part_file_name = TMail::Mail.get_part_file_name(mail_part)
        if part_file_name.nil?
            return nil
        end
        part_file_name = part_file_name.dup
        return part_file_name
    end

    def MailParsingWithTmail.get_part_body(mail_part)
        mail_part.body
    end

    # (This risks losing info if the unchosen alternative is the only one to contain
    # useful info, but let's worry about that another time)
    def MailParsingWithTmail.get_attachment_leaves(mail)
        return _get_attachment_leaves_recursive(mail, nil, mail)
    end

    def MailParsingWithTmail._get_attachment_leaves_recursive(curr_mail, within_rfc822_attachment, parent_mail)
        leaves_found = []
        if curr_mail.multipart?
            if curr_mail.parts.size == 0
                raise "no parts on multipart mail"
            end

            if curr_mail.sub_type == 'alternative'
                # Choose best part from alternatives
                best_part = nil
                # Take the last text/plain one, or else the first one
                curr_mail.parts.each do |m|
                    if not best_part
                        best_part = m
                    elsif m.content_type == 'text/plain'
                        best_part = m
                    end
                end
                # Take an HTML one as even higher priority. (They tend
                # to render better than text/plain, e.g. don't wrap links here:
                # http://www.whatdotheyknow.com/request/amount_and_cost_of_freedom_of_in#incoming-72238 )
                curr_mail.parts.each do |m|
                    if m.content_type == 'text/html'
                        best_part = m
                    end
                end
                leaves_found += _get_attachment_leaves_recursive(best_part, within_rfc822_attachment, parent_mail)
            else
                # Add all parts
                curr_mail.parts.each do |m|
                    leaves_found += _get_attachment_leaves_recursive(m, within_rfc822_attachment, parent_mail)
                end
            end
        else
            # XXX Yuck. this section alters various content_types. That puts
            # it into conflict with ensure_parts_counted which it has to be
            # called both before and after.  It will fail with cases of
            # attachments of attachments etc.
            charset = curr_mail.charset # save this, because overwriting content_type also resets charset
            # Don't allow nil content_types
            if curr_mail.content_type.nil?
                curr_mail.content_type = 'application/octet-stream'
            end
            # PDFs often come with this mime type, fix it up for view code
            if curr_mail.content_type == 'application/octet-stream'
                part_file_name = self.get_part_file_name(curr_mail)
                part_body = get_part_body(curr_mail)
                calc_mime = AlaveteliFileTypes.filename_and_content_to_mimetype(part_file_name, part_body)
                if calc_mime
                    curr_mail.content_type = calc_mime
                end
            end

            # Use standard content types for Word documents etc.
            curr_mail.content_type = MailParsingGeneral::normalise_content_type(curr_mail.content_type)
            if curr_mail.content_type == 'message/rfc822'
                ensure_parts_counted(parent_mail)# fills in rfc822_attachment variable
                if curr_mail.rfc822_attachment.nil?
                    # Attached mail didn't parse, so treat as text
                    curr_mail.content_type = 'text/plain'
                end
            end
            if curr_mail.content_type == 'application/vnd.ms-outlook' || curr_mail.content_type == 'application/ms-tnef'
                ensure_parts_counted(parent_mail) # fills in rfc822_attachment variable
                if curr_mail.rfc822_attachment.nil?
                    # Attached mail didn't parse, so treat as binary
                    curr_mail.content_type = 'application/octet-stream'
                end
            end
            # If the part is an attachment of email
            if curr_mail.content_type == 'message/rfc822' || curr_mail.content_type == 'application/vnd.ms-outlook' || curr_mail.content_type == 'application/ms-tnef'
                ensure_parts_counted(parent_mail) # fills in rfc822_attachment variable
                leaves_found += _get_attachment_leaves_recursive(curr_mail.rfc822_attachment, curr_mail.rfc822_attachment, parent_mail)
            else
                # Store leaf
                curr_mail.within_rfc822_attachment = within_rfc822_attachment
                leaves_found += [curr_mail]
            end
            # restore original charset
            curr_mail.charset = charset
        end
        return leaves_found
    end

    # Number the attachments in depth first tree order, for use in URLs.
    # XXX This fills in part.rfc822_attachment and part.url_part_number within
    # all the parts of the email (see TMail monkeypatch above for how these
    # attributes are added). ensure_parts_counted must be called before using
    # the attributes.
    def MailParsingWithTmail.ensure_parts_counted(mail)
        mail.count_parts_count = 0
        _count_parts_recursive(mail, mail)
        # we carry on using these numeric ids for attachments uudecoded from within text parts
        mail.count_first_uudecode_count = mail.count_parts_count
    end

    def MailParsingWithTmail._count_parts_recursive(part, parent_mail)
        if part.multipart?
            part.parts.each do |p|
                _count_parts_recursive(p, parent_mail)
            end
        else
            part_filename = get_part_file_name(part)
            begin
                if part.content_type == 'message/rfc822'
                    # An email attached as text
                    # e.g. http://www.whatdotheyknow.com/request/64/response/102
                    part.rfc822_attachment = TMail::Mail.parse(part.body)
                elsif part.content_type == 'application/vnd.ms-outlook' || part_filename && AlaveteliFileTypes.filename_to_mimetype(part_filename) == 'application/vnd.ms-outlook'
                    # An email attached as an Outlook file
                    # e.g. http://www.whatdotheyknow.com/request/chinese_names_for_british_politi
                    msg = Mapi::Msg.open(StringIO.new(part.body))
                    part.rfc822_attachment = TMail::Mail.parse(msg.to_mime.to_s)

                elsif part.content_type == 'application/ms-tnef'
                    # A set of attachments in a TNEF file
                    part.rfc822_attachment = TNEF.as_tmail(part.body)
                end
            rescue
                # If attached mail doesn't parse, treat it as text part
                part.rfc822_attachment = nil
            else
                unless part.rfc822_attachment.nil?
                    _count_parts_recursive(part.rfc822_attachment, parent_mail)
                end
            end
            if part.rfc822_attachment.nil?
                parent_mail.count_parts_count += 1
                part.url_part_number = parent_mail.count_parts_count
            end
        end
    end

    def MailParsingWithTmail.get_attachment_attributes(mail)
        leaves = get_attachment_leaves(mail) # XXX check where else this is called from
        # XXX we have to call ensure_parts_counted after get_attachment_leaves
        # which is really messy.
        ensure_parts_counted(mail)
        attachments = []
        for leaf in leaves
            body = leaf.body
            # As leaf.body causes MIME decoding which uses lots of RAM, do garbage collection here
            # to prevent excess memory use. XXX not really sure if this helps reduce
            # peak RAM use overall. Anyway, maybe there is something better to do than this.
            GC.start
            if leaf.within_rfc822_attachment
                within_rfc822_subject = leaf.within_rfc822_attachment.subject
                # Test to see if we are in the first part of the attached
                # RFC822 message and it is text, if so add headers.
                # XXX should probably use hunting algorithm to find main text part, rather than
                # just expect it to be first. This will do for now though.
                # Example request that needs this:
                # http://www.whatdotheyknow.com/request/2923/response/7013/attach/2/Cycle%20Path%20Bank.txt
                if leaf.within_rfc822_attachment == leaf && leaf.content_type == 'text/plain'
                    headers = ""
                    for header in [ 'Date', 'Subject', 'From', 'To', 'Cc' ]
                        if leaf.within_rfc822_attachment.header.include?(header.downcase)
                            header_value = leaf.within_rfc822_attachment.header[header.downcase]
                            # Example message which has a blank Date header:
                            # http://www.whatdotheyknow.com/request/30747/response/80253/attach/html/17/Common%20Purpose%20Advisory%20Group%20Meeting%20Tuesday%202nd%20March.txt.html
                            if !header_value.blank?
                                headers = headers + header + ": " + header_value.to_s + "\n"
                            end
                        end
                    end
                    # XXX call _convert_part_body_to_text here, but need to get charset somehow
                    # e.g. http://www.whatdotheyknow.com/request/1593/response/3088/attach/4/Freedom%20of%20Information%20request%20-%20car%20oval%20sticker:%20Article%2020,%20Convention%20on%20Road%20Traffic%201949.txt
                    body = headers + "\n" + body

                    # This is quick way of getting all headers, but instead we only add some a) to
                    # make it more usable, b) as at least one authority accidentally leaked security
                    # information into a header.
                    #attachment.body = leaf.within_rfc822_attachment.port.to_s
                end
            end
            hexdigest = Digest::MD5.hexdigest(body)
            leaf_attributes = { :hexdigest => hexdigest,
                                :body => body,
                                :leaf => leaf,
                                :within_rfc822_subject => within_rfc822_subject,
                                :filename => get_part_file_name(leaf) }
            attachments << leaf_attributes
        end
        return attachments
    end

    def MailParsingWithTmail.address_from_name_and_email(name, email)
        if !MySociety::Validate.is_valid_email(email)
            raise "invalid email " + email + " passed to address_from_name_and_email"
        end
        if name.nil?
            return TMail::Address.parse(email)
        end
        # Botch an always quoted RFC address, then parse it
        name = name.gsub(/(["\\])/, "\\\\\\1")
        return TMail::Address.parse('"' + name + '" <' + email + '>')

    end

    def MailParsingWithTmail.sanitize_text(text, source_charset)
         # If TMail can't convert text, it just returns it, so we sanitise it.
        begin
            # Test if it's good UTF-8
            text = Iconv.conv('utf-8', 'utf-8', text)
        rescue Iconv::IllegalSequence
            # Text looks like unlabelled nonsense,
            # strip out anything that isn't UTF-8
            begin
                source_charset = 'utf-8' if source_charset.nil?
                text = Iconv.conv('utf-8//IGNORE', source_charset, text) +
                    _("\n\n[ {{site_name}} note: The above text was badly encoded, and has had strange characters removed. ]",
                      :site_name => MySociety::Config.get('SITE_NAME', 'Alaveteli'))
            rescue Iconv::InvalidEncoding, Iconv::IllegalSequence
                if source_charset != "utf-8"
                    source_charset = "utf-8"
                    retry
                end
            end
        end
        return text
    end

    # Given a main text part, converts it to text
    def MailParsingWithTmail.convert_part_body_to_text(part)
        if part.nil?
            text = "[ Email has no body, please see attachments ]"
            source_charset = "utf-8"
        else
            text = part.body # by default, TMail converts to UTF8 in this call
            source_charset = part.charset
            if part.content_type == 'text/html'
                # e.g. http://www.whatdotheyknow.com/request/35/response/177
                # XXX This is a bit of a hack as it is calling a
                # convert to text routine.  Could instead call a
                # sanitize HTML one.

                # If the text isn't UTF8, it means TMail had a problem
                # converting it (invalid characters, etc), and we
                # should instead tell elinks to respect the source
                # charset
                use_charset = "utf-8"
                begin
                    text = Iconv.conv('utf-8', 'utf-8', text)
                rescue Iconv::IllegalSequence
                    use_charset = source_charset
                end
                text = MailParsingGeneral._get_attachment_text_internal_one_file(part.content_type, text, use_charset)
            end
        end

        text = MailParsing.sanitize_text(text, source_charset)

        # Fix DOS style linefeeds to Unix style ones (or other later regexps won't work)
        # Needed for e.g. http://www.whatdotheyknow.com/request/60/response/98
        text = text.gsub(/\r\n/, "\n")

        # Compress extra spaces down to save space, and to stop regular expressions
        # breaking in strange extreme cases. e.g. for
        # http://www.whatdotheyknow.com/request/spending_on_consultants
        text = text.gsub(/ +/, " ")

        return text
    end

    def MailParsingWithTmail.get_content_type(part)
      part.content_type
    end

    def MailParsingWithTmail.get_header_string(header, mail)
        mail.header_string(header)
    end

end
