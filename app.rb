#
# Ruby Text-to-Speech Starter - Backend Server
#
# This is a simple Sinatra server that provides a text-to-speech API endpoint
# powered by Deepgram's Text-to-Speech service. It's designed to be easily
# modified and extended for your own projects.
#
# Key Features:
# - Contract-compliant API endpoint: POST /api/text-to-speech
# - Accepts text in body and model as query parameter
# - Returns binary audio data (audio/mpeg)
# - CORS enabled for frontend communication
# - JWT session auth with rate limiting (production only)
# - Pure API server (frontend served separately)
#

require 'sinatra/base'
require 'sinatra/cross_origin'
require 'json'
require 'jwt'
require 'net/http'
require 'uri'
require 'securerandom'
require 'toml-rb'
require 'dotenv/load'

# ============================================================================
# SECTION 1: CONFIGURATION - Customize these values for your needs
# ============================================================================

#
# Default text-to-speech model to use when none is specified.
# Options: "aura-2-thalia-en", "aura-2-theia-en", "aura-2-andromeda-en", etc.
# See: https://developers.deepgram.com/docs/text-to-speech-models
#
DEFAULT_MODEL = 'aura-2-thalia-en'

# ============================================================================
# SECTION 2: SESSION AUTH - JWT tokens for production security
# ============================================================================

#
# Session secret for signing JWTs.
# Auto-generated if SESSION_SECRET env var is not set.
#
SESSION_SECRET = ENV['SESSION_SECRET'] || SecureRandom.hex(32)

# JWT expiry time (1 hour)
JWT_EXPIRY = 3600

# ============================================================================
# SECTION 3: API KEY LOADING - Load Deepgram API key from .env
# ============================================================================

#
# Loads the Deepgram API key from environment variables.
# Exits with a helpful error message if not found.
#
def load_api_key
  api_key = ENV['DEEPGRAM_API_KEY']

  unless api_key && !api_key.empty?
    $stderr.puts "\n  ERROR: Deepgram API key not found!\n"
    $stderr.puts "Please set your API key using one of these methods:\n"
    $stderr.puts "1. Create a .env file (recommended):"
    $stderr.puts "   DEEPGRAM_API_KEY=your_api_key_here\n"
    $stderr.puts "2. Environment variable:"
    $stderr.puts "   export DEEPGRAM_API_KEY=your_api_key_here\n"
    $stderr.puts "Get your API key at: https://console.deepgram.com\n"
    exit 1
  end

  api_key
end

API_KEY = load_api_key

# ============================================================================
# SECTION 4: SETUP - Initialize Sinatra application and middleware
# ============================================================================

class App < Sinatra::Base
  configure do
    enable :cross_origin
    set :bind, ENV['HOST'] || '0.0.0.0'
    set :port, (ENV['PORT'] || 8081).to_i
  end

  # Enable CORS on all responses (wildcard is safe -- same-origin via
  # Vite proxy / Caddy in production)
  before do
    response.headers['Access-Control-Allow-Origin'] = '*'
    response.headers['Access-Control-Allow-Methods'] = 'GET, POST, OPTIONS'
    response.headers['Access-Control-Allow-Headers'] = 'Content-Type, Authorization'
  end

  # Handle CORS preflight requests
  options '*' do
    status 204
    body ''
  end

  # ============================================================================
  # SECTION 5: HELPER FUNCTIONS - Validation and error formatting utilities
  # ============================================================================

  #
  # Validates that text was provided in the request body.
  # Returns true if text is a non-empty string.
  #
  def validate_text_input(text)
    text.is_a?(String) && !text.strip.empty?
  end

  #
  # Formats error responses in a consistent structure matching the contract.
  # Returns a hash with statusCode and body keys.
  #
  def format_error_response(message, status_code = 500, error_code = nil)
    err_type = status_code == 400 ? 'ValidationError' : 'GenerationError'

    unless error_code
      msg = message.downcase
      if status_code == 400
        if msg.include?('empty')
          error_code = 'EMPTY_TEXT'
        elsif msg.include?('model')
          error_code = 'MODEL_NOT_FOUND'
        elsif msg.include?('long')
          error_code = 'TEXT_TOO_LONG'
        else
          error_code = 'INVALID_TEXT'
        end
      else
        error_code = 'INVALID_TEXT'
      end
    end

    {
      statusCode: status_code,
      body: {
        error: {
          type: err_type,
          code: error_code,
          message: message,
          details: {
            originalError: message
          }
        }
      }
    }
  end

  # ============================================================================
  # SECTION 6: AUTH MIDDLEWARE - JWT validation for protected routes
  # ============================================================================

  #
  # Validates JWT from Authorization header.
  # Halts with 401 JSON error if token is missing or invalid.
  #
  def require_session!
    auth_header = request.env['HTTP_AUTHORIZATION']

    unless auth_header && auth_header.start_with?('Bearer ')
      halt 401, { 'Content-Type' => 'application/json' }, {
        error: {
          type: 'AuthenticationError',
          code: 'MISSING_TOKEN',
          message: 'Authorization header with Bearer token is required'
        }
      }.to_json
    end

    token = auth_header.sub('Bearer ', '')
    begin
      JWT.decode(token, SESSION_SECRET, true, algorithm: 'HS256')
    rescue JWT::ExpiredSignature
      halt 401, { 'Content-Type' => 'application/json' }, {
        error: {
          type: 'AuthenticationError',
          code: 'INVALID_TOKEN',
          message: 'Session expired, please refresh the page'
        }
      }.to_json
    rescue JWT::DecodeError
      halt 401, { 'Content-Type' => 'application/json' }, {
        error: {
          type: 'AuthenticationError',
          code: 'INVALID_TOKEN',
          message: 'Invalid session token'
        }
      }.to_json
    end
  end

  # ============================================================================
  # SECTION 7: DEEPGRAM API CLIENT - Direct HTTP calls to Deepgram REST API
  # ============================================================================

  #
  # Calls the Deepgram Text-to-Speech API with the given text and model.
  # Returns raw binary audio data on success, or raises an error.
  #
  def call_deepgram_tts(text, model)
    uri = URI("https://api.deepgram.com/v1/speak?model=#{URI.encode_www_form_component(model)}")

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 120
    http.open_timeout = 30

    req = Net::HTTP::Post.new(uri)
    req['Authorization'] = "Token #{API_KEY}"
    req['Content-Type'] = 'application/json'
    req.body = { text: text }.to_json

    response = http.request(req)

    unless response.is_a?(Net::HTTPSuccess)
      error_body = begin
        JSON.parse(response.body)
      rescue StandardError
        { 'message' => response.body }
      end
      error_msg = error_body['err_msg'] || error_body['message'] || "Deepgram API returned status #{response.code}"
      raise error_msg
    end

    response.body
  end

  # ============================================================================
  # SECTION 8: SESSION ROUTES - Auth endpoints (unprotected)
  # ============================================================================

  #
  # GET /api/session - Issues a signed JWT for session authentication.
  #
  get '/api/session' do
    content_type :json

    payload = {
      iat: Time.now.to_i,
      exp: Time.now.to_i + JWT_EXPIRY
    }

    token = JWT.encode(payload, SESSION_SECRET, 'HS256')
    { token: token }.to_json
  end

  # ============================================================================
  # SECTION 9: API ROUTES - Define your API endpoints here
  # ============================================================================

  #
  # POST /api/text-to-speech
  #
  # Contract-compliant text-to-speech endpoint per starter-contracts specification.
  # Accepts:
  # - Query parameter: model (optional, defaults to aura-2-thalia-en)
  # - Body: JSON with text field (required)
  #
  # Returns:
  # - Success (200): Binary audio data (audio/mpeg)
  # - Error (4XX): JSON error response matching contract format
  #
  # Protected by JWT session auth (require_session!).
  #
  post '/api/text-to-speech' do
    require_session!

    # Parse JSON body
    begin
      body = JSON.parse(request.body.read)
    rescue JSON::ParserError
      err = format_error_response('Invalid JSON in request body', 400, 'INVALID_TEXT')
      halt err[:statusCode], { 'Content-Type' => 'application/json' }, err[:body].to_json
    end

    # Get model from query parameter (contract specifies query param, not body)
    model = params['model'] || DEFAULT_MODEL
    text = body['text']

    # Validate input - text is required
    if text.nil?
      err = format_error_response('Text parameter is required', 400, 'EMPTY_TEXT')
      halt err[:statusCode], { 'Content-Type' => 'application/json' }, err[:body].to_json
    end

    unless validate_text_input(text)
      err = format_error_response('Text must be a non-empty string', 400, 'EMPTY_TEXT')
      halt err[:statusCode], { 'Content-Type' => 'application/json' }, err[:body].to_json
    end

    # Generate audio from text via Deepgram API
    begin
      audio_data = call_deepgram_tts(text, model)

      # Return binary audio data with proper mime type
      content_type 'audio/mpeg'
      audio_data
    rescue StandardError => e
      $stderr.puts "Text-to-speech error: #{e.message}"

      # Determine error type and status code based on error message
      status_code = 500
      error_code = nil
      error_msg = e.message.downcase

      if error_msg.include?('model') || error_msg.include?('not found')
        status_code = 400
        error_code = 'MODEL_NOT_FOUND'
      elsif error_msg.include?('too long') || error_msg.include?('length') || error_msg.include?('limit') || error_msg.include?('exceed')
        status_code = 400
        error_code = 'TEXT_TOO_LONG'
      elsif error_msg.include?('invalid') || error_msg.include?('malformed')
        status_code = 400
        error_code = 'INVALID_TEXT'
      end

      err = format_error_response(e.message, status_code, error_code)
      halt err[:statusCode], { 'Content-Type' => 'application/json' }, err[:body].to_json
    end
  end

  #
  # GET /api/metadata
  #
  # Returns metadata about this starter application from deepgram.toml.
  # Required for standardization compliance.
  #
  get '/api/metadata' do
    content_type :json

    begin
      toml_path = File.join(File.dirname(__FILE__), 'deepgram.toml')
      config = TomlRB.load_file(toml_path)

      unless config['meta']
        halt 500, { 'Content-Type' => 'application/json' }, {
          error: 'INTERNAL_SERVER_ERROR',
          message: 'Missing [meta] section in deepgram.toml'
        }.to_json
      end

      config['meta'].to_json
    rescue StandardError => e
      $stderr.puts "Error reading metadata: #{e.message}"
      halt 500, { 'Content-Type' => 'application/json' }, {
        error: 'INTERNAL_SERVER_ERROR',
        message: 'Failed to read metadata from deepgram.toml'
      }.to_json
    end
  end

  #
  # GET /health
  #
  # Simple health check endpoint.
  #
  get '/health' do
    content_type :json
    { status: 'ok' }.to_json
  end

  # ============================================================================
  # SECTION 10: SERVER START
  # ============================================================================

  def self.start!
    port = (ENV['PORT'] || 8081).to_i

    puts ''
    puts '=' * 70
    puts "  Backend API running at http://localhost:#{port}"
    puts '  GET  /api/session'
    puts '  POST /api/text-to-speech (auth required)'
    puts '  GET  /api/metadata'
    puts '  GET  /health'
    puts '=' * 70
    puts ''

    super
  end
end
