require 'lockfile'
require 'net/ssh'
require 'tempfile'
require 'tmpdir'
require 'stringio'

require 'gitolite_conf.rb'
require 'gitolite_recycle.rb'
require 'git_adapter_hooks.rb'


module GitHosting
        LOCK_WAIT_IF_UNDEF = 10                # In case settings not migrated (normally from settings)
	REPOSITORY_IF_UNDEF = "repositories/"  # In case settings not migrated (normally from settings)

	# Used to register errors when pulling and pushing the conf file
  	class GitHostingException < StandardError
        end

        # Time in seconds to wait before giving up on acquiring the lock
        def self.lock_wait_time
        	Setting.plugin_redmine_git_hosting['gitLockWaitTime'].to_i || LOCK_WAIT_IF_UNDEF
        end
        
        # Repository base path (relative to git user home directory)
        def self.repository_base
        	Setting.plugin_redmine_git_hosting['gitRepositoryBasePath'] || REPOSITORY_IF_UNDEF
        end

        @@logger = nil
	def self.logger
        	@@logger ||= MyLogger.new
	end

	@@web_user = nil
	def self.web_user
		if @@web_user.nil?
			@@web_user = (%x[whoami]).chomp.strip
		end
		return @@web_user
	end

        def self.web_user=(setuser)
        	@@web_user = setuser
        end

	def self.git_user
		Setting.plugin_redmine_git_hosting['gitUser']
	end

	@@mirror_pubkey = nil
	def self.mirror_push_public_key
		if @@mirror_pubkey.nil?

			%x[cat '#{Setting.plugin_redmine_git_hosting['gitoliteIdentityFile']}' | #{GitHosting.git_user_runner} 'cat > ~/.ssh/gitolite_admin_id_rsa ' ]
			%x[cat '#{Setting.plugin_redmine_git_hosting['gitoliteIdentityPublicKeyFile']}' | #{GitHosting.git_user_runner} 'cat > ~/.ssh/gitolite_admin_id_rsa.pub ' ]
			%x[ #{GitHosting.git_user_runner} 'chmod 600 ~/.ssh/gitolite_admin_id_rsa' ]
			%x[ #{GitHosting.git_user_runner} 'chmod 644 ~/.ssh/gitolite_admin_id_rsa.pub' ]

			pubk =  ( %x[cat '#{Setting.plugin_redmine_git_hosting['gitoliteIdentityPublicKeyFile']}' ]  ).chomp.strip
			git_user_dir = ( %x[ #{GitHosting.git_user_runner} "cd ~ ; pwd" ] ).chomp.strip
			%x[ #{GitHosting.git_user_runner} 'echo "#{pubk}"  > ~/.ssh/gitolite_admin_id_rsa.pub ' ]
			%x[ echo '#!/bin/sh' | #{GitHosting.git_user_runner} 'cat > ~/.ssh/run_gitolite_admin_ssh']
			%x[ echo 'exec ssh -o BatchMode=yes -o StrictHostKeyChecking=no -i #{git_user_dir}/.ssh/gitolite_admin_id_rsa    "$@"' | #{GitHosting.git_user_runner} "cat >> ~/.ssh/run_gitolite_admin_ssh"  ]
			%x[ #{GitHosting.git_user_runner} 'chmod 644 ~/.ssh/gitolite_admin_id_rsa.pub' ]
			%x[ #{GitHosting.git_user_runner} 'chmod 600 ~/.ssh/gitolite_admin_id_rsa']
			%x[ #{GitHosting.git_user_runner} 'chmod 700 ~/.ssh/run_gitolite_admin_ssh']

			@@mirror_pubkey = pubk.split(/[\t ]+/)[0].to_s + " " + pubk.split(/[\t ]+/)[1].to_s

			#settings = Setting["plugin_redmine_git_hosting"]
			#settings["gitMirrorPushPublicKey"] = publicKey
			#Setting["plugin_redmine_git_hosting"] = settings
		end
		@@mirror_pubkey
	end


	@@sudo_git_to_web_user_stamp = nil
	@@sudo_git_to_web_user_cached = nil
	def self.sudo_git_to_web_user
		if not @@sudo_git_to_web_user_cached.nil? and (Time.new - @@sudo_git_to_web_user_stamp <= 0.5):
			return @@sudo_git_to_web_user_cached
		end
		logger.info "Testing if git user(\"#{git_user}\") can sudo to web user(\"#{web_user}\")"
		if git_user == web_user
			@@sudo_git_to_web_user_cached = true
			@@sudo_git_to_web_user_stamp = Time.new
			return @@sudo_git_to_web_user_cached
		end
		test = %x[#{GitHosting.git_user_runner} sudo -nu #{web_user} echo "yes" ]
		if test.match(/yes/)
			@@sudo_git_to_web_user_cached = true
			@@sudo_git_to_web_user_stamp = Time.new
			return @@sudo_git_to_web_user_cached
		end
		logger.warn "Error while testing sudo_git_to_web_user: #{test}"
		@@sudo_git_to_web_user_cached = test
		@@sudo_git_to_web_user_stamp = Time.new
		return @@sudo_git_to_web_user_cached
	end

	@@sudo_web_to_git_user_stamp = nil
	@@sudo_web_to_git_user_cached = nil
	def self.sudo_web_to_git_user
		if not @@sudo_web_to_git_user_cached.nil? and (Time.new - @@sudo_web_to_git_user_stamp <= 0.5):
			return @@sudo_web_to_git_user_cached
		end
		logger.info "Testing if web user(\"#{web_user}\") can sudo to git user(\"#{git_user}\")"
		if git_user == web_user
			@@sudo_web_to_git_user_cached = true
			@@sudo_web_to_git_user_stamp = Time.new
			return @@sudo_web_to_git_user_cached
		end
 		test = %x[#{GitHosting.git_user_runner} echo "yes"]
		if test.match(/yes/)
			@@sudo_web_to_git_user_cached = true
			@@sudo_web_to_git_user_stamp = Time.new
			return @@sudo_web_to_git_user_cached
		end
		logger.warn "Error while testing sudo_web_to_git_user: #{test}"
		@@sudo_web_to_git_user_cached = test
		@@sudo_web_to_git_user_stamp = Time.new
		return @@sudo_web_to_git_user_cached
	end

	def self.get_full_parent_path(project, is_file_path)
		parent_parts = [];
		p = project
		while p.parent
			parent_id = p.parent.identifier.to_s
			parent_parts.unshift(parent_id)
			p = p.parent
		end
		return is_file_path ? File.join(parent_parts) : parent_parts.join("/")
	end

	def self.repository_name project
		return "#{get_full_parent_path(project, false)}/#{project.identifier}".sub(/^\//, "")
	end

	def self.repository_path project
		return File.join(repository_base, repository_name(project)) + ".git"
	end

	def self.add_route_for_project(p)

		if defined? map
			add_route_for_project_with_map p, map
		else
			ActionController::Routing::Routes.draw do |map|
				add_route_for_project_with_map p, map
			end
		end
	end
	def self.add_route_for_project_with_map(p,m)
		repo = p.repository
		if repo.is_a?(Repository::Git)
			repo_name= p.parent ? File.join(GitHosting::get_full_parent_path(p, true),p.identifier) : p.identifier
			repo_path = repo_name + ".git"
			m.connect repo_path,                  :controller => 'git_http', :p1 => '', :p2 =>'', :p3 =>'', :id=>"#{p[:identifier]}", :path=>"#{repo_path}"
			m.connect repo_path,                  :controller => 'git_http', :p1 => '', :p2 =>'', :p3 =>'', :id=>"#{p[:identifier]}", :path=>"#{repo_path}"
			m.connect repo_path + "/:p1",         :controller => 'git_http', :p2 => '', :p3 =>'', :id=>"#{p[:identifier]}", :path=>"#{repo_path}"
			m.connect repo_path + "/:p1/:p2",     :controller => 'git_http', :p3 => '', :id=>"#{p[:identifier]}", :path=>"#{repo_path}"
			m.connect repo_path + "/:p1/:p2/:p3", :controller => 'git_http', :id=>"#{p[:identifier]}", :path=>"#{repo_path}"
		end
	end
	def self.get_tmp_dir
                @@git_hosting_tmp_dir ||= File.join(Dir.tmpdir, "redmine_git_hosting", "#{git_user}")
		if !File.directory?(@@git_hosting_tmp_dir)
			%x[mkdir -p "#{@@git_hosting_tmp_dir}"]
			%x[chmod 700 "#{@@git_hosting_tmp_dir}"]
			%x[chown #{web_user} "#{@@git_hosting_tmp_dir}"]
		end
		return @@git_hosting_tmp_dir
	end
	def self.get_bin_dir
        	@@git_hosting_bin_dir ||= 
                	Rails.root.join("vendor/plugins/redmine_git_hosting/bin")
		if !File.directory?(@@git_hosting_bin_dir)
                  	logger.info "Creating bin directory: #{@@git_hosting_bin_dir}, Owner #{web_user}"
			%x[mkdir -p "#{@@git_hosting_bin_dir}"]
			%x[chmod 750 "#{@@git_hosting_bin_dir}"]
			%x[chown #{web_user} "#{@@git_hosting_bin_dir}"]
		end
                if !File.directory?(@@git_hosting_bin_dir)
                	logger.error "Cannot create bin directory: #{@@git_hosting_bin_dir}"
                end
		return @@git_hosting_bin_dir
	end

	@@git_bin_dir_writeable = nil
        def self.bin_dir_writeable?(*option)
        	@@git_bin_dir_writeable = nil if option.length > 0 && option[0] == :reset
		if @@git_bin_dir_writeable == nil
                	mybindir = get_bin_dir
	                mytestfile = "#{mybindir}/writecheck"
        		if (!File.directory?(mybindir))
	                	@@git_bin_dir_writeable = false
        	        else
	        	        %x[touch "#{mytestfile}"]
                		if (!File.exists?("#{mytestfile}"))
                                	@@git_bin_dir_writeable = false
                        	else
                                	%x[rm "#{mytestfile}"]
                        		@@git_bin_dir_writeable = true
                        	end
			end
        	end
		@@git_bin_dir_writeable
        end

	def self.git_exec_path
		return File.join(get_bin_dir, "run_git_as_git_user")
	end

	def self.gitolite_ssh_path
		return File.join(get_bin_dir, "gitolite_admin_ssh")
	end
	def self.git_user_runner_path
		return File.join(get_bin_dir, "run_as_git_user")
	end


	def self.git_exec
		if !File.exists?(git_exec_path())
			update_git_exec
		end
		return git_exec_path()
	end
	def self.gitolite_ssh
		if !File.exists?(gitolite_ssh_path())
			update_git_exec
		end
		return gitolite_ssh_path()
	end
	def self.git_user_runner
		if !File.exists?(git_user_runner_path())
			update_git_exec
		end
		return git_user_runner_path()
	end


	def self.update_git_exec
		logger.info "Setting up #{get_bin_dir}"
		gitolite_key=Setting.plugin_redmine_git_hosting['gitoliteIdentityFile']

		File.open(gitolite_ssh_path(), "w") do |f|
			f.puts "#!/bin/sh"
			f.puts "exec ssh -o BatchMode=yes -o StrictHostKeyChecking=no -i #{gitolite_key} \"$@\""
		end if !File.exists?(gitolite_ssh_path())

		##############################################################################################################################
		# So... older versions of sudo are completely different than newer versions of sudo
		# Try running sudo -i [user] 'ls -l' on sudo > 1.7.4 and you get an error that command 'ls -l' doesn't exist
		# do it on version < 1.7.3 and it runs just fine.  Different levels of escaping are necessary depending on which
		# version of sudo you are using... which just completely CRAZY, but I don't know how to avoid it
		#
		# Note: I don't know whether the switch is at 1.7.3 or 1.7.4, the switch is between ubuntu 10.10 which uses 1.7.2
		# and ubuntu 11.04 which uses 1.7.4.  I have tested that the latest 1.8.1p2 seems to have identical behavior to 1.7.4
		##############################################################################################################################
		sudo_version_str=%x[ sudo -V 2>&1 | head -n1 | sed 's/^.* //g' | sed 's/[a-z].*$//g' ]
		split_version = sudo_version_str.split(/\./)
		sudo_version = 100*100*(split_version[0].to_i) + 100*(split_version[1].to_i) + split_version[2].to_i
		sudo_version_switch = (100*100*1) + (100 * 7) + 3

		File.open(git_exec_path(), "w") do |f|
			f.puts '#!/bin/sh'
			f.puts "if [ \"\$(whoami)\" = \"#{git_user}\" ] ; then"
			f.puts '	cmd=$(printf "\\"%s\\" " "$@")'
			f.puts '	cd ~'
			f.puts '	eval "git $cmd"'
			f.puts "else"
			if sudo_version < sudo_version_switch
				f.puts '	cmd=$(printf "\\\\\\"%s\\\\\\" " "$@")'
				f.puts "	sudo -u #{git_user} -i eval \"git $cmd\""
			else
				f.puts '	cmd=$(printf "\\"%s\\" " "$@")'
				f.puts "	sudo -u #{git_user} -i eval \"git $cmd\""
			end
			f.puts 'fi'
		end if !File.exists?(git_exec_path())

		# use perl script for git_user_runner so we can
		# escape output more easily
		File.open(git_user_runner_path(), "w") do |f|
			f.puts '#!/usr/bin/perl'
			f.puts ''
			f.puts 'my $command = join(" ", @ARGV);'
			f.puts ''
			f.puts 'my $user = `whoami`;'
			f.puts 'chomp $user;'
			f.puts 'if ($user eq "' + git_user + '")'
			f.puts '{'
			f.puts '	exec("cd ~ ; $command");'
			f.puts '}'
			f.puts 'else'
			f.puts '{'
			f.puts '	$command =~ s/\\\\/\\\\\\\\/g;'
			f.puts '	$command =~ s/"/\\\\"/g;'
			f.puts '	exec("sudo -u ' + git_user + ' -i eval \"$command\"");'
			f.puts '}'
		end if !File.exists?(git_user_runner_path())

		File.chmod(0550, git_exec_path())
		File.chmod(0550, gitolite_ssh_path())
		File.chmod(0550, git_user_runner_path())
		%x[chown #{web_user} -R "#{get_bin_dir}"]
	end

	@@lock_file = nil
	def self.lock(retries)
		is_locked = false
		if @@lock_file.nil?
			@@lock_file=File.new(File.join(get_tmp_dir,'redmine_git_hosting_lock'),File::CREAT|File::RDONLY)
		end

		while retries > 0
			is_locked = @@lock_file.flock(File::LOCK_EX|File::LOCK_NB) 
			retries-=1
			if (!is_locked) && retries > 0
				sleep 1
			end
		end
		return is_locked
	end

	def self.unlock
		if !@@lock_file.nil?
			@@lock_file.flock(File::LOCK_UN)
		end
	end

        def self.shell(command)
        	begin
                	my_command = "#{command} 2>&1"
                	result = %x[#{my_command}].chomp
                	code = $?.exitstatus
                rescue Exception => e
			result=e.message
                	code = -1
                end
      		if code != 0
                  	logger.error "Command failed (return #{code}): #{command}"
                  	logger.error "#{result}"
                	raise GitHostingException, "Shell Error"
                end
        end

        # Try to get a cloned version of gitolite-admin repository. 
        #
        # This code tries to recover from a variety of errors which have been observed
        # in the field, including a loss of the admin key and an empty top-level directory
        #
        # Return:    	false => have uncommitted changes 
        #		true =>  directory on master
        #
        # This routine must only be called after acquisition of the lock
       	#
       	# John Kubiatowicz, 11/15/11
	def self.clone_or_pull_gitolite_admin
		# clone/pull from admin repo
          	repo_dir = File.join(get_tmp_dir,"gitolite-admin")
        	begin
			if (File.exists? "#{repo_dir}") && (File.exists? "#{repo_dir}/.git") && (File.exists? "#{repo_dir}/keydir") && (File.exists? "#{repo_dir}/conf")
                        	logger.info "Fetching changes from gitolite-admin repository to #{repo_dir}"
                        	shell %[env GIT_SSH=#{gitolite_ssh()} git --git-dir='#{repo_dir}/.git' --work-tree='#{repo_dir}' fetch]
				shell %[env GIT_SSH=#{gitolite_ssh()} git --git-dir='#{repo_dir}/.git' --work-tree='#{repo_dir}' merge FETCH_HEAD]

                          	# unmerged changes=> non-empty return
                          	return_val = %x[env GIT_SSH=#{gitolite_ssh()} git --git-dir='#{repo_dir}/.git' --work-tree='#{repo_dir}' status --short].empty?
                        else
                        	logger.info "Cloning gitolite-admin repository to #{repo_dir}"
                        	shell %[rm -rf "#{repo_dir}"]
                        	shell %[env GIT_SSH=#{gitolite_ssh()} git clone #{git_user}@#{Setting.plugin_redmine_git_hosting['gitServer']}:gitolite-admin.git #{repo_dir}]
                          	return_val = true # on master, since fresh clone
                        end
                  	shell %[chmod 700 "#{repo_dir}" ]
                	# Make sure we have our hooks setup
			GitAdapterHooks.check_hooks_installed

                  	return return_val
                rescue
                	# Hm.... perhaps we have some other sort of failure...
  	              	logger.error "Failure to access gitolite-admin repository.  Attempting to fix..."
                	begin
                        	logger.info "  Reestablishing gitolite key"
                        	shell %[cat #{Setting.plugin_redmine_git_hosting['gitoliteIdentityPublicKeyFile']} | #{GitHosting.git_user_runner} 'cat > ~/id_rsa.pub']
                		shell %[#{GitHosting.git_user_runner} 'gl-setup ~/id_rsa.pub']
                          	shell %[#{GitHosting.git_user_runner} 'rm ~/id_rsa.pub']

                        	logger.info "  Deleting and recloning gitolite-admin to #{repo_dir}"
                          	shell %[rm -r #{repo_dir}] unless !File.exists?(repo_dir)
                        	shell %[env GIT_SSH=#{gitolite_ssh()} git clone #{git_user}@#{Setting.plugin_redmine_git_hosting['gitServer']}:gitolite-admin.git #{repo_dir}]
                        	shell %[chmod 700 "#{repo_dir}" ]
                		# Make sure we have our hooks setup
				GitAdapterHooks.check_hooks_installed
                          	logger.info "Successfully restablished access to gitolite-admin repository!"
                        rescue
				logger.error "Failure again.  Probably requires human intervention"
				raise GitHostingException, "Gitolite-admine Clone Failure"
                	end
                end
	end

        # Commit Changes to the gitolite-admin repository.  This assumes that repository exists 
        # (i.e. that a clone_or_fetch_gitolite_admin has already be called).
        #
        # This routine must only be called after acquisition of the lock
       	#
       	# John Kubiatowicz, 11/15/11
        def self.commit_gitolite_admin(*args)
		resyncing = args && args.first

		# create tmp dir, return cleanly if, for some reason, we don't have proper permissions
          	repo_dir = File.join(get_tmp_dir,"gitolite-admin")

		# commit / push changes to gitolite admin repo
        	begin
			if (!resyncing)
                        	logger.info "Committing changes to gitolite-admin repository"
                        	message = "Updated by Redmine"
                        else
                        	logger.info "Committing corrections to gitolite-admin repository"
                        	message = "Updated by Redmine: Corrections discovered during RESYNC_ALL"
                        end
			shell %[env GIT_SSH=#{gitolite_ssh()} git --git-dir='#{repo_dir}/.git' --work-tree='#{repo_dir}' add keydir/*]
			shell %[env GIT_SSH=#{gitolite_ssh()} git --git-dir='#{repo_dir}/.git' --work-tree='#{repo_dir}' add conf/gitolite.conf]
                	shell %[env GIT_SSH=#{gitolite_ssh()} git --git-dir='#{repo_dir}/.git' --work-tree='#{repo_dir}' config user.email '#{Setting.mail_from}']
			shell %[env GIT_SSH=#{gitolite_ssh()} git --git-dir='#{repo_dir}/.git' --work-tree='#{repo_dir}' config user.name 'Redmine']
                	shell %[env GIT_SSH=#{gitolite_ssh()} git --git-dir='#{repo_dir}/.git' --work-tree='#{repo_dir}' commit -a -m '#{message}']
			shell %[env GIT_SSH=#{gitolite_ssh()} git --git-dir='#{repo_dir}/.git' --work-tree='#{repo_dir}' push ]
                rescue
                	logger.error "Problems committing changes to gitolite-admin repository!! Probably requires human intervention"
                	raise GitHostingException, "Gitlite-admin Commit Failure"
                end
        end

	def self.move_repository(old_name, new_name)
		#lock
		if !lock(lock_wait_time)
                	logger.error "git_hosting: move_repository() exited without acquiring lock!"
			return
		end

		begin
			# Make sure we have gitoite-admin cloned
			clone_or_pull_gitolite_admin

			old_path = File.join(repository_base, "#{old_name}.git")
			new_path = File.join(repository_base, "#{new_name}.git")

                	logger.warn "Adjusting position of repository from '#{old_name}' to '#{new_name}' in gitolite.conf"

			# rename in conf file
			conf = GitoliteConfig.new(File.join(get_tmp_dir, 'gitolite-admin', 'conf', 'gitolite.conf'))
                	conf.rename_repo( old_name, new_name )
			conf.save

               		logger.warn "  Moving repository from '#{old_path}' to '#{new_path}' in gitolite repository"

			# physicaly move the repo BEFORE committing/pushing conf changes to gitolite admin repo
                  	prefix = new_name[/.*(?=\/)/] # Complete directory path (if exists) without trailing '/'
                  	if prefix
                        	# Has subdirectory.  Must construct destination directory
                        	repo_prefix = File.join(repository_base, prefix)
                          	GitHosting.shell %[#{git_user_runner} mkdir -p '#{repo_prefix}']
                        end
			shell %[#{git_user_runner} 'mv "#{old_path}" "#{new_path}"']

                  	# If any empty directories left behind, try to delete them.  Ignore failure.
                  	old_prefix = old_name[/.*?(?=\/)/] # Top-level old directory without trailing '/'
                  	if old_prefix
                        	repo_subpath = File.join(repository_base, old_prefix)
                        	result = %x[#{GitHosting.git_user_runner} find '#{repo_subpath}' -type d ! -regex '.*\.git/.*' -empty -depth -delete -print].chomp.split("\n")
                          	result.each { |dir| logger.warn "  Removing empty repository subdirectory: #{dir}"}
                        end

			# Commit / push changes to gitolite admin repo
			commit_gitolite_admin

                rescue GitHostingException
			logger.error "git_hosting: move_repository() failed"
                rescue => e
                  	logger.error e.message
                  	logger.error e.backtrace[0..4].join("\n")
			logger.error "git_hosting: move_repository() failed"
                end
		# unlock
		unlock()
	end

	
        # Delete repository from specified project.  
        #
        # We remove all redmine keys from the repository access rights.  
        # There are then three options:
        #
        # 1) The repo has non-redmine keys => we leave it alone
        # 2) The repo has no keys left, but repository delete is not enabled 
        #        => will leave repository alone with redmine_dummy_key
        # 3) The repo has no keys left and repository delete is enabled 
        #        => will delete repository
        def self.delete_repository(project)
		# Grab lock
		if !lock(lock_wait_time)
                       	logger.error "git_hosting: delete_repository() exited without acquiring lock!"
			return
		end

          	begin
                	# Make sure we have gitolite-admin cloned
			clone_or_pull_gitolite_admin

			repo_name = repository_name(project)

			conf = GitoliteConfig.new(File.join(get_tmp_dir, 'gitolite-admin', 'conf', 'gitolite.conf'))

                  	# Kill off redmine keys
                	conf.delete_redmine_keys repo_name

                	if Setting.plugin_redmine_git_hosting['deleteGitRepositories'] == "true"
                        	if conf.repo_has_no_keys? repo_name
	                        	logger.warn "Deleting repository '#{repo_name}' from gitolite.conf"
        	                	conf.delete_repo repo_name
                	        	GitoliteRecycle.move_repository_to_recycle repo_name
                                else
                                	logger.warn "Repository '#{repo_name}' not deleted from gitolite.conf (non-redmine keys present and preserved)"
                                end
                        else
               			logger.warn "Deleting all redmine keys for repository '#{repo_name}' from gitolite.conf"
                        end

                	conf.save
                  
			# Commit / push changes to gitolite admin repo
                	commit_gitolite_admin

                rescue GitHostingException
                	logger.error "git_hosting: delete_repository() failed" 
                rescue => e
                  	logger.error e.message
                  	logger.error e.backtrace[0..4].join("\n")
                	logger.error "git_hosting: delete_repository() failed" 
                end
		unlock()
	end

      	# Update keys for all members of projects of interest 
        #
        # This code is entirely self-correcting for keys owned by users of the specified
        # projects.  It should work regardless of the history of steps that got us here.
        # 
        # Note that this code has changed from the original.  Now, we look at all keys owned
        # by users in the specified projects to make sure that they are still live.  We 
        # do this with a single pass through the keydir and do not rely on the "inactive"
        # status to tell us that a key should be deleted.  The reason is that weird
        # synchronization issues (not entirely understood) can cause phantom keys to get left
        # in the keydir which can really mess up gitolite.
        #
        # Also, when performing :resync_all, if the 'deleteGitRepositories' setting is 'true', 
        # then we will remove repositories in the gitolite.conf file that are identifiable as 
        # "redmine managed" (because they have one or more keys of the right form) but which 
        # are nolonger live for some reason (probably because the project was deleted).
        #
        # John Kubiatowicz, 11/15/11
        #
        # Usage:
        #
        # 1) update_repositories(project) => update for specified project
        # 2) update_repositories([list of projects]) => update all projects
        # 3) update_repositories(:flag1=>true, :flag2 => false)
        #
        # Current flags:
        # 	:resync_all =>  go through all redmine-maintained gitolite repos,
        #			clean up keydir, delete unused keys, clean up gitolite.conf
	@@recursionCheck = false
	def self.update_repositories(*args)
        	flags = {}
                args.each {|arg| flags.merge!(arg) if arg.is_a?(Hash)}
        	if flags[:resync_all]
                	logger.info "Executing RESYNC_ALL operation on gitolite configuration"
                	projects = Project.active.has_module(:repository).find(:all, :include => :repository)
                else
                	projects = args.flatten.select{|p| p.is_a?(Project)}
                end
		git_projects = projects.uniq.select{|p|  p.repository.is_a?(Repository::Git) }
                return if git_projects.empty?

		if(defined?(@@recursionCheck))
			if(@@recursionCheck)
                          	# This shouldn't happen any more -- log as error
                        	logger.error "git_hosting: update_repositories() exited with positive recursionCheck flag!"
				return
			end
                end
		@@recursionCheck = true

		# Grab actual lock
		if !lock(lock_wait_time)
                       	logger.error "git_hosting: update_repositories() exited without acquiring lock!"
			@@recursionCheck = false
			return
		end

          	begin
                	# Make sure we have gitoite-admin cloned. 
			on_master = clone_or_pull_gitolite_admin

               		# Get directory for the gitolite-admin
       			repo_dir = File.join(get_tmp_dir,"gitolite-admin")

               		# Flag to indicate whether repo has changed.  If we have uncommited changes, we will commit later.
                	changed = !on_master

                        # logger.info "Updating keydirectory for projects: #{git_projects.join ', '}"
                	  	
                  	keydir = File.join(repo_dir,"keydir")
               		old_keyhash = {}
               		Dir.foreach(keydir) do |keyfile|
  				user_token = GitolitePublicKey.ident_to_user_token(keyfile)
              			if !user_token.nil?
                	               	old_keyhash[user_token] ||= []
                	               	old_keyhash[user_token] << keyfile
                	        end
                	end
	
	                git_projects.map{|proj| proj.member_principals.map(&:user).compact}.flatten.uniq.each do |cur_user|
	              		active_keys = cur_user.gitolite_public_keys.active || []
	
	                        # Remove old keys that happen to be left around
				cur_token = GitolitePublicKey.user_to_user_token(cur_user)
	                	old_keynames = old_keyhash[cur_token] || []
			        cur_keynames = active_keys.map{|key| "#{key.identifier}.pub"}
	                        (old_keynames - cur_keynames).each do |keyname|
	                               	filename = File.join(keydir,"#{keyname}")
	                               	logger.warn "Removing gitolite key: #{keyname}"
                  			%x[git --git-dir='#{repo_dir}/.git' --work-tree='#{repo_dir}' rm keydir/#{keyname}]
					changed = true
	                        end

	                        # Remove inactive keys (will already be deleted by above code)
	                        cur_user.gitolite_public_keys.inactive.each {|key| GitolitePublicKey.destroy(key.id)}
	
	                        # Add missing keys to the keydir 
	                        active_keys.each do |key|
                  			keyname = "#{key.identifier}.pub"
	                               	unless old_keynames.index(keyname)
                                               	filename = File.join(keydir,"#{keyname}")
                                               	logger.info "Adding gitolite key: #{keyname}"
						File.open(filename, 'w') {|f| f.write(key.key.gsub(/\n/,'')) }
						changed = true
					end
	                        end
              			
              			# In preparation for resync_all, below
              			old_keyhash.delete(cur_token)
	                end

			# Remove keys for deleted users
                  	if flags[:resync_all]
                        	# All keys left in old_keyhash should be for users nolonger authorized for gitolite repos
				old_keyhash.each_value do |keyname|
	                               	filename = File.join(keydir,"#{keyname}")
	                               	logger.warn "Removing orphan gitolite key: #{keyname}"
                  			%x[git --git-dir='#{repo_dir}/.git' --work-tree='#{repo_dir}' rm keydir/#{keyname}]
					changed = true
                		end
			end

			conf = GitoliteConfig.new(File.join(repo_dir, 'conf', 'gitolite.conf'))
			orig_repos = conf.all_repos
			new_repos = []
			new_projects = []
	
	        	# Regenerate configuration file for projects of interest
                        # logger.info "Updating gitolite.conf for projects: #{git_projects.join ', '}"
			git_projects.each do |proj|
	                        repo_name = repository_name(proj)
	
				#check whether we're adding a new repo
              			if orig_repos[ repo_name ] == nil
					changed = true
					add_route_for_project(proj)
					new_repos.push repo_name
					new_projects.push proj

                                	# Attempt to recover repository from recycle_bin, if present
                                	GitoliteRecycle.recover_repository_if_present repo_name
				end
	
				# fetch users
				users = proj.member_principals.map(&:user).compact.uniq
				write_users = users.select{ |user| user.allowed_to?( :commit_access, proj ) }
				read_users = users.select{ |user| user.allowed_to?( :view_changesets, proj ) && !user.allowed_to?( :commit_access, proj ) }
	
				# update users
				read_user_keys = []
				write_user_keys = []
				read_users.map{|u| u.gitolite_public_keys.active}.flatten.compact.uniq.each do |key|
					read_user_keys.push key.identifier
				end
				write_users.map{|u| u.gitolite_public_keys.active}.flatten.compact.uniq.each do |key|
					write_user_keys.push key.identifier
				end
	
				#git daemon
				if (proj.repository.extra.git_daemon == 1 || proj.repository.extra.git_daemon == nil )  && proj.is_public
					read_user_keys.push "daemon"
				end
	
				# Remove previous redmine keys, then add new keys
              			# By doing things this way, we leave non-redmine keys alone
              			conf.delete_redmine_keys repo_name
				conf.add_read_user repo_name, read_user_keys
				conf.add_write_user repo_name, write_user_keys

				# This is in preparation for full resync (below)
              			orig_repos.delete repo_name
			end
	
			# If resyncing, check for orphan repositories which still have redmine keys...
                        # At this point, orig_repos contains all repositories in original gitolite.conf
                  	# which are not part of an active redmine project.  There are four possibilities:
                  	#
                  	# 1) These repos do not have redmine keys => we leave them alone
                        # 2) They have both redmine keys and other (non-redmine) keys => remove redmine keys
                  	# 3) They have only redmine keys, but repository delete is not enabled 
                  	#        => remove redmine keys (will leave redmine_dummy_key when we save)
                  	# 4) They have only redmine keys and repository delete is enabled => delete repository
                  	#
			# Finally, delete expired files from recycle bin.
			if flags[:resync_all]
                        	orig_repos.each_key do |repo_name|
                			if conf.is_redmine_repo? repo_name 
                                        	# First, delete redmine keys for this repository
                                        	conf.delete_redmine_keys repo_name
                                        	if (Setting.plugin_redmine_git_hosting['deleteGitRepositories'] == "true") && (conf.repo_has_no_keys? repo_name)
                                                	logger.warn "Deleting orphan repository '#{repo_name}' from gitolite.conf"
                                        		conf.delete_repo repo_name
                                                	GitoliteRecycle.move_repository_to_recycle repo_name
                                                else
                                                	logger.info "Deleting redmine keys for orphan repository '#{repo_name}' from gitolite.conf"
                                                end
                                        end
                		end
                          	GitoliteRecycle.delete_expired_files
                        end

			if conf.changed?
				conf.save
				changed = true
			end
	
			if changed
                        	# Have changes. Commit / push changes to gitolite admin repo
				commit_gitolite_admin flags[:resync_all]
			end
	
			# Set post recieve hooks for new projects
			# We need to do this AFTER push, otherwise necessary repos may not be created yet
			if new_projects.length > 0
				GitAdapterHooks.setup_hooks(new_projects)
			end

                rescue GitHostingException
                	logger.error "git_hosting: update_repositories() failed" 
                rescue => e
                  	logger.error e.message
                  	logger.error e.backtrace[0..4].join("\n")
                	logger.error "git_hosting: update_repositories() failed" 
                end

		unlock()
		@@recursionCheck = false
	end

 	def self.clear_cache_for_project(project)
		if project.is_a?(Project)
			project = project.identifier
		end
		# Clear cache
		old_cached=GitCache.find_all_by_proj_identifier(project)
		if old_cached != nil
			old_ids = old_cached.collect(&:id)
			GitCache.destroy(old_ids)
		end
	end


	def self.check_hooks_installed
		installed = false
		if lock(5)
			installed = GitAdapterHooks.check_hooks_installed
			unlock()
		end
		installed
	end
	def self.setup_hooks(projects=nil)
		if lock(5)
			GitAdapterHooks.setup_hooks(projects)
			unlock()
		end
	end
	def self.update_global_hook_params
		if lock(5)
			GitAdapterHooks.update_global_hook_params
			unlock()
		end
	end

        class MyLogger
         	# Prefix to error messages
        	ERROR_PREFIX = "***> "

                # For errors, add our prefix to all messages
                def error(*progname, &block)
                	if block_given?
                          	Rails.logger.error(*progname) { "#{ERROR_PREFIX}#{yield}".gsub(/\n/,"\n#{ERROR_PREFIX}") }
                        else 
                        	Rails.logger.error "#{ERROR_PREFIX}#{progname}".gsub(/\n/,"\n#{ERROR_PREFIX}") 
                        end
                end

                # Handle everything else with base object
                def method_missing(m, *args, &block)
                	Rails.logger.send m, *args, &block
                end
        end
end

