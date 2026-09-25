# frozen_string_literal: true

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
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301, USA.
#
# See COPYRIGHT and LICENSE files for more details.
#++

require "spec_helper"

RSpec.describe OpenProject::AcsEmailDelivery do
  subject(:delivery) { described_class.new }

  let(:endpoint) { "https://example.communication.azure.com" }
  let(:access_key) { Base64.strict_encode64("supersecretkey") }
  let(:sender_address) { "DoNotReply@example.azurecomm.net" }

  let(:mail) do
    ActionMailer::Base.mail(
      to: "recipient@example.com",
      from: sender_address,
      subject: "Hello from OpenProject",
      body: "Plain text body"
    )
  end

  around do |example|
    ClimateControl.modify(
      "AZURE_ACS_EMAIL_ENDPOINT" => endpoint,
      "AZURE_ACS_EMAIL_KEY" => access_key,
      "AZURE_ACS_EMAIL_SENDER_ADDRESS" => sender_address
    ) { example.run }
  end

  describe "#deliver!" do
    it "posts a signed request to the ACS emails:send endpoint with the mail content" do
      stub = stub_request(:post, "#{endpoint}/emails:send?api-version=2023-03-31")
             .with do |request|
               body = JSON.parse(request.body)
               expect(body["senderAddress"]).to eq(sender_address)
               expect(body["recipients"]["to"]).to eq([{ "address" => "recipient@example.com" }])
               expect(body["content"]["subject"]).to eq("Hello from OpenProject")
               expect(body["content"]["plainText"]).to eq("Plain text body")
               expect(request.headers["Authorization"]).to match(/\AHMAC-SHA256 SignedHeaders=/)
               expect(request.headers["X-Ms-Date"]).to be_present
               expect(request.headers["X-Ms-Content-Sha256"]).to be_present
             end
             .to_return(status: 202, body: "")

      delivery.deliver!(mail)

      expect(stub).to have_been_requested
    end

    it "raises when the ACS API responds with an error" do
      stub_request(:post, "#{endpoint}/emails:send?api-version=2023-03-31")
        .to_return(status: 401, body: "unauthorized")

      expect { delivery.deliver!(mail) }.to raise_error(OpenProject::AcsEmailDelivery::Error, /401/)
    end

    it "raises a descriptive error when a required environment variable is missing" do
      ClimateControl.modify("AZURE_ACS_EMAIL_ENDPOINT" => nil) do
        expect { delivery.deliver!(mail) }.to raise_error(OpenProject::AcsEmailDelivery::Error, /AZURE_ACS_EMAIL_ENDPOINT/)
      end
    end
  end
end
