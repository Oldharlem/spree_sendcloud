require 'spec_helper'
include ActiveMerchant::Shipping

module ActiveShipping
  describe Spree::Calculator::Shipping::Sendcloud::Base do
    WebMock.disable_net_connect!

    def set_keys(shipment, key, secret)
      calc = shipment.shipping_method.calculator
      calc.set_preference(:api_key, key)
      calc.set_preference(:api_secret, secret)
      calc.save!
    end

    let(:address) { FactoryGirl.create(:address) }
    let(:stock_location) { FactoryGirl.create(:stock_location) }
    let!(:order) do
      order = FactoryGirl.create(:order_with_line_items, :ship_address => address, :line_items_count => 2)
      order.line_items.first.tap do |line_item|
        line_item.quantity = 2
        line_item.variant.save
        line_item.variant.weight = 1
        line_item.variant.save
        line_item.save
        # product packages?
      end
      order.line_items.last.tap do |line_item|
        line_item.quantity = 2
        line_item.variant.save
        line_item.variant.weight = 2
        line_item.variant.save
        line_item.save
        # product packages?
      end
      order
    end

    let(:carrier) { ActiveMerchant::Shipping::SendCloud.new(:api_key => "API_KEY", :api_secret => "API_SECRET") }
    let(:calculator) { Spree::Calculator::Shipping::Sendcloud::PakketNederland.new }
    let(:response) { double('response', :rates => rates, :params => {}) }
    let(:package) { order.shipments.first.to_package }

    before(:each) do
      Spree::StockLocation.destroy_all
      stock_location
      order.create_proposed_shipments
      order.shipments.count.should == 1
      calculator.stub(:carrier).and_return(carrier)
      Rails.cache.clear
    end

    describe "package.order" do
      it{ expect(package.order).to eq(order) }
      it{ expect(package.order.ship_address).to eq(address) }
      it{ expect(package.order.ship_address.country.iso).to eq('US') }
      it{ expect(package.stock_location).to eq(stock_location) }
    end

    describe "available" do
      context "when rates are available" do
        let(:rates) do
          [ double('rate', :service_name => 'Pakket Nederland (PostNL)', :service_code => "Pakket Nederland (PostNL)", :price => 1) ]
        end

        before do
          carrier.should_receive(:find_rates).and_return(response)
        end

        it "should return true" do
          calculator.available?(package).should be(true)
        end

        it "should use zero as a valid weight for service" do
          calculator.stub(:max_weight_for_country).and_return(0)
          calculator.available?(package).should be(true)
        end
      end

      context "when rates are not available" do
        let(:rates) { [] }

        before do
          carrier.should_receive(:find_rates).and_return(response)
        end

        it "should return false" do
          calculator.available?(package).should be(false)
        end
      end

      context "when there is an error retrieving the rates" do
        before do
          carrier.should_receive(:find_rates).and_raise(ActiveMerchant::ActiveMerchantError)
        end

        it "should return false" do
          calculator.available?(package).should be(false)
        end
      end
    end

    describe "available?" do
      it "should not return rates if the weight requirements for the destination country are not met" do
        # if max_weight_for_country is nil -> the carrier does not ship to that country
        # if max_weight_for_country is 0 -> the carrier does not have weight restrictions to that country
        calculator.stub(:max_weight_for_country).and_return(nil)
        calculator.should_receive(:is_package_shippable?).and_raise Spree::ShippingError
        calculator.available?(package).should be(false)
      end
    end

    describe "compute" do
      let(:rates) do
        [ double('rate', :service_name => 'Pakket Nederland (PostNL)', :service_code => "Pakket Nederland (PostNL)", :price => 999) ]
      end

      context "with valid response" do
        before do
          carrier.should_receive(:find_rates).and_return(response)
        end

        it "should return rate based on calculator's service_name" do
          rate = calculator.compute(package)
          rate.should == 9.99
        end

        it "should return nil if service_name is not found in rate_hash" do
          calculator.class.should_receive(:description).and_return("Extra-Super Fast")
          rate = calculator.compute(package)
          rate.should be_nil
        end
      end
    end

    describe "create_shipment" do
      let!(:shipment) { create(:sendcloud_shipment, order: order) }
      let!(:payment) { create(:payment, amount: order.total, order: order, state: :completed) }
      before do
        country = Spree::Country.last
        country.update!(iso: 'NL', name: 'Netherlands')
        state = Spree::State.last
        state.update!(name: 'Noord-Holland')
        shipment.order.ship_address.update(zipcode: '5617BC', city: 'Eindhoven')
      end

      it "should set tracking, print_label and sendcloud parcel id" do
        set_keys(shipment, 'TEST_KEY', 'TEST_SECRET')
        VCR.use_cassette "create shipment" do
          shipment.shipping_method.calculator.create_shipment(shipment)
          expect(shipment.tracking).to eql('3SYZXG114161295')
          expect(shipment.print_link).to eql('https://panel.sendcloud.nl/api/v2/labels/label_printer/410656?hash=70286456cab252a543dae6be5037592a4d8c6e40')
          expect(shipment.sendcloud_parcel_id).to eql(410656)
        end
      end

      it "should return false when bad api key is provided" do
        set_keys(shipment, 'WRONG_KEY', 'WRONG_SECRET')
        VCR.use_cassette "create shipment without valid key" do
          expect{
            shipment.shipping_method.calculator.create_shipment(shipment)
          }.to raise_error
        end
      end
    end

    describe "service_name" do
      it "should return description when not defined" do
        calculator.class.service_name.should == calculator.description
      end
    end
  end
end
