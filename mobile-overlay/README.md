# mobile-overlay

Go source for the `mobile` package that wraps the upstream MasterDnsVPN client
in a `gomobile bind`-friendly API.

This is kept **outside** of `upstream/` so the upstream submodule stays a clean
mirror of `masterking32/MasterDnsVPN`. Before running `gomobile bind`, the
build scripts and CI workflow copy these files into `upstream/mobile/` so that
the `internal/` packages of the upstream module are visible to them.

See `scripts/build-local.sh` and `.github/workflows/ios-build.yml` for the
exact copy step.
