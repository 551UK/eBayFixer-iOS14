# eBayFixer iOS 14

Compatibility tweak for eBay 6.96.0 on rootful iOS 14.

Version 1.0.14 tests the original native Home flow instead of redirecting its requests to the newer VLP service. The version/update bypass and diagnostic capture remain enabled.

Build and package validation do not confirm live Home loading. Item loading remains under investigation. Both IPAs still need to be compared; this release is based on the source and supplied logs.

Install the deb from Releases, then fully close and reopen eBay. If Home still fails, send the new eBayFixer log and HOME response.
