# Add to basket: supplied IPA comparison

## Inputs

IPA filenames contain spoofed versions; filenames alone do not establish the app implementation.

| Input | Examined binary | SHA-256 |
| --- | --- | --- |
| Older supplied CrackerXI IPA | `ItemProduct` | `bfe2f68730c98fe714b9a8c9270e28ae76b3c78592e0cfdbcea5d232334e34e8` |
| Supplied 6.192.0 IPA | `eBay` | `ef302a314841c2a125a392ec078e95690dede24f0a8f2a9b943b82cb1eeb409a` |

## Confirmed findings

1. `ItemProduct.AddToCartListing` / `_TtC11ItemProduct16AddToCartListing` is present in the newer main executable, with `listingID`, `selectedVariationID`, and `quantityRequested` Objective-C accessors. No file in the older app bundle contains that runtime class name. The older ItemProduct class list has no such class. The 1.0.68 fallback therefore returns NO at its class lookup on that older app.
2. Older ItemProduct at unslid address `0x248ce8` dispatches a response action. At `0x248d10` it loads `type`; it compares with ResponseActionType raw value 3. ModuleLinker at `0x6b064` maps enum value 3 to `OPERATION` (jump table at `0x10a474`, then `0x6b404`).
3. The matching branch reads the `name` selector (`__objc_selrefs` slot `0x3f2cb0`) and compares against Swift small-string `VI_ADD_TO_CART` at `0x248dd4–0x248e34`. A match calls `0x249e7c`. It does not compare against `ADD_TO_CART` on that branch.
4. The older native add flow obtains the current ViewItemDataManager listing, selected variation and customization data. At `0x24b120–0x24b138` it invokes `addListingToCart:preferredShippingCode:selectedByBuyer:itemCustomizationParams:` with the native listing. A second native call exists at `0x258c60–0x258c78`. The old API protocol description expects the older listing protocol composition, whereas the newer IPA describes `CartListingProtocol`. The two versions cannot safely share an assumed wrapper.
5. The supplied historical response log contains `name = VI_ADD_TO_CART`, `type = OPERATION`, and the visible label `Add to basket`. Its cart action need not carry an invented listing ID: the native handler obtains listing context separately. This historical log is not a fresh runtime trace from .68.
6. 1.0.68 compiled both ItemActionCompat156 (JSON rename) and RuntimeCartCompat159 (runtime getter rename). Removing only one would leave the other breaking the native dispatch.

## Change

Remove the four cart-only patch units from the build and source: ItemActionCompat156, RuntimeCartCompat159, ItemResponseCartCompat162 and DirectCartButton168. Preserve incoming native action fields instead of renaming the operation, inventing quantity/identity metadata, or issuing a second cart request with a synthetic object. All non-cart runtime source files are byte-for-byte unchanged from 1.0.68.

## Validation and limits

Static comparison confirms the missing class, native dispatch string/type, and incompatible assumed listing interface. Build workflow compiles both arm64 variants and validates package structure. These checks establish concrete defects in .68, but do not establish successful live cart requests on iOS 14. Device testing must cover a simple listing, selected variations, quantity changes, back navigation between listings, and the server result. No purchase is performed during verification.
