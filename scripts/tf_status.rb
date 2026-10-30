# Prints the newest TestFlight builds and uploads with their state as GitHub annotations (read-only).
require "spaceship"
require "net/http"
require "json"
token = Spaceship::ConnectAPI::Token.create(key_id: ENV.fetch("ASC_KEY_ID"),
  issuer_id: ENV.fetch("ASC_ISSUER_ID"), key: ENV.fetch("ASC_KEY_P8"))
Spaceship::ConnectAPI.token = token
app = Spaceship::ConnectAPI::App.find(ENV.fetch("AWW_BUNDLE_ID"))
resp = Spaceship::ConnectAPI.get_builds(filter: { app: app.id }, includes: "buildBetaDetail", sort: "-uploadedDate", limit: 5)
resp.to_models.each do |b|
  puts "::notice::build #{b.version} processing=#{b.processing_state} uploaded=#{b.uploaded_date}"
end
def get(path, token)
  uri = URI("https://api.appstoreconnect.apple.com#{path}")
  req = Net::HTTP::Get.new(uri); req["Authorization"] = "Bearer #{token.text}"
  r = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |h| h.request(req) }
  [r.code, r.body]
end
code, body = get("/v1/buildUploads?filter[app]=#{app.id}&sort=-uploadedDate&limit=4", token)
if code == "200"
  JSON.parse(body)["data"].each do |u|
    a = u["attributes"] || {}
    st = a["state"]; errs = (st.is_a?(Hash) ? (st["errors"] || []).map { |e| "#{e['code']}: #{e['description']}" }.join(" | ") : "")
    puts "::notice::upload #{a['cfBundleVersion']} state=#{st.is_a?(Hash) ? st['state'] : st} uploaded=#{a['uploadedDate']} #{errs}"[0, 900]
  end
else
  puts "::notice::buildUploads #{code} #{body[0, 300]}"
end
