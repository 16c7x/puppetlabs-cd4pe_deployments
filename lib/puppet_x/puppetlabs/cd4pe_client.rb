require 'puppet_x'
require 'net/http'
require 'uri'
require 'json'

module PuppetX::Puppetlabs
  # Provides a class for interacting with CD4PE's API
  class CD4PEClient < Object
    attr_reader :config, :owner_ajax_path

    def initialize
      uri = URI.parse(web_ui_endpoint)

      @config = {
        server: uri.host,
        port: uri.port || '8080',
        scheme: uri.scheme || 'http',
        token: deployment_token,
        deployment_id: deployment_id,
        deployment_owner: deployment_owner,
      }

      @owner_ajax_path = "/#{deployment_owner}/ajax"
    end

    def pin_nodes_to_env(nodes, node_group_id)
      payload = {
        op: 'PinNodesToGroup',
        content: {
          deploymentId: @config[:deployment_id],
          nodeGroupId: node_group_id,
          nodes: nodes,
        },
      }
      make_request(:post, @owner_ajax_path, payload.to_json)
    end

    def get_node_group(node_group_id)
      query = "?op=GetNodeGroupInfo&deploymentId=#{deployment_id}&nodeGroupId=#{node_group_id}"
      complete_path = @owner_ajax_path + query
      make_request(:get, complete_path)
    end

    def delete_node_group(node_group_id)
      payload = {
        op: 'DeleteNodeGroup',
        content: {
          deploymentId: @config[:deployment_id],
          nodeGroupId: node_group_id,
        },
      }
      make_request(:post, @owner_ajax_path, payload.to_json)
    end

    def deploy_code(environment_name, default_branch_override)
      payload = {
        op: 'DeployCode',
        content: {
          deploymentId: @config[:deployment_id],
          environmentName: environment_name,
        },
      }

      payload[:content][:defaultBranchOverride] = default_branch_override if default_branch_override
      make_request(:post, @owner_ajax_path, payload.to_json)
    end

    def get_approval_state # rubocop:disable Style/AccessorMethodName
      query = "?op=GetDeploymentApprovalState&deploymentId=#{deployment_id}"
      complete_path = @owner_ajax_path + query
      make_request(:get, complete_path)
    end

    def run_puppet(environment_name, nodes, concurrency, noop)
      run_puppet_payload = {
        op: 'RunPuppet',
        content: {
          deploymentId: @config[:deployment_id],
          environmentName: environment_name,
          nodes: nodes,
          withNoop: noop,
        },
      }
      run_puppet_payload[:content][:concurrency] = concurrency if concurrency
      make_request(:post, @owner_ajax_path, run_puppet_payload.to_json)
    end

    def get_puppet_run_status(job)
      get_job_status_payload = {
        op: 'GetPuppetRunStatus',
        content: {
          deploymentId: @config[:deployment_id],
          jobId: job,
        },
      }
      make_request(:post, @owner_ajax_path, get_job_status_payload.to_json)
    end

    def create_temp_node_group(parent_node_group_id, environment_name, is_environment_node_group)
      payload = {
        op: 'CreateTempNodeGroup',
        content: {
          deploymentId: @config[:deployment_id],
          parentNodeGroupId: parent_node_group_id,
          environmentName: environment_name,
          isEnvironmentNodeGroup: is_environment_node_group,
        },
      }
      make_request(:post, @owner_ajax_path, payload.to_json)
    end

    def delete_git_branch(branch_name)
      payload = {
        op: 'DeleteGitBranch',
        content: {
          deploymentId: @config[:deployment_id],
          branchName: branch_name,
        },
      }
      make_request(:post, @owner_ajax_path, payload.to_json)
    end

    def update_git_branch_ref(branch_name, commit_sha)
      payload = {
        op: 'UpdateGitRef',
        content: {
          deploymentId: @config[:deployment_id],
          branchName: branch_name,
          commitSha: commit_sha,
        },
      }
      make_request(:post, @owner_ajax_path, payload.to_json)
    end

    private

    def deployment_token
      token = ENV['DEPLOYMENT_TOKEN']
      raise Puppet::Error, 'Could not get token for deployment' unless token
      token
    end

    def deployment_owner
      owner = ENV['DEPLOYMENT_OWNER']
      raise Puppet::Error, 'Could not get owner for deployment' unless owner
      owner
    end

    def deployment_id
      id = ENV['DEPLOYMENT_ID']
      raise Puppet::Error, 'Could not get ID for deployment' unless id
      id
    end

    def web_ui_endpoint
      endpoint = ENV['WEB_UI_ENDPOINT']
      raise Puppet::Error, 'Could not get CD4PE Web UI Endpoint' unless endpoint
      endpoint
    end

    def make_request(type, api_url, payload = '')
      connection = Net::HTTP.new(@config[:server], @config[:port])

      headers = {
        'Content-Type' => 'application/json',
        'Authorization' => "Bearer token #{@config[:token]}",
      }

      max_attempts = 3
      attempts = 0

      while attempts < max_attempts
        attempts += 1
        begin
          Puppet.debug("cd4pe_client: requesting #{type} #{api_url}")
          case type
          when :delete
            response = connection.delete(api_url, headers)
          when :get
            response = connection.get(api_url, headers)
          when :post
            response = connection.post(api_url, payload, headers)
          when :put
            response = connection.put(api_url, payload, headers)
          else
            raise Puppet::Error, "cd4pe_client#make_request called with invalid request type #{type}"
          end
        rescue SocketError => e
          raise Puppet::Error, "Could not connect to the CD4PE service at #{service_url}: #{e.inspect}", e.backtrace
        end

        case response
        when Net::HTTPSuccess, Net::HTTPRedirection
          return response
        when Net::HTTPInternalServerError
          if attempts < max_attempts # rubocop:disable Style/GuardClause
            Puppet.debug("Received #{response} error from #{service_url}, attempting to retry. (Attempt #{attempts} of #{max_attempts})")
            Kernel.sleep(3)
          else
            raise Puppet::Error, "Received #{attempts} server error responses from the CD4PE service at #{service_url}: #{response.code} #{response.body}"
          end
        else
          return response
        end
      end
    end

    def service_url
      "#{@config[:scheme]}://#{@config[:server]}:#{@config[:port]}"
    end
  end
end
