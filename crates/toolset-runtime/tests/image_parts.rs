//! Tool-result media contract, toolset runtime side.
//!
//! The toolset runtime turns image bytes into an image content part and
//! enforces the 3.5 MiB cap by erroring rather than truncating. Both the
//! script-dispatch path and the in-process builtin path must route image
//! bytes through the same seam, so it lives as one function:
//!
//!     toolset_runtime::parts::image_part_or_oversize_error(media_type, bytes)
//!         -> Result<ContentBlock, _>   // Ok = image part; Err = over-cap.
//!
//! This is the runtime's enforcing seam for the cap; testing it here keeps the
//! cap load-bearing on the real path rather than on an unused helper.

/// 3.5 MiB, the spec's exact cap: 3,670,016 bytes.
const CAP: usize = 3_670_016;

// One byte over the cap must be an error — never any image part (truncated or
// whole).
#[test]
fn image_one_byte_over_the_cap_returns_an_error_not_a_truncated_image() {
    let bytes = vec![0u8; CAP + 1];
    let result = toolset_runtime::parts::image_part_or_oversize_error("image/png", bytes);
    assert!(
        result.is_err(),
        "an over-cap image must return an error rather than any image part"
    );
}
