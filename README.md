# eBayFixer iOS 14

Native compatibility patch for the real eBay 6.96.0 app on rootful iOS 14.

- Spoofs the app version as 6.273.0 and removes the expired/update-required prompt.
- Keeps eBay's DCS `1.0.0-seed` config version untouched.
- Forces the newer VLP Home flow already built into 6.96.0 instead of the old Bullseye path.
- Forces View Item onto the native `listing_details/v2` / RaptorIO path used by the newer 6.192.0 app.
- Leaves Apollo's own client-version header alone.
- Uses native eBay screens only; there is no web-view fallback.

For this test build, focused Home/Search/View Item diagnostics are written to the app Documents folder as `eBayFixer.log`.

The fix was derived by comparing the supplied eBay 6.96.0 iOS 14 IPA against the supplied eBay 6.192.0 iOS 16 IPA.