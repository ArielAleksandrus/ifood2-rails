class Ifood2
	###### Domain-specific errors ######
	class IfoodNotReadyError < StandardError
		def message
			"Ifood2 lib: IfoodMerchant not created"
		end
	end
	class IfoodTokenExpiredError < StandardError
		def message
			"Ifood2 lib: Token has expired"
		end
	end
	class IfoodServerError < StandardError
		def message
			"Ifood2 lib: Ifood server error"
		end
	end
	################################

	# Constants
	@@api_url = "https://merchant-api.ifood.com.br"
	@@client_id = ENV['IFOOD_CLIENT_ID']
	@@client_token = ENV['IFOOD_CLIENT_TOKEN']

	# Attributes
	attr_accessor :merchant_id, :merchant_name
	attr_accessor :token, :expiry, :status
	attr_accessor :initted, :ifood2_integration

	def initialize
		get_token()

		if self.status == 'ok'
			get_merchant()
			self.initted = true
			self.ifood2_integration = Ifood2Integration.new
		end
	end

	###### MERCHANT INTEGRATION TO NCOMMERCE ######
	def self.is_ready?
		return IfoodMerchant.last.present? && IfoodMerchant.last.is_ready?
	end
	def self.gen_code
		url = @@api_url + "/authentication/v1.0/oauth/userCode"

		response = RestClient.post(url, {clientId: @@client_id})
		json = JSON.parse(response.body)

		im = IfoodMerchant.last
		if im.present?
			im.update!(user_code: json["userCode"], auth_code_verifier: json["authorizationCodeVerifier"])
		else
			im = IfoodMerchant.create(user_code: json["userCode"], auth_code_verifier: json["authorizationCodeVerifier"])
		end

		return json["verificationUrlComplete"]
	end
	def self.store_auth_code auth_code
		IfoodMerchant.last.update(auth_code: auth_code)
	end
	#############################

	###### TOKEN HANDLING ######
	def get_token
		unless Ifood2.is_ready?
			raise IfoodNotReadyError
		end

		im = IfoodMerchant.last
		if im.token.present?
			self.token = im.token
			self.expiry = im.expiry

			if im.expiry > Time.now + 40.minutes # refresh token 40 minutes prior to expiration
				self.status = "ok"
			else
				begin
					return refresh_token()
				rescue IfoodTokenExpiredError => e
					self.status = "expired"
				end
			end
		else
			generate_token
		end

		return {token: token, expiry: expiry, status: status}
	end
	def generate_token
		im = IfoodMerchant.last
		response = RestClient.post(@@api_url + "/authentication/v1.0/oauth/token", {
			grantType: "authorization_code",
			clientId: @@client_id,
			clientSecret: @@client_token,
			authorizationCode: im.auth_code,
			authorizationCodeVerifier: im.auth_code_verifier
		})

		json = JSON.parse(response.body)
		im.update!(token: json["accessToken"], expiry: Time.now + json["expiresIn"].seconds, refresh_token: json["refreshToken"])
		
		self.token = json["accessToken"]
		self.expiry = Time.now + json["expiresIn"].seconds
		self.status = "ok"

		return {token: token, expiry: expiry, status: status}

	end
	def refresh_token
		return nil unless Ifood2.is_ready?

		im = IfoodMerchant.last

		begin
			response = RestClient.post(@@api_url + "/authentication/v1.0/oauth/token", {
				grantType: "refresh_token",
				clientId: @@client_id,
				clientSecret: @@client_token,
				refreshToken: im.refresh_token
			})

			json = JSON.parse(response.body)
			im.update!(token: json["accessToken"], expiry: Time.now + json["expiresIn"].seconds, refresh_token: json["refreshToken"])
			self.token = json["accessToken"]
			self.expiry = Time.now + json["expiresIn"].seconds
			self.status = "ok"

			return {token: token, expiry: expiry, status: status}
		rescue RestClient::ExceptionWithResponse => e
			if e.response.code >= 500 && e.response.code <= 599
				Rails.logger.error e.message
				raise IfoodServerError
			elsif e.response.code >= 400 && e.response.code <= 499
				Rails.logger.error e.message
				raise IfoodTokenExpiredError
			else
				Rails.logger.error e.message
				raise e
			end
		end
	end
	def get_headers
		return {
			"Content-Type": "application/json",
			"Authorization": "Bearer " + self.token
		}
	end
	#############################

	###### Merchant handling ######
	def get_merchant
		return nil unless Ifood2.is_ready?

		im = IfoodMerchant.last
		unless im.merchant_id.present?
			response = RestClient.get(@@api_url + "/merchant/v1.0/merchants", get_headers())
			json = JSON.parse(response.body)
			merchant = json[0]

			im.update!(merchant_id: merchant["id"], merchant_name: merchant["name"])
		end

		self.merchant_id = im.merchant_id
		self.merchant_name = im.merchant_name
		return {merchant_id: merchant_id, merchant_name: merchant_name}
	end
	def availability
		return nil unless Ifood2.is_ready?

		response = RestClient.get(@@api_url + "/merchant/v1.0/merchants/#{merchant_id}/status", get_headers())
		availabilities = JSON.parse response.body

		res = {available: true, messages: []}

		availabilities.each do |availability|
			availability["validations"].each do |validation|
				res[:messages] << validation
				if ["OK", "WARNING"].exclude? validation["state"]
					res[:available] = false
				end
			end
		end

		return res
	end
	def list_interruptions
		response = RestClient.get(@@api_url + "/merchant/v1.0/merchants/#{merchant_id}/interruptions", get_headers())
		return JSON.parse(response.body)
	end
	def remove_interruptions
		interruptions = list_interruptions()

		interruptions.each do |interruption|
			response = RestClient.delete(@@api_url + "/merchant/v1.0/merchants/#{merchant_id}/interruptions/#{interruption["id"]}", get_headers())

			return false if response.code != 204
		end

		return true
	end
	def pause
		response = RestClient.post(@@api_url + "/merchant/v1.0/merchants/#{merchant_id}/interruptions", {
			id: "pausa-manual-" + Time.now.to_i.to_s,
			description: "Pausa Manual",
			start: Time.now.strftime("%Y-%m-%dT%T"),
			end: (Time.now + 4.hours).strftime("%Y-%m-%dT%T")
		}, get_headers())
		return response.code == 201
	end
	def unpause
		remove_interruptions()
	end
	#############################

	###### Events handling ######
	def treat_events
		events = poll_events()

		events.each do |event|
			case event["fullCode"]
			when "PLACED"
				ifood_order = ifood2_integration.create_order(fetch_order(event["orderId"]))
			when "CONFIRMED"
				ifood_order = IfoodOrder.where(uuid: event["orderId"]).last

				if ifood_order.blank?
					ifood_order = ifood2_integration.create_order(self.fetch_order(event["orderId"]))
				end

				if ifood_order.present? && ifood_order.status == 'pending'
					success = ifood2_integration.accept_order(ifood_order)
					ifood_order.update(status: 'accepted') # do not use ifood_order.accept! as it has already been accepted by 'gestor de pedidos'
				end
			when "CANCELLATION_REQUESTED"
				ifood_order = IfoodOrder.where(uuid: event["orderId"]).take
				ifood2_integration.request_order_cancellation(ifood_order, "customer")
			when "CANCELLED"
				ifood2_integration.cancel_order(event["orderId"])
			when "CONCLUDED"
				ifood2_integration.finish_order(event["orderId"])
			when "ASSIGN_DRIVER"
				ifood2_integration.deliverer_req_success(event["orderId"], fetch_deliverer_json(event["orderId"]))
			when "REQUEST_DRIVER_FAILED"
				ifood2_integration.deliverer_req_failed(event["orderId"])
			when "COLLECTED"
				ifood2_integration.deliverer_in_transit(event["orderId"])
			when "DELIVERED"
				ifood2_integration.order_delivered(event["orderId"])
			end
		end
		
		ack_events(events)
	end
	def fetch_deliverer_json event
		return event["metadata"]
	end
	def poll_events
		return unless @initted

		begin
			response = RestClient.get(@@api_url + "/order/v1.0/events:polling", get_headers())

			if response.code == 204
				return []
			else
				return JSON.parse(response.body)
			end
		rescue RestClient::ExceptionWithResponse => e
			if e.response.code >= 500 && e.response.code <= 599
				Rails.logger.error e.message
				raise IfoodServerError
			elsif e.response.code >= 400 && e.response.code <= 499
				Rails.logger.error e.message
				raise IfoodTokenExpiredError
			else
				Rails.logger.error e.message
				raise e
			end
		end
	end
	def ack_events events
		return if events.blank?

		# yes, Ifood has written 'acknowledgement' wrong
		url = @@api_url + "/order/v1.0/events/acknowledgment"

		params = []
		events.each do |event|
			params << {
				id: event["id"]
			}
		end

		response = RestClient.post(url, params.to_json, get_headers())

		return response.code == 202
	end
	#############################


	###### Order handling ######
	def fetch_order orderId
		url = @@api_url + "/order/v1.0/orders/#{orderId}"

		response = RestClient.get(url, get_headers())

		order = JSON.parse(response.body)

		return order
	end

	def accept_order ifood_order
		url = @@api_url + "/order/v1.0/orders/#{ifood_order.uuid}/confirm"
		response = RestClient.post(url, {}, get_headers())
		if response.code == 202
			ifood2_integration.accept_order(ifood_order)
			return true
		else
			return false
		end
	end
	def reject_order ifood_order
		cancel_order(ifood_order)
	end
	def cancel_order ifood_order, reason = "DIFICULDADES INTERNAS DO RESTAURANTE", code = "509"
		url = @@api_url + "/order/v1.0/orders/#{ifood_order.uuid}/requestCancellation"
		response = RestClient.post(url, {
			reason: reason,
			cancellationCode: code
		}.to_json, get_headers())
		return response.code == 202
	end

	def accept_customer_cancellation ifood_order, return_to_stock = true
		url = @@api_url + "/order/v1.0/orders/#{ifood_order.uuid}/acceptCancellation"
		response = RestClient.post(url, {}, get_headers())

		success = response.code == 202
		if success
			ifood2_integration.accept_order_cancellation(ifood_order, return_to_stock)
		end
		return success
	end
	def reject_customer_cancellation ifood_order
		url = @@api_url + "/order/v1.0/orders/#{ifood_order.uuid}/denyCancellation"
		response = RestClient.post(url, {}, get_headers())

		success = response.code == 202
		if success
			ifood2_integration.deny_order_cancellation(ifood_order)
		end
		return success
	end
	#############################

	###### Delivery handling ######
	def inform_pickup ifood_order
		url = @@api_url + "/order/v1.0/orders/#{ifood_order.uuid}/readyToPickup"
		response = RestClient.post(url, {}, get_headers())
		return response.code == 202
	end
	def inform_takeout ifood_order
		url = @@api_url + "/order/v1.0/orders/#{ifood_order.uuid}/readyToPickup"
		response = RestClient.post(url, {}, get_headers())
		return response.code == 202
	end
	def request_ifood_deliverer ifood_order
		url = @@api_url + "/order/v1.0/orders/#{ifood_order.uuid}/dispatch"
		response = RestClient.post(url, {}, get_headers())
		return response.code == 202
	end
	def inform_delivery ifood_order
		url = @@api_url + "/order/v1.0/orders/#{ifood_order.uuid}/dispatch"
		response = RestClient.post(url, {}, get_headers())
		return response.code == 202
	end
	#############################
end
