# Building Scarf

Scarf is a native macOS app built with Xcode. For contributor builds, use the local script:

```bash
./scripts/local-build.sh
```

Requirements:

- macOS with Xcode selected by `xcode-select`
- Xcode 16.0 or newer
- Metal toolchain installed

If the Metal toolchain is missing, the script will offer to install it in interactive shells. You can also install it manually:

```bash
xcodebuild -downloadComponent MetalToolchain
```

`scripts/local-build.sh` resolves Swift package dependencies, detects `arm64` vs `x86_64`, and builds the Debug app unsigned. Signing is intentionally disabled for local Debug builds so contributors do not need the maintainer's Apple Developer account.

Release signing is separate from contributor builds. Maintainers should continue using the existing release process for signed distributable builds.
