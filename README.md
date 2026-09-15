# eBayFixer iOS 14

Compatibility tweak for **eBay 6.96.0** on **rootful iOS 14**.

This project restores the parts of the old eBay app that stopped working after eBay retired or changed several backend services used by 6.96.0.

## What it fixes

### Home
The original Home request used by eBay 6.96.0 no longer works. The tweak moves Home onto eBay's newer Vertical Landing Page service while keeping the old app's expected F90 Home configuration and supported component contract.

The old app also gets stuck behind its `HomeHotSwapper` path, so the Home ViewModel never asks the native ModelManager to fetch and publish the page. The tweak rebinds the original 6.96.0 ViewModel and calls its native ModelManager fetch directly. eBay's own parser, models and UI then render the Home feed normally.

A small compatibility pass removes a few newer nested Home component types that do not exist in the 6.96.0 client.

### Search / item pages
Search results themselves still use the old app UI, but opening item data relies on retired listing-detail requests. The tweak moves those old v1 listing-detail requests to the newer v2 endpoints and adds the newer `itemId` / `variationId` parameter names while keeping the old parameters in place for compatibility.

It also enables the old app's native newer item-service feature path where required.

### Version checks
The tweak bypasses the expired/update-required checks and presents a newer app version to the services that require it. DCS is kept on the real **6.96.0** version because newer spoofed DCS versions are rejected by the server.
