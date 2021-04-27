# ifood2-rails
New IFood's api integration

Requires gem 'dotenv-rails', and 'rest-client'

Create a .env file in your app's directory with this content

    IFOOD_CLIENT_ID=<your client id here>
    IFOOD_CLIENT_TOKEN=<your client secret here>
    
Create a model named IfoodMerchant:

    rails g model IfoodMerchant user_code:string auth_code:string auth_code_verifier:string token:string expiry:datetime refresh_token:string merchant_id:string merchant_name:string
    
Create a model named IfoodOrder (and add a reference to your "Comanda" model):

    rails g model IfoodOrder uuid:string:uniq short_reference:string status:string scheduled:datetime address_json:text order_json:text <comanda:references>
    
I use 'status' attribute as an Enum of 'pending', 'accepted', 'rejected', 'producing', 'produced', 'delivering', 'delivered', etc...
    
Place ifood2.rb in your app/lib/ folder, and create ifood2_integration.rb also in app/lib/ folder.

The reason I did not upload ifood2_integration.rb is because it contains the inner workings of my own app, with my models and their attributes. As it varies from project to project, it's your job to implement ifood2_integration.rb based on ifood2.rb function calls. I always like to provide examples, so this is a very short snippet of my Ifood2Integration class:

    class Ifood2Integration

      ####################### ORDER-RELATED ##############################
      def create_order order_json
        if order_json.class == String
          order_json = JSON.parse(order_json)
        end

        existing = IfoodOrder.where(uuid: order_json["id"]).last

        if existing.present?
          # do nothing
        else
          params = {
            uuid: order_json["id"],
            short_reference: order_json["displayId"],
            scheduled: order_json["schedule"].present? ? order_json["schedule"]["deliveryDateTimeStart"] : nil,
            address_json: order_json["delivery"].present? ? order_json["delivery"]["deliveryAddress"].to_json : nil,
            order_json: order_json.to_json
          }
          existing = IfoodOrder.create!(params)
        end

        return existing
      end
      def accept_order ifood_order
        if !ifood_order || ifood_order.status != "pending"
          return
        end
        order_json = JSON.parse(ifood_order.order_json)


        # discount is a coupon that's sponsored by the RESTAURANT, not ifood.
        discount = 0
        if order_json["benefits"].present?
          order_json["benefits"].each do |coupon|
            coupon["sponsorshipValues"].each do |sponsorship_value|
              discount += sponsorship_value["value"] if sponsorship_value["name"] == "MERCHANT"
            end
          end
        end

        customer = fetch_customer(order_json)
        bill_name = "#{customer.name} - IFOOD \##{order_json["displayId"] || ifood_order.id}"
        if order_json["schedule"].present? && order_json["schedule"]["deliveryDateTimeStart"].present?
          bill_name += " (AGENDADO)"
        end
        params = {
          name: bill_name,
          customer_id: customer.id,
          description: gen_description(order_json, customer, discount),
          delivery_fee: order_json["total"]["deliveryFee"] || 0,
          discount: discount
        }

        bill = Bill.create!(params)
        create_items(order_json, bill)
        create_payments(order_json, bill)

        ifood_order.update!(bill_id: bill.id)
        PrintItems.print_bill(bill)

        return bill
      end
      
      ...
    
