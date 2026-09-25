#-- copyright
# OpenProject is an open source project management software.
# Copyright (C) the OpenProject GmbH
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License version 3.
#
# OpenProject is a fork of ChiliProject, which is a fork of Redmine. The copyright follows:
# Copyright (C) 2006-2013 Jean-Philippe Lang
# Copyright (C) 2010-2013 the ChiliProject Team
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
#
# See COPYRIGHT and LICENSE files for more details.
#++

require "net/http"
require "openssl"
require "digest"
require "base64"
require "json"

module OpenProject
  # ActionMailer delivery method for Azure Communication Services Email,
  # authenticated via access key (HMAC-SHA256) rather than SMTP, since the
  # latter requires an Entra app registration with an RBAC role assignment
  # on the Communication Services resource, which is unavailable in some
  # restricted Azure subscriptions (e.g. subscriptions without permission
  # to create role assignments).
  #
  # Registered via `ActionMailer::Base.add_delivery_method :acs, ...` in
  # config/initializers/acs_email_delivery_method.rb. Activate by setting
  # OPENPROJECT_EMAIL__DELIVERY__METHOD=acs.
  class AcsEmailDelivery
    API_VERSION = "2023-03-31"

    Error = Class.new(StandardError)

    def initialize(_settings = {}); end

    def deliver!(mail)
      uri = URI.parse("#{endpoint}/emails:send?api-version=#{API_VERSION}")
      body = build_body(mail)

      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      sign_request!(request, uri, body)
      request.body = body

      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |http| http.request(request) }

      unless response.code.to_i.between?(200, 299)
        raise Error, "Azure Communication Services email delivery failed: #{response.code} #{response.body}"
      end

      response
    end

    private

    def endpoint
      fetch_env("AZURE_ACS_EMAIL_ENDPOINT").chomp("/")
    end

    def access_key
      fetch_env("AZURE_ACS_EMAIL_KEY")
    end

    def sender_address
      fetch_env("AZURE_ACS_EMAIL_SENDER_ADDRESS")
    end

    def fetch_env(name)
      ENV.fetch(name) { raise Error, "Missing #{name} environment variable for ACS email delivery" }
    end

    def build_body(mail)
      content = {
        subject: mail.subject,
        plainText: text_part(mail),
        html: html_part(mail)
      }.compact

      {
        senderAddress: sender_address,
        recipients: {
          to: Array(mail.to).map { |address| { address: } }
        },
        content:
      }.to_json
    end

    def text_part(mail)
      if mail.multipart?
        mail.text_part&.decoded
      elsif mail.content_type.to_s.start_with?("text/plain") || mail.content_type.nil?
        mail.body.decoded
      end
    end

    def html_part(mail)
      if mail.multipart?
        mail.html_part&.decoded
      elsif mail.content_type.to_s.start_with?("text/html")
        mail.body.decoded
      end
    end

    def sign_request!(request, uri, body)
      date = Time.now.httpdate
      content_hash = Base64.strict_encode64(Digest::SHA256.digest(body))
      string_to_sign = "POST\n#{uri.request_uri}\n#{date};#{uri.host};#{content_hash}"
      signature = Base64.strict_encode64(OpenSSL::HMAC.digest("SHA256", Base64.decode64(access_key), string_to_sign))

      request["x-ms-date"] = date
      request["x-ms-content-sha256"] = content_hash
      request["Authorization"] =
        "HMAC-SHA256 SignedHeaders=x-ms-date;host;x-ms-content-sha256&Signature=#{signature}"
    end
  end
end
