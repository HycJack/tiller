//! Chrome's user agent and client hints. Tiller runs a Chromium build, whose
//! client hints name only Chromium, while Google Chrome's name Google Chrome
//! too. Sites that check the browser compare the two, so each page, its
//! frames in other processes and its workers get Chrome's through DevTools.

use cef::sys;
use serde_json::{Value, json};

/// The product in the user agent. Chrome only gives its major version.
pub fn product() -> String {
    format!("Chrome/{}.0.0.0", sys::CHROME_VERSION_MAJOR)
}

/// The whole user agent, as Chromium builds it around `product` on macOS.
fn user_agent() -> String {
    format!(
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) {} Safari/537.36",
        product()
    )
}

/// The brands in the order and with the made-up brand Chrome gives them
/// (`GenerateBrandVersionList` in Chromium's user_agent_utils.cc, seeded with
/// the major version), each with `version` of its own.
fn brands(major: &str, full: &str, full_versions: bool) -> Vec<Value> {
    const GREASE_CHARS: [&str; 11] = [" ", "(", ":", "-", ".", "/", ")", ";", "=", "?", "_"];
    const GREASE_VERSIONS: [&str; 3] = ["8", "99", "24"];
    const ORDERS: [[usize; 3]; 6] = [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]];
    let seed = sys::CHROME_VERSION_MAJOR as usize;
    let grease_brand = format!("Not{}A{}Brand", GREASE_CHARS[seed % 11], GREASE_CHARS[(seed + 1) % 11]);
    let grease_major = GREASE_VERSIONS[seed % 3];
    let grease_version = if full_versions { format!("{grease_major}.0.0.0") } else { grease_major.to_string() };
    let version = if full_versions { full } else { major };
    let order = ORDERS[seed % 6];
    let mut list = vec![Value::Null; 3];
    list[order[0]] = json!({ "brand": grease_brand, "version": grease_version });
    list[order[1]] = json!({ "brand": "Chromium", "version": version });
    list[order[2]] = json!({ "brand": "Google Chrome", "version": version });
    list
}

/// The macOS version as Chrome gives it, `15.3.0`.
fn platform_version() -> String {
    let v = objc2_foundation::NSProcessInfo::processInfo().operatingSystemVersion();
    format!("{}.{}.{}", v.majorVersion, v.minorVersion, v.patchVersion)
}

/// Parameters for `Emulation.setUserAgentOverride` and, in workers,
/// `Network.setUserAgentOverride`.
pub fn override_params() -> Value {
    let major = sys::CHROME_VERSION_MAJOR.to_string();
    let full = format!(
        "{}.{}.{}.{}",
        sys::CHROME_VERSION_MAJOR,
        sys::CHROME_VERSION_MINOR,
        sys::CHROME_VERSION_BUILD,
        sys::CHROME_VERSION_PATCH
    );
    json!({
        "userAgent": user_agent(),
        "userAgentMetadata": {
            "brands": brands(&major, &full, false),
            "fullVersionList": brands(&major, &full, true),
            "fullVersion": full,
            "platform": "macOS",
            "platformVersion": platform_version(),
            "architecture": if cfg!(target_arch = "aarch64") { "arm" } else { "x86" },
            "model": "",
            "mobile": false,
            "bitness": "64",
            "wow64": false,
            "formFactors": ["Desktop"],
        },
    })
}
