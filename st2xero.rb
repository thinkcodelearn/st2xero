# encoding: utf-8
require 'xeroizer'
require 'yaml'
require 'csv'

TAXES = {
  "DK" => "TAX002",
  "DE" => "TAX003",
  "GB" => "OUTPUT2",
  "US" => "NONE",
  "CA" => "NONE",
  "AU" => "NONE",
}

config = YAML.load(File.read("keys.yaml"))

xero = Xeroizer::PrivateApplication.new(config['key'], config['secret'], "privatekey.pem")

paypal_account = xero.Account.all(where: { name: "Paypal GBP" }).first
stripe_account = xero.Account.all(where: { name: "Stripe" }).first
paypal_contact = xero.Contact.all(where: { name: "Paypal" }).first
stripe_contact = xero.Contact.all(where: { name: "Stripe" }).first

csv = $stdin.read

CSV.parse(csv, headers: true) do |row|
  if row["State"] == "Complete"
    # Create new contact from CSV
    email = row["Buyer Email"]
    name = row["Buyer Name"] ? "#{row["Buyer Name"]} (#{email})" : email
    country = row["Buyers Country"]
    gateway_fee = row["Gateway Fee"]
    paypal_transaction = !!row["PayPal Email"]
    account = paypal_transaction ? paypal_account : stripe_account
    gateway_contact = paypal_transaction ? paypal_contact : stripe_contact
    total = row["Amount"].to_f + row["Tax"].to_f

    puts "Searching for contacts for #{email}"
    contacts = xero.Contact.all(where: %(Name.Contains("#{email}")))
    if contacts.empty?
      puts "Not found: creating new contact"
      contact = xero.Contact.build(name: name, email_address: email)
    else
      contact = contacts.first
      contact.email_address = email
    end
    contact.add_address(type: "STREET",
                        line1: row["Buyer Address 1"],
                        line2: row["Buyer Address 2"],
                        city: row["Buyer City"],
                        region: row["Buyer Region"],
                        postal_code: row["Buyer Postcode"],
                        country: country)
    contact.is_customer = true
    contact.tax_number = row["Business VAT Number"]
    contact.save

    date = Time.parse(row["Order date/time"])
    invoice_no = "INV-SO-#{row["SendOwl Transaction ID"]}"
    if (xero.Invoice.all(where: { invoice_number: invoice_no }).empty?)
      puts "Creating new invoice #{invoice_no}"
      invoice = xero.Invoice.build(
        type: "ACCREC",
        invoice_number: invoice_no,
        date: date,
        due_date: date,
        status: "AUTHORISED"
      )
      invoice.contact = contact
      puts "Finding tax code for #{country}"
      tax_code = TAXES.fetch(country)
      invoice.add_line_item(
        quantity: 1,
        account_code: "STKS",
        unit_amount: row["Amount"],
        description: row["Item Name"],
        tax_type: tax_code,
      )
      invoice.save

      payment = xero.Payment.build(
        date: date,
        amount: "%0.2f" % total,
        invoice: invoice,
        account: account
      )
      payment.save

      puts "Adding gateway fee of #{gateway_fee}"
      fee = xero.BankTransaction.build(
        bank_account: {account_id: account.account_id},
        contact: gateway_contact,
        date: date,
        type: "SPEND",
      )
      fee.add_line_item(
        quantity: 1,
        description: "Gateway fee for #{invoice_no}",
        account_code: "STGWFEES",
        unit_amount: gateway_fee,
      )
      fee.save
    else
      puts "INVOICE #{invoice_no} already exists: remove in Xero to re-add"
    end
  end
end
