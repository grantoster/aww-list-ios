# Aww List for iPhone

Finds the cutest photos of your kids in your iPhone photo library and ranks them year by year, like the Aww List web page. Everything runs on the phone with Apple's Vision framework; no photo is uploaded.

## What it does
- Scans every photo in the library (asks for photo access once). Screenshots, documents, photos without a child, and bath, pool, beach, swimwear and diaper photos are left out — along with every photo taken within 10 minutes of one, so a missed frame of a bath burst can't slip through.
- Shots less than 60 seconds apart count as one moment (2 minutes at most); the best shot is shown with a "+N similar" note.
- Each moment gets a 1–10 score from the main subject's smile (other faces count less), a second face close by, face size, and how clearly a child is the subject, scaled down for blur. Scores are spread by percentile with every year weighted equally, so 9s and 10s stay rare, a weak photo can't reach a high score, and small libraries top out at 8 or 9.
- When the scoring changes, photos are re-analyzed automatically on the next scan.
- Overall and per-year Top 20 (#1 large, #2–5 cards, #6–20 grid), a See-all grid sorted by cuteness or date, a Baby/Kid filter, a full-screen viewer with swipe, share, and "remove from list".

## Build it (Mac not required)
The included GitHub Actions workflow builds on a cloud Mac.

1. Put this folder in a GitHub repository and push to `main`. The **iOS** workflow generates the Xcode project (XcodeGen), builds the app and runs the unit tests on a simulator.
2. To send it to your iPhone through TestFlight you need an Apple Developer Program membership, then:
   - **Create the app record once:** App Store Connect → Apps → + → New App. Platform iOS, any name (e.g. "Aww List – Cutest Photos"), bundle ID: pick "Register a new bundle ID" link or use one you created at developer.apple.com → Identifiers (e.g. `com.yourname.awwlist`), SKU anything.
   - **Create an API key:** App Store Connect → Users and Access → Integrations → App Store Connect API → Team Keys → +, role **Admin** (needed for cloud signing). Download the .p8 (only downloadable once) and note the Key ID and Issuer ID.
   - **Add repository secrets** (GitHub → Settings → Secrets and variables → Actions): `APPLE_TEAM_ID` (developer.apple.com → Account → Membership), `BUNDLE_ID` (same as the app record), `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8` (paste the whole .p8 file).
3. Actions → **iOS** → Run workflow → tick "Upload a build to TestFlight".
4. After Apple finishes processing (10–30 minutes), App Store Connect → TestFlight → add yourself as an internal tester. Install the TestFlight app on the iPhone and install Aww List from there.

## Project layout
- `project.yml` – XcodeGen spec (iOS 17+, SwiftUI)
- `AwwList/Scan` – Vision analysis (`Analyzer`), scoring and burst grouping (`Scorer`), library scan (`PhotoScanner`)
- `AwwList/Model` – stored scores and ranked moments (`Library`)
- `AwwList/Views` – home list, viewer, onboarding, settings
- `AwwListTests` – scoring, calibration and burst tests
