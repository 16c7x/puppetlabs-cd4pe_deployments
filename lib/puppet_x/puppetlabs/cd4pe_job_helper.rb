require 'puppet_x'
require 'json'

module PuppetX::Puppetlabs
  # A class to help with the job creation / running process for CD4PE
  class CD4PEJobHelper < Object
    attr_reader :docker_run_args

    MANIFEST_TYPE = { 
      :JOB => "JOB", 
      :AFTER_JOB_SUCCESS => "AFTER_JOB_SUCCESS", 
      :AFTER_JOB_FAILURE => "AFTER_JOB_FAILURE" }

    def initialize(working_dir:, docker_image: nil, docker_run_args: nil)
      @docker_image = docker_image
      @docker_run_args = docker_run_args
      @docker_based_job = !docker_image.nil?
      @working_dir = working_dir

      @local_jobs_dir = File.join(@working_dir, "cd4pe_job", "jobs", "unix")
      @local_repo_dir = File.join(@working_dir, "cd4pe_job", "repo")
      
      @docker_run_args = docker_run_args.nil? ? '' : docker_run_args.join(' ')
    end

    def set_job_env_vars(task_params)
      ENV["WEB_UI_ENDPOINT"] = task_params['cd4pe_web_ui_endpoint']
      ENV["JOB_TOKEN"] = task_params['cd4pe_token']
      ENV["JOB_OWNER"] = task_params['cd4pe_job_owner']
      ENV["JOB_INSTANCE_ID"] = task_params['job_instance_id']
    
      user_specified_env_vars = task_params['env_vars']
      if (!user_specified_env_vars.nil?)
        user_specified_env_vars.each do |var|
          pair = var.split("=")
          key = pair[0]
          value = pair[1]
          ENV[key] = value
      end
    end

    def make_working_dir(working_dir)
      Dir.mkdir(working_dir) unless File.exists?(working_dir)
    end

    def get_job_script_and_control_repo
      target_file = File.join(@working_dir, "cd4pe_job.tar.gz")
      client = PuppetX::Puppetlabs::CD4PEClient.new
      response = client.get_job_script_and_control_repo(target_file)
      case response
      when Net::HTTPNotFound
        raise "Message: #{response.body}\nCode: #{response.code}"
      when Net::HTTPServerError
        raise "Unknown HTTP Error with code: #{response.code} and body #{response.body}"
      end

      target_file
    end

    def run_job
      result = execute_manifest(MANIFEST_TYPE[:JOB])
      
      if (result[:exit_code] == 0)
        on_job_complete(result, MANIFEST_TYPE[:AFTER_JOB_SUCCESS])
      else
        on_job_complete(result, MANIFEST_TYPE[:AFTER_JOB_FAILURE])
      end
    end

    def on_job_complete(result, next_manifest_type)
      output = {}
      output[:job] = {
        exit_code: result[:exit_code], 
        message: result[:message]
      }
    
      # if a AFTER_JOB_SUCCESS or AFTER_JOB_FAILURE script exists, run it now!
      run_followup_script = File.exists?(File.join(@local_jobs_dir, next_manifest_type))
      if (run_followup_script)
        @@logs.push("#{next_manifest_type} script specified.")
        followup_script_result = execute_manifest(next_manifest_type)
        output[next_manifest_type.downcase] = {
          exit_code: followup_script_result[:exit_code], 
          message: followup_script_result[:message]
        }
      end
    
      output
    end

    def execute_manifest(manifest_type)
      @@logs.push("Executing #{manifest_type} manifest.")
      result = {}
      if (@docker_based_job)
        @@logs.push("Docker image specified. Running #{manifest_type} manifest on docker image: #{@docker_image}.")
        result = run_with_docker(manifest_type)
      else
        @@logs.push("No docker image specified. Running #{manifest_type} manifest directly on machine.")
        result = run_with_system(manifest_type)
      end
      
      if (result[:exit_code] == 0)
        @@logs.push("#{manifest_type} succeeded!")
      else 
        @@logs.push("#{manifest_type} failed with exit code: #{result[:exit_code]}: #{result[:message]}")
      end
      result
    end
    
    def run_with_system(manifest_type)
      local_job_script = File.join(@local_jobs_dir, manifest_type)
      run_system_cmd(local_job_script)
    end

    def get_docker_run_cmd(manifest_type)
      repo_volume_mount = "#{@local_repo_dir}:/repo"
      scripts_volume_mount = "#{@local_jobs_dir}:/cd4pe_job"
      docker_bash_script = "/cd4pe_job/#{manifest_type}"
      "docker run #{@docker_run_args} -v #{repo_volume_mount} -v #{scripts_volume_mount} #{@docker_image} #{docker_bash_script}"
    end
    
    def run_with_docker(manifest_type)
      docker_cmd = get_docker_run_cmd(manifest_type)
      run_system_cmd(docker_cmd)
    end
    
    def run_system_cmd(cmd)
      output = ''
      exit_code = 0
    
      Open3.popen2e(cmd) do |stdin, stdout_stderr, wait_thr|
        exit_code = wait_thr.value.exitstatus
        output = stdout_stderr.read
      end
    
      { :exit_code => exit_code, :message => output }
    end

    def blank?(str)
      str.nil? || str.empty?
    end
  
    end
  end
end
