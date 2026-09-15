# eBayFixer iOS 14

Compatibility tweak for **eBay 6.96.0** on rootful iOS 14.

## Fixes
- **Home:** moves the retired Home request to eBay's VLP service, forces the 6.96 F90 Home route, and bypasses the stale HomeHotSwapper gate so the native ModelManager actually fetches and publishes the Home feed.
- **Search / items:** moves old listing-detail requests to the newer v2 endpoints and adds the newer item/variation parameter names expected by the service.
- Bypasses the old app update/kill-switch checks while keeping DCS on the real 6.96.0 version.

Settings includes an **Enabled** switch and a link to this GitHub repo. No respring button is needed; fully close and reopen eBay after changing the switch.
