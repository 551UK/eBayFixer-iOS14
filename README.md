# eBayFixer iOS 14

Compatibility tweak for **eBay 6.96.0** on **rootful iOS 14**.

Current stable build: **1.0.73**

## Fixes

### Home
Restores the Home feed using eBay's newer Vertical Landing Page service while preserving the older app's expected Home configuration and supported component contract.

It also bypasses the stale Home routing gate, reconnects the native ViewModel/ModelManager flow and removes unsupported newer Home component types before the old client parses them.

### Search and item pages
Rewrites retired listing-detail v1 requests to the working v2 service and supplies the newer `itemId` / `variationId` parameter names while preserving the older parameters for compatibility.

The tweak also enables the newer native item-service path required by the current backend.

### Add to basket
Restores the confirmed-working Add to basket path.

The tweak catches the `VI_ADD_TO_CART` action before the old client drops it, then passes the active listing through eBay's own configured shopping-cart service using the ModuleLinker protocol contract required by the supplied eBay binaries. Variation IDs are preserved when present.

### Version and update checks
Bypasses the expired/update-required checks and presents the newer application version to services that require it.

DCS remains on the original **6.96.0** compatibility version because newer spoofed DCS versions are rejected, while item and cart traffic use the newer service version.

## Package
- Rootful iOS 14
- arm64 + arm64e
- Settings enable switch
- eBay Settings icon
- No diagnostic logger or test instrumentation in the release build
