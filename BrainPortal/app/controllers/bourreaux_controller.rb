
#
# CBRAIN Project
#
# Copyright (C) 2008-2012
# The Royal Institution for the Advancement of Learning
# McGill University
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.  
#

# Bourreau controller for the BrainPortal interface
#
# RESTful controller for managing the Bourreau (remote execution server) resource. 
# All actions except +index+ and +show+ require *admin* privileges.
class BourreauxController < ApplicationController

  include DateRangeRestriction

  Revision_info=CbrainFileRevision[__FILE__] #:nodoc:
  
  api_available :except  => :row_data

  before_filter :login_required
  before_filter :manager_role_required, :except  => [:index, :show, :row_data, :load_info, :rr_disk_usage, :cleanup_caches, :rr_access, :rr_access_dp, :update, :start, :stop]
                                                                

  def index #:nodoc:
    @filter_params["sort_hash"]["order"] ||= "remote_resources.type"
    @filter_params["sort_hash"]["dir"] ||= "DESC"
    @header_scope = RemoteResource.find_all_accessible_by_user(current_user)
    @filtered_scope = base_filtered_scope @header_scope.includes(:user, :group)
    @bourreaux      = base_sorted_scope @filtered_scope

    if current_user.has_role? :admin_user
      @filter_params['details'] = 'on' unless @filter_params.has_key?('details')
    end
    
    respond_to do |format|
      format.html
      format.xml  { render :xml => @bourreaux }
      format.js
    end
  end
  
  def show #:nodoc:
    @users    = current_user.available_users
    @bourreau = RemoteResource.find(params[:id])

    cb_notice "Execution Server not accessible by current user." unless @bourreau.can_be_accessed_by?(current_user)
    
    respond_to do |format|
      format.html # show.html.erb
      format.xml  { render :xml => @bourreau }
    end
  end
  
  def new #:nodoc:
    bourreau_group_id = ( current_project && current_project.id ) || current_user.own_group.id
    @users    = current_user.available_users
    @groups   = current_user.available_groups
    @bourreau = Bourreau.new( :user_id   => current_user.id,
                              :group_id  => bourreau_group_id,
                              :cache_trust_expire => 1.month.to_i.to_s,
                              :online    => true
                            )
    sensible_defaults(@bourreau)
    render :partial => "new"
  end

  def create #:nodoc:
    fields    = params[:bourreau]

    @bourreau = Bourreau.new( fields )
    @bourreau.save

    if @bourreau.errors.empty?
      flash[:notice] = "Execution Server successfully created."
      
      respond_to do |format|
        format.js  { redirect_to :action => :index, :format => :js }
        format.xml { render      :xml    => @bourreau }
      end
    else
      respond_to do |format|
        format.js  { render :partial => "shared/failed_create",  :locals => { :model_name => "bourreau" } }
        format.xml { render :xml     => @bourreau.errors.to_xml, :status =>   :unprocessable_entity       }
      end
    end
  end

  def update #:nodoc:
    id        = params[:id]
    @bourreau = RemoteResource.find(id)

    cb_notice "This #{@bourreau.class.to_s} is not accessible by you." unless @bourreau.has_owner_access?(current_user)

    @users    = current_user.available_users
    @groups   = current_user.available_groups

    fields    = params[:bourreau]
    fields ||= {}
    
    subtype          = fields.delete(:type)
    old_dp_cache_dir = @bourreau.dp_cache_dir

    if ! @bourreau.update_attributes_with_logging(fields, current_user,
        RemoteResource.columns_hash.keys.grep(/actres_|cache_trust|cms_|dp_|url|online|proxied_hosts|rr_timeout|ssh_|email|tunnel_|worker/)
      )
      @bourreau.reload
      respond_to do |format|
        format.html { render :action => 'show' }
        format.xml  { render :xml  => @bourreau.errors, :status  => :unprocessable_entity}
      end
      return
    end

    # Adjust task limits, and store them into the meta data store
    syms_limit_users = @users.map { |u| "task_limit_user_#{u.id}".to_sym }
    add_meta_data_from_form(@bourreau, [ :task_limit_total, :task_limit_user_default, :error_message_mailing_list ] + syms_limit_users )

    if old_dp_cache_dir != @bourreau.dp_cache_dir
      old_ss = SyncStatus.where( :remote_resource_id => @bourreau.id )
      old_ss.each do |ss|
        ss.destroy rescue true
      end
      info_message = "Since the Data Provider cache directory has been changed, all\n" +
                     "synchronization status objects were reset.\n"
      unless old_dp_cache_dir.blank?
        host = @bourreau.ssh_control_host
        host = @bourreau.actres_host      if host.blank?
        host = 'localhost'                if host.blank?
        info_message += "You may have to clean up the content of the old cache directory\n" +
                        "'#{old_dp_cache_dir}' on host '#{host}'\n"
      end
      Message.send_message(current_user,
        :message_type => :system,
        :critical     => true,
        :header       => "Data Provider cache directory changed for #{@bourreau.class} '#{@bourreau.name}'",
        :description  => info_message
      )
    end

    flash[:notice] = "#{@bourreau.class.to_s} #{@bourreau.name} successfully updated"

    respond_to do |format|
      format.html { redirect_to :action => :show }
      format.js { render :partial => "shared/flash_update"}
      format.xml  { head        :ok }
    end
  end

  def destroy #:nodoc:
    id        = params[:id]
    @bourreau = RemoteResource.find(id)
    
    raise CbrainDeleteRestrictionError.new("Execution Server not accessible by current user.") unless @bourreau.has_owner_access?(current_user)
    
    @bourreau.destroy
    
    flash[:notice] = "Execution Server successfully deleted."
      
    respond_to do |format|
      format.html { redirect_to :action => :index}
      format.js   { redirect_to :action => :index, :format => :js}
      format.xml  { head :ok }
    end
  rescue ActiveRecord::DeleteRestrictionError => e
    flash[:error] = "Execution Server destruction failed: #{e.message.humanize}."
    
    respond_to do |format|
      format.html { redirect_to :action => :index}
      format.js   { redirect_to :action => :index, :format => :js}
      format.xml  { head :conflict }
    end
  end
  
  def row_data #:nodoc:
    @remote_resource = RemoteResource.find_accessible_by_user(params[:id], current_user)
    render :partial => 'bourreau_table_row', :locals  => { :bourreau  => @remote_resource, :row_number => params[:row_number].to_i }
  end

  def load_info #:nodoc:
    
    if params[:bourreau_id].blank? && params[:tool_config_id].blank? 
      render :text  => ""
      return
    end

    bourreau_id = params[:bourreau_id] || ToolConfig.find(params[:tool_config_id]).bourreau_id
    @bourreau   = Bourreau.find(bourreau_id)

    respond_to do |format|
      format.html { render :partial => 'load_info', :locals => { :bourreau => @bourreau } }
      format.xml  { render :xml     => @bourreau   }
    end
    
  rescue => ex
    #render :text  => "#{ex.class} #{ex.message}\n#{ex.backtrace.join("\n")}"
    render :text  => '<strong style="color:red">No Information Available</strong>'
  end

  def start #:nodoc:
    @bourreau = Bourreau.find(params[:id])

    cb_notice "This #{@bourreau.class.to_s} is not accessible by you."                         unless @bourreau.has_owner_access?(current_user)
    cb_notice "Execution Server '#{@bourreau.name}' not accessible by current user."           unless @bourreau.can_be_accessed_by?(current_user)
    cb_notice "Execution Server '#{@bourreau.name}' is not yet configured for remote control." unless @bourreau.has_ssh_control_info?
    cb_notice "Execution Server '#{@bourreau.name}' has already been alive for #{pretty_elapsed(@bourreau.info(:ping).uptime)}." if @bourreau.is_alive?(:ping)

    # New behavior: if a bourreau is marked OFFLINE we turn in back ONLINE.
    unless @bourreau.online?
      @bourreau.online=true
      @bourreau.save
    end

    @bourreau.start_tunnels
    cb_error "Could not start master SSH connection and tunnels for '#{@bourreau.name}'." unless @bourreau.ssh_master.is_alive?

    started_ok = @bourreau.start
    alive_ok   = started_ok && (sleep 3) && @bourreau.is_alive?(:ping)
    workers_ok = false

    if alive_ok
      @bourreau.addlog("Rails application started by user #{current_user.login}.")
      @bourreau.reload if @bourreau.auth_token.blank? # New bourreaux? Token will have just been created.
      res = @bourreau.send_command_start_workers rescue nil
      workers_ok = true if res && res[:command_execution_status] == "OK"
    end

    # Messages

    flash[:notice] = ""
    flash[:error]  = ""

    if alive_ok
      flash[:notice] = "Execution Server '#{@bourreau.name}' started."
    elsif started_ok
      flash[:error] = "Execution Server '#{@bourreau.name}' was started but did not reply to first inquiry:\n" +
                      @bourreau.operation_messages
    else
      flash[:error] = "Execution Server '#{@bourreau.name}' could not be started. Diagnostics:\n" +
                      @bourreau.operation_messages
    end

    if workers_ok
      flash[:notice] += "\nWorkers on Execution Server '#{@bourreau.name}' started."
    elsif alive_ok
      flash[:error] += "However, we couldn't start the workers."
    end
    
    respond_to do |format|
      format.html { redirect_to :action => :index }
      format.xml  { head workers_ok ? :ok : :internal_server_error  }  # TODO change internal_server_error ?
    end  

  end

  def stop #:nodoc:
    @bourreau = Bourreau.find(params[:id])

    cb_notice "This #{@bourreau.class.to_s} is not accessible by you."                         unless @bourreau.has_owner_access?(current_user)
    cb_notice "Execution Server '#{@bourreau.name}' not accessible by current user."           unless @bourreau.can_be_accessed_by?(current_user)
    cb_notice "Execution Server '#{@bourreau.name}' is not yet configured for remote control." unless @bourreau.has_ssh_control_info?

    flash[:notice] = flash[:error] = ""

    begin
      res = @bourreau.send_command_stop_workers
      raise "Failed command to stop workers" unless res && res[:command_execution_status] == "OK" # to trigger rescue
      @bourreau.addlog("Workers stopped by user #{current_user.login}.")
      flash[:notice] += "Workers on Execution Server '#{@bourreau.name}' stopped."
    rescue
      flash[:error]  += "It seems we couldn't stop the workers on Execution Server '#{@bourreau.name}'. They'll likely die by themselves."
    end

    @bourreau.online = true # to trick layers below into doing the 'stop' operation
    boustop = @bourreau.stop
    tunstop = @bourreau.stop_tunnels
    @bourreau.online = false
    @bourreau.save

    @bourreau.addlog("Rails application stopped by user #{current_user.login}.")

    if boustop
      flash[:notice] += "\nExecution Server '#{@bourreau.name}' stopped."
      flash[:notice] += "\nStopped Control SSH connection." if tunstop
    else
      flash[:error]  += "\nFailed to stop Rails application for '#{@bourreau.name}'."
    end
    flash[:error]  += "\nFailed to stop Control SSH connection." if ! tunstop

    respond_to do |format|
      format.html { redirect_to :action => :index }
      format.xml { head :ok  }
    end

  rescue => e
    flash[:error] = e.message
    respond_to do |format|
      format.html { redirect_to :action => :index }
      format.xml { render :xml  => { :message  => e.message }, :status  => 500 }
    end
  end

  # Define disk usage of remote ressource, 
  # with date filtration if wanted.
  def rr_disk_usage
    @providers = DataProvider.find_all_accessible_by_user(current_user).all
    date_filtration = params[:date_range] || {}

    # Time:     Present ............................................................ Past
    # In Words: now .......... older_limit ..... younger_limit ................. long ago
    # Num Secs: 0 secs ago ................. < ........................ infinite secs ago
    # Vars:     .............. @cache_older  <  @cache_younger ..........................
    #
    #                          |---- files to be deleted ----|

    date_filtration["relative_from"] ||= 50.years.to_i.to_s
    date_filtration["relative_to"]   ||= 1.week.to_i.to_s
    accessed_after  = date_filtration["relative_from"].to_i.ago
    accessed_before = date_filtration["relative_to"].to_i.ago

    # Used only relative value for determine_date_range_start_end --> harcode the 4 first values.
    (accessed_after,accessed_before) = determine_date_range_start_end(false , false, Time.now, Time.now , date_filtration["relative_from"], date_filtration["relative_to"])

    # For the interface
    @cache_younger = Time.now.to_i - accessed_after.to_i  # partial will adjust to closest value in selection box
    @cache_older   = Time.now.to_i - accessed_before.to_i # partial will adjust to closest value in selection box

    # Users in statistics table
    userlist         = current_user.available_users.all

    # Remote resources in statistics table
    rrlist           = RemoteResource.find_all_accessible_by_user(current_user).all

    # Create disk usage statistics table
    stats_options = { :users            => userlist,
                      :remote_resources => rrlist,
                      :accessed_before  => accessed_before,
                      :accessed_after   => accessed_after
                    }
                    
    @report_stats    = ModelsReport.rr_usage_statistics(stats_options)

    # Keys and arrays into statistics tables, for HTML output
    @report_rrs         = @report_stats['!rrs!']
    @report_users       = @report_stats['!users!'] # does not include the 'all' column, if any

    # Filter out users for which there are no stats
    @report_users.reject! { |u| (! @report_stats[u]) || (! @report_rrs.any? { |rr| @report_stats[u][rr] }) }
    @report_users_all   = @report_users + (@report_users.size > 1 ? [ 'TOTAL' ] : [])  # users + 'all'?

    # Filter out rrs for which there are no stats
    @report_rrs.reject! { |rr| ! (@report_users_all.any? { |u| @report_stats[u] && @report_stats[u][rr] }) }

    true
  end

  # Provides the interface to trigger cache cleanup operations
  def cleanup_caches
    flash[:notice] ||= ""
    
    # First param is cleanup_older, which is the number
    # of second before NOW at which point files OLDER than
    # that become eligible for elimination
    cleanup_older = params[:cleanup_older] || 0
    if cleanup_older.to_s =~ /^\d+/
      cleanup_older = cleanup_older.to_i
      cleanup_older = 50.year.to_i if cleanup_older > 50.year.to_i
    else
      cleanup_older = 50.year.to_i
    end

    # Second param is cleanup_younger, which is the number
    # of second before NOW at which point files YOUNGER than
    # that become eligible for elimination
    cleanup_younger = params[:cleanup_younger] || 0
    if cleanup_younger.to_s =~ /^\d+/
      cleanup_younger = cleanup_younger.to_i
      cleanup_younger = 50.year.to_i if cleanup_younger > 50.year.to_i
    else
      cleanup_younger = 0
    end

    # Third param is clean_cache, a set of pairs in
    # the form "uuu,rrr" where uuu is a user_id and
    # rrr is a remote_resource_id. Both must be accessible
    # by the current user.
    clean_cache    = params[:clean_cache]    || []
    unless clean_cache.is_a?(Array)
      clean_cache = [ clean_cache ]
    end

    # List of acceptable users
    userlist         = current_user.available_users.all

    # List of acceptable remote_resources
    rrlist           = RemoteResource.find_all_accessible_by_user(current_user).all

    # Index of acceptable users and remote_resources
    userlist_index   = userlist.index_by &:id
    rrlist_index     = rrlist.index_by &:id

    # Extract what caches are asked to be cleaned up
    rrid_to_userids = {}  # rr_id => { uid => true , uid => true , uid => true ...}
    clean_cache.each do |pair|
      next unless pair.to_s.match(/^(\d+),(\d+)$/)
      user_id            = Regexp.last_match[1].to_i
      remote_resource_id = Regexp.last_match[2].to_i
      # Make sure we're allowed
      next unless userlist_index[user_id] && rrlist_index[remote_resource_id]
      # Group and uniq them
      rrid_to_userids[remote_resource_id] ||= {}
      rrid_to_userids[remote_resource_id][user_id] = true
    end

    # Send the cleanup message
    rrid_to_userids.each_key do |rrid|
      remote_resource = RemoteResource.find(rrid)
      userlist = rrid_to_userids[rrid]  # uid => true, uid => true ...
      userids = userlist.keys.each { |uid| uid.to_s }.join(",")  # "uid,uid,uid"
      flash[:notice] += "\n" unless flash[:notice].blank?
      begin
        remote_resource.send_command_clean_cache(userids,cleanup_older.ago,cleanup_younger.ago)
        flash[:notice] += "Sending cleanup command to #{remote_resource.name}."
      rescue => e
        flash[:notice] += "Could not contact #{remote_resource.name}."
      end
    end

    date_filtration                              = {}
    date_filtration["relative_from"]             = cleanup_younger
    date_filtration["relative_to"]               = cleanup_older
    
    redirect_to :action => :rr_disk_usage, :date_range => date_filtration
    
  end
  
  # Define remote ressource and users accessible/available by
  # the current user.
  def rr_access
    @remote_r = RemoteResource.find_all_accessible_by_user(current_user).all.sort { |a,b| a.name <=> b.name }
    @users    = current_user.available_users.all.sort { |a,b| a.login <=> b.login }
  end

  # Define which remote resource can acces which data provider.
  def rr_access_dp
    @rrs = RemoteResource.find_all_accessible_by_user(current_user).all.sort do |a,b|
           (b.online?.to_s <=> a.online?.to_s).nonzero? ||
           (b.type         <=> a.type).nonzero?         ||
           (a.name         <=> b.name)
    end
    @dps = DataProvider.find_all_accessible_by_user(current_user).all.sort   do |a,b|
           (b.online?.to_s       <=> a.online?.to_s).nonzero?       ||
           (a.is_browsable?.to_s <=> b.is_browsable?.to_s).nonzero? ||
           (a.name               <=> b.name)
    end

    refresh    = params[:refresh]
    refresh_bs = []
    if refresh == 'all'
      refresh_bs = @rrs
    else
      refresh_bs = @rrs.select { |b| b.id == refresh.to_i }
    end

    sent_refresh = [] # for flash message
    refresh_bs.each do |b|
      if b.online? && b.has_owner_access?(current_user) && (! b.meta[:data_provider_statuses_last_update] || b.meta[:data_provider_statuses_last_update] < 1.minute.ago)
        b.send_command_check_data_providers(@dps.map &:id) rescue true
        sent_refresh << b.name
      end
    end

    if ! refresh.blank?
      if sent_refresh.size > 0
        flash[:notice] = "Sent a request to check the Data Providers to these servers: #{sent_refresh.join(", ")}\n" +
                         "This will be done in background and can take several minutes before the reports are ready."
      else
        flash[:notice] = "No refresh needed, access information is recent enough."
      end
      redirect_to :action => :rr_access_dp  # try again, without the 'refresh' param
    end

  end

  
  private
  
  # Adds sensible default values to some field for
  # new objects, or existing ones being edited.
  def sensible_defaults(portal_or_bourreau)
    if portal_or_bourreau.is_a?(BrainPortal)
      if portal_or_bourreau.site_url_prefix.blank?
        guess = "http://" + request.env["HTTP_HOST"] + "/"
        portal_or_bourreau.site_url_prefix = guess
      end
    end

    if portal_or_bourreau.dp_ignore_patterns.nil? # not blank, nil!
      portal_or_bourreau.dp_ignore_patterns = [ ".DS_Store", "._*" ]
    end
  end

end
