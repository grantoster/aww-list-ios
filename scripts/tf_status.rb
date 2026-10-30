# Prints the newest TestFlight builds and their processing state as GitHub annotations (read-only).
require "spaceship"
token = Spaceship::ConnectAPI::Token.create(key_id: ENV.fetch("ASC_KEY_ID"), issuer_id: ENV.fetch("ASC_ISSUER_ID"),
                                            key: ENV.fetch("ASC_KEY_P8"))
Spaceship::ConnectAPI.token = token
app = Spaceship::ConnectAPI::App.find(ENV.fetch("AWW_BUNDLE_ID"))
builds = Spaceship::ConnectAPI::Build.all(app_id: app.id, sort: "-uploadedDate", limit: 6, includes: "buildBetaDetail")
builds.each do |b|
  d = b.build_beta_detail
  puts "::notice::build #{b.version} processing=#{b.processing_state} internal=#{d&.internal_build_state} external=#{d&.external_build_state} uploaded=#{b.uploaded_date} expired=#{b.expired}"
end
