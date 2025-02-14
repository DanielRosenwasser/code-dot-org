require "base64"
require "queries/lti"
require "services/lti"
require "policies/lti"
require "concerns/partial_registration"
require "clients/lti_advantage_client"
require "cdo/honeybadger"

class LtiV1Controller < ApplicationController
  # Don't require an authenticity token because LTI Platforms POST to this
  # controller.
  skip_before_action :verify_authenticity_token

  # [GET/POST] /lti/v1/login(/:platform_id)
  #
  # Most LTI Platforms should send a client_id as part of the login request.
  # However, it is not required per the LTI 1.3 spec. In these cases, we can
  # supply clients with a unique login URL (with a platform_id), so we can
  # identify the caller's identity. The requst will always contain the iss param,
  # as required by the LTI 1.3 standard
  # https://www.imsglobal.org/spec/security/v1p0/#step-1-third-party-initiated-login
  def login
    if params[:client_id]
      query_params = {client_id: params[:client_id], issuer: params[:iss]}
    elsif params[:platform_id]
      query_params = {platform_id: params[:platform_id]}
    else
      return log_unauthorized(
        'Missing required parameters for LTI authentication',
        {
          client_id: params[:client_id],
          issuer: params[:iss],
          platform_id: params[:platform_id],
        }
      )
    end

    lti_integration = LtiIntegration.find_by(query_params)
    return log_unauthorized('LTI integration not found', query_params) unless lti_integration

    state_and_nonce = create_state_and_nonce
    # set cache key as state value, since we get this back in the final response
    # from the LTI Platform, and can use it to query for these values in the
    # authenticate controller action.
    begin
      write_cache(state_and_nonce[:state], state_and_nonce)
    rescue => exception
      Honeybadger.notify(exception, context: {message: 'Error writing state and nonce to cache'})
      return render status: :internal_server_error
    end

    auth_redirect_url = URI(lti_integration[:auth_redirect_url])
    auth_redirect_url.query = {
      scope: 'openid',
      response_type: 'id_token',
      client_id: lti_integration[:client_id],
      redirect_uri: CDO.studio_url('/lti/v1/authenticate', CDO.default_scheme),
      login_hint:  params[:login_hint],
      lti_message_hint: params[:lti_message_hint].to_s, # Required by Canvas
      state: state_and_nonce[:state],
      response_mode: 'form_post',
      nonce: state_and_nonce[:nonce],
      prompt: 'none',
    }.to_query

    redirect_to auth_redirect_url.to_s
  end

  def authenticate
    id_token = params[:id_token]
    return log_unauthorized('Missing LTI ID token') unless id_token
    begin
      decoded_jwt_no_auth = JSON::JWT.decode(id_token, :skip_verification)
    rescue => exception
      return log_unauthorized(exception)
    end
    # client_id is the aud[ience] in the JWT
    extracted_client_id = decoded_jwt_no_auth[:aud]
    extracted_issuer_id = decoded_jwt_no_auth[:iss]

    integration = LtiIntegration.find_by({client_id: extracted_client_id, issuer: extracted_issuer_id})
    if integration.nil?
      return log_unauthorized('LTI integration not found', {client_id: extracted_client_id, issuer: extracted_issuer_id})
    end

    # check state and nonce in response and id_token against cached values
    begin
      cached_state_and_nonce = read_cache params[:state]
    rescue => exception
      Honeybadger.notify(exception, context: {message: 'Error reading state and nonce from cache'})
      return render status: :internal_server_error
    end
    if (params[:state] != cached_state_and_nonce[:state]) || (decoded_jwt_no_auth[:nonce] != cached_state_and_nonce[:nonce])
      return log_unauthorized(
        'State or nonce mismatch in LTI JWT auth',
        {
          state: params[:state],
          nonce: decoded_jwt_no_auth[:nonce],
          cached_state: cached_state_and_nonce[:state],
          cached_nonce: cached_state_and_nonce[:nonce],
        }
      )
    end

    begin
      # verify the jwt via the integration's public keyset
      decoded_jwt = get_decoded_jwt(integration, id_token)
    rescue => exception
      return log_unauthorized(exception)
    end

    jwt_verifier = JwtVerifier.new(decoded_jwt, integration)

    if jwt_verifier.verify_jwt
      message_type = decoded_jwt[:'https://purl.imsglobal.org/spec/lti/claim/message_type']
      return wrong_resource_type unless message_type == 'LtiResourceLinkRequest'

      user = Queries::Lti.get_user(decoded_jwt)
      target_link_uri = decoded_jwt[:'https://purl.imsglobal.org/spec/lti/claim/target_link_uri']

      launch_context = decoded_jwt[Policies::Lti::LTI_CONTEXT_CLAIM]
      nrps_url = decoded_jwt[Policies::Lti::LTI_NRPS_CLAIM][:context_memberships_url]
      resource_link_id = decoded_jwt[Policies::Lti::LTI_RESOURCE_LINK_CLAIM][:id]
      deployment_id = decoded_jwt[Policies::Lti::LTI_DEPLOYMENT_ID_CLAIM]
      deployment = Queries::Lti.get_deployment(integration.id, deployment_id)
      redirect_params = {
        lti_integration_id: integration.id,
        deployment_id: deployment.id,
        context_id: launch_context[:id],
        rlid: resource_link_id,
        nrps_url: nrps_url,
      }

      if user
        sign_in user
        redirect_to "#{target_link_uri}?#{redirect_params.to_query}"
      else
        user = Services::Lti.initialize_lti_user(decoded_jwt)
        PartialRegistration.persist_attributes(session, user)
        session[:user_return_to] = "#{target_link_uri}?#{redirect_params.to_query}"
        redirect_to new_user_registration_url
      end
    else
      jwt_error_message = jwt_verifier.errors.empty? ? 'Invalid JWT' : jwt_verifier.errors.join(', ')
      return log_unauthorized('Invalid JWT', {errors: jwt_error_message})
    end
  end

  def get_decoded_jwt(integration, id_token)
    public_jwk_url = integration.jwks_url
    response = JSON.parse(HTTParty.get(public_jwk_url).body)
    jwk_set = JSON::JWK::Set.new response
    JSON::JWT.decode(id_token, jwk_set)
  end

  def render_sync_course_error(message, status)
    @lti_section_sync_result = {error: message}
    Honeybadger.notify(
      'LTI roster sync error',
      context: {
        reason: message,
      }
    )
    return respond_to do |format|
      format.html do
        render lti_v1_sync_course_path, status: status
      end
      format.json {render json: @lti_section_sync_result, status: status}
    end
  end

  # GET /lti/v1/sync_course
  # Syncs an LMS course from an LTI launch or from the teacher dashboard sync button.
  # It can respond to either HTML or JSON content requests.
  def sync_course
    return unauthorized_status unless current_user
    unless current_user.teacher?
      return redirect_to home_path
    end
    params.require([:lti_integration_id, :deployment_id, :context_id, :rlid, :nrps_url]) if params[:section_code].blank?

    lti_course, lti_integration, deployment_id, context_id, resource_link_id, nrps_url = nil
    if params[:section_code].present?
      # Section code present, meaning this is a sync from the teacher dashboard.
      # Populate vars from the section associated with the input code.
      lti_course = Queries::Lti.get_lti_course_from_section_code(params[:section_code])
      unless lti_course
        return render_sync_course_error('We couldn\'t find the given section.', :bad_request)
      end
      lti_integration = lti_course.lti_integration
      deployment_id = lti_course.lti_deployment_id
      context_id = lti_course.context_id
      resource_link_id = lti_course.resource_link_id
      nrps_url = lti_course.nrps_url
    else
      # Section code isn't present, meaning this is a sync from an LTI launch.
      # Populate vars from the request params.
      begin
        lti_integration = LtiIntegration.find(params[:lti_integration_id])
      rescue
        return render_sync_course_error('LTI Integration not found', :bad_request)
      end
      deployment_id = params[:deployment_id]
      context_id = params[:context_id]
      resource_link_id = params[:rlid]
      nrps_url = params[:nrps_url]
    end

    result = {
      all: {},
      changed: {}
    }

    had_changes = false
    ActiveRecord::Base.transaction do
      lti_course ||= Queries::Lti.find_or_create_lti_course(
        lti_integration_id: lti_integration.id,
        context_id: context_id,
        deployment_id: deployment_id,
        nrps_url: nrps_url,
        resource_link_id: resource_link_id
      )

      lti_advantage_client = LtiAdvantageClient.new(lti_integration.client_id, lti_integration.issuer)
      nrps_response = lti_advantage_client.get_context_membership(nrps_url, resource_link_id)
      nrps_sections = Services::Lti.parse_nrps_response(nrps_response)

      sync_course_roster_results = Services::Lti.sync_course_roster(lti_integration: lti_integration, lti_course: lti_course, nrps_sections: nrps_sections, section_owner_id: current_user.id)
      had_changes ||= sync_course_roster_results

      # Report which sections were updated
      nrps_sections.each do |section_id, section|
        result[:all][section_id] = {
          name: section[:name],
          size: section[:members].size,
        }
      end
    end

    @lti_section_sync_result = result

    respond_to do |format|
      format.html do
        if had_changes || params[:force]
          render lti_v1_sync_course_path
        else
          redirect_to home_path
        end
      end
      format.json {render json: result}
    end
  end

  # POST /lti/v1/integrations
  # Creates a new LtiIntegration
  def create_integration
    begin
      params.require([:client_id, :lms, :email])
    rescue
      render status: :bad_request, json: {error: I18n.t('lti.error.missing_params')}
      return
    end

    client_id = params[:client_id]
    platform_name = params[:lms]
    admin_email = params[:email]

    unless Policies::Lti::LMS_PLATFORMS.key?(platform_name.to_sym)
      render status: :bad_request, json: {error: I18n.t('lti.error.unsupported_lms_type')}
      return
    end

    platform_urls = Policies::Lti::LMS_PLATFORMS[platform_name.to_sym]
    issuer = platform_urls[:issuer]
    auth_redirect_url = platform_urls[:auth_redirect_url]
    jwks_url = platform_urls[:jwks_url]
    access_token_url = platform_urls[:access_token_url]

    existing_integration = Queries::Lti.get_lti_integration(issuer, client_id)

    if existing_integration.nil?
      Services::Lti.create_lti_integration(
        client_id: client_id,
        issuer: issuer,
        platform_name: platform_name,
        auth_redirect_url: auth_redirect_url,
        jwks_url: jwks_url,
        access_token_url: access_token_url,
        admin_email: admin_email
      )
      render status: :ok, json: {body: I18n.t('lti.create_integration_success')}
    else
      render status: :conflict, json: {error: I18n.t('lti.error.integration_exists')}
    end
  end

  private

  NAMESPACE = 'lti_v1_controller'.freeze

  def unauthorized_status
    render(status: :unauthorized, json: {error: 'Unauthorized'})
  end

  def wrong_resource_type
    render(status: :not_acceptable, json: {error: I18n.t('lti.error.wrong_resource_type')})
  end

  def create_state_and_nonce
    state = generate_random_string 10
    nonce = Digest::SHA2.hexdigest(generate_random_string(10))

    {state: state, nonce: nonce}
  end

  def write_cache(key, value)
    # TODO: Add error handling
    CDO.shared_cache.write("#{NAMESPACE}/#{key}", value.to_json, expires_in: 1.minute)
  end

  def read_cache(key)
    # TODO: Add error handling
    json_value = CDO.shared_cache.read("#{NAMESPACE}/#{key}")
    JSON.parse(json_value).symbolize_keys
  end

  def generate_random_string(length)
    SecureRandom.alphanumeric length
  end

  def log_unauthorized(exception, context = nil)
    Honeybadger.notify(
      exception,
      context: context
    )
    unauthorized_status
  end
end
