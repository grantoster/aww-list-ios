# Aww List for iPhone

Finds the cutest photos of your kids in your iPhone photo library and ranks them year by year, like the Aww List web page. Everything runs on the phone with Apple's Vision framework; no photo is uploaded.

## What it does
- Scans every photo in the library (asks for photo access once). Screenshots, bath and swimwear photos, documents and photos without a child are left out.
- Shots less than 60 seconds apart count as one moment; the best shot is shown with a "+N similar" note.
- Each moment gets a 1–10 score from smiles, faces together, face size and sharpness, and how clearly a child is the subject. Scores are spread across the whole library so 9s and 10s stay rare and every year competes on one scale.
- Overall and per-year Top 20 (#1 large, #2–5 cards, #6–20 grid), a See-all grid sorted by cuteness or date, a Baby/Kid filter, a full-screen viewer with swipe, share, and "remove from list".

## Build it (Mac not required)
The included GitHub Actions workflow builds on a cloud Mac.

1. Put this folder in a GitHub repository and push to `main`. The **iOS** workflow generates the Xcode project (XcodeGen), builds the app and runs the unit tests on a simulator.
2. To send it to your iPhone through TestFlight, you need an Apple Developer Program membership. Then add these repository secrets:
   - `APPLE_TEAM_ID` – 10-character Team ID (developer.apple.com → Membership)
   - `BUNDLE_ID` – e.g. `com.yourname.awwlist`
   - `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8` – an App Store Connect API key with the App Manager role (App Store Connect → Users and Access → Integrations → Keys); paste the whole .p8 file into `ASC_KEY_P8`
3. Run the **iOS** workflow manually with "Upload a build to TestFlight" ticked.
4. Install the TestFlight app on the iPhone, accept the invite, and install Aww List.

## Project layout
- `project.yml` – XcodeGen spec (iOS 17+, SwiftUI)
- `AwwList/Scan` – Vision analysis (`Analyzer`), scoring and burst grouping (`Scorer`), library scan (`PhotoScanner`)
- `AwwList/Model` – stored scores and ranked moments (`Library`)
- `AwwList/Views` – home list, viewer, onboarding, settings
- `AwwListTests` – scoring, calibration and burst tests
