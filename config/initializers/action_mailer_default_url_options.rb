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

# ApplicationMailer overrides `default_url_options` per mailer instance from Setting.host_name,
# but ActionText renders rich-text mail bodies (e.g. work package descriptions) through
# ActionText::Content.renderer (ApplicationController.renderer by default), which is a separate
# rendering context that falls back to Rails.application.routes.default_url_options instead of
# ActionMailer::Base's override. That global routing default is never set anywhere, which only
# goes unnoticed as long as mail is delivered synchronously from within a web request (Rails can
# infer the host from it). Once mail is delivered from a background job (GoodJob, used for all
# mail delivery in production), there is no request to fall back on, and any rich-text content
# raises "Missing host to link to!".
#
# Uses OpenProject::Configuration (env-backed, no DB access) rather than Setting (an
# ActiveRecord model) since this also runs during asset precompilation, before any database
# is available.
if OpenProject::Configuration.host_name.present?
  url_options = {
    host: OpenProject::Configuration.host_name,
    protocol: OpenProject::Configuration.https? ? "https" : "http"
  }
  Rails.application.routes.default_url_options.merge!(url_options)
  ActionMailer::Base.default_url_options.merge!(url_options)
end
