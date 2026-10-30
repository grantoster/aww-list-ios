# Prints the newest TestFlight builds and their processing state as GitHub annotations (read-only).
require "spaceship"
Spaceship::ConnectAPI.token = Spaceship::ConnectAPI::Token.create(key_id: ENV.fetch("ASC_KEY_ID"),
  issuer_id: ENV.fetch("ASC_ISSUER_ID"), key: ENV.fetch("ASC_KEY_P8"))
app = Spaceship::ConnectAPI::App.find(ENV.fetch("AWW_BUNDLE_ID"))
resp = Spaceship::ConnectAPI.get_builds(filter: { app: app.id }, includes: "buildBetaDetail", sort: "-uploadedDate", limit: 8)
resp.to_models.each do |b|
  d = b.build_beta_detail
  puts "::notice::build #{b.version} processing=#{b.processing_state} internal=#{d&.internal_build_state} uploaded=#{b.uploaded_date}"
end
